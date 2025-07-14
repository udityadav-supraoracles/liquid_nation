module liquid_nation::treasury_pool {
    friend liquid_nation::position_manager;

    use std::signer;
    use std::error;
    use std::string::String;
    use aptos_std::table::{Self, Table};
    use aptos_std::math64;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::coin::{Self, Coin};
    use supra_framework::event;
    use supra_framework::timestamp;
    use supra_framework::type_info::{Self, TypeInfo};
    use supra_oracle::supra_oracle_storage;
    use liquid_nation::lp_token;


    // ======================================================================================================================================================
    //                                                                          CONSTANTS
    // ======================================================================================================================================================


    /// Minimum deposit is set to 1 USD
    const MIN_AMOUNT: u64 = 10^18;
    /// Basis points for precision (10000 = 100%)
    const BASIS_POINTS: u64 = 10000;
    /// Minimum basis points for operational buffer (500 = 5%)
    const OPERATIONAL_BUFFER_BP: u64 = 500;


    /// Comprehensive error codes for all contract operations
    /// Caller is not authorized
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Insufficient lp token balance
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    /// Insufficient balance in pool
    const E_INSUFFICIENT_POOL_BALANCE: u64 = 3;
    /// Invalid pool state
    const E_INVALID_POOL_STATE: u64 = 4; 
    /// Invalid amount
    const E_INVALID_AMOUNT: u64 = 5;
    /// Pool is not initialized
    const E_POOL_NOT_INITIALIZED: u64 = 6;
    /// Pool is paused
    const E_POOL_PAUSED: u64 = 7;
    /// Stale price from oracle
    const E_ORACLE_PRICE_STALE: u64 = 8;
    /// Invalid input for address
    const E_INVALID_ADDRESS: u64 = 9;


    // ======================================================================================================================================================
    //                                                                          STRUCTS
    // ======================================================================================================================================================


    /// Pool state for each supported token
    struct PoolState<phantom CoinType> has key {
        total_deposits: u64,
        total_lp_tokens: u64,
        active_positions_value: u64,
        cumulative_pnl: u64,
        pnl_is_positive: bool,
        fee_reserves: u64,
        asset_balance: Coin<CoinType>,
        paused: bool,
    }

    /// Global pool registry
    struct PoolRegistry has key {
        supported_tokens: Table<TypeInfo, bool>,
        admin: address,
    }

    /// Signer capability storage
    struct ResourceAccountCapability has key {
        signer_cap: SignerCapability,
    }


    // ======================================================================================================================================================
    //                                                                          EVENTS
    // ======================================================================================================================================================


    #[event]
    /// Emitted when a liquidity provider adds liquidity
    struct PoolDeposit has drop, store {
        depositor: address,
        token_name: String,
        amount: u64,
        lp_tokens_minted: u64,
        timestamp: u64,
    }

    #[event]
    /// Emitted when a liquidity provider removes liquidity
    struct PoolWithdrawal has drop, store {
        withdrawer: address,
        token_name: String,
        amount: u64,
        lp_tokens_burned: u64,
        timestamp: u64,
    }

    #[event]
    /// Emitted when a trader gets liquidated 
    struct PoolStateUpdated has drop, store {
        token_name: String,
        total_deposits: u64,
        cumulative_pnl: u64,
        pnl_is_positive: bool,
        timestamp: u64,
    }

    #[event]
    /// Emitted when the fee gets distributed
    struct FeeDistributed has drop, store {
        token_name: String,
        total_fee_amount: u64,
        treasury_fee_amount: u64,
        protocol_fee_amount: u64,
        protocol_recipient: address,
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

        // Create resource account for treasury pool
        let (resource_signer, signer_cap) = account::create_resource_account(admin, b"treasury_pool");

        // Move the capability to the resource account
        move_to(&resource_signer, ResourceAccountCapability {
            signer_cap,
        });

        // Move PoolRegistry to the resource account
        move_to(&resource_signer, PoolRegistry {
            supported_tokens: table::new(),
            admin: admin_addr,
        });
    }

    /// Calculates the pool value
    fun calculate_pool_value<CoinType>(pool: &PoolState<CoinType>): u64 {
        let base_value = coin::value(&pool.asset_balance);
        
        // Adjust for cumulative PnL
        if (pool.pnl_is_positive) {
            base_value + pool.cumulative_pnl
        } else {
            if (base_value > pool.cumulative_pnl) {
                base_value - pool.cumulative_pnl
            } else {
                0
            }
        }
    }

    /// Calculates USD value of token_amount using oracle
    public(friend) fun calculate_usd_value(
        token_amount: u64,
        token_decimals: u8,
        oracle_price: u128,
        oracle_price_decimals: u16
    ): u64 {
        let price_u64 = (oracle_price as u64);
        
        // Calculate USD value with 18 decimal precision
        let token_decimal_factor = math64::pow(10, (token_decimals as u64));
        let price_decimal_factor = math64::pow(10, (oracle_price_decimals as u64));
        
        (token_amount * price_u64 * MIN_AMOUNT) / (token_decimal_factor * price_decimal_factor)
    }

    /// Internal helper function to ensure the pool is initialized
    fun ensure_pool_initialized<CoinType>() {
        let resource_addr = get_resource_account_address();
        assert!(exists<PoolState<CoinType>>(resource_addr), error::invalid_state(E_POOL_NOT_INITIALIZED));
    }


    // ======================================================================================================================================================
    //                                                                   POOL MANAGEMENT
    // ======================================================================================================================================================


    /// Deposits liquidity to pool
    public entry fun deposit<CoinType>(
        depositor: &signer,
        amount: u64,
        pair_id: u32
    ) acquires PoolState {
        ensure_pool_initialized<CoinType>();
        let pool = borrow_global_mut<PoolState<CoinType>>(get_resource_account_address());
        assert!(!pool.paused, error::permission_denied(E_POOL_PAUSED));
        
        let depositor_addr = signer::address_of(depositor);

        let (price, price_decimals, price_timestamp, _) = supra_oracle_storage::get_price(pair_id);
        assert!(price > 0 && timestamp::now_seconds() - price_timestamp <= 10, error::invalid_state(E_ORACLE_PRICE_STALE));
        let usd_value = calculate_usd_value(amount, coin::decimals<CoinType>(), (price as u128), price_decimals);
        assert!(usd_value >= MIN_AMOUNT, error::invalid_argument(E_INVALID_AMOUNT));

        // Calculate LP tokens to mint
        let lp_tokens_to_mint = if (pool.total_lp_tokens == 0) {
            // First deposit - 1:1 ratio
            amount
        } else {
            // Calculate based on current pool value
            let pool_value = calculate_pool_value(pool);
            assert!(pool_value > 0, error::invalid_state(E_INVALID_POOL_STATE));

            (amount * pool.total_lp_tokens) / pool_value
        };

        // Transfer coins to pool
        let deposit_coins = coin::withdraw<CoinType>(depositor, amount);
        coin::merge(&mut pool.asset_balance, deposit_coins);

        // Update pool state
        pool.total_deposits = pool.total_deposits + amount;
        pool.total_lp_tokens = pool.total_lp_tokens + lp_tokens_to_mint;

        // Mint LP tokens to depositor
        lp_token::mint_to<CoinType>(depositor_addr, lp_tokens_to_mint);

        let token_name = coin::name<CoinType>();

        // Emit event
        event::emit(PoolDeposit {
            depositor: depositor_addr,
            token_name,
            amount,
            lp_tokens_minted: lp_tokens_to_mint,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Withdraws liquidity from pool
    public entry fun withdraw<CoinType>(
        withdrawer: &signer,
        lp_tokens_to_burn: u64
    ) acquires PoolState {
        ensure_pool_initialized<CoinType>();
        let withdrawer_addr = signer::address_of(withdrawer);
        let pool = borrow_global_mut<PoolState<CoinType>>(get_resource_account_address());
        
        assert!(!pool.paused, error::permission_denied(E_POOL_PAUSED));
        assert!(lp_tokens_to_burn > 0, error::invalid_argument(E_INVALID_AMOUNT));

        assert!(
            lp_token::balance<CoinType>(withdrawer_addr) >= lp_tokens_to_burn,
            error::invalid_argument(E_INSUFFICIENT_BALANCE)
        );

        // Calculate withdrawal amount
        let pool_value = calculate_pool_value(pool);
        assert!(pool.total_lp_tokens > 0, error::invalid_state(E_INVALID_POOL_STATE));
        let withdrawal_amount = if (pool.total_lp_tokens > 0) {
            (lp_tokens_to_burn * pool_value) / pool.total_lp_tokens
        } else {
            0
        };
        
        assert!(
            coin::value(&pool.asset_balance) >= withdrawal_amount,
            error::resource_exhausted(E_INSUFFICIENT_POOL_BALANCE)
        );

        // Update pool state
        assert!(pool.total_deposits >= withdrawal_amount, error::invalid_state(E_INVALID_POOL_STATE));
        pool.total_deposits = pool.total_deposits - withdrawal_amount;
        pool.total_lp_tokens = pool.total_lp_tokens - lp_tokens_to_burn;

        // Burn LP tokens
        lp_token::burn_from<CoinType>(withdrawer, lp_tokens_to_burn);

        // Transfer coins to withdrawer
        let withdrawal_coins = coin::extract(&mut pool.asset_balance, withdrawal_amount);
        coin::deposit(withdrawer_addr, withdrawal_coins);

        // Emit event
        event::emit(PoolWithdrawal {
            withdrawer: withdrawer_addr,
            token_name: coin::name<CoinType>(),
            amount: withdrawal_amount,
            lp_tokens_burned: lp_tokens_to_burn,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Deposits asset from trading positions
    public(friend) fun deposit_asset<CoinType>(coins: Coin<CoinType>) acquires PoolState {
        ensure_pool_initialized<CoinType>();
        
        let pool = borrow_global_mut<PoolState<CoinType>>(get_resource_account_address());
        let amount = coin::value(&coins);
        
        coin::merge(&mut pool.asset_balance, coins);
        pool.active_positions_value = pool.active_positions_value + amount;
    }

    /// Withdraws payout for winning positions
    public(friend) fun withdraw_payout<CoinType>(payout_amount: u64, wagered_amount: u64): Coin<CoinType> acquires PoolState {
        ensure_pool_initialized<CoinType>();
        let pool = borrow_global_mut<PoolState<CoinType>>(get_resource_account_address());
        
        assert!(
            coin::value(&pool.asset_balance) >= payout_amount,
            error::resource_exhausted(E_INSUFFICIENT_POOL_BALANCE)
        );

        // Update PnL (pool loses money when traders win)
        if (pool.pnl_is_positive) {
            if (pool.cumulative_pnl >= payout_amount) {
                pool.cumulative_pnl = pool.cumulative_pnl - payout_amount;
            } else {
                pool.cumulative_pnl = payout_amount - pool.cumulative_pnl;
                pool.pnl_is_positive = false;
            }
        } else {
            pool.cumulative_pnl = pool.cumulative_pnl + payout_amount;
        };

        pool.active_positions_value = if (pool.active_positions_value >= wagered_amount) {
            pool.active_positions_value - wagered_amount
        } else {
            0
        };

        coin::extract(&mut pool.asset_balance, payout_amount)
    }

    /// Records loss from liquidated position (pool gains money)
    public(friend) fun record_loss<CoinType>(amount: u64) acquires PoolState {
        ensure_pool_initialized<CoinType>();
        let pool = borrow_global_mut<PoolState<CoinType>>(get_resource_account_address());
        
        // Update PnL (pool gains money when traders lose)
        if (!pool.pnl_is_positive) {
            if (pool.cumulative_pnl >= amount) {
                pool.cumulative_pnl = pool.cumulative_pnl - amount;
            } else {
                pool.cumulative_pnl = amount - pool.cumulative_pnl;
                pool.pnl_is_positive = true;
            }
        } else {
            pool.cumulative_pnl = pool.cumulative_pnl + amount;
        };
        assert!(pool.active_positions_value >= amount, error::invalid_state(E_INVALID_POOL_STATE));

        pool.active_positions_value = pool.active_positions_value - amount;
        let token_name = coin::name<CoinType>();

        event::emit(PoolStateUpdated {
            token_name,
            total_deposits: pool.total_deposits,
            cumulative_pnl: pool.cumulative_pnl,
            pnl_is_positive: pool.pnl_is_positive,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Distributes fees
    public fun distribute_fee<CoinType>(total_fee_amount: u64, treasury_fee_amount:u64, protocol_fee_amount: u64, protocol_recipient: address) acquires PoolState {
        ensure_pool_initialized<CoinType>();
        let pool = borrow_global_mut<PoolState<CoinType>>(get_resource_account_address());
        let fee_coins = coin::extract(&mut pool.asset_balance, protocol_fee_amount);
        coin::deposit(protocol_recipient, fee_coins);

        pool.fee_reserves = pool.fee_reserves + treasury_fee_amount;

        // Emit event
        event::emit(FeeDistributed {
            token_name: coin::name<CoinType>(),
            total_fee_amount,
            treasury_fee_amount,
            protocol_fee_amount,
            protocol_recipient,
            timestamp: timestamp::now_seconds(),
        });
    }
    

    // ======================================================================================================================================================
    //                                                              VIEW FUNCTIONS
    // ======================================================================================================================================================

    #[view]
    /// Returns pool info
    public fun get_pool_info<CoinType>(): (u64, u64, u64, u64, bool) acquires PoolState {
        let pool = borrow_global<PoolState<CoinType>>(get_resource_account_address());
        (
            pool.total_deposits,
            pool.total_lp_tokens,
            coin::value(&pool.asset_balance),
            pool.cumulative_pnl,
            pool.pnl_is_positive
        )
    }

    #[view]
    /// Returns the pool value
    public fun get_pool_value<CoinType>(): u64 acquires PoolState {
        let pool = borrow_global<PoolState<CoinType>>(get_resource_account_address());
        calculate_pool_value(pool)
    }

    #[view]
    /// Calculates the lp token value
    public fun calculate_lp_token_value<CoinType>(lp_tokens: u64): u64 acquires PoolState {
        let pool = borrow_global<PoolState<CoinType>>(get_resource_account_address());
        if (pool.total_lp_tokens == 0) {
            0
        } else {
            let pool_value = calculate_pool_value(pool);
            (lp_tokens * pool_value) / pool.total_lp_tokens
        }
    }

    #[view]
    /// Returns if a token is supported
    public fun is_token_supported<CoinType>(): bool acquires PoolRegistry {
        let registry = borrow_global<PoolRegistry>(get_resource_account_address());
        let type_info = type_info::type_of<CoinType>();
        table::contains(&registry.supported_tokens, type_info)
    }
    
    #[view]
    /// Checks if pool can cover maximum payout
    public fun can_cover_payout<CoinType>(max_payout: u64): bool acquires PoolState {
        let pool = borrow_global<PoolState<CoinType>>(get_resource_account_address());
        let available_balance = coin::value(&pool.asset_balance);
        
        // Reserve some liquidity for withdrawals
        let reserved_amount = (available_balance * OPERATIONAL_BUFFER_BP) / BASIS_POINTS;
        let available_for_payouts = if (available_balance > reserved_amount) {
            available_balance - reserved_amount
        } else {
            0
        };
        
        max_payout <= available_for_payouts
    }

    #[view]
    /// Returns the resource account address
    fun get_resource_account_address(): address {
        account::create_resource_address(&@liquid_nation, b"treasury_pool")
    }


    // ======================================================================================================================================================
    //                                                              ADMIN FUNCTIONS
    // ======================================================================================================================================================


    /// Pauses the deposit and withdraw
    public entry fun pause_pool<CoinType>(admin: &signer) acquires PoolState, PoolRegistry {
        let admin_addr = signer::address_of(admin);
        let registry = borrow_global_mut<PoolRegistry>(get_resource_account_address());
        let pool = borrow_global_mut<PoolState<CoinType>>(get_resource_account_address());
        assert!(registry.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        pool.paused = true;
    }

    /// Unpauses the deposit and withdraw
    public entry fun unpause_pool<CoinType>(admin: &signer) acquires PoolState, PoolRegistry {
        let admin_addr = signer::address_of(admin);
        let registry = borrow_global_mut<PoolRegistry>(get_resource_account_address());
        let pool = borrow_global_mut<PoolState<CoinType>>(get_resource_account_address());
        assert!(registry.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        pool.paused = false;
    }

    /// Add a token and initialize its pool
    public entry fun add_supported_token<CoinType>(
        admin: &signer,
    ) acquires PoolRegistry, ResourceAccountCapability {
        let admin_addr = signer::address_of(admin);
        let resource_addr = get_resource_account_address();

        // Early exit if pool already exists
        if (exists<PoolState<CoinType>>(resource_addr)) return;

        let registry = borrow_global_mut<PoolRegistry>(resource_addr);
        assert!(registry.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));

        let type_info = type_info::type_of<CoinType>();

        // Add to registry
        if (!table::contains(&registry.supported_tokens, type_info)) {
            table::add(&mut registry.supported_tokens, type_info, true);
        };

        // Try to initialize LP token (might already exist)
        // Note: This might abort if LP token already exists
        lp_token::initialize_lp_token<CoinType>();

        // Initialize pool state
        let resource_signer = account::create_signer_with_capability(
            &borrow_global<ResourceAccountCapability>(resource_addr).signer_cap
        );

        move_to(&resource_signer, PoolState<CoinType> {
            total_deposits: 0,
            total_lp_tokens: 0,
            active_positions_value: 0,
            cumulative_pnl: 0,
            pnl_is_positive: true,
            fee_reserves: 0,
            asset_balance: coin::zero<CoinType>(),
            paused: false,
        });
    }

    /// Removes a supported token
    public entry fun remove_supported_token<CoinType>(
        admin: &signer,
    ) acquires PoolRegistry {
        let admin_addr = signer::address_of(admin);
        let registry = borrow_global_mut<PoolRegistry>(get_resource_account_address());
        let type = type_info::type_of<CoinType>();
        
        assert!(registry.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        table::remove(&mut registry.supported_tokens, type);
    }

    /// Allows withdrawal
    public entry fun emergency_withdraw<CoinType>(
        admin: &signer,
        amount: u64,
    ) acquires PoolState, PoolRegistry {
        let admin_addr = signer::address_of(admin);
        let registry = borrow_global_mut<PoolRegistry>(get_resource_account_address());
        let pool = borrow_global_mut<PoolState<CoinType>>(get_resource_account_address());
        
        assert!(registry.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(pool.paused, error::permission_denied(E_NOT_AUTHORIZED));
        
        assert!(
            coin::value(&pool.asset_balance) >= amount,
            error::resource_exhausted(E_INSUFFICIENT_POOL_BALANCE)
        );
        
        let emergency_coins = coin::extract(&mut pool.asset_balance, amount);
        coin::deposit(admin_addr, emergency_coins);
    }

    /// Updates the admin of the contract
    public entry fun update_admin(
        admin: &signer,
        new_admin: address,
    ) acquires PoolRegistry {
        let registry = borrow_global_mut<PoolRegistry>(get_resource_account_address());
        let old_admin = registry.admin;

        assert!(old_admin == signer::address_of(admin), error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_admin != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        registry.admin = new_admin;

        event::emit(AdminUpdated{
            old_admin,
            new_admin,
            timestamp: timestamp::now_seconds(),
        });
    }
}