module liquid_nation::treasury_pool {
    use std::signer;
    use std::error;
    use std::string::String;
    use supra_framework::coin::{Self, Coin};
    use supra_framework::event;
    use supra_framework::timestamp;
    use supra_framework::type_info::{Self, TypeInfo};
    use aptos_std::table::{Self, Table};
    use liquid_nation::lp_token;


    // ======================================================================================================================================================
    //                                                                          CONSTANTS
    // ======================================================================================================================================================


    /// 1M precision for calculations
    const PRECISION: u64 = 1000000;
    /// 1 USD minimum deposit
    const MIN_DEPOSIT: u64 = 1000000;

    /// Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_INVALID_AMOUNT: u64 = 3;
    const E_POOL_NOT_INITIALIZED: u64 = 4;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 5;
    const E_POOL_PAUSED: u64 = 6;


    // ======================================================================================================================================================
    //                                                                          STRUCTS
    // ======================================================================================================================================================


    /// Pool state for each supported token
    struct PoolState<phantom CoinType> has key {
        total_deposits: u64,
        total_lp_tokens: u64,
        active_positions_value: u64,
        cumulative_pnl: u64, // Signed value represented as u64
        pnl_is_positive: bool,
        fee_reserves: u64,
        asset_balance: Coin<CoinType>,
        admin: address,
        paused: bool,
    }

    /// Global pool registry
    struct PoolRegistry has key {
        supported_tokens: Table<TypeInfo, bool>,
        admin: address,
    }


    // ======================================================================================================================================================
    //                                                                          EVENTS
    // ======================================================================================================================================================


    #[event]
    struct PoolDeposit has drop, store {
        depositor: address,
        token_name: String,
        amount: u64,
        lp_tokens_minted: u64,
        timestamp: u64,
    }

    #[event]
    struct PoolWithdrawal has drop, store {
        withdrawer: address,
        token_name: String,
        amount: u64,
        lp_tokens_burned: u64,
        timestamp: u64,
    }

    #[event]
    struct PoolStateUpdated has drop, store {
        token_name: String,
        total_deposits: u64,
        cumulative_pnl: u64,
        pnl_is_positive: bool,
        timestamp: u64,
    }

    #[event]
    struct FeeDistributed has drop, store {
        token_name: String,
        amount: u64,
        timestamp: u64,
    }


    // ======================================================================================================================================================
    //                                                                      HELPER FUNCTIONS
    // ======================================================================================================================================================


    /// Initialize pool registry
    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        
        move_to(admin, PoolRegistry {
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


    // ======================================================================================================================================================
    //                                                                   POOL MANAGEMENT
    // ======================================================================================================================================================


    /// Initialize pool for a specific token
    public entry fun initialize_pool<CoinType>(
        admin: &signer
    ) acquires PoolRegistry {
        let admin_addr = signer::address_of(admin);
        let registry = borrow_global_mut<PoolRegistry>(@liquid_nation);

        assert!(registry.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        let type_info = type_info::type_of<CoinType>(); 
        if (!table::contains(&registry.supported_tokens, type_info)) {
            lp_token::initialize_lp_token<CoinType>();
            // Add token to registry
            table::add(&mut registry.supported_tokens, type_info, true);
        };

        // Initialize pool state
        move_to(admin, PoolState<CoinType> {
            total_deposits: 0,
            total_lp_tokens: 0,
            active_positions_value: 0,
            cumulative_pnl: 0,
            pnl_is_positive: true,
            fee_reserves: 0,
            asset_balance: coin::zero<CoinType>(),
            admin: admin_addr,
            paused: false,
        });
    }

    /// Deposit liquidity to pool
    public entry fun deposit<CoinType>(
        depositor: &signer,
        amount: u64,
    ) acquires PoolState {
        let depositor_addr = signer::address_of(depositor);
        let pool = borrow_global_mut<PoolState<CoinType>>(@liquid_nation);
        
        assert!(!pool.paused, error::permission_denied(E_POOL_PAUSED));
        assert!(amount >= MIN_DEPOSIT, error::invalid_argument(E_INVALID_AMOUNT));

        // Calculate LP tokens to mint
        let lp_tokens_to_mint = if (pool.total_lp_tokens == 0) {
            // First deposit - 1:1 ratio
            amount
        } else {
            // Calculate based on current pool value
            let pool_value = calculate_pool_value(pool);
            assert!(pool_value > 0, error::invalid_state(E_INVALID_AMOUNT));

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

    /// Withdraw liquidity from pool
    public entry fun withdraw<CoinType>(
        withdrawer: &signer,
        lp_tokens_to_burn: u64
    ) acquires PoolState {
        let withdrawer_addr = signer::address_of(withdrawer);
        let pool = borrow_global_mut<PoolState<CoinType>>(@liquid_nation);
        
        assert!(!pool.paused, error::permission_denied(E_POOL_PAUSED));
        assert!(lp_tokens_to_burn > 0, error::invalid_argument(E_INVALID_AMOUNT));

        assert!(
            lp_token::balance<CoinType>(withdrawer_addr) >= lp_tokens_to_burn,
            error::invalid_argument(E_INSUFFICIENT_BALANCE)
        );

        // Calculate withdrawal amount
        let pool_value = calculate_pool_value(pool);
        assert!(pool.total_lp_tokens > 0, error::invalid_state(E_INVALID_AMOUNT));
        let withdrawal_amount = if (pool.total_lp_tokens > 0) {
            (lp_tokens_to_burn * pool_value) / pool.total_lp_tokens
        } else {
            0
        };
        
        assert!(
            coin::value(&pool.asset_balance) >= withdrawal_amount,
            error::resource_exhausted(E_INSUFFICIENT_BALANCE)
        );

        // Burn LP tokens
        lp_token::burn_from<CoinType>(withdrawer, lp_tokens_to_burn);


        // Transfer coins to withdrawer
        let withdrawal_coins = coin::extract(&mut pool.asset_balance, withdrawal_amount);
        coin::deposit(withdrawer_addr, withdrawal_coins);

        // Update pool state
        assert!(pool.total_deposits >= withdrawal_amount, error::invalid_state(E_INSUFFICIENT_BALANCE));

        pool.total_deposits = pool.total_deposits - withdrawal_amount;
        pool.total_lp_tokens = pool.total_lp_tokens - lp_tokens_to_burn;

        let token_name = coin::name<CoinType>();

        // Emit event
        event::emit(PoolWithdrawal {
            withdrawer: withdrawer_addr,
            token_name,
            amount: withdrawal_amount,
            lp_tokens_burned: lp_tokens_to_burn,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Deposit asset from trading positions
    public fun deposit_asset<CoinType>(coins: Coin<CoinType>) acquires PoolState {
        let pool = borrow_global_mut<PoolState<CoinType>>(@liquid_nation);
        let amount = coin::value(&coins);
        
        coin::merge(&mut pool.asset_balance, coins);
        pool.active_positions_value = pool.active_positions_value + amount;
    }

    /// Withdraw payout for winning positions
    public fun withdraw_payout<CoinType>(payout_amount: u64, wagered_amount: u64): Coin<CoinType> acquires PoolState {
        let pool = borrow_global_mut<PoolState<CoinType>>(@liquid_nation);
        
        assert!(
            coin::value(&pool.asset_balance) >= payout_amount,
            error::resource_exhausted(E_INSUFFICIENT_BALANCE)
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

    /// Record loss from liquidated position (pool gains money)
    public fun record_loss<CoinType>(amount: u64) acquires PoolState {
        let pool = borrow_global_mut<PoolState<CoinType>>(@liquid_nation);
        
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
        assert!(pool.active_positions_value >= amount, error::invalid_state(E_INSUFFICIENT_BALANCE));

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

    /// Distribute fees to pool
    public fun distribute_fees<CoinType>(fee_coins: Coin<CoinType>) acquires PoolState {
        let pool = borrow_global_mut<PoolState<CoinType>>(@liquid_nation);
        let fee_amount = coin::value(&fee_coins);
        
        coin::merge(&mut pool.asset_balance, fee_coins);
        pool.fee_reserves = pool.fee_reserves + fee_amount;

        let token_name = coin::name<CoinType>();

        // Emit event
        event::emit(FeeDistributed {
            token_name,
            amount: fee_amount,
            timestamp: timestamp::now_seconds(),
        });
    }
    

    // ======================================================================================================================================================
    //                                                              VIEW FUNCTIONS
    // ======================================================================================================================================================

    #[view]
    public fun get_pool_info<CoinType>(): (u64, u64, u64, u64, bool) acquires PoolState {
        let pool = borrow_global<PoolState<CoinType>>(@liquid_nation);
        (
            pool.total_deposits,
            pool.total_lp_tokens,
            coin::value(&pool.asset_balance),
            pool.cumulative_pnl,
            pool.pnl_is_positive
        )
    }

    #[view]
    public fun get_pool_value<CoinType>(): u64 acquires PoolState {
        let pool = borrow_global<PoolState<CoinType>>(@liquid_nation);
        calculate_pool_value(pool)
    }

    #[view]
    public fun calculate_lp_token_value<CoinType>(lp_tokens: u64): u64 acquires PoolState {
        let pool = borrow_global<PoolState<CoinType>>(@liquid_nation);
        if (pool.total_lp_tokens == 0) {
            0
        } else {
            let pool_value = calculate_pool_value(pool);
            (lp_tokens * pool_value) / pool.total_lp_tokens
        }
    }

    #[view]
    public fun is_token_supported<CoinType>(): bool acquires PoolRegistry {
        let registry = borrow_global<PoolRegistry>(@liquid_nation);
        let type_info = type_info::type_of<CoinType>();
        table::contains(&registry.supported_tokens, type_info)
    }
    
    #[view]
    /// Checks if pool can cover maximum payout
    public fun can_cover_payout<CoinType>(max_payout: u64): bool acquires PoolState {
        let pool = borrow_global<PoolState<CoinType>>(@liquid_nation);
        let available_balance = coin::value(&pool.asset_balance);
        
        // Reserve some liquidity for withdrawals
        let reserved_amount = available_balance / 20; // 5% operational buffer
        let available_for_payouts = if (available_balance > reserved_amount) {
            available_balance - reserved_amount
        } else {
            0
        };
        
        max_payout <= available_for_payouts
    }


    // ======================================================================================================================================================
    //                                                              ADMIN FUNCTIONS
    // ======================================================================================================================================================


    /// Pauses the deposit and withdraw
    public entry fun pause_pool<CoinType>(admin: &signer) acquires PoolState {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<PoolState<CoinType>>(@liquid_nation);
        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        pool.paused = true;
    }

    /// Unpauses the deposit and withdraw
    public entry fun unpause_pool<CoinType>(admin: &signer) acquires PoolState {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<PoolState<CoinType>>(@liquid_nation);
        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        pool.paused = false;
    }

    /// Add a token
    public entry fun add_supported_token<CoinType>(
        admin: &signer,
    ) acquires PoolRegistry {
        let admin_addr = signer::address_of(admin);
        let registry = borrow_global_mut<PoolRegistry>(@liquid_nation);
        let type = type_info::type_of<CoinType>();
        
        assert!(registry.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        table::add(&mut registry.supported_tokens, type, true);
    }

    /// Remove a token
    public entry fun remove_supported_token<CoinType>(
        admin: &signer,
    ) acquires PoolRegistry {
        let admin_addr = signer::address_of(admin);
        let registry = borrow_global_mut<PoolRegistry>(@liquid_nation);
        let type = type_info::type_of<CoinType>();
        
        assert!(registry.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        table::remove(&mut registry.supported_tokens, type);
    }

    /// Allows withdrawal
    public entry fun emergency_withdraw<CoinType>(
        admin: &signer,
        amount: u64,
    ) acquires PoolState {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<PoolState<CoinType>>(@liquid_nation);
        
        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(pool.paused, error::permission_denied(E_NOT_AUTHORIZED));
        
        assert!(
            coin::value(&pool.asset_balance) >= amount,
            error::resource_exhausted(E_INSUFFICIENT_BALANCE)
        );
        
        let emergency_coins = coin::extract(&mut pool.asset_balance, amount);
        coin::deposit(admin_addr, emergency_coins);
    }
}