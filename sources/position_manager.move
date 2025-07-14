module liquid_nation::position_manager {
    use std::signer;
    use std::string::String;
    use std::vector;
    use std::error;
    use std::timestamp;
    use aptos_std::table::{Self, Table};
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::coin;
    use supra_framework::event;
    use supra_oracle::supra_oracle_storage;
    use liquid_nation::treasury_pool;
    use liquid_nation::fee_controller;


    // ======================================================================================================================================================
    //                                                                          CONSTANTS
    // ======================================================================================================================================================


    /// Maximum allowed leverage
    const MAX_LEVERAGE: u8 = 100;
    /// Profit capped at 500%
    const PROFIT_CAP: u64 = 500;
    /// Minimum wager set to 1 USD
    const MIN_WAGER: u64 = 10^18;
    /// 100% represented in basis points
    const PERCENTAGE_PRECISION: u64 = 10000;
    /// Maximum value for u64
    const U64_MAX: u64 = 18446744073709551615;


    /// Comprehensive error codes for all contract operations
    /// Caller not authorised
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Invalid leverage amount
    const E_INVALID_LEVERAGE: u64 = 2;
    /// Invalid amount as wager
    const E_INVALID_WAGER: u64 = 3;
    /// Contract is paused
    const E_PAUSED: u64 = 4;
    /// Position does not exist
    const E_POSITION_NOT_FOUND: u64 = 5;
    /// Position is closed
    const E_POSITION_CLOSED: u64 = 6;
    /// Pool does not have sufficient balance
    const E_INSUFFICIENT_POOL_BALANCE: u64 = 7;
    /// Stale price from oracle
    const E_ORACLE_PRICE_STALE: u64 = 8;
    /// Position already exists
    const E_POSITION_ALREADY_EXISTS: u64 = 9;
    /// Token is not supported
    const E_UNSUPPORTED_TOKEN: u64 = 10;
    /// Asset does not match with the position 
    const E_INVALID_ASSET: u64 = 11;
    /// Insufficient payout amount
    const E_INSUFFICIENT_PAYOUT: u64 = 12;
    /// Invalid input for address
    const E_INVALID_ADDRESS: u64 = 13; 


    // ======================================================================================================================================================
    //                                                                          STRUCTS
    // ======================================================================================================================================================

    /// Represents a trade position
    struct Position has store, copy, drop {
        trader: address,
        asset: String,
        pair_id: u32,
        amount_wagered: u64,
        leverage: u8,
        entry_price: u64,
        liquidation_price: u64,
        target_price: u64,
        timestamp_opened: u64,
        is_long: bool,
        is_closed: bool,
        exit_price: u64,
        payout_amount: u64,
    }

    /// Global storage for trade positions and contract configuration
    struct PositionManager has key {
        positions: Table<u64, Position>,
        user_positions: Table<address, vector<u64>>,
        position_counter: u64,
        admin: address,
        paused: bool,
        automation_account: address,
    }

    /// Signer capability storage
    struct ResourceAccountCapability has key {
        signer_cap: SignerCapability,
    }


    // ======================================================================================================================================================
    //                                                                          EVENTS
    // ======================================================================================================================================================


    #[event]
    /// Emitted when a trade position is opened
    struct PositionOpened has drop, store {
        position_id: u64,
        trader: address,
        asset: String,
        amount_wagered: u64,
        leverage: u8,
        entry_price: u64,
        is_long: bool,
        timestamp: u64,
        liquidation_price: u64,
        target_price: u64,
    }

    #[event]
    /// Emitted when a trade position is closed
    struct PositionClosed has drop, store {
        position_id: u64,
        trader: address,
        exit_price: u64,
        payout_amount: u64,
        pnl_percentage: u64,
        timestamp: u64,
    }

    #[event]
    /// Emitted when a trade position is liquidated
    struct PositionLiquidated has drop, store {
        position_id: u64,
        trader: address,
        liquidation_price: u64,
        timestamp: u64,
    }

    #[event]
    /// Emitted when the admin is updated
    struct AdminUpdated has drop, store {
        old_admin: address,
        new_admin: address,
        timestamp: u64,
    }

    // ======================================================================================================================================================
    //                                                                      HELPER FUNCTIONS
    // ======================================================================================================================================================


    /// Initializes the module with required resources
    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);

        // Create resource account for position manager
        let (resource_signer, signer_cap) = account::create_resource_account(admin, b"position_manager");

        // Move the capability to the resource account
        move_to(&resource_signer, ResourceAccountCapability {
            signer_cap,
        });
        
        // Move PositionManager to resource account
        move_to(&resource_signer, PositionManager {
            positions: table::new(),
            user_positions: table::new(),
            position_counter: 0,
            admin: admin_addr,
            paused: false,
            automation_account: @automation_account,
        });
    }

    /// Calculates the liquidation price
    fun calculate_liquidation_price(entry_price: u64, leverage: u8, is_long: bool): u64 {
        assert!(leverage > 0 && leverage <= MAX_LEVERAGE, error::invalid_argument(E_INVALID_LEVERAGE));

        let ratio = PERCENTAGE_PRECISION / (leverage as u64);

        if (is_long) {
            // entry * (1 - 1/leverage)
            (entry_price * (PERCENTAGE_PRECISION - ratio)) / PERCENTAGE_PRECISION
        } else {
            // entry * (1 + 1/leverage)
            (entry_price * (PERCENTAGE_PRECISION + ratio)) / PERCENTAGE_PRECISION
        }

    }

    /// Calculates the target price
    fun calculate_target_price(entry_price: u64, leverage: u8, is_long: bool): u64 {
        assert!(leverage > 0 && leverage <= MAX_LEVERAGE, error::invalid_argument(E_INVALID_LEVERAGE));

        let price_movement_percentage = (PROFIT_CAP * PERCENTAGE_PRECISION) / (leverage as u64);

        if (is_long) {
            (entry_price * (PERCENTAGE_PRECISION + price_movement_percentage)) / PERCENTAGE_PRECISION
        } else {
            (entry_price * (PERCENTAGE_PRECISION - price_movement_percentage)) / PERCENTAGE_PRECISION
        }
    }

    /// Calculates if a user is in profit/loss, payout amount and profit/loss percentage
    /// 0 represents profit and 1 represents loss
    fun calculate_payout(
        amount_wagered: u64,
        leverage: u8,
        entry_price: u64,
        current_price: u64,
        is_long: bool
    ): (u8, u64, u64) {
        // No price change - return original wager
        if (current_price == entry_price) {
            return (0, amount_wagered, 0)
        };

        // Pre-calculate leverage values
        let leverage_u64 = (leverage as u64);
        let leverage_precision = leverage_u64 * PERCENTAGE_PRECISION;

        // Determine profit/loss and price change based on the three cases
        let (is_profit, price_change_abs) = if (current_price > entry_price) {
            // Price went up
            (is_long, current_price - entry_price)
        } else {
            // Price went down (current_price < entry_price)
            (!is_long, entry_price - current_price)
        };

        // Overflow protection
        assert!(price_change_abs <= U64_MAX / leverage_precision, error::invalid_argument(E_INVALID_WAGER));

        // Calculate leveraged PnL percentage
        let leveraged_pnl_percentage = (price_change_abs * leverage_precision) / entry_price;

        if (is_profit) {
            // Profit case: cap at maximum allowed profit
            let capped_pnl = if (leveraged_pnl_percentage > PROFIT_CAP * 100) {
                PROFIT_CAP * 100
            } else {
                leveraged_pnl_percentage
            };
            let payout = amount_wagered + ((amount_wagered * capped_pnl) / PERCENTAGE_PRECISION);
            (0, payout, capped_pnl)
        } else {
            // Loss case: check for liquidation
            if (leveraged_pnl_percentage >= PERCENTAGE_PRECISION) {
                (1, 0, PERCENTAGE_PRECISION)    // Complete liquidation
            } else {
                let loss_amount = (amount_wagered * leveraged_pnl_percentage) / PERCENTAGE_PRECISION;
                let remaining = if (loss_amount >= amount_wagered) {
                    0
                } else {
                    amount_wagered - loss_amount
                };
                (1, remaining, leveraged_pnl_percentage)
            }
        }
    }

    /// Checks if position is liquidated
    fun check_liquidation(position: &Position, current_price: u64): bool {
        if (position.is_long) {
            current_price <= position.liquidation_price
        } else {
            current_price >= position.liquidation_price
        }
    }

    /// Checks if profit cap is hit
    fun check_profit_cap(position: &Position, current_price: u64): bool {
        if (position.is_long) {
            current_price >= position.target_price
        } else {
            current_price <= position.target_price
        }
    }

    /// Fetches oracle price and validates it
    fun get_and_validate_oracle_price(pair_id: u32): (u64, u16) {
        let (current_price, price_decimals, price_timestamp, _) = supra_oracle_storage::get_price(pair_id);
        assert!(current_price > 0 && timestamp::now_seconds() - price_timestamp <= 10, error::invalid_state(E_ORACLE_PRICE_STALE));
        ((current_price as u64), price_decimals)
    }

    /// Internal helper function to distribute payout and fees 
    fun distribute_payout_and_fees<CoinType>(position: &mut Position, position_id: u64, current_price: u64, payout_amount: u64, pnl_percentage: u64) {
        let fee_amount = fee_controller::calculate_fee(payout_amount);
        assert!(fee_amount <= payout_amount, error::invalid_state(E_INSUFFICIENT_PAYOUT));
        let net_payout = payout_amount - fee_amount;

        // Update position
        position.is_closed = true;
        position.exit_price = current_price;
        position.payout_amount = net_payout;
        
        // Handle payout
        if (net_payout > 0) {
            let payout_coins = treasury_pool::withdraw_payout<CoinType>(net_payout, position.amount_wagered);

            coin::deposit(position.trader, payout_coins);
        };

        // Distribute fees
        if (fee_amount > 0) {
            fee_controller::distribute_fee<CoinType>(fee_amount);
        };

        // Emit event
        event::emit(PositionClosed {
            position_id,
            trader: position.trader,
            exit_price: current_price,
            payout_amount: net_payout,
            pnl_percentage,
            timestamp: timestamp::now_seconds(),
        });
    }


    // ======================================================================================================================================================
    //                                                                   TRADE MANAGEMENT
    // ======================================================================================================================================================


    /// Opens a new position
    public entry fun open_position<CoinType>(
        trader: &signer,
        amount_wagered: u64,
        leverage: u8,
        is_long: bool,
        pair_id: u32
    ) acquires PositionManager {
        let trader_addr = signer::address_of(trader);
        let position_manager = borrow_global_mut<PositionManager>(get_resource_account_address());
        
        assert!(!position_manager.paused, error::permission_denied(E_PAUSED));
        assert!(leverage >= 1 && leverage <= MAX_LEVERAGE, error::invalid_argument(E_INVALID_LEVERAGE));
        assert!(treasury_pool::is_token_supported<CoinType>(), error::invalid_argument(E_UNSUPPORTED_TOKEN));

        // Get current price from oracle
        let (entry_price, price_decimals) = get_and_validate_oracle_price(pair_id);
        let usd_value = treasury_pool::calculate_usd_value(amount_wagered, coin::decimals<CoinType>(), (entry_price as u128), price_decimals);
        assert!(usd_value >= MIN_WAGER, error::invalid_argument(E_INVALID_WAGER));

        if (table::contains(&position_manager.user_positions, trader_addr)) {
            let user_positions = table::borrow(&position_manager.user_positions, trader_addr);
            let positions_len = vector::length(user_positions);
            let i = 0;
            while (i < positions_len) {
                let existing_position_id = *vector::borrow(user_positions, i);
                let existing_position = table::borrow(&position_manager.positions, existing_position_id);
                assert!(
                    existing_position.is_closed,
                    error::invalid_state(E_POSITION_ALREADY_EXISTS)
                );
                i = i + 1;
            };
        };

        let max_payout = amount_wagered + ((amount_wagered * PROFIT_CAP) / 100);
        
        // Check if pool can cover max payout
        assert!(
            treasury_pool::can_cover_payout<CoinType>(max_payout),
            error::resource_exhausted(E_INSUFFICIENT_POOL_BALANCE)
        );

        // Calculate liquidation and target prices
        let entry_price_u64 = (entry_price as u64);
        let liquidation_price = calculate_liquidation_price(entry_price_u64, leverage, is_long);
        let target_price = calculate_target_price(entry_price_u64, leverage, is_long);

        // Transfer asset to treasury
        let coins = coin::withdraw<CoinType>(trader, amount_wagered);
        treasury_pool::deposit_asset<CoinType>(coins);

        // Create position
        let position_id = position_manager.position_counter;
        position_manager.position_counter = position_id + 1;

        let token_name = coin::name<CoinType>();

        let position = Position {
            trader: trader_addr,
            asset: token_name,
            pair_id,
            amount_wagered,
            leverage,
            entry_price: entry_price_u64,
            liquidation_price,
            target_price,
            timestamp_opened: timestamp::now_seconds(),
            is_long,
            is_closed: false,
            exit_price: 0,
            payout_amount: 0,
        };

        table::add(&mut position_manager.positions, position_id, position);

        // Add to user positions
        if (!table::contains(&position_manager.user_positions, trader_addr)) {
            table::add(&mut position_manager.user_positions, trader_addr, vector::empty<u64>());
        };
        let user_positions = table::borrow_mut(&mut position_manager.user_positions, trader_addr);
        vector::push_back(user_positions, position_id);

        // Emit event
        event::emit(PositionOpened {
            position_id,
            trader: trader_addr,
            asset: token_name,
            amount_wagered,
            leverage,
            entry_price: entry_price_u64,
            is_long,
            timestamp: timestamp::now_seconds(),
            liquidation_price,
            target_price,
        });
    }

    /// Closes position manually
    public entry fun close_position<CoinType>(
        trader: &signer,
        position_id: u64,
    ) acquires PositionManager {
        let trader_addr = signer::address_of(trader);
        let position_manager = borrow_global_mut<PositionManager>(get_resource_account_address());
        
        assert!(table::contains(&position_manager.positions, position_id), error::not_found(E_POSITION_NOT_FOUND));
        
        let position = table::borrow_mut(&mut position_manager.positions, position_id);
        assert!(position.trader == trader_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(!position.is_closed, error::invalid_state(E_POSITION_CLOSED));
        assert!(position.asset == coin::name<CoinType>(), error::invalid_argument(E_INVALID_ASSET));

        // Get current price
        let (current_price, _) = get_and_validate_oracle_price(position.pair_id);        
        
        // Calculate payout
        let (_, payout_amount, pnl_percentage) = calculate_payout(
            position.amount_wagered,
            position.leverage,
            position.entry_price,
            current_price,
            position.is_long
        );

        distribute_payout_and_fees<CoinType>(position, position_id, current_price, payout_amount, pnl_percentage);      
    }

    /// Force close position (for automation)
    public entry fun force_close_position<CoinType>(
        automation: &signer,
        position_id: u64,
    ) acquires PositionManager {
        let position_manager = borrow_global_mut<PositionManager>(get_resource_account_address());
        assert!(signer::address_of(automation) == position_manager.automation_account, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(table::contains(&position_manager.positions, position_id), error::not_found(E_POSITION_NOT_FOUND));
        
        let position = table::borrow_mut(&mut position_manager.positions, position_id);
        assert!(!position.is_closed, error::invalid_state(E_POSITION_CLOSED));
        assert!(position.asset == coin::name<CoinType>(), error::invalid_argument(E_INVALID_ASSET));

        // Get current price
        let (current_price, _) = get_and_validate_oracle_price(position.pair_id);        
        
        // Check if position should be liquidated or hit profit cap
        let should_liquidate = check_liquidation(position, current_price);
        let hit_profit_cap = check_profit_cap(position, current_price);
        
        assert!(should_liquidate || hit_profit_cap, error::invalid_state(E_NOT_AUTHORIZED));

        let current_time = timestamp::now_seconds();
        if (should_liquidate) {
            // Liquidation - trader gets nothing
            position.is_closed = true;
            position.exit_price = current_price;
            position.payout_amount = 0;
            treasury_pool::record_loss<CoinType>(position.amount_wagered);

            event::emit(PositionLiquidated {
                position_id,
                trader: position.trader,
                liquidation_price: current_price,
                timestamp: current_time,
            });
        } else {
            // Profit cap hit - calculate max payout
            let max_payout = position.amount_wagered + ((position.amount_wagered * PROFIT_CAP) / 100);

            distribute_payout_and_fees<CoinType>(position, position_id, current_price, max_payout, PROFIT_CAP);
        };
    }


    // ======================================================================================================================================================
    //                                                              VIEW FUNCTIONS
    // ======================================================================================================================================================


    #[view]
    /// Returns a Position
    public fun get_position(position_id: u64): Position acquires PositionManager {
        let position_manager = borrow_global<PositionManager>(get_resource_account_address());
        assert!(table::contains(&position_manager.positions, position_id), error::not_found(E_POSITION_NOT_FOUND));
        *table::borrow(&position_manager.positions, position_id)
    }

    #[view]
    /// Returns a user's positions
    public fun get_user_positions(user: address): vector<u64> acquires PositionManager {
        let position_manager = borrow_global<PositionManager>(get_resource_account_address());
        if (table::contains(&position_manager.user_positions, user)) {
            *table::borrow(&position_manager.user_positions, user)
        } else {
            vector::empty<u64>()
        }
    }

    #[view]
    /// Returns if a user is in profit/loss, payout amount and profit/loss percentage
    /// 0 represents profit and 1 represents loss
    public fun calculate_current_pnl(position_id: u64): (u8, u64, u64) acquires PositionManager {
        let position_manager = borrow_global<PositionManager>(get_resource_account_address());
        let position = table::borrow(&position_manager.positions, position_id);
        
        assert!(!position.is_closed, error::invalid_state(E_POSITION_CLOSED));

        let (current_price, _) = get_and_validate_oracle_price(position.pair_id);
        calculate_payout(
            position.amount_wagered,
            position.leverage,
            position.entry_price,
            current_price,
            position.is_long
        )
    }

    #[view]
    /// Returns the resource account address
    fun get_resource_account_address(): address {
        account::create_resource_address(&@liquid_nation, b"position_manager")
    }

    // ======================================================================================================================================================
    //                                                              ADMIN FUNCTIONS
    // ======================================================================================================================================================


    /// Pauses the open_position
    public entry fun pause(admin: &signer) acquires PositionManager {
        let admin_addr = signer::address_of(admin);
        let position_manager = borrow_global_mut<PositionManager>(get_resource_account_address());
        assert!(position_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        position_manager.paused = true;
    }

    /// Unpauses the open_position
    public entry fun unpause(admin: &signer) acquires PositionManager {
        let admin_addr = signer::address_of(admin);
        let position_manager = borrow_global_mut<PositionManager>(get_resource_account_address());
        assert!(position_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        position_manager.paused = false;
    }

    /// Sets the automation account
    public entry fun set_automation_account(admin: &signer, new_automation_account: address) acquires PositionManager {
        let admin_addr = signer::address_of(admin);
        let position_manager = borrow_global_mut<PositionManager>(get_resource_account_address());
        assert!(position_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        position_manager.automation_account = new_automation_account;
    }

    /// Updates the admin of the contract
    public entry fun update_admin(
        admin: &signer,
        new_admin: address,
    ) acquires PositionManager {
        let position_manager = borrow_global_mut<PositionManager>(get_resource_account_address());
        let old_admin = position_manager.admin;
        
        assert!(old_admin == signer::address_of(admin), error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_admin != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        position_manager.admin = new_admin;

        event::emit(AdminUpdated{
            old_admin,
            new_admin,
            timestamp: timestamp::now_seconds()
        });
    }
}