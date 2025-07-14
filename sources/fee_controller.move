module liquid_nation::fee_controller {
    friend liquid_nation::position_manager;

    use std::signer;
    use std::error;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::event;
    use supra_framework::timestamp;
    use liquid_nation::treasury_pool;


    // ======================================================================================================================================================
    //                                                                          CONSTANTS
    // ======================================================================================================================================================

    
    /// 100% in basis points
    const BASIS_POINTS: u64 = 10000;

    // Error codes
    const E_INVALID_FEE_RATE: u64 = 1;
    const E_INVALID_SHARES: u64 = 2;
    const E_INVALID_ADDRESS: u64 = 3;
    const E_NOT_AUTHORIZED: u64 = 4;
    const E_NOT_INITIALIZED: u64 = 5;
    const E_PAUSED: u64 = 6;


    // ======================================================================================================================================================
    //                                                                          STRUCTS
    // ======================================================================================================================================================


    /// Fee configuration
    struct FeeConfig has key {
        fee_rate: u64, // In basis points
        treasury_share: u64, // In basis points
        protocol_share: u64, // In basis points
        protocol_recipient: address,
        admin: address,
        paused: bool,
    }

    /// Fee collection tracking
    struct FeeStats has key {
        total_fees_collected: u64,
        treasury_fees_distributed: u64,
        protocol_fees_distributed: u64,
        last_update: u64,
    }

    /// Signer capability storage
    struct ResourceAccountCapability has key {
        signer_cap: SignerCapability,
    }


    // ======================================================================================================================================================
    //                                                                          EVENTS
    // ======================================================================================================================================================


    #[event]
    struct FeeConfigUpdated has drop, store {
        old_fee_rate: u64,
        new_fee_rate: u64,
        timestamp: u64,
    }

    #[event]
    struct FeeSharesUpdated has drop, store {
        old_treasury_share: u64,
        new_treasury_share: u64,
        old_protocol_share: u64,
        new_protocol_share: u64,
        timestamp: u64,
    }

    #[event]
    struct ProtocolRecipientUpdated has drop, store {
        old_recipient: address,
        new_recipient: address,
        timestamp: u64,
    }
    

    // ======================================================================================================================================================
    //                                                                      HELPER FUNCTIONS
    // ======================================================================================================================================================

    /// Initialize fee controller
    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);

        // Create resource account for treasury pool
        let (resource_signer, signer_cap) = account::create_resource_account(admin, b"fee_controller");

        // Move the capability to the resource account
        move_to(&resource_signer, ResourceAccountCapability {
            signer_cap,
        });
        
        move_to(&resource_signer, FeeConfig {
            fee_rate: 200,
            treasury_share: 5000,
            protocol_share: 5000,
            protocol_recipient: @protocol_recipient,
            admin: admin_addr,
            paused: false,
        });

        move_to(&resource_signer, FeeStats {
            total_fees_collected: 0,
            treasury_fees_distributed: 0,
            protocol_fees_distributed: 0,
            last_update: timestamp::now_seconds(),
        });
    }


    // ======================================================================================================================================================
    //                                                                   FEE MANAGEMENT
    // ======================================================================================================================================================


    /// Distribute fees between treasury and protocol
    public(friend) fun distribute_fees<CoinType>(total_fee_amount: u64) acquires FeeConfig, FeeStats {
        let config = borrow_global<FeeConfig>(get_resource_account_address());
        let stats = borrow_global_mut<FeeStats>(get_resource_account_address());
        
        assert!(!config.paused, error::permission_denied(E_PAUSED));

        // Calculate distribution amounts
        let treasury_amount = (total_fee_amount * config.treasury_share) / BASIS_POINTS;
        let protocol_amount = (total_fee_amount * config.protocol_share) / BASIS_POINTS;

        // Distribute to protocol recipient
        treasury_pool::distribute_fees<CoinType>(total_fee_amount, treasury_amount, protocol_amount, config.protocol_recipient);

        // Update stats
        stats.total_fees_collected = stats.total_fees_collected + total_fee_amount;
        stats.treasury_fees_distributed = stats.treasury_fees_distributed + treasury_amount;
        stats.protocol_fees_distributed = stats.protocol_fees_distributed + protocol_amount;
        stats.last_update = timestamp::now_seconds();
    }


    // ======================================================================================================================================================
    //                                                              ADMIN FUNCTIONS
    // ======================================================================================================================================================


    public entry fun set_fee_rate(
        admin: &signer,
        new_fee_rate: u64,
    ) acquires FeeConfig {
        let admin_addr = signer::address_of(admin);
        let config = borrow_global_mut<FeeConfig>(get_resource_account_address());
        
        assert!(config.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_fee_rate > 0, error::invalid_argument(E_INVALID_FEE_RATE));

        let old_fee_rate = config.fee_rate;
        config.fee_rate = new_fee_rate;

        event::emit(FeeConfigUpdated {
            old_fee_rate,
            new_fee_rate,
            timestamp: timestamp::now_seconds(),
        });
    }

    public entry fun set_fee_shares(
        admin: &signer,
        new_treasury_share: u64,
        new_protocol_share: u64,
    ) acquires FeeConfig {
        let admin_addr = signer::address_of(admin);
        let config = borrow_global_mut<FeeConfig>(get_resource_account_address());
        
        assert!(config.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_treasury_share + new_protocol_share == BASIS_POINTS, error::invalid_argument(E_INVALID_SHARES));

        let old_treasury_share = config.treasury_share;
        let old_protocol_share = config.protocol_share;

        config.treasury_share = new_treasury_share;
        config.protocol_share = new_protocol_share;

        event::emit(FeeSharesUpdated{
            old_treasury_share,
            new_treasury_share,
            old_protocol_share,
            new_protocol_share,
            timestamp: timestamp::now_seconds(),
        });
    }

    public entry fun set_protocol_recipient(
        admin: &signer,
        new_recipient: address,
    ) acquires FeeConfig {
        let admin_addr = signer::address_of(admin);
        let config = borrow_global_mut<FeeConfig>(get_resource_account_address());
        
        assert!(config.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_recipient != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        let old_recipient = config.protocol_recipient;
        config.protocol_recipient = new_recipient;

        event::emit(ProtocolRecipientUpdated {
            old_recipient,
            new_recipient,
            timestamp: timestamp::now_seconds(),
        });
    }

    public entry fun pause_fee_distribution(admin: &signer) acquires FeeConfig {
        let admin_addr = signer::address_of(admin);
        let config = borrow_global_mut<FeeConfig>(get_resource_account_address());
        
        assert!(config.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        config.paused = true;
    }

    public entry fun unpause_fee_distribution(admin: &signer) acquires FeeConfig {
        let admin_addr = signer::address_of(admin);
        let config = borrow_global_mut<FeeConfig>(get_resource_account_address());
        
        assert!(config.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        config.paused = false;
    }

    public entry fun transfer_admin(
        admin: &signer,
        new_admin: address,
    ) acquires FeeConfig {
        let admin_addr = signer::address_of(admin);
        let config = borrow_global_mut<FeeConfig>(get_resource_account_address());
        
        assert!(config.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_admin != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        config.admin = new_admin;
    }

    // ======================================================================================================================================================
    //                                                              VIEW FUNCTIONS
    // ======================================================================================================================================================

    #[view]
    /// Get fee configuration
    public fun get_fee_info(): (u64, u64, u64, address, address, bool) acquires FeeConfig {
        let config = borrow_global<FeeConfig>(get_resource_account_address());
        (
            config.fee_rate,
            config.treasury_share,
            config.protocol_share,
            config.protocol_recipient,
            config.admin,
            config.paused
        )
    }

    #[view]
    public fun get_fee_stats(): (u64, u64, u64, u64) acquires FeeStats {
        let stats = borrow_global<FeeStats>(get_resource_account_address());
        (
            stats.total_fees_collected,
            stats.treasury_fees_distributed,
            stats.protocol_fees_distributed,
            stats.last_update
        )
    }

    #[view]
    /// Calculate fee amount
    public fun calculate_fee(amount: u64): u64 acquires FeeConfig {
        let config = borrow_global<FeeConfig>(get_resource_account_address());
        (amount * config.fee_rate) / BASIS_POINTS
    }

    #[view]
    /// Returns the resource account address
    fun get_resource_account_address(): address {
        account::create_resource_address(&@liquid_nation, b"fee_controller")
    }
}