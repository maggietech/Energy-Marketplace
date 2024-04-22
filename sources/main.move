module energy::main {
    // Imports (adjust as needed)
    use sui::transfer;
    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::clock::{Clock, timestamp_ms};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{TxContext, sender};
    use sui::table::{Self, Table};

    use std::option::{Option, none, some, borrow};
    use std::string::{String};
    use std::vector::{};

    // Errors

    const ERROR_MARKET_CLOSED: u64 = 0;
    const ERROR_INVALID_CAP: u64 = 1;
    const ERROR_INSUFFICIENT_FUNDS: u64 = 2;
    const ERROR_WRONG_ADDRESS: u64 = 3;
    const ERROR_TIME_IS_UP: u64 = 4;


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
        price: u64,
        total_units: u64,
        dispute: bool,
        status: bool,
        buyer: Option<address>,
        energySubmitted: bool,
        created_at: u64,
        deadline: u64,
    }

    struct EnergyOfferCap has key, store {
        id: UID,
        offer_id: ID
    }

    struct Buyer has key, store {
        id: UID,
        offer_id: ID,
        buyer: address,
        quantity: u64
    }

    // A hot potato for escrow
    struct Offer {
        item: EnergyOfferCap,
        price: u64,
        recipient: address
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
        price_: u64, 
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
            price: price_,
            total_units: total_units_,
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
    public fun new_purchase(self: &EnergyOffer, offer: ID, quantity_: u64, ctx: &mut TxContext) : Buyer {
        assert!(self.price == quantity_, ERROR_INSUFFICIENT_FUNDS);
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
    public fun choose_buyer(cap: &EnergyOfferCap, offer: &mut EnergyOffer, chosen_buyer: address) : Buyer {
        assert!(cap.offer_id == object::id(offer), ERROR_INVALID_CAP);
        let buyer = table::remove(&mut offer.buyers, chosen_buyer);
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

    public fun deposit(buyer: &Buyer, offer: Offer, coin: Coin<SUI>, ctx: &mut TxContext)  {
        assert!(sender(ctx) == buyer.buyer, ERROR_WRONG_ADDRESS);
        assert!(coin::value(&coin) == buyer.quantity, ERROR_INSUFFICIENT_FUNDS);
        let Offer {
            item,
            price,
            recipient
        } = offer;
        assert!(coin::value(&coin) == price, ERROR_INSUFFICIENT_FUNDS);
        transfer::public_transfer(item, sender(ctx));
        transfer::public_transfer(coin, recipient);
    }

    // Provider confirms energy delivery
    public fun confirm_energy(cap: EnergyOfferCap, self: &mut EnergyOffer, ctx: &mut TxContext) : Offer {
        assert!(cap.offer_id == object::id(self), ERROR_INVALID_CAP);
        self.status = true; 
        let offer = Offer {
            item: cap,
            price: self.price,
            recipient: sender(ctx)
        };
       offer
    }
}
