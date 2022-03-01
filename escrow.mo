import Array        "mo:base/Array";
import Blob         "mo:base/Blob";
import Bool         "mo:base/Bool";
import Buffer       "mo:base/Buffer";
import Debug        "mo:base/Debug";
import Error        "mo:base/Error";
import Float        "mo:base/Float";
import Hash         "mo:base/Hash";
import HashMap      "mo:base/HashMap";
import Int          "mo:base/Int";
import Int64        "mo:base/Int64";
import Iter         "mo:base/Iter";
import List         "mo:base/List";
import Nat          "mo:base/Nat";
import Nat64        "mo:base/Nat64";
import Principal    "mo:base/Principal";
import Result       "mo:base/Result";
import Text         "mo:base/Text";
import Time         "mo:base/Time";
import Trie         "mo:base/Trie";

// import Backend      "canister:backend";

import Account      "./account";
import Hex          "./hex";
import Types        "./types";
import Utils        "./utils";

actor class EscrowCanister(projectId: Types.ProjectId, recipient: Principal, nftNumber : Nat, nftPriceE8S : Nat, endTime : Time.Time) = this {

    stable var nextSubAccount : Nat = 1_000_000_000;

    // CONSTS
    let FEE : Nat64 = 10_000;
    let CROWDFUNDNFT_ACCOUNT = "8ac924e2eb6ad3d5c9fd6db905716aa04d949fe1a944442844214f59cf024e53";

    type AccountId = Types.AccountId; // Blob
    type AccountIdText = Types.AccountIdText;
    type ProjectId = Types.ProjectId; // Nat
    type Subaccount = Types.Subaccount; // Nat
    type SubaccountBlob = Types.SubaccountBlob;
    type SubaccountNat8Arr = Types.SubaccountNat8Arr;
    type SubaccountStatus = Types.SubaccountStatus;

    // BACKEND
    type ProjectIdText = Text;
    type ProjectState = {
        #whitelist: [Principal];
        #live;
        #closed;
        #noproject;
    };
    let Backend = actor "54shx-2yaaa-aaaai-qbhyq-cai" : actor {
        getProjectState : shared ProjectIdText -> async ProjectState;
    };

    // LEDGER
    type AccountBalanceArgs = Types.AccountBalanceArgs;
    type ICPTs = Types.ICPTs;
    type SendArgs = Types.SendArgs;
    let Ledger = actor "ryjl3-tyaaa-aaaaa-aaaba-cai" : actor { 
        send_dfx : shared SendArgs -> async Nat64;
        account_balance_dfx : shared query AccountBalanceArgs -> async ICPTs; 
    };

    stable var accountInfo : Trie.Trie<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)> = Trie.empty();
    stable var logsCSV : Text = "time, info, isIncoming, from, to, amount, blockHeight, worked\n";

    type AccountIdAndTime = {
        accountId   : AccountIdText;
        time        : Time.Time;
    };
    stable var emptyAccounts : [AccountIdAndTime] = [];
    stable var confirmedAccounts : [AccountIdAndTime] = [];

    // DISBURSEMENTS

    type APS = (AccountIdText, Principal, SubaccountBlob);
    private stable var disbursements : [TransferRequest] = [];
    private stable var disbursementToDisburse : Nat = 0;
    private stable var subaccountsToDrain : [APS] = [];
    private stable var subaccountToDrain : Nat = 0;
    private stable var subaccountsToRefund : [APS] = [];
    private stable var subaccountToRefund : Nat = 0;
    private stable var hasStartedDrainingAccounts : Bool = false;
    private stable var hasPaidOut : Bool = false;

    private func addDisbursements(transferRequests : [TransferRequest]) : () {
        disbursements := Array.append<TransferRequest>(disbursements, transferRequests);
    };

    // SUBACCOUNTS

    public func getNewAccountId (principal: Principal) : async AccountIdText {
        if (getNumberOfUncancelledSubaccounts() >= nftNumber) throw Error.reject("Not enough subaccounts.");
        if (endTime * 1_000_000 < Time.now()) throw Error.reject("Project is past crowdfund close date.");
        if (principalHasUncancelledSubaccount(principal)) throw Error.reject("Principal already has an uncancelled subaccount.");
        func isEqPrincipal (p: Principal) : Bool { p == principal }; 
        switch ((await Backend.getProjectState(Nat.toText(projectId))) : ProjectState) {
            case (#whitelist(whitelist)) {
                if (Array.filter<Principal>(whitelist, isEqPrincipal).size() == 0) throw Error.reject("Principal is not on whitelist.");
            }; case (#closed) {
                throw Error.reject("Project is not open to funding.");
            }; case _ {};
        };
        let subaccount = nextSubAccount;
        nextSubAccount += 1;
        let subaccountBlob : SubaccountBlob = Utils.subToSubBlob(subaccount);
        let accountIdText = Utils.accountIdToHex(Account.getAccountId(getPrincipal(), subaccountBlob));
        accountInfo := Trie.putFresh<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(accountIdText), Text.equal, (principal, #empty, subaccountBlob));
        emptyAccounts := Array.append<AccountIdAndTime>(emptyAccounts, [{ accountId = accountIdText; time = Time.now() }]);
        return accountIdText;
    };

    // RELEASE FUNDS TO PROJECT CREATOR

    public func releaseFunds () : async () {
        assert(projectIsFullyFunded());
        assert(subaccountsToDrain.size() == 0 and hasStartedDrainingAccounts == false);

        let defaultAccountId = Account.getAccountId(getPrincipal(), Utils.defaultSubaccount());

        var _subaccountsToDrain : Buffer.Buffer<APS> = Buffer.Buffer<APS>(1);
        var _subaccountsToRefund : Buffer.Buffer<APS> = Buffer.Buffer<APS>(1);

        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo)) {
            let accountIdText = kv.0;
            let principal = kv.1.0;
            let status = kv.1.1;
            let subBlob = kv.1.2;

            if (status == #funded) {
                _subaccountsToDrain.add((accountIdText, principal, subBlob));
            } else { // there should be no funds in subaccount, but just in case, we return it to backer
                _subaccountsToRefund.add((accountIdText, principal, subBlob));
            };
        };

        subaccountsToDrain := _subaccountsToDrain.toArray();
        subaccountsToRefund := _subaccountsToRefund.toArray();
    };

    // REFUND BACKERS

    public func returnFunds () : async () {
        assert(endTime * 1_000_000 < Time.now() and projectIsFullyFunded() == false);

        var _subaccountsToRefund : Buffer.Buffer<APS> = Buffer.Buffer<APS>(1);

        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo)) {
            let accountIdText = kv.0;
            let principal = kv.1.0;
            let subBlob = kv.1.2;
            _subaccountsToRefund.add((accountIdText, principal, subBlob));
        };

        subaccountsToRefund := _subaccountsToRefund.toArray();
    };

    // CONFIRM/CANCEL TRANSFER

    public func confirmTransfer(a : AccountIdText) : async () {
        switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(a), Text.equal)) {
            case (?pss) { 
                if (pss.1 == #empty) {
                    accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(a), Text.equal, ?(pss.0, #confirmed, pss.2)).0;
                    confirmedAccounts := Array.append<AccountIdAndTime>(confirmedAccounts, [{ accountId = a; time = Time.now(); }]);
                } else {
                    throw Error.reject("Account is not in empty state.");
                };
            };
            case null { throw Error.reject("Account not found."); };
        };
    };

    public func cancelTransfer(a : AccountIdText) : async () {
        switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(a), Text.equal)) {
            case (?pss) { 
                if (pss.1 == #empty) {
                    accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(a), Text.equal, ?(pss.0, #cancelled, pss.2)).0;
                } else {
                    throw Error.reject("Account is not in empty state.");
                };
            };
            case null { throw Error.reject("Account not found."); };
        }; 
    };

    stable var previousHeartbeatDone = true;
    system func heartbeat() : async () {
        if (previousHeartbeatDone == false) return;
        previousHeartbeatDone := false;
        if (emptyAccounts.size() > 0) await cancelOpenAccountIds();
        if (confirmedAccounts.size() > 0) await checkConfirmedAccountsForFunds();
        if (subaccountToDrain < subaccountsToDrain.size()) await drainOneSubaccount();
        if (subaccountToRefund < subaccountsToRefund.size()) await refundOneSubaccount();
        if (disbursementToDisburse < disbursements.size()) await executeOneDisbursement();
        if (hasStartedDrainingAccounts and subaccountToDrain >= subaccountsToDrain.size()) {
            await payout();
        };
        previousHeartbeatDone := true;
    };

    func cancelOpenAccountIds() : async () {
        if (emptyAccounts.size() == 0) return;
        let cutoff = Time.now() - 1_000_000_000 * 60 * 2;
        let newEmptyAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
        // If an account hasn't recieved a confirmation or cancellation, after 2 minutes it is set to cancelled.
        for (acc in Iter.fromArray(emptyAccounts)) {
            let accountIdText = acc.accountId;
            let time = acc.time;
            if (time < cutoff) {
                switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(accountIdText), Text.equal)) {
                    case (?pss) { 
                        if (pss.1 == #empty) {
                            accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pss.0, #cancelled, pss.2)).0;
                        };
                    };
                    case null { };
                };
            } else {
                newEmptyAccounts.add(acc);
            };
        };
        emptyAccounts := newEmptyAccounts.toArray();
    };

    func checkConfirmedAccountsForFunds() : async () {
        if (confirmedAccounts.size() == 0) return;
        let cutoff = Time.now() - 1_000_000_000 * 60 * 2;
        let newConfirmedAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
        // If an account hasn't recieved a confirmation or cancellation, after 2 minutes it is set to cancelled.
        for (acc in Iter.fromArray(confirmedAccounts)) {
            let accountIdText = acc.accountId;
            let time = acc.time;
            switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(accountIdText), Text.equal)) {
                case (?pss) { 
                    var balance : Nat64 = 0;
                    try {
                        balance := (await accountBalance(accountIdText)).e8s;
                    } catch (e) { };
                    if (balance >= Nat64.fromNat(nftPriceE8S)) {
                        accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pss.0, #funded, pss.2)).0;
                        log({
                            info = "transfer into the escrow";
                            isIncoming = true;
                            from = null;
                            to = accountIdText;
                            amount = { e8s = balance };
                            blockHeight = 0;
                            worked = true;
                        })
                    } else {
                        if (time < cutoff) {
                            accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pss.0, #cancelled, pss.2)).0;
                        } else {
                            newConfirmedAccounts.add(acc);
                        };
                    };
                };
                case null { };
            };
        };
        confirmedAccounts := newConfirmedAccounts.toArray();
    };

    func executeOneDisbursement() : async () {
        if (disbursementToDisburse >= disbursements.size()) return;
        let d = disbursements[disbursementToDisburse];
        disbursementToDisburse += 1;
        switch (await transfer(d)) {
            case (#ok(nat)) { }; case (#err(err)) { 
                // todo : check how much is in subaccount and disburse that amount. if empty, remove from list
            };
        };
    };

    func drainOneSubaccount () : async () {
        hasStartedDrainingAccounts := true;
        if (subaccountToDrain >= subaccountsToDrain.size()) return;
        let s = subaccountsToDrain[subaccountToDrain];
        subaccountToDrain += 1;
        let accountIdText = s.0;
        let subBlob = s.2; 
        let defaultAccountId = Account.getAccountId(getPrincipal(), Utils.defaultSubaccount());
        let amountInSubaccount = (await accountBalance(accountIdText)).e8s;
        if (amountInSubaccount > FEE) {
            addDisbursements([{ 
                info = "sub to default account";
                from = ?Utils.subBlobToSubNat8Arr(subBlob);
                to = Utils.accountIdToHex(defaultAccountId);
                amount = { e8s = amountInSubaccount - FEE };
            }]);
        };
    };

    func refundOneSubaccount () : async () {
        if (subaccountToRefund >= subaccountsToRefund.size()) return;
        let s = subaccountsToRefund[subaccountToRefund];
        let accountIdText = s.0;
        let principal = s.1;
        let subBlob = s.2; 
        let amountInSubaccount = (await accountBalance(accountIdText)).e8s;
        if (amountInSubaccount > FEE) {
            addDisbursements([{
                info = "refund from non-#funded account";
                from = ?Utils.subBlobToSubNat8Arr(subBlob); 
                to = Utils.accountIdToHex(Account.getAccountId(principal, Utils.defaultSubaccount()));
                amount = { e8s = amountInSubaccount - FEE };
            }]);
        };
    }; 

    func payout () : async () {
        if (subaccountToRefund < subaccountsToRefund.size() or disbursementToDisburse < disbursements.size()) return;
        hasPaidOut := true;
        let defaultAccountIdHex = Utils.accountIdToHex(Account.getAccountId(getPrincipal(), Utils.defaultSubaccount()));
        let recipientAccountIdHex = Utils.accountIdToHex(Account.getAccountId(recipient, Utils.defaultSubaccount()));
        let expectedPayout = Nat64.fromNat(Int.abs(Float.toInt(Float.fromInt(nftNumber) * Float.fromInt(nftPriceE8S) * 0.95))); // We take a 5% cut.
        let total = (await accountBalance(defaultAccountIdHex)).e8s;
        var payout = expectedPayout;
        if (total < expectedPayout) {
            payout := total;
        };
        addDisbursements([{
            info = "payout to project creator";
            from = null;
            to = recipientAccountIdHex;
            amount = { e8s = payout - FEE }; 
        }]);

        // Our cut
        let ourCut : Nat64 = total - payout;
        if (ourCut > FEE) {
            addDisbursements([{
                info = "crowdfundnft 5% cut";
                from = null;
                to = CROWDFUNDNFT_ACCOUNT;
                amount = { e8s = ourCut - FEE }
            }]);
        }; 
    };

    // LEDGER WRAPPERS

    func accountBalance (account: AccountIdText) : async ICPTs {
        await Ledger.account_balance_dfx({ account = account });
    };

    type TransferRequest = {
        info: Text;
        from: ?SubaccountNat8Arr;
        to: AccountIdText;
        amount: ICPTs;
    };
    func transfer (r: TransferRequest) : async Result.Result<Nat64, Text> {
        try {
            let blockHeight = await Ledger.send_dfx({
                memo = Nat64.fromNat(0);
                from_subaccount = r.from;
                to = r.to;
                amount = r.amount;
                fee = { e8s = FEE };
                created_at_time = ?Time.now();
            });
            log({
                info = r.info;
                isIncoming = false;
                from = r.from;
                to = r.to;
                amount = r.amount;
                blockHeight = blockHeight;
                worked = true;
            });
            return #ok(blockHeight);
        } catch (e) {
            log({
                info = r.info;
                isIncoming = false;
                from = r.from;
                to = r.to;
                amount = r.amount;
                blockHeight = 0 : Nat64;
                worked = false;
            });
            return #err("Something went wrong.");
        };
    };

    // STATS

    type EscrowStats = Types.EscrowStats;
    public query func getStats () : async EscrowStats {
        var fundedSubaccounts   = 0;
        var openSubaccounts     = 0;
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo)) {
            let status = ss.1.1;
            if (status == #funded) {
                fundedSubaccounts += 1;
            };
            if (status == #empty or status == #confirmed) {
                openSubaccounts += 1;
            };
        };
        { 
            nftNumber       = nftNumber;
            nftPriceE8S     = nftPriceE8S;
            endTime         = endTime;
            nftsSold        = fundedSubaccounts;
            openSubaccounts = openSubaccounts;
        };
    };

    // LOGGING

    type Log = {
        isIncoming : Bool;
        info: Text;
        from : ?SubaccountNat8Arr;
        to : AccountIdText;
        amount : ICPTs;
        blockHeight : Nat64;
        worked: Bool;
    };
    func log (msg : Log) : () {
        var fromString = "";
        switch (msg.from) {
            case (?f) { fromString := Utils.accountIdToHex(Blob.fromArray(f)); };
            case null { fromString := "null"; };
        };
        logsCSV #= Int.toText(Time.now()) # ", " # msg.info # ", " # Bool.toText(msg.isIncoming) # ", " # fromString # ", " # msg.to # ", " # Nat64.toText(msg.amount.e8s) # ", " # Nat64.toText(msg.blockHeight) # ", " # Bool.toText(msg.worked) # "\n";
    };

    public query func getAccountsInfo () : async Text { 
        func statusToText (s : SubaccountStatus) : Text { 
            switch (s) {
                case (#funded) { return "funded" };
                case (#empty) { return "empty"; };
                case (#cancelled) { return "cancelled"; };
                case (#confirmed) { return "confirmed"; };
                case (_) { return "other"; };
            }
        };
        var csv = "accountId, principal, subaccountStatus, subaccountBlob\n";
        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo)) {
            let accountIdText = kv.0;
            let principal = kv.1.0;
            let status = kv.1.1;
            let subBlob = kv.1.2;
            csv #= accountIdText # ", " # Principal.toText(principal) # ", " # statusToText(status) # ", " # Utils.accountIdToHex(subBlob) # "\n";
        };
        return csv;
    };
    public query func getLogs () : async Text { logsCSV; };
    public query func getDisbursements () : async Text { 
        var str : Text = "index, info, from, to, amount\n";
        var i = 0;
        for (d in Iter.fromArray(disbursements)) {
            var fromStr = "null";
            switch (d.from) {
                case (?f) { fromStr := Utils.accountIdToHex(Blob.fromArray(f)); };
                case null { };
            };
            str #= Nat.toText(i) # ", " # d.info # ", " # fromStr # ", " # d.to # ", " # Nat64.toText(d.amount.e8s) # "\n";
            i += 1;
        };
        return str;
    };

    // UTILS

    func getPrincipal () : Principal {
        return Principal.fromActor(this);
    };

    func getNumberOfUncancelledSubaccounts () : Nat {
        var count = 0;
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo)) {
            let status = ss.1.1;
            if (status != #cancelled) {
                count += 1;
            };
        };
        count;
    };

    func principalHasUncancelledSubaccount (p : Principal) : Bool {
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo)) {
            if (ss.1.0 == p and ss.1.1 != #cancelled) {
                return true;
            };
        }; 
        return false;
    };

    func projectIsFullyFunded () : Bool { 
        var count = 0;
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo)) {
            if (ss.1.1 == #funded) {
                count += 1;
            };
        };
        return count == nftNumber;
    };

    func accIdTextKey(s : AccountIdText) : Trie.Key<AccountIdText> {
        { key = s; hash = Text.hash(s) };
    };

};