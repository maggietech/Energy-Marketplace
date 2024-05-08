module energy_marketplace::energy_marketplace {

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
    const ERROR_INSUFFICIENT_UNITS: u64 = 9;

    // Struct definitions

    // EnergyOffer struct
    struct EnergyOffer has key, store {
        id: UID,
        inner: ID,
        provider: address,
        offers: Table<address, BuyerOffer>,
        description: String,
        energy_type: String,
        total_units: u64,
        agreed_price: u64,
        pay: Balance<SUI>,
        dispute: bool,
        status: bool,
        buyer: Option<address>,
        energySubmitted: bool,
        completed: bool,
        created_at: u64,
        deadline: u64,
    }

    struct EnergyOfferCap has key {
        id: UID,
        offer_id: ID
    }

    struct BuyerOffer has key, store {
        id: UID,
        offer_id: ID,
        buyer: address,
        offer_price: u64
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
            offers: table::new(ctx),
            description: description_,
            energy_type: energy_type_,
            total_units: total_units_,
            agreed_price: 0,
            pay: balance::zero(),
            dispute: false,
            status: false,
            buyer: none(),
            energySubmitted: false,
            completed: false,
            created_at: timestamp_ms(c),
            deadline: deadline_
        });

        transfer::transfer(EnergyOfferCap{id: object::new(ctx), offer_id: inner_}, sender(ctx));
    }

    // Buyers can bid for energy
    public fun bid_energy(offer: &mut EnergyOffer, quantity_: u64, ctx: &mut TxContext) {
        assert!(!offer.status, ERROR_MARKET_CLOSED);
        let buyer = BuyerOffer {
            id: object::new(ctx),
            offer_id: object::id(offer),
            buyer: sender(ctx),
            offer_price: quantity_
        };
        table::add(&mut offer.offers, sender(ctx), buyer);
    }

    // Energy provider should choose buyer and send energy to buyer object
    public fun choose_buyer(cap: &EnergyOfferCap, offer: &mut EnergyOffer, chosen_buyer: address) : BuyerOffer {
        assert!(cap.offer_id == object::id(offer), ERROR_INVALID_CAP);
        assert!(!offer.status, ERROR_MARKET_CLOSED);
        // chosen_buyer must have an offer
        assert!(table::contains<address, BuyerOffer>(&mut offer.offers, chosen_buyer), ERROR_WRONG_ADDRESS);
        let buyer = table::remove(&mut offer.offers, chosen_buyer);
        // Close the offer
        offer.status = true;
        offer.agreed_price = buyer.offer_price;
        // Set the buyer's address 
        offer.buyer = some(chosen_buyer);
        buyer
    }
    // Energy provider should choose buyer and send energy to buyer object
    public fun deposit_to_offer(offer: &mut EnergyOffer, coin: Coin<SUI>, ctx: &mut TxContext) {
        assert!(*borrow(&offer.buyer) == sender(ctx), ERROR_WRONG_ADDRESS);
        assert!(coin::value(&coin) >= offer.agreed_price, ERROR_INSUFFICIENT_FUNDS);

        let balance_ = coin::into_balance(coin);
        // Submit the payment
        balance::join(&mut offer.pay, balance_);
    }

    // Provider should confirm that energy has been submitted
    public fun submit_energy(cap: &EnergyOfferCap, self: &mut EnergyOffer, c:&Clock, ctx: &mut TxContext) {
        assert!(cap.offer_id == object::id(self), ERROR_INVALID_CAP);
        assert!(timestamp_ms(c) < self.deadline, ERROR_TIME_IS_UP);
        self.energySubmitted = true;
    }

    // Buyer confirms energy delivery
    public fun confirm_energy(self: &mut EnergyOffer, ctx: &mut TxContext) {
        assert!(self.energySubmitted, ERROR_ENERGY_NOT_SUBMITTED);
        assert!(*borrow(&self.buyer) == sender(ctx), ERROR_WRONG_ADDRESS);
        let balance_ = balance::withdraw_all(&mut self.pay);
        let coin_ = coin::from_balance(balance_, ctx);
        self.completed = true;
        transfer::public_transfer(coin_, self.provider);
    }

    // Either buyer or provider can raise a complaint
    public fun raise_complaint(self: &mut EnergyOffer, c:&Clock, reason_: String, ctx: &mut TxContext) {
        assert!(self.status, ERROR_DISPUTE_FALSE);
        assert!(!self.completed, ERROR_DISPUTE_FALSE);
        let complainant = sender(ctx);
        let other_party = self.provider;

        assert!(complainant == *borrow(&self.buyer) || other_party == sender(ctx), ERROR_INCORRECT_PARTY);

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