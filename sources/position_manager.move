module liquid_nation::position_manager {
    use std::signer;
    use std::string::String;
    use std::vector;
    use std::error;
    use std::timestamp;
    use aptos_std::table::{Self, Table};
    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::type_info;
    use liquid_nation::treasury_pool;
    use liquid_nation::fee_controller;
    use liquid_nation::supra_oracle;


    // ======================================================================================================================================================
    //                                                                          CONSTANTS
    // ======================================================================================================================================================


    const MAX_LEVERAGE: u8 = 100;
    /// 500%
    const PROFIT_CAP: u64 = 500;
    /// 1 USD in microunits
    const MIN_WAGER: u64 = 1_000_000;
    /// 100.00%
    const PERCENTAGE_PRECISION: u64 = 10000;

    // Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INVALID_LEVERAGE: u64 = 2;
    const E_INVALID_WAGER: u64 = 3;
    const E_PAUSED: u64 = 4;
    const E_POSITION_NOT_FOUND: u64 = 5;
    const E_POSITION_CLOSED: u64 = 6;
    const E_INSUFFICIENT_POOL_BALANCE: u64 = 7;
    const E_ORACLE_PRICE_STALE: u64 = 8;
    const E_POSITION_ALREADY_EXISTS: u64 = 9;
    const E_UNSUPPORTED_TOKEN: u64 = 10;
    const E_INVALID_ASSET: u64 = 11;
    const E_INSUFFICIENT_PAYOUT: u64 = 12;


    // ======================================================================================================================================================
    //                                                                          STRUCTS
    // ======================================================================================================================================================


    struct Position has store, copy, drop {
        trader: address,
        asset: String,
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

    struct PositionManager has key {
        positions: Table<u64, Position>,
        user_positions: Table<address, vector<u64>>,
        position_counter: u64,
        admin: address,
        paused: bool,
        automation_account: address,
    }


    // ======================================================================================================================================================
    //                                                                          EVENTS
    // ======================================================================================================================================================


    #[event]
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
    struct PositionClosed has drop, store {
        position_id: u64,
        trader: address,
        exit_price: u64,
        payout_amount: u64,
        pnl_percentage: u64,
        timestamp: u64,
    }

    #[event]
    struct PositionLiquidated has drop, store {
        position_id: u64,
        trader: address,
        liquidation_price: u64,
        timestamp: u64,
    }


    // ======================================================================================================================================================
    //                                                                      HELPER FUNCTIONS
    // ======================================================================================================================================================


    /// Initializes the position manager
    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        
        move_to(admin, PositionManager {
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

    /// Calculates payout
    fun calculate_payout(
        amount_wagered: u64,
        leverage: u8,
        entry_price: u64,
        current_price: u64,
        is_long: bool
    ): (u8, u64, u64) {
        assert!(entry_price > 0, error::invalid_argument(E_INVALID_AMOUNT));

        // Calculate price change and determine profit/loss in one step
        let (is_profit, price_change_abs) = if (is_long) {
            if (current_price >= entry_price) {
                (true, current_price - entry_price)
            } else {
                (false, entry_price - current_price)
            }
        } else {
            if (entry_price >= current_price) {
                (true, entry_price - current_price)
            } else {
                (false, current_price - entry_price)
            }
        };

        // Calculate leveraged PnL percentage
        let max_safe_multiplier = u64::MAX / ((leverage as u64) * PERCENTAGE_PRECISION);
        assert!(price_change_abs <= max_safe_multiplier, error::invalid_argument(E_INVALID_WAGER));

        let leveraged_pnl_percentage = (price_change_abs * PERCENTAGE_PRECISION * (leverage as u64)) / entry_price;

        if (is_profit) {
            // Cap profit at 500%
            let capped_pnl = if (leveraged_pnl_percentage > PROFIT_CAP * 100) {
                PROFIT_CAP * 100
            } else {
                leveraged_pnl_percentage
            };

            let payout = amount_wagered + ((amount_wagered * capped_pnl) / PERCENTAGE_PRECISION);
            (0, payout, capped_pnl)
        } else {
            // Handle loss - check liquidation first
            if (leveraged_pnl_percentage >= PERCENTAGE_PRECISION) {
                (1, 0, PERCENTAGE_PRECISION) // Liquidation
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


    // ======================================================================================================================================================
    //                                                                   TRADE MANAGEMENT
    // ======================================================================================================================================================


    /// Opens a new position
    public entry fun open_position<CoinType>(
        trader: &signer,
        amount_wagered: u64,
        leverage: u8,
        is_long: bool,
    ) acquires PositionManager {
        let trader_addr = signer::address_of(trader);
        let position_manager = borrow_global_mut<PositionManager>(@liquid_nation);
        
        assert!(!position_manager.paused, error::permission_denied(E_PAUSED));
        assert!(leverage >= 1 && leverage <= MAX_LEVERAGE, error::invalid_argument(E_INVALID_LEVERAGE));
        assert!(
            treasury_pool::is_token_supported<CoinType>(),
            error::invalid_argument(E_UNSUPPORTED_TOKEN)
        );
        assert!(amount_wagered >= MIN_WAGER, error::invalid_argument(E_INVALID_WAGER));

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

        let token_name = coin::name<CoinType>();

        // Get current price from oracle
        let entry_price = supra_oracle::get_price(token_name);
        let price_timestamp = supra_oracle::get_price_timestamp(token_name);
        assert!(entry_price > 0 && timestamp::now_seconds() - price_timestamp <= 10, error::invalid_state(E_ORACLE_PRICE_STALE));
        let max_payout = amount_wagered + (amount_wagered * PROFIT_CAP / 100);
        
        // Check if pool can cover max payout
        assert!(
            treasury_pool::can_cover_payout<CoinType>(max_payout),
            error::resource_exhausted(E_INSUFFICIENT_POOL_BALANCE)
        );

        // Calculate liquidation and target prices
        let liquidation_price = calculate_liquidation_price(entry_price, leverage, is_long);
        let target_price = calculate_target_price(entry_price, leverage, is_long);

        // Transfer asset to treasury
        let coins = coin::withdraw<CoinType>(trader, amount_wagered);
        treasury_pool::deposit_asset<CoinType>(coins);

        // Create position
        let position_id = position_manager.position_counter;
        position_manager.position_counter = position_id + 1;

        let position = Position {
            trader: trader_addr,
            asset: token_name,
            amount_wagered,
            leverage,
            entry_price,
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
            entry_price,
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
        let position_manager = borrow_global_mut<PositionManager>(@liquid_nation);
        
        assert!(table::contains(&position_manager.positions, position_id), error::not_found(E_POSITION_NOT_FOUND));
        
        let position = table::borrow_mut(&mut position_manager.positions, position_id);
        assert!(position.trader == trader_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(!position.is_closed, error::invalid_state(E_POSITION_CLOSED));

        assert!(
            position.asset == coin::name<CoinType>(),
            error::invalid_argument(E_INVALID_ASSET)
        );

        // Get current price
        let current_price = supra_oracle::get_price(position.asset);
        let price_timestamp = supra_oracle::get_price_timestamp(position.asset);
        assert!(current_price > 0 && timestamp::now_seconds() - price_timestamp <= 10, error::invalid_state(E_ORACLE_PRICE_STALE));
        
        // Calculate payout
        let (_, payout_amount, pnl_percentage) = calculate_payout(
            position.amount_wagered,
            position.leverage,
            position.entry_price,
            current_price,
            position.is_long
        );

        // Apply fees
        let fee_amount = fee_controller::calculate_fee(payout_amount);
        assert!(fee_amount <= payout_amount, error::invalid_state(E_INSUFFICIENT_PAYOUT));

        let net_payout = if (payout_amount > fee_amount) {
            payout_amount - fee_amount
        } else {
            0
        };

        // Update position
        position.is_closed = true;
        position.exit_price = current_price;
        position.payout_amount = net_payout;

        // Handle payout
        if (net_payout > 0) {
            let payout_coins = treasury_pool::withdraw_payout<CoinType>(net_payout, position.amount_wagered);

            coin::deposit(trader_addr, payout_coins);
        };

        // Distribute fees
        if (fee_amount > 0) {
            fee_controller::distribute_fees<CoinType>(fee_amount);
        };

        // Emit event
        event::emit(PositionClosed {
            position_id,
            trader: trader_addr,
            exit_price: current_price,
            payout_amount: net_payout,
            pnl_percentage,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Force close position (for automation)
    public entry fun force_close_position<CoinType>(
        _automation: &signer,
        position_id: u64,
    ) acquires PositionManager {
        let automation_addr = signer::address_of(_automation);

        let position_manager = borrow_global_mut<PositionManager>(@liquid_nation);
        assert!(automation_addr == position_manager.automation_account, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(table::contains(&position_manager.positions, position_id), error::not_found(E_POSITION_NOT_FOUND));
        
        let position = table::borrow_mut(&mut position_manager.positions, position_id);
        assert!(!position.is_closed, error::invalid_state(E_POSITION_CLOSED));

        assert!(
            position.asset == coin::name<CoinType>(),
            error::invalid_argument(E_INVALID_ASSET)
        );

        let current_price = supra_oracle::get_price(position.asset);
        let price_timestamp = supra_oracle::get_price_timestamp(position.asset);
        assert!(current_price > 0 && timestamp::now_seconds() - price_timestamp <= 10, error::invalid_state(E_ORACLE_PRICE_STALE));
        
        // Check if position should be liquidated or hit profit cap
        let should_liquidate = check_liquidation(position, current_price);
        let hit_profit_cap = check_profit_cap(position, current_price);
        
        assert!(should_liquidate || hit_profit_cap, error::invalid_state(E_NOT_AUTHORIZED));

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
                timestamp: timestamp::now_seconds(),
            });
        } else {
            // Profit cap hit - calculate max payout
            let max_payout = position.amount_wagered + (position.amount_wagered * PROFIT_CAP / 100);

            let fee_amount = fee_controller::calculate_fee(max_payout);
            assert!(fee_amount <= max_payout, error::invalid_state(E_INSUFFICIENT_POOL_BALANCE));

            let net_payout = max_payout - fee_amount;

            position.is_closed = true;
            position.exit_price = current_price;
            position.payout_amount = net_payout;

            // Handle payout
            let payout_coins = treasury_pool::withdraw_payout<CoinType>(net_payout, position.amount_wagered);

            coin::deposit(position.trader, payout_coins);

            // Distribute fees
            if (fee_amount > 0) {
                fee_controller::distribute_fees<CoinType>(fee_amount);
            };

            event::emit(PositionClosed {
                position_id,
                trader: position.trader,
                exit_price: current_price,
                payout_amount: net_payout,
                pnl_percentage: PROFIT_CAP,
                timestamp: timestamp::now_seconds(),
            });
        };
    }


    // ======================================================================================================================================================
    //                                                              VIEW FUNCTIONS
    // ======================================================================================================================================================


    #[view]
    public fun get_position(position_id: u64): Position acquires PositionManager {
        let position_manager = borrow_global<PositionManager>(@liquid_nation);
        assert!(table::contains(&position_manager.positions, position_id), error::not_found(E_POSITION_NOT_FOUND));
        *table::borrow(&position_manager.positions, position_id)
    }

    #[view]
    public fun get_user_positions(user: address): vector<u64> acquires PositionManager {
        let position_manager = borrow_global<PositionManager>(@liquid_nation);
        if (table::contains(&position_manager.user_positions, user)) {
            *table::borrow(&position_manager.user_positions, user)
        } else {
            vector::empty<u64>()
        }
    }

    #[view]
    public fun calculate_current_pnl(position_id: u64): (u8, u64, u64) acquires PositionManager {
        let position_manager = borrow_global<PositionManager>(@liquid_nation);
        let position = table::borrow(&position_manager.positions, position_id);
        
        if (position.is_closed) {
            return (0, position.payout_amount, 0)
        };

        let current_price = supra_oracle::get_price(position.asset);
        let price_timestamp = supra_oracle::get_price_timestamp(position.asset);
        assert!(current_price > 0 && timestamp::now_seconds() - price_timestamp <= 10, error::invalid_state(E_ORACLE_PRICE_STALE));
        calculate_payout(
            position.amount_wagered,
            position.leverage,
            position.entry_price,
            current_price,
            position.is_long
        )
    }


    // ======================================================================================================================================================
    //                                                              ADMIN FUNCTIONS
    // ======================================================================================================================================================


    /// Pauses the open_position
    public entry fun pause(admin: &signer) acquires PositionManager {
        let admin_addr = signer::address_of(admin);
        let position_manager = borrow_global_mut<PositionManager>(@liquid_nation);
        assert!(position_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        position_manager.paused = true;
    }

    /// Unpauses the open_position
    public entry fun unpause(admin: &signer) acquires PositionManager {
        let admin_addr = signer::address_of(admin);
        let position_manager = borrow_global_mut<PositionManager>(@liquid_nation);
        assert!(position_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        position_manager.paused = false;
    }

    /// Sets the automation account
    public entry fun set_automation_account(admin: &signer, new_automation_account: address) acquires PositionManager {
        let admin_addr = signer::address_of(admin);
        let position_manager = borrow_global_mut<PositionManager>(@liquid_nation);
        assert!(position_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        position_manager.automation_account = new_automation_account;
    }
}