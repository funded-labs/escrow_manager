import E            "mo:base/Error";
import Float        "mo:base/Float";
import Hash         "mo:base/Hash";
import HashMap      "mo:base/HashMap";
import Int          "mo:base/Int";
import Nat64        "mo:base/Nat64";
import Principal    "mo:base/Principal";
import Time         "mo:base/Time";

// import Ledger       "canister:ledger";

import Account      "./account";
import Types        "./types";
import Utils        "./utils";

actor class EscrowCanister(recipient: Principal, nftNumber : Nat, nftPriceE8S : Nat)  = this {

    stable var nextSubAccount : Nat = 1_000_000_000;

    // CONSTS
    let FEE : Nat64 = 10_000;
    let OUR_CANISTER_PRINCIPAL = Principal.fromText("i6y63-n76h6-g7i74-ri4sk-cacpy-r5vyh-a323i-giot4-talgz-5v23z-wae");

    type AccountId = Types.AccountId;
    type Subaccount = Types.Subaccount;
    type SubaccountBlob = Types.SubaccountBlob;
    type SubaccountStatus = Types.SubaccountStatus;

    // LEDGER
    type AccountBalanceArgs = Types.AccountBalanceArgs;
    type ICPTs = Types.ICPTs;
    type SendArgs = Types.SendArgs;
    let Ledger = actor "ryjl3-tyaaa-aaaaa-aaaba-cai" : actor { 
        send_dfx : shared SendArgs -> async Nat64;
        account_balance_dfx : shared query AccountBalanceArgs -> async ICPTs; 
    };

    func isEqSubaccount (a: Subaccount, b: Subaccount) : Bool { a == b };
    let subaccountStatuses = HashMap.HashMap<Subaccount, SubaccountStatus>(1, isEqSubaccount, Hash.hash);
    let subaccountToUser = HashMap.HashMap<Subaccount, Principal>(1, isEqSubaccount, Hash.hash);

    public func getNewAccountId (user: Principal) : async SubaccountBlob {
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

    public func projectIsFullyFunded () : async Bool { 
        var count = 0;
        for (status in subaccountStatuses.vals()) {
            if (status == #funded) {
                count += 1;
            };
        };
        return count == nftNumber;
    };

    // RELEASE FUNDS TO PROJECT CREATOR

    public func releaseFunds () : async () {

        let defaultAccountId = Account.getAccountId(getPrincipal(), Utils.defaultSubaccount());

        for (kv in subaccountStatuses.entries()) {
            let subaccount = kv.0;
            let status = kv.1;

            let subBlob = Utils.subToSubBlob(subaccount);
            let accountId = Account.getAccountId(getPrincipal(), subBlob);
            if (status == #funded) {
                let amountInSubaccount = (await accountBalance(accountId)).e8s;
                let res = await transfer(?subBlob, defaultAccountId, { e8s = amountInSubaccount - FEE });
            } else { // there should be no funds in subaccount, but just in case, we return it to backer
                let amountInSubaccount = (await accountBalance(accountId)).e8s;
                if (amountInSubaccount > FEE) {
                    switch (subaccountToUser.get(subaccount)) {
                        case (?principal) { 
                            let res = await transfer(?subBlob, Account.getAccountId(principal, Utils.defaultSubaccount()), { e8s = amountInSubaccount - FEE });
                        };
                        case null {}
                    };
                };
            };
        };

        let expectedPayout = Nat64.fromNat(Int.abs(Float.toInt(Float.fromInt(nftNumber) * Float.fromInt(nftPriceE8S) * 0.95))); // We take a 5% cut.
        let total : Nat64 = (await accountBalance(defaultAccountId)).e8s;
        let payoutRes = await transfer(null, defaultAccountId, { e8s = expectedPayout - FEE });

        // Our cut
        let ourCut = total - expectedPayout;
        let ourAccountId = Account.getAccountId(OUR_CANISTER_PRINCIPAL, Utils.defaultSubaccount());
        let cutRes = await transfer(null, ourAccountId, { e8s = ourCut - FEE });
    };

    // REFUND BACKERS

    public func returnFunds () : async () {

    };

    // LEDGER WRAPPERS

    func accountBalance (account: AccountId) : async ICPTs {
        await Ledger.account_balance_dfx({ account = account });
    };

    func transfer (from: ?SubaccountBlob, to: AccountId, amount: ICPTs) : async Nat64 {
        await Ledger.send_dfx({
            memo = Nat64.fromNat(0);
            from_subaccount = from;
            to = to;
            amount = amount;
            fee = { e8s = FEE };
            created_at_time = ?Time.now();
        });
    };

    // UTILS

    func getPrincipal () : Principal {
        return Principal.fromActor(this);
    };

    func getNumberOfEmptyAndFundedSubaccounts () : Nat {
        var count = 0;
        for (status in subaccountStatuses.vals()) {
            if (status == #empty or status == #funded) {
                count += 1;
            };
        };
        count;
    };

}