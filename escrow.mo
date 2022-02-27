import Array        "mo:base/Array";
import Blob         "mo:base/Blob";
import Bool         "mo:base/Bool";
import Debug        "mo:base/Debug";
import Error        "mo:base/Error";
import Float        "mo:base/Float";
import Hash         "mo:base/Hash";
import HashMap      "mo:base/HashMap";
import Int          "mo:base/Int";
import Iter         "mo:base/Iter";
import Nat          "mo:base/Nat";
import Nat64        "mo:base/Nat64";
import Principal    "mo:base/Principal";
import Result       "mo:base/Result";
import Text         "mo:base/Text";
import Time         "mo:base/Time";
import Trie         "mo:base/Trie";

// import Ledger       "canister:ledger";

import Account      "./account";
import Hex          "./hex";
import Types        "./types";
import Utils        "./utils";

actor class EscrowCanister(recipient: Principal, nftNumber : Nat, nftPriceE8S : Nat, endTime : Time.Time) = this {

    stable var nextSubAccount : Nat = 1_000_000_000;

    // CONSTS
    let FEE : Nat64 = 10_000;
    let CROWDFUNDNFT_ACCOUNT = "8ac924e2eb6ad3d5c9fd6db905716aa04d949fe1a944442844214f59cf024e53";

    type AccountId = Types.AccountId; // Blob
    type AccountIdText = Types.AccountIdText;
    type Subaccount = Types.Subaccount; // Nat
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

    stable var accountInfo : Trie.Trie<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)> = Trie.empty();
    stable var logsCSV : Text = "time, info, isIncoming, from, to, amount, blockHeight, worked\n";

    type AccountIdAndTime = {
        accountId   : AccountIdText;
        time        : Time.Time;
    };
    stable var emptyAccounts : [AccountIdAndTime] = [];
    stable var confirmedAccounts : [AccountIdAndTime] = [];

    // SUBACCOUNTS

    public func getNewAccountId (principal: Principal) : async AccountIdText {
        if (getNumberOfUncancelledSubaccounts() >= nftNumber) throw Error.reject("Not enough subaccounts.");
        if (principalHasUncancelledSubaccount(principal)) throw Error.reject("Principal already has an uncancelled subaccount.");
        let subaccount = nextSubAccount;
        nextSubAccount += 1;
        let subaccountBlob : SubaccountBlob = Utils.subToSubBlob(subaccount);
        let accountIdText = Utils.accountIdToHex(Account.getAccountId(getPrincipal(), subaccountBlob));
        accountInfo := Trie.putFresh<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(accountIdText), Text.equal, (principal, #empty, subaccountBlob));
        emptyAccounts := Array.append<AccountIdAndTime>(emptyAccounts, [{ accountId = accountIdText; time = Time.now() }]);
        return accountIdText;
    };

    // RELEASE FUNDS TO PROJECT CREATOR

    public func releaseFunds () : async Nat {

        assert(projectIsFullyFunded());

        var errors = 0;
        let defaultAccountId = Account.getAccountId(getPrincipal(), Utils.defaultSubaccount());

        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo)) {
            let accountIdText = kv.0;
            let accountId = Utils.hexToAccountId(accountIdText);
            let principal = kv.1.0;
            let status = kv.1.1;
            let subBlob = kv.1.2;

            if (status == #funded) {
                let amountInSubaccount = (await accountBalance(accountId)).e8s;
                switch(await transfer("sub to default account", ?subBlob, defaultAccountId, { e8s = amountInSubaccount - FEE })) {
                    case (#ok(nat)) {};
                    case (#err(err)) { errors += 1; };
                };
            } else { // there should be no funds in subaccount, but just in case, we return it to backer
                let amountInSubaccount = (await accountBalance(accountId)).e8s;
                if (amountInSubaccount > FEE) {
                    switch(await transfer("refund from non-#funded account", ?subBlob, Account.getAccountId(principal, Utils.defaultSubaccount()), { e8s = amountInSubaccount - FEE })) {
                        case (#ok(nat)) {};
                        case (#err(err)) { errors += 1; }; 
                    };
                };
            };
        };

        let expectedPayout = Nat64.fromNat(Int.abs(Float.toInt(Float.fromInt(nftNumber) * Float.fromInt(nftPriceE8S) * 0.95))); // We take a 5% cut.
        let total : Nat64 = (await accountBalance(defaultAccountId)).e8s;
        switch(await transfer("payout to project creator", null, defaultAccountId, { e8s = expectedPayout - FEE })) {
            case (#ok(nat)) {};
            case (#err(err)) { errors += 1; };  
        };

        // Our cut
        let ourCut = total - expectedPayout;
        let ourAccountId = Utils.hexToAccountId(CROWDFUNDNFT_ACCOUNT);
        switch(await transfer("crowdfundnft 5% cut", null, ourAccountId, { e8s = ourCut - FEE })) {
            case (#ok(nat)) {};
            case (#err(err)) { errors += 1; };   
        };

        return errors;
    };

    // REFUND BACKERS

    public func returnFunds () : async Nat {

        assert(Time.now() > endTime);

        var errors = 0;

        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo)) {
            let accountIdText = kv.0;
            let accountId = Utils.hexToAccountId(accountIdText);
            let principal = kv.1.0;
            let status = kv.1.1;
            let subBlob = kv.1.2;
            let amountInSubaccount = (await accountBalance(accountId)).e8s;
            if (amountInSubaccount > FEE) {
                switch(await transfer("refund to backer because not fully-funded", ?subBlob, Account.getAccountId(principal, Utils.defaultSubaccount()), { e8s = amountInSubaccount - FEE })) {
                    case (#ok(nat)) {};
                    case (#err(err)) { errors += 1; };    
                };
            };
        };

        return errors;

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
        try {
            let now = Time.now();
            let cutoff = now - 1_000_000_000 * 60 * 2; // 2 minutes (nanoseconds * seconds * minutes)
            var newEmptyAccounts : [AccountIdAndTime] = [];
            var newConfirmedAccounts : [AccountIdAndTime] = [];
            if (emptyAccounts.size() > 0) {
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
                        newEmptyAccounts := Array.append<AccountIdAndTime>(newEmptyAccounts, [{ accountId = accountIdText; time = time; }]);
                    };
                };
            };
            Debug.print("confirmedAccounts.size() " # Nat.toText(confirmedAccounts.size()));
            if (confirmedAccounts.size() > 0) {
                // Check if funds have been recieved. After 2 minutes, subaccount status is changed to cancelled.
                for (acc in Iter.fromArray(confirmedAccounts)) {
                    let accountIdText = acc.accountId;
                    let time = acc.time;
                    let accountId = Utils.hexToAccountId(accountIdText);
                    Debug.print(accountIdText # " " # Int.toText(time));
                    switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(accountIdText), Text.equal)) {
                        case (?pss) { 
                            Debug.print("here");
                            var balance : Nat64 = 0;
                            try {
                                balance := (await accountBalance(accountId)).e8s;
                            } catch (e) { };
                            Debug.print(Nat64.toText(balance) # " " # Nat64.toText(Nat64.fromNat(nftPriceE8S)));
                            if (balance >= Nat64.fromNat(nftPriceE8S)) {
                                accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pss.0, #funded, pss.2)).0;
                                log({
                                    info = "transfer into the escrow";
                                    isIncoming = true;
                                    from = null;
                                    to = accountId;
                                    amount = { e8s = balance };
                                    blockHeight = 0;
                                    worked = true;
                                })
                            } else {
                                if (time < cutoff) {
                                    accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pss.0, #cancelled, pss.2)).0;
                                } else {
                                    newConfirmedAccounts := Array.append<AccountIdAndTime>(newConfirmedAccounts, [acc]);
                                };
                            };
                        };
                        case null { };
                    };
                };
            };
            emptyAccounts := newEmptyAccounts;
            confirmedAccounts := newConfirmedAccounts;
            previousHeartbeatDone := true;
        } catch (e) {
            previousHeartbeatDone := true;
        };
    };

    // LEDGER WRAPPERS

    func accountBalance (account: AccountId) : async ICPTs {
        await Ledger.account_balance_dfx({ account = account });
    };

    func transfer (info: Text, from: ?SubaccountBlob, to: AccountId, amount: ICPTs) : async Result.Result<Nat64, Text> {
        try {
            let blockHeight = await Ledger.send_dfx({
                memo = Nat64.fromNat(0);
                from_subaccount = from;
                to = to;
                amount = amount;
                fee = { e8s = FEE };
                created_at_time = ?Time.now();
            });
            log({
                info = info;
                isIncoming = false;
                from = from;
                to = to;
                amount = amount;
                blockHeight = blockHeight;
                worked = true;
            });
            return #ok(blockHeight);
        } catch (e) {
            log({
                info = info;
                isIncoming = false;
                from = from;
                to = to;
                amount = amount;
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
        from : ?SubaccountBlob;
        to : AccountId;
        amount : ICPTs;
        blockHeight : Nat64;
        worked: Bool;
    };
    func log (msg : Log) : () {
        var fromString = "";
        switch (msg.from) {
            case (?f) { fromString := Utils.accountIdToHex(f); };
            case null { fromString := "null"; };
        };
        logsCSV #= Int.toText(Time.now()) # ", " # msg.info # ", " # Bool.toText(msg.isIncoming) # ", " # fromString # ", " # Utils.accountIdToHex(msg.to) # ", " # Nat64.toText(msg.amount.e8s) # ", " # Nat64.toText(msg.blockHeight) # ", " # Bool.toText(msg.worked) # "\n";
    };

    public query func getLogs () : async Text { logsCSV; };
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