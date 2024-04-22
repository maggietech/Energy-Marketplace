module energy::main {
    // Imports (adjust as needed)
    use sui::transfer;
    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock, timestamp_ms};
    use sui::object::{Self, UID, ID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext, sender};
    use sui::table::{Self, Table};

    use std::option::{Option, none, some, is_some,borrow};
    use std::string::{Self, String};
    use std::vector::{Self};

    // Errors
    const ERROR_INVALID_PROVIDER: u64 = 0;
    const ERROR_MARKET_CLOSED: u64 = 1;
    const ERROR_INVALID_CAP: u64 = 2;
    const ERROR_INSUFFICIENT_FUNDS: u64 = 3;
    const ERROR_ENERGY_NOT_SUBMITTED: u64 = 4;
    const ERROR_WRONG_ADDRESS: u64 = 5;
    const ERROR_TIME_IS_UP: u64 = 6;
    const ERROR_INCORRECT_PARTY: u64 = 7;
    const ERROR_DISPUTE_FALSE: u64 = 8;

    // Struct definitions

    // EnergyOffer struct
    struct EnergyOffer has key, store {
        id: UID,
        inner: ID,
        provider: address,
        buyers: Table<address, Buyer>,
        description: String,
        energy_type: String,
        price_per_unit: u64,
        total_units: u64,
        pay: Balance<SUI>,
        dispute: bool,
        status: bool,
        buyer: Option<address>,
        energySubmitted: bool,
        created_at: u64,
        deadline: u64,
    }

    struct EnergyOfferCap has key {
        id: UID,
        offer_id: ID
    }

    struct Buyer has key, store {
        id: UID,
        offer_id: ID,
        buyer: address,
        quantity: u64
    }

    struct Complaint has key, store {
        id: UID,
        buyer: address,
        provider: address,
        reason: String,
        decision: bool,
    }

    struct AdminCap has key {id: UID}

    fun init(ctx: &mut TxContext) {
        transfer::transfer(AdminCap{id: object::new(ctx)}, sender(ctx));
    }

    // Accessors
    public fun get_offer_description(offer: &EnergyOffer): String {
        offer.description
    }

    public fun get_offer_price_per_unit(offer: &EnergyOffer): u64 {
        offer.price_per_unit
    }

    public fun get_offer_status(offer: &EnergyOffer): bool {
        offer.status
    }

    public fun get_offer_deadline(offer: &EnergyOffer): u64 {
        offer.deadline
    }

    // Public - Entry functions

    // Create a new energy offer
    public entry fun new_offer(
        c: &Clock, 
        description_: String,
        energy_type_: String,
        price_per_unit_: u64, 
        total_units_: u64, 
        duration_: u64, 
        ctx: &mut TxContext
        ) {
        let id_ = object::new(ctx);
        let inner_ = object::uid_to_inner(&id_);
        let deadline_ = timestamp_ms(c) + duration_;

        transfer::share_object(EnergyOffer {
            id: id_,
            inner: inner_,
            provider: sender(ctx),
            buyers: table::new(ctx),
            description: description_,
            energy_type: energy_type_,
            price_per_unit: price_per_unit_,
            total_units: total_units_,
            pay: balance::zero(),
            dispute: false,
            status: false,
            buyer: none(),
            energySubmitted: false,
            created_at: timestamp_ms(c),
            deadline: deadline_
        });

        transfer::transfer(EnergyOfferCap{id: object::new(ctx), offer_id: inner_}, sender(ctx));
    }

    // Buyers should create a new purchase
    public fun new_purchase(offer: ID, quantity_: u64, ctx: &mut TxContext) : Buyer {
        let buyer = Buyer {
            id: object::new(ctx),
            offer_id: offer,
            buyer: sender(ctx),
            quantity: quantity_
        };
        buyer
    }

    // Buyers can bid for energy
    public fun bid_energy(offer: &mut EnergyOffer, purchase: Buyer, ctx: &mut TxContext) {
        assert!(!offer.status, ERROR_MARKET_CLOSED);
        table::add(&mut offer.buyers, sender(ctx), purchase);
    }

    // Energy provider should choose buyer and send energy to buyer object
    public fun choose_buyer(cap: &EnergyOfferCap, offer: &mut EnergyOffer, coin: Coin<SUI>, chosen_buyer: address) : Buyer {
        assert!(cap.offer_id == object::id(offer), ERROR_INVALID_CAP);
        assert!(coin::value(&coin) >= offer.price_per_unit, ERROR_INSUFFICIENT_FUNDS);

        let buyer = table::remove(&mut offer.buyers, chosen_buyer);
        let balance_ = coin::into_balance(coin);
        // Submit the payment
        balance::join(&mut offer.pay, balance_);
        // Close the offer
        offer.status = true;
        // Set the buyer's address 
        offer.buyer = some(chosen_buyer);
        buyer
    }

    // Buyer should submit energy purchase
    public fun submit_energy(self: &mut EnergyOffer, c:&Clock, ctx: &mut TxContext) {
        assert!(timestamp_ms(c) < self.deadline, ERROR_TIME_IS_UP);
        assert!(*borrow(&self.buyer) == sender(ctx), ERROR_WRONG_ADDRESS);
        self.energySubmitted = true;
    }

    // Provider confirms energy delivery
    public fun confirm_energy(cap: &EnergyOfferCap, self: &mut EnergyOffer, ctx: &mut TxContext) {
        assert!(cap.offer_id == object::id(self), ERROR_INVALID_CAP);
        assert!(self.energySubmitted, ERROR_ENERGY_NOT_SUBMITTED);
        
        let balance_ = balance::withdraw_all(&mut self.pay);
        let coin_ = coin::from_balance(balance_, ctx);
        
        transfer::public_transfer(coin_, *borrow(&self.buyer));
    }

    // Either buyer or provider can raise a complaint
    public fun raise_complaint(self: &mut EnergyOffer, c:&Clock, reason_: String, ctx: &mut TxContext) {
        assert!(timestamp_ms(c) > self.deadline, ERROR_TIME_IS_UP);

        let complainant = sender(ctx);
        let other_party = self.provider;

        assert!(complainant == sender(ctx) || other_party == sender(ctx), ERROR_INCORRECT_PARTY);

        // Define the complaint
        let complaint_ = Complaint{
            id: object::new(ctx),
            buyer: sender(ctx),
            provider: other_party,
            reason: reason_,
            decision: false,
        };
        self.dispute = true;

        transfer::share_object(complaint_);
    }

    // Admin resolves disputes
    public fun resolve_dispute(
        _: &AdminCap,
        self: &mut EnergyOffer,
        complaint: &mut Complaint,
        decision: bool,
        ctx: &mut TxContext
    ) {
        assert!(self.dispute, ERROR_DISPUTE_FALSE);
        let complainant = complaint.buyer;
        let provider = complaint.provider;

        // If admin decides true, resolve the dispute
        if(decision == true) { 
            let balance_ = balance::withdraw_all(&mut self.pay);
            let coin_ = coin::from_balance(balance_, ctx);
            transfer::public_transfer(coin_, *borrow(&self.buyer));
        }
    }
}
