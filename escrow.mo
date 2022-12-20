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

actor class EscrowCanister(projectId: Types.ProjectId, recipient: Principal, nfts: [Types.NFTInfo], endTime : Time.Time, maxNFTsPerWallet : Nat, oversellPercentage: Nat) = this {

    stable var nextSubAccount : Nat = 1_000_000_000;

    // CONSTS
    let FEE : Nat64 = 10_000;
    let CROWDFUNDNFT_ACCOUNT = "8ac924e2eb6ad3d5c9fd6db905716aa04d949fe1a944442844214f59cf024e53";

    type AccountId = Types.AccountId; // Blob
    type AccountIdText = Types.AccountIdText;
    type ProjectId = Types.ProjectId; // Nat
    type NFTInfo = Types.NFTInfo;
    type NFTInfoIndex = Nat;
    type Subaccount = Types.Subaccount; // Nat
    type SubaccountBlob = Types.SubaccountBlob;
    type SubaccountNat8Arr = Types.SubaccountNat8Arr;
    type SubaccountStatus = Types.SubaccountStatus;

    public query func getMetadata () : async ({
        projectId : ProjectId;
        recipient : Principal;
        nfts: [NFTInfo];
        endTime : Time.Time;
        maxNFTsPerWallet : Nat;
        oversellPercentage: Nat;
    }) {
        return {
            projectId = projectId;
            recipient = recipient;
            nfts = nfts;
            endTime = endTime;
            maxNFTsPerWallet = maxNFTsPerWallet;
            oversellPercentage = oversellPercentage;
        };
    };

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

    stable var accountInfo : Trie.Trie<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)> = Trie.empty();
    stable var logsCSV : Text = "time, info, isIncoming, from, to, amount, blockHeight, worked\n";

    type AccountIdAndTime = {
        accountId   : AccountIdText;
        time        : Time.Time;
    };
    var emptyAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
    var confirmedAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
    var cancelledThenConfirmedAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
    stable var _emptyAccounts : [AccountIdAndTime] = [];
    stable var _confirmedAccounts : [AccountIdAndTime] = [];
    stable var _cancelledThenConfirmedAccounts : [AccountIdAndTime] = [];

    public query func getConfirmedAccountsArray () : async [AccountIdAndTime] {
        confirmedAccounts.toArray();
    };

    public func addConfirmedAccountsToConfirmedAccountsArray () : async () {
        let newConfirmedAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo)) {
            let accountIdText = kv.0;
            let status = kv.1.1;
            if (status == #confirmed) {
                newConfirmedAccounts.add({ accountId = accountIdText; time = Time.now() });
            };
        };
        confirmedAccounts := newConfirmedAccounts;
    };

    // DISBURSEMENTS

    type APS = (AccountIdText, Principal, SubaccountBlob);

    private var disbursements : Buffer.Buffer<TransferRequest> = Buffer.Buffer<TransferRequest>(1);
    private var subaccountsToDrain : Buffer.Buffer<APS> = Buffer.Buffer<APS>(1);
    private var subaccountsToRefund : Buffer.Buffer<APS> = Buffer.Buffer<APS>(1);

    private stable var _disbursements : [TransferRequest] = [];
    private stable var disbursementToDisburse : Nat = 0;
    private stable var _subaccountsToDrain : [APS] = [];
    private stable var subaccountToDrain : Nat = 0;
    private stable var _subaccountsToRefund : [APS] = [];
    private stable var subaccountToRefund : Nat = 0;
    private stable var hasStartedDrainingAccounts : Bool = false;
    private stable var hasPaidOut : Bool = false;

    private func addDisbursements(transferRequests : [TransferRequest]) : () {
        for (tr in Iter.fromArray(transferRequests)) {
            disbursements.add(tr);
        };
    };

    system func preupgrade() {
        _emptyAccounts := emptyAccounts.toArray();
        _confirmedAccounts := confirmedAccounts.toArray();
        _cancelledThenConfirmedAccounts := cancelledThenConfirmedAccounts.toArray();
        _disbursements := disbursements.toArray();
        _subaccountsToDrain := subaccountsToDrain.toArray();
        _subaccountsToRefund := subaccountsToRefund.toArray();
    };
    stable var previousHeartbeatDone = true;
    system func postupgrade() {
        previousHeartbeatDone := true;
        emptyAccounts := Buffer.Buffer<AccountIdAndTime>(1);
        confirmedAccounts := Buffer.Buffer<AccountIdAndTime>(1);
        cancelledThenConfirmedAccounts := Buffer.Buffer<AccountIdAndTime>(1);
        disbursements := Buffer.Buffer<TransferRequest>(1);
        subaccountsToDrain := Buffer.Buffer<APS>(1);
        subaccountsToRefund := Buffer.Buffer<APS>(1);
        for (accountIdAndTime in Iter.fromArray(_emptyAccounts)) {
            emptyAccounts.add(accountIdAndTime);
        };
        for (accountIdAndTime in Iter.fromArray(_confirmedAccounts)) {
            confirmedAccounts.add(accountIdAndTime);
        };
        for (accountIdAndTime in Iter.fromArray(_cancelledThenConfirmedAccounts)) {
            cancelledThenConfirmedAccounts.add(accountIdAndTime);
        };
        for (tr in Iter.fromArray(_disbursements)) {
            disbursements.add(tr);
        };
        for (aps in Iter.fromArray(_subaccountsToDrain)) {
            subaccountsToDrain.add(aps);
        };
        for (aps in Iter.fromArray(_subaccountsToRefund)) {
            subaccountsToRefund.add(aps);
        };
        _emptyAccounts := [];
        _confirmedAccounts := [];
        _cancelledThenConfirmedAccounts := [];
        _disbursements := [];
        _subaccountsToDrain := [];
        _subaccountsToRefund := [];
    };

    // SUBACCOUNTS

    stable var projectState : ProjectState = #closed;
    public query func getProjectState() : async ProjectState {
        projectState;
    };
    public func updateProjectState () : async ProjectState {
        projectState := await Backend.getProjectState(Nat.toText(projectId));
        projectState;
    };
    let CNFT_NFT_Canister = actor "2glp2-eqaaa-aaaak-aajoa-cai" : actor { 
        principalOwnsOne : shared Principal -> async Bool;
    };

    public func getNewAccountId (principal: Principal, tier: NFTInfoIndex) : async Result.Result<AccountIdText, Text> {
        if (getNumberOfUncancelledSubaccounts(tier) >= nfts[tier].number) return #err("This project or project tier is fully funded (or almost there, so we are pausing new transfers for the time being).");
        if (endTime * 1_000_000 < Time.now()) return #err("Project is past crowdfund close date.");
        if (maxNFTsPerWallet > 0 and principalNumSubaccounts(principal) >= maxNFTsPerWallet) return #err("This project only allows each wallet to back the project " # Nat.toText(maxNFTsPerWallet) # " times. You have already attained this maximum.");
        func isEqPrincipal (p: Principal) : Bool { p == principal }; 
        switch (projectState) {
            case (#whitelist(whitelist)) {
                if (
                    Array.filter<Principal>(whitelist, isEqPrincipal).size() == 0
                    and (await CNFT_NFT_Canister.principalOwnsOne(principal)) == false
                ) return #err("Principal is not on whitelist.");
            }; case (#closed) {
                return #err("Project is not open to funding.");
            }; case _ {};
        };
        let subaccount = nextSubAccount;
        nextSubAccount += 1;
        let subaccountBlob : SubaccountBlob = Utils.subToSubBlob(subaccount);
        let accountIdText = Utils.accountIdToHex(Account.getAccountId(getPrincipal(), subaccountBlob));
        accountInfo := Trie.putFresh<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(accountIdText), Text.equal, (principal, #empty, subaccountBlob, tier));
        emptyAccounts.add({ accountId = accountIdText; time = Time.now() });
        return #ok(accountIdText);
    };
    public func testHasCNFT (principal: Principal) : async Bool {
        if (await CNFT_NFT_Canister.principalOwnsOne(principal)) return true;
        return false;
    };

    // RELEASE FUNDS TO PROJECT CREATOR

    public func releaseFunds () : async () {
        assert(projectIsFullyFunded());
        assert(subaccountsToDrain.size() == 0 and hasStartedDrainingAccounts == false);

        let defaultAccountId = Account.getAccountId(getPrincipal(), Utils.defaultSubaccount());

        var newSubaccountsToDrain : Buffer.Buffer<APS> = Buffer.Buffer<APS>(1);
        var newSubaccountsToRefund : Buffer.Buffer<APS> = Buffer.Buffer<APS>(1);

        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo)) {
            let accountIdText = kv.0;
            let principal = kv.1.0;
            let status = kv.1.1;
            let subBlob = kv.1.2;

            if (status == #funded) {
                newSubaccountsToDrain.add((accountIdText, principal, subBlob));
            } else { // there should be no funds in subaccount, but just in case, we return it to backer
                newSubaccountsToRefund.add((accountIdText, principal, subBlob));
            };
        };

        subaccountsToDrain := newSubaccountsToDrain;
        subaccountsToRefund := newSubaccountsToRefund;
    };

    public query func getSubaccountsInfo () : async ({ 
        toDrain : { index : Nat; count : Nat; arr : [APS] };
        toRefund : { index : Nat; count : Nat; arr : [APS] };
    }) {
        { 
            toDrain = { index = subaccountToDrain; count = subaccountsToDrain.size(); arr = subaccountsToDrain.toArray();};
            toRefund = { index = subaccountToRefund; count = subaccountsToRefund.size(); arr = subaccountsToRefund.toArray(); };
        };
    };

    // REFUND BACKERS

    public func returnFunds () : async () {
        assert(endTime * 1_000_000 < Time.now() and projectIsFullyFunded() == false);

        var newSubaccountsToRefund : Buffer.Buffer<APS> = Buffer.Buffer<APS>(1);

        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo)) {
            let accountIdText = kv.0;
            let principal = kv.1.0;
            let subBlob = kv.1.2;
            newSubaccountsToRefund.add((accountIdText, principal, subBlob));
        };

        subaccountsToRefund := newSubaccountsToRefund;
    };

    // CONFIRM/CANCEL TRANSFER

    let emptyAccountCutOff = 2; // minutes
    public func confirmTransfer(a : AccountIdText) : async Result.Result<(), Text> {
        switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(a), Text.equal)) {
            case (?pssi) { 
                if (pssi.1 == #empty) {
                    accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(a), Text.equal, ?(pssi.0, #confirmed, pssi.2, pssi.3)).0;
                    confirmedAccounts.add({ accountId = a; time = Time.now(); });
                    return #ok();
                } else {
                    if (pssi.1 == #confirmed) {
                        return #err("This transfer has already been confirmed.");
                    } else {
                        cancelledThenConfirmedAccounts.add({ accountId = a; time = Time.now(); });
                        return #err("You took longer than " # Nat.toText(emptyAccountCutOff) # " minutes to transfer the funds. In order to make sure that crowdfunding projects don't get 'frozen' by people who click the crowdfund button but don't transfer quickly, we don't accept transfers past this cutoff. You will be refunded within the next few minutes, and if the project is not yet fully funded, you can attempt to fund it again. Thank you for your understanding.");
                    };
                };
            };
            case null { return #err("Account not found."); };
        };
    };

    public func cancelTransfer(a : AccountIdText) : async () {
        switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(a), Text.equal)) {
            case (?pssi) { 
                if (pssi.1 == #empty) {
                    accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(a), Text.equal, ?(pssi.0, #cancelled, pssi.2, pssi.3)).0;
                } else {
                    throw Error.reject("Account is not in empty state.");
                };
            };
            case null { throw Error.reject("Account not found."); };
        }; 
    };

    public func resetHeartbeat () : async () {
        previousHeartbeatDone := true;
    };
    system func heartbeat() : async () {
        if (previousHeartbeatDone == false) return;
        previousHeartbeatDone := false;
        if (emptyAccounts.size() > 0) await cancelOpenAccountIds();
        if (confirmedAccounts.size() > 0) await checkConfirmedAccountsForFunds();
        if (cancelledThenConfirmedAccounts.size() > 0) await checkCancelledThenConfirmedAccountsForRefund();
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
        for (acc in emptyAccounts.vals()) {
            let accountIdText = acc.accountId;
            let time = acc.time;
            if (time < cutoff) {
                switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(accountIdText), Text.equal)) {
                    case (?pssi) { 
                        if (pssi.1 == #empty) {
                            accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pssi.0, #cancelled, pssi.2, pssi.3)).0;
                        };
                    };
                    case null { };
                };
            } else {
                newEmptyAccounts.add(acc);
            };
        };
        emptyAccounts := newEmptyAccounts;
    };

    func checkConfirmedAccountsForFunds() : async () {
        if (confirmedAccounts.size() == 0) return;
        let cutoff = Time.now() - 1_000_000_000 * 60 * 2;
        let newConfirmedAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
        // If an account hasn't recieved a confirmation or cancellation, after 2 minutes it is set to cancelled.
        for (acc in confirmedAccounts.vals()) {
            let accountIdText = acc.accountId;
            let time = acc.time;
            switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(accountIdText), Text.equal)) {
                case (?pssi) { 
                    var balance : Nat64 = 0;
                    try {
                        balance := (await accountBalance(accountIdText)).e8s;
                    } catch (e) { };
                    if (balance >= Nat64.fromNat(nfts[pssi.3].priceE8S)) {
                        accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pssi.0, #funded, pssi.2, pssi.3)).0;
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
                            accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pssi.0, #cancelled, pssi.2, pssi.3)).0;
                        } else {
                            newConfirmedAccounts.add(acc);
                        };
                    };
                };
                case null { };
            };
        };
        confirmedAccounts := newConfirmedAccounts;
    };

    func checkCancelledThenConfirmedAccountsForRefund() : async () {
        if (cancelledThenConfirmedAccounts.size() == 0) return;
        let cutoff = Time.now() - 1_000_000_000 * 60 * 5; // 5 minutes
        let newCancelledThenConfirmedAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
        for (acc in cancelledThenConfirmedAccounts.vals()) {
            let accountIdText = acc.accountId;
            let time = acc.time;
            switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo, accIdTextKey(accountIdText), Text.equal)) {
                case (?pssi) { 
                    var balance : Nat64 = 0;
                    try {
                        balance := (await accountBalance(accountIdText)).e8s;
                    } catch (e) { };
                    if (balance >= FEE) {
                        addDisbursements([{
                            info = "refund from non-#funded account";
                            from = ?Utils.subBlobToSubNat8Arr(pssi.2); 
                            to = Utils.accountIdToHex(Account.getAccountId(pssi.0, Utils.defaultSubaccount()));
                            amount = { e8s = balance - FEE };
                        }]);
                    } else {
                        if (time < cutoff) {
                            newCancelledThenConfirmedAccounts.add(acc);
                        };
                    };
                };
                case null { };
            };
        };
        cancelledThenConfirmedAccounts := newCancelledThenConfirmedAccounts;
    };

    func executeOneDisbursement() : async () {
        if (disbursementToDisburse >= disbursements.size()) return;
        let d = disbursements.get(disbursementToDisburse);
        disbursementToDisburse += 1;
        switch (await transfer(d)) {
            case (#ok(nat)) { }; case (#err(err)) { 
                // todo : check how much is in subaccount and disburse that amount. if empty, remove from list
            };
        };
    };

    public query func subaccountDrainingInfo () : async (Nat, Nat, Nat, Nat) {
        (subaccountsToDrain.size(), subaccountToDrain, subaccountsToRefund.size(), subaccountToRefund);
    };

    func drainOneSubaccount () : async () {
        hasStartedDrainingAccounts := true;
        if (subaccountToDrain >= subaccountsToDrain.size()) return;
        let s = subaccountsToDrain.get(subaccountToDrain);
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
        let s = subaccountsToRefund.get(subaccountToRefund);
        subaccountToRefund += 1;
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
        var expectedPayout = Nat64.fromNat(0);
        for (tier in Iter.fromArray<NFTInfo>(nfts)) {
            expectedPayout += Nat64.fromNat(Int.abs(Float.toInt(Float.fromInt(tier.number) * Float.fromInt(tier.priceE8S) * 0.95))); // We take a 5% cut.
        };
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

    type NFTStats = Types.NFTStats;
    type EscrowStats = Types.EscrowStats;
    public query func getStats () : async EscrowStats {
        var nftStats = Buffer.Buffer<NFTStats>(1);
        for (t in Iter.fromArray<NFTInfo>(nfts)) {
            nftStats.add({
                number = t.number;
                priceE8S = t.priceE8S;
                sold = 0;
                openSubaccounts = 0;
                oversellNumber = oversellNFTNumber(t.number);
            });
        };
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo)) {
            let status = ss.1.1;
            let nftInfoIndex = ss.1.3;
            if (status == #funded) {
                let curStats = nftStats.get(nftInfoIndex);
                nftStats.put(nftInfoIndex, { 
                    number = curStats.number;
                    priceE8S = curStats.priceE8S;
                    sold = curStats.sold + 1;
                    openSubaccounts = curStats.openSubaccounts; 
                    oversellNumber = oversellNFTNumber(curStats.number);
                });
            };
            if (status == #empty or status == #confirmed) {
                let curStats = nftStats.get(nftInfoIndex);
                nftStats.put(nftInfoIndex, { 
                    number = curStats.number;
                    priceE8S = curStats.priceE8S;
                    sold = curStats.sold;
                    openSubaccounts = curStats.openSubaccounts + 1; 
                    oversellNumber = oversellNFTNumber(curStats.number);
                });
            };
        };
        { 
            endTime  = endTime;
            nftStats = nftStats.toArray();
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
                // case (_) { return "other"; };
            }
        };
        var csv = "accountId,principal,subaccountStatus,subaccountBlob,nftIndex\n";
        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo)) {
            let accountIdText = kv.0;
            let principal = kv.1.0;
            let status = kv.1.1;
            let subBlob = kv.1.2;
            let nftIndex = kv.1.3;
            csv #= accountIdText # "," # Principal.toText(principal) # "," # statusToText(status) # "," # Utils.accountIdToHex(subBlob) # "," # Nat.toText(nftIndex) # "\n";
        };
        return csv;
    };
    public query func getLogs () : async Text { logsCSV; };
    public query func getDisbursements () : async Text { 
        var str : Text = "index, info, from, to, amount\n";
        var i = 0;
        for (d in disbursements.vals()) {
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

    func getNumberOfUncancelledSubaccounts (nftInfoIndex : Nat) : Nat {
        var count = 0;
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo)) {
            let status = ss.1.1;
            if (status != #cancelled and ss.1.3 == nftInfoIndex) {
                count += 1;
            };
        };
        count;
    };

    func principalHasUncancelledSubaccount (p : Principal) : Bool {
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo)) {
            if (ss.1.0 == p and ss.1.1 != #cancelled) {
                return true;
            };
        }; 
        return false;
    };
    func principalNumSubaccounts (p : Principal) : Nat {
        var count : Nat = 0;
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo)) {
            if (ss.1.0 == p and ss.1.1 != #cancelled) {
                count += 1;
            };
        };
        count;
    };

    func totalNFTNumber () : Nat { 
        var total : Nat = 0;
        for (nftInfo in Iter.fromArray<NFTInfo>(nfts)) {
            total += nftInfo.number;
        };
        total;
    };
    
    func oversellNFTNumber(number: Nat) : Nat {
        if(oversellPercentage == 0) {
            return number;
        } else {
            return Nat.mul(number, Nat.div((oversellPercentage, 100)));
        }
    };

    func projectIsFullyFunded () : Bool { 
        var count = 0;
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex)>(accountInfo)) {
            if (ss.1.1 == #funded) {
                count += 1;
            };
        };

        return count >= totalNFTNumber();
    };
    
    func accIdTextKey(s : AccountIdText) : Trie.Key<AccountIdText> {
        { key = s; hash = Text.hash(s) };
    };

};