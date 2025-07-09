module liquid_nation::lp_token {
    friend liquid_nation::treasury_pool;

    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::table::{Self, Table};
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::coin::{Self, Coin, BurnCapability, FreezeCapability, MintCapability};
    use supra_framework::type_info::{Self, TypeInfo};


    // ======================================================================================================================================================
    //                                                                          CONSTANTS
    // ======================================================================================================================================================


    // Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_TOKEN_NOT_INITIALIZED: u64 = 3;
    const E_TOKEN_ALREADY_INITIALIZED: u64 = 5;


    // ======================================================================================================================================================
    //                                                                          STRUCTS
    // ======================================================================================================================================================


    /// LP Token struct for each supported coin type
    struct LPToken<phantom CoinType> has key {}

    /// Capabilities storage
    struct LPTokenCapabilities<phantom CoinType> has key {
        mint_cap: MintCapability<LPToken<CoinType>>,
        burn_cap: BurnCapability<LPToken<CoinType>>,
        freeze_cap: FreezeCapability<LPToken<CoinType>>,
    }

    // Registry for all LP tokens
    struct LPTokenRegistry has key {
        token_names: Table<TypeInfo, bool>,
        admin: address,
    }

    /// Signer capability storage
    struct ResourceAccountCapability has key {
        signer_cap: SignerCapability,
    }


    // ======================================================================================================================================================
    //                                                                      HELPER FUNCTIONS
    // ======================================================================================================================================================


    /// Initialize the module - called automatically when module is published
    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);
    
        // Create resource account for LP tokens
        let (resource_signer, signer_cap) = account::create_resource_account(admin, b"lp_tokens");
    
        // Store the capability in the admin's account for future use
        move_to(admin, ResourceAccountCapability {
            signer_cap,
        });
    
        // Move registry to the resource account
        move_to(&resource_signer, LPTokenRegistry {
            token_names: table::new(),
            admin: admin_addr,
        });
    }


    // ======================================================================================================================================================
    //                                                                      TOKEN MANAGEMENT
    // ======================================================================================================================================================


    // Initialize LP token for a specific underlying coin type
    public(friend) fun initialize_lp_token<CoinType>() acquires LPTokenRegistry, ResourceAccountCapability {
        let resource_addr = get_resource_account_address();

        if (!exists<LPTokenRegistry>(resource_addr)) {
            abort error::not_found(E_TOKEN_NOT_INITIALIZED)
        };

        let registry = borrow_global_mut<LPTokenRegistry>(resource_addr);

        // Check if already initialized
        let type_info = type_info::type_of<CoinType>();
        assert!(!table::contains(&registry.token_names, type_info), error::already_exists(E_TOKEN_ALREADY_INITIALIZED));

        // Get resource account signer
        let resource_cap = borrow_global<ResourceAccountCapability>(@liquid_nation);
        let resource_signer = account::create_signer_with_capability(&resource_cap.signer_cap);

        // Get coin information
        let coin_name = coin::name<CoinType>();
        let coin_symbol = coin::symbol<CoinType>();
        let coin_decimals = coin::decimals<CoinType>();

        // Create LP token name and symbol
        let mut lp_name = string::utf8(b"LP-");
        string::append(&mut lp_name, coin_name);

        let mut lp_symbol = string::utf8(b"lp");
        string::append(&mut lp_symbol, coin_symbol);

        // Initialize the LP token capabilities using resource account
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<LPToken<CoinType>>(
            &resource_signer,
            lp_name,
            lp_symbol,
            coin_decimals,
            true // monitor_supply
        );

        // Store capabilities in resource account
        move_to(&resource_signer, LPTokenCapabilities<CoinType> {
            mint_cap,
            burn_cap,
            freeze_cap,
        });

        // Mark as initialized
        table::add(&mut registry.token_names, type_info, true);
    }

    /// Mint LP tokens to a user (called by treasury pool)
    public(friend) fun mint_to<CoinType>(
        recipient: address,
        amount: u64,
    ) acquires LPTokenCapabilities {
        let resource_addr = get_resource_account_address();
        let caps = borrow_global<LPTokenCapabilities<CoinType>>(resource_addr);
        let coins = coin::mint(amount, &caps.mint_cap);
        coin::force_deposit(recipient, coins);
    }

    /// Burn LP tokens from a user (called by treasury pool)
    public(friend) fun burn_from<CoinType>(
        account: &signer,
        amount: u64,
    ) acquires LPTokenCapabilities {
        let resource_addr = get_resource_account_address();
        let caps = borrow_global<LPTokenCapabilities<CoinType>>(resource_addr);
        let coins = coin::withdraw<LPToken<CoinType>>(account, amount);
        coin::burn(coins, &caps.burn_cap);
    }

    // Transfer LP tokens between accounts
    public entry fun transfer<CoinType>(
        from: &signer,
        to: address,
        amount: u64,
    ) {
        let coins = coin::withdraw<LPToken<CoinType>>(from, amount);
        coin::force_deposit(to, coins);
    }


    // ======================================================================================================================================================
    //                                                              ADMIN FUNCTIONS
    // ======================================================================================================================================================


    public entry fun freeze_account<CoinType>(
        admin: &signer,
        account: address,
    ) acquires LPTokenCapabilities, LPTokenRegistry {
        let admin_addr = signer::address_of(admin);
        let resource_addr = get_resource_account_address();
        let registry = borrow_global<LPTokenRegistry>(resource_addr);

        assert!(registry.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));

        let caps = borrow_global<LPTokenCapabilities<CoinType>>(resource_addr);
        coin::freeze_coin_store(account, &caps.freeze_cap);
    }

    public entry fun unfreeze_account<CoinType>(
        admin: &signer,
        account: address,
    ) acquires LPTokenCapabilities, LPTokenRegistry {
        let admin_addr = signer::address_of(admin);
        let resource_addr = get_resource_account_address();
        let registry = borrow_global<LPTokenRegistry>(resource_addr);

        assert!(registry.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));

        let caps = borrow_global<LPTokenCapabilities<CoinType>>(resource_addr);
        coin::unfreeze_coin_store(account, &caps.freeze_cap);
    }

    
    // ======================================================================================================================================================
    //                                                              VIEW FUNCTIONS
    // ======================================================================================================================================================


    #[view]
    /// Get LP token balance for a user
    public fun balance<CoinType>(account: address): u64 {
        coin::balance<LPToken<CoinType>>(account)
    }

    #[view]
    /// Get LP token info
    public fun get_token_info<CoinType>(): (String, String, u8) {
        let name = coin::name<LPToken<CoinType>>();
        let symbol = coin::symbol<LPToken<CoinType>>();
        let decimals = coin::decimals<LPToken<CoinType>>();
        (name, symbol, decimals)
    }

    #[view]
    /// Get total supply of LP tokens
    public fun total_supply<CoinType>(): u128 {
        coin::supply<LPToken<CoinType>>()
    }

    #[view]
    /// Check if account is frozen
    public fun is_frozen<CoinType>(account: address): bool {
        coin::is_coin_store_frozen<LPToken<CoinType>>(account)
    }

    #[view]
    /// Returns the resource account address
    fun get_resource_account_address(): address acquires LPTokenRegistry {
        account::create_resource_address(&@liquid_nation, b"lp_tokens")
    }
}