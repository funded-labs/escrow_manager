import E            "mo:base/Error";
import Hash         "mo:base/Hash";
import HashMap      "mo:base/HashMap";
import Int          "mo:base/Int";
import Nat64        "mo:base/Nat64";
import Principal    "mo:base/Principal";
import Time         "mo:base/Time";

import Ledger       "canister:ledger";

import Account      "./account";
import Types        "./types";
import Utils        "./utils";

actor class EscrowCanister(recipient: Types.AccountId, nftNumber : Nat, nftPriceE8S : Nat)  = this {

    stable var nextSubAccount : Nat = 1_000_000_000;

    // CONSTS
    let FEE = 10_000;
    let OUR_CANISTER_PRINCIPAL = Principal.fromText("");

    type AccountId = Types.AccountId;
    type Subaccount = Types.Subaccount;
    type SubaccountBlob = Types.SubaccountBlob;
    type SubaccountStatus = Types.SubaccountStatus;

    let subaccountStatuses = HashMap.HashMap<Subaccount, SubaccountStatus>(1, isEqSubaccount, Hash.hash);
    let subaccountToUser = HashMap.HashMap<Subaccount, Principal>(1, isEqSubaccount, Hash.hash);

    public func getNewAccountId (user: Principal) : SubaccountBlob {
        if (getNumberOfEmptyAndFundedSubaccounts() >= nftNumber) {
            throw E.reject("Not enough subaccounts.");
        };
        let subaccount = nextSubAccount;
        nextSubAccount += 1;
        subaccountToUser.put(subaccount, user);
        subaccountStatuses.put(subaccount, #empty);
        let subaccountBlob : SubaccountBlob = Utils.subToSubBlob(subaccount);
        return Account.getAccountId(getPrincipal(), subaccountBlob);
    };

    public func projectIsFullyFunded () : Bool { 
        var count = 0;
        for (status in subaccountStatuses.vals()) {
            if (status == #funded) {
                count += 1;
            };
        };
        return count == nftNumber;
    }

    // release funds to project creator
    public func releaseFunds () : async () {

        let defaultAccountId = Account.getAccountId(getPrincipal(), Utils.defaultSubaccount());

        for (kv in subaccountStatuses.entries()) {
            let subaccount = kv.0;
            let status = kv.1;

            let subBlob = Utils.subToSubBlob(subaccount);
            let accountId = Account.getAccountId(getPrincipal(), subBlob);
            if (status == #funded) {
                let amountInSubaccount = await Ledger.account_balance({ account = accountId }).e8s;
                let res = await Ledger.transfer({
                    memo = Nat64.fromNat(0);
                    from_subaccount = subBlob;
                    to = defaultAccountId;
                    amount = { e8s = amountInSubaccount - FEE };
                    fee = { e8s = FEE };
                    created_at_time = ?{ timestamp_nanos = Nat64.fromNat(Int.abs(Time.now())) };
                });
            } else { // there should be no funds in subaccount, but just in case, we return it to backer
                let amountInSubaccount = await Ledger.account_balance({ account = accountId }).e8s;
                if (amountInSubaccount > FEE) {
                    switch (subaccountToUser.get(subaccount)) {
                        case (?principal) { 
                            await Ledger.transfer({
                                memo = Nat64.fromNat(0);
                                from_subaccount = subBlob;
                                to = Account.getAccountId(principal, Utils.defaultSubaccount());
                                amount = { e8s = amountInSubaccount - FEE };
                                fee = { e8s = FEE };
                                created_at_time = ?{ timestamp_nanos = Nat64.fromNat(Int.abs(Time.now())) };
                            });
                        };
                    };
                };
            };
        }

        let expectedPayout : Nat = nftNumber * nftPriceE8S * 0.95; // We take a 5% cut.
        let total = await Ledger.account_balance({ account = defaultAccountId }).e8s;
        await Ledger.transfer({
            memo = Nat64.fromNat(0);
            from_subaccount = null;
            to = defaultAccountId;
            amount = { e8s = expectedPayout - FEE };
            fee = { e8s = FEE };
            created_at_time = ?{ timestamp_nanos = Nat64.fromNat(Int.abs(Time.now())) };
        });

        // Our cut
        let ourCut = total - expectedPayout;
        let ourAccountId = Account.getAccountId(OUR_CANISTER_PRINCIPAL, Utils.defaultSubaccount());
        await Ledger.transfer({
            memo = Nat64.fromNat(0);
            from_subaccount = null;
            to = ourAccountId;
            amount = { e8s = ourCut - FEE };
            fee = { e8s = FEE };
            created_at_time = ?{ timestamp_nanos = Nat64.fromNat(Int.abs(Time.now())) };
        });
    }

    // refund backers
    public func returnFunds () : () {

    }

    // Utils

    func getPrincipal () : Principal {
        return Principal.fromActor(this);
    };

    func getNumberOfEmptyAndFundedSubaccounts () : Nat {
        var count = 0;
        for (status in subaccountStatuses.vals()) {
            if (status == #empty || status == #funded) {
                count += 1;
            };
        };
        count;
    };

    // Comparators

    func isEqSubaccount (a: Subaccount, b: Subaccount) -> Bool { a == b; };

}