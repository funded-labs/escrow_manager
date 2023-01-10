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
import Char         "mo:base/Char";
import Nat32        "mo:base/Nat32";
import BitcoinWallet "./BitcoinWallet";
import BitcoinApi "./BitcoinApi";
import EcdsaApi "./EcdsaApi";

import Account      "./account";
import Hex          "./hex";
import Types        "./types";
import Utils        "./utils";

actor class EscrowCanister(
    projectId: Types.ProjectId,
    recipientICP: Principal,
    recipientBTC: Text,
    nfts: [Types.NFTInfo],
    endTime : Time.Time,
    maxNFTsPerWallet : Nat,
    btcNetwork: Types.Network,
    backendPrincipal: Text,
    oversellPercentage: Nat
) = this {

    stable var nextSubAccount : Nat = 1_000_000_000;

    // CONSTS
    let FEE : Nat64 = 10_000;
    let CROWDFUNDNFT_ACCOUNT_ICP = "8ac924e2eb6ad3d5c9fd6db905716aa04d949fe1a944442844214f59cf024e53";

    // Addresses should be in 
    let CROWDFUNDNFT_ACCOUNT_BTC = switch (btcNetwork) {
        case (#Mainnet) { "1LdthGkYStYKpDkcS5w9eRXyhqEpJDQubX" };
        case (#Testnet) { "tb1qlecdyqtrvxgutaplzcmgwf2vkm8mva7tjnlmv0" };
        case _ { "2MvTdVBNz6WqBJ9aNeYmERrZ1eZMCBCPVSf" };
    };

    type AccountId = Types.AccountId; // Blob
    type AccountIdText = Types.AccountIdText;
    type ProjectId = Types.ProjectId; // Nat
    type NFTInfo = Types.NFTInfo;
    type NFTInfoIndex = Nat;
    type Subaccount = Types.Subaccount; // Nat
    type SubaccountBlob = Types.SubaccountBlob;
    type SubaccountNat8Arr = Types.SubaccountNat8Arr;
    type SubaccountStatus = Types.SubaccountStatus;
    type TransferRequest = Types.TransferRequest;

    // FOR BITCOIN INTEGRATION
    type GetUtxosResponse = Types.GetUtxosResponse;
    type MillisatoshiPerByte = Types.MillisatoshiPerByte;
    type SendRequest = Types.SendRequest;
    type BitcoinAddress = Types.BitcoinAddress;
    type ECDSAPublicKey = Types.ECDSAPublicKey;
    type ECDSAPublicKeyReply = Types.ECDSAPublicKeyReply;
    type SubaccountNetwork = Types.SubaccountNetwork; // "ICP or "BTC"

    // The derivation path to use for ECDSA secp256k1.
    let DERIVATION_PATH : [[Nat8]] = [[]];
    // The ECDSA key name.
    let KEY_NAME : Text = switch btcNetwork {
        // For local development, we use a special test key with dfx.
        case (#Regtest) "dfx_test_key";
        // On the IC we're using a test ECDSA key.
        case _ "test_key_1"
    };
    /// Returns the UTXOs of the given Bitcoin address.
    public func get_utxos(address : BitcoinAddress) : async GetUtxosResponse {
        await BitcoinApi.get_utxos(btcNetwork, address)
    };
    /// Returns the 100 fee percentiles measured in millisatoshi/byte.
    /// Percentiles are computed from the last 10,000 transactions (if available).
    public func get_current_fee_percentiles() : async [MillisatoshiPerByte] {
        await BitcoinApi.get_current_fee_percentiles(btcNetwork)
    };
    public func get_p2pkh() : async BitcoinAddress {
        await get_p2pkh_address();
    };
    public func get_balance() : async Nat64 {
        let accountId : AccountIdText = await defaultAccountId("BTC");
        await accountBalance(accountId, "BTC");
    };
    /// Returns the P2PKH address of this canister at a specific derivation path.
    func get_p2pkh_address() : async BitcoinAddress {
        await BitcoinWallet.get_p2pkh_address(btcNetwork, KEY_NAME, DERIVATION_PATH)
    };

    public query func getMetadata () : async ({
        projectId : ProjectId;
        recipientICP : Principal;
        recipientBTC: Text;
        nfts: [NFTInfo];
        endTime : Time.Time;
        maxNFTsPerWallet : Nat;
        oversellPercentage: Nat;
    }) {
        return {
            projectId = projectId;
            recipientICP = recipientICP;
            recipientBTC = recipientBTC;
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
    let Backend = actor(backendPrincipal) : actor {
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

    stable var accountInfo : Trie.Trie<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)> = Trie.empty();
    stable var logsCSV : Text = "time, info, isIncoming, from, to, amount, network, blockHeight, worked\n";

    type AccountIdAndTime = {
        accountId   : AccountIdText;
        time        : Time.Time;
    };
    type RefundDetails = {
        accountId     : AccountIdText;
        walletAddress : Text;
        email         : Text;
    };

    var emptyAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
    var confirmedAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
    var cancelledThenConfirmedAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
    var refundDetails : Buffer.Buffer<RefundDetails> = Buffer.Buffer<RefundDetails>(1);
    stable var _emptyAccounts : [AccountIdAndTime] = [];
    stable var _confirmedAccounts : [AccountIdAndTime] = [];
    stable var _cancelledThenConfirmedAccounts : [AccountIdAndTime] = [];

    public query func getConfirmedAccountsArray () : async [AccountIdAndTime] {
        confirmedAccounts.toArray();
    };

    public func addConfirmedAccountsToConfirmedAccountsArray () : async () {
        let newConfirmedAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo)) {
            let accountIdText = kv.0;
            let status = kv.1.1;
            if (status == #confirmed) {
                newConfirmedAccounts.add({ accountId = accountIdText; time = Time.now() });
            };
        };
        confirmedAccounts := newConfirmedAccounts;
    };

    // DISBURSEMENTS

    type APS = (AccountIdText, Principal, SubaccountBlob, SubaccountNetwork);

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

    public func getNewAccountId (principal: Principal, tier: NFTInfoIndex, network: SubaccountNetwork, refundWalletAddress: Text, email: Text) : async Result.Result<AccountIdText, Text> {
        if (getNumberOfUncancelledSubaccounts(tier) >= nfts[tier].number + oversellNFTNumber(nfts[tier].number)) return #err("This project or project tier is fully funded (or almost there, so we are pausing new transfers for the time being).");
        if (endTime * 1_000_000 < Time.now()) return #err("Project is past crowdfund close date.");
        if (maxNFTsPerWallet > 0 and principalNumSubaccounts(principal) >= maxNFTsPerWallet) return #err("This project only allows each wallet to back the project " # Nat.toText(maxNFTsPerWallet) # " times. You have already attained this maximum.");
        if (not isAllowedNetwork(network)) return #err("This network is unknown or not supported in this Crowdfunding round");
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
        let accountIdText : AccountIdText = await accountIdFromBlob(subaccountBlob, network);
        accountInfo := Trie.putFresh<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(accountIdText), Text.equal, (principal, #empty, subaccountBlob, tier, network));
        emptyAccounts.add({ accountId = accountIdText; time = Time.now() });
        
        if (network == "BTC") {
            refundDetails.add({ accountId = accountIdText; walletAddress = refundWalletAddress; email = email; });
        };
        return #ok(accountIdText);
    };

    public query func getRefundDetails(): async [RefundDetails] {
        refundDetails.toArray();
    };

    func isAllowedNetwork (network: Text): Bool {
        var allowedNetworks : [Types.SubaccountNetwork] = [];
        switch (nfts[0].priceE8S) {
            case (?priceE8S) {
                allowedNetworks := Array.append(allowedNetworks, ["ICP"]);
            };
            case null {};
        };
        switch (nfts[0].priceSatoshi) {
            case (?priceSatoshi) {
                allowedNetworks := Array.append(allowedNetworks, ["BTC"]);
            };
            case null {};
        };
        func isSupportedNetwork (p: SubaccountNetwork) : Bool { p == network };
        Array.filter<SubaccountNetwork>(allowedNetworks, isSupportedNetwork).size() > 0;
    };

    func accountIdFromBlob (subaccountBlob: SubaccountBlob, network: SubaccountNetwork): async AccountIdText {
        var accountIdText : AccountIdText = "";
        switch (network) {
            case ("ICP") {
                accountIdText := Utils.accountIdToHex(Account.getAccountId(getPrincipal(), subaccountBlob));
            };
            case ("BTC") {
                let subaccountNat8Arr : SubaccountNat8Arr = Utils.subBlobToSubNat8Arr(subaccountBlob);
                accountIdText := await BitcoinWallet.get_p2pkh_address(btcNetwork, KEY_NAME, [subaccountNat8Arr]);
            };
            case _ {};
        };
        return accountIdText;
    };

    func defaultAccountId (network: Text): async AccountIdText {
        if (network == "ICP") {
            Utils.accountIdToHex(Account.getAccountId(getPrincipal(), Utils.defaultSubaccount()));
        } else {
            await BitcoinWallet.get_p2pkh_address(btcNetwork, KEY_NAME, DERIVATION_PATH);
        };

    };

    public func accountBalance (account: AccountIdText, network: SubaccountNetwork) : async Nat64 {
        var balance : Nat64 = 0;
        switch (network) {
            case ("ICP") {
                balance := (await Ledger.account_balance_dfx({ account = account })).e8s;
            };
            case ("BTC") {
                balance := await BitcoinApi.get_balance(btcNetwork, account);
            };
            case _ {};
        };
        return balance;
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

        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo)) {
            let accountIdText = kv.0;
            let principal = kv.1.0;
            let status = kv.1.1;
            let subBlob = kv.1.2;
            let subNetwork = kv.1.4;

            if (status == #funded) {
                newSubaccountsToDrain.add((accountIdText, principal, subBlob, subNetwork));
            } else { // there should be no funds in subaccount, but just in case, we return it to backer
                newSubaccountsToRefund.add((accountIdText, principal, subBlob, subNetwork));
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

        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo)) {
            let accountIdText = kv.0;
            let principal = kv.1.0;
            let subBlob = kv.1.2;
            let subNetwork = kv.1.4;
            newSubaccountsToRefund.add((accountIdText, principal, subBlob, subNetwork));
        };

        subaccountsToRefund := newSubaccountsToRefund;
    };

    // CONFIRM/CANCEL TRANSFER

    let emptyAccountCutOff = 2; // minutes
    public func confirmTransfer(a : AccountIdText) : async Result.Result<(), Text> {
        switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(a), Text.equal)) {
            case (?pssi) {
                if (pssi.1 == #empty) {
                    accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(a), Text.equal, ?(pssi.0, #confirmed, pssi.2, pssi.3, pssi.4)).0;
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
        switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(a), Text.equal)) {
            case (?pssi) {
                if (pssi.1 == #empty) {
                    accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(a), Text.equal, ?(pssi.0, #cancelled, pssi.2, pssi.3, pssi.4)).0;
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
        let cutoff = Time.now() - 1_000_000_000 * 60 * 20;
        let newEmptyAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);
        // If an account hasn't recieved a confirmation or cancellation, after 20 minutes it is set to cancelled.
        
        for (acc in emptyAccounts.vals()) {
            let accountIdText = acc.accountId;
            let time = acc.time;
            if (time < cutoff) {
                switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(accountIdText), Text.equal)) {
                    case (?pssi) {
                        if (pssi.1 == #empty) {
                            accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pssi.0, #cancelled, pssi.2, pssi.3, pssi.4)).0;
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
        
        let newConfirmedAccounts : Buffer.Buffer<AccountIdAndTime> = Buffer.Buffer<AccountIdAndTime>(1);

        for (acc in confirmedAccounts.vals()) {
            let accountIdText = acc.accountId;
            let time = acc.time;
            switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(accountIdText), Text.equal)) {
                case (?pssi) {
                    var balance : Nat64 = 0;

                    // If an account hasn't recieved a confirmation or cancellation, after time it is set to cancelled.
                    // ICP rounds - cutoff 2 minutes; BTC rounds - 2hours
                    
                    let cutoffDiff = switch (pssi.4) {
                        case ("BTC") { 1_000_000_000 * 60 * 60 * 2 };
                        case _ { 1_000_000_000 * 60 * 2 };
                    };
                    
                    try {
                        balance := await accountBalance(accountIdText, pssi.4);
                    } catch (e) { };
                    let price: Nat64 = switch (pssi.4) {
                        case ("ICP") {
                            switch (nfts[pssi.3].priceE8S) {
                                case (?priceE8S) {Nat64.fromNat(priceE8S);};
                                case null {Nat64.fromNat(0);};
                            };
                        };
                        case ("BTC") {
                            switch (nfts[pssi.3].priceSatoshi) {
                                case (?priceSatoshi) {Nat64.fromNat(priceSatoshi);};
                                case null {Nat64.fromNat(0);};
                            }
                        };
                        case _ {Nat64.fromNat(0)};
                    };

                    let _balance = Float.fromInt(Nat64.toNat(balance));
                    let _price = Float.fromInt(Nat64.toNat(price));
                    let minBalance = Float.mul(_price, 0.9);

                    if (_balance >= minBalance) {
                        accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pssi.0, #funded, pssi.2, pssi.3, pssi.4)).0;
                        log({
                            info = "transfer into the escrow";
                            isIncoming = true;
                            from = null;
                            to = accountIdText;
                            amount = balance;
                            network = pssi.4;
                            blockHeight = 0;
                            transactionId = [0];
                            worked = true;
                        })
                    } else {
                        if (Time.now() - time > cutoffDiff) {
                            accountInfo := Trie.replace<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(accountIdText), Text.equal, ?(pssi.0, #cancelled, pssi.2, pssi.3, pssi.4)).0;
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
            switch(Trie.get<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo, accIdTextKey(accountIdText), Text.equal)) {
                case (?pssi) {
                    var balance : Nat64 = 0;
                    try {
                        balance := await accountBalance(accountIdText, pssi.4);
                    } catch (e) { };
                    if (balance >= FEE) {
                        let to = await defaultAccountId(pssi.4);
                        addDisbursements([{
                            info = "refund from non-#funded account";
                            from = ?Utils.subBlobToSubNat8Arr(pssi.2);
                            to = to;
                            amount = balance - FEE;
                            network = pssi.4;
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
            case (#ok(text)) { }; case (#err(err)) {
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
        let subNetwork = s.3;
        let amountInSubaccount = await accountBalance(accountIdText, subNetwork);

        if (subNetwork == "ICP" and amountInSubaccount < FEE) {
            return;
        };
        
        let to = await defaultAccountId(subNetwork);
        
        addDisbursements([{
            info = "sub to default account";
            from = ?Utils.subBlobToSubNat8Arr(subBlob);
            to = to;
            amount = if (subNetwork == "BTC") { amountInSubaccount} else { amountInSubaccount - FEE };
            network = s.3;
        }]);
    };

    func refundOneSubaccount () : async () {
        if (subaccountToRefund >= subaccountsToRefund.size()) return;
        let s = subaccountsToRefund.get(subaccountToRefund);
        subaccountToRefund += 1;
        let accountIdText = s.0;
        let principal = s.1;
        let subBlob = s.2;
        let subNetwork = s.3;
        let amountInSubaccount = await accountBalance(accountIdText, subNetwork);

        if (subNetwork == "ICP" and amountInSubaccount < FEE) {
            return;
        };

        addDisbursements([{
            info = "refund from non-#funded account";
            from = ?Utils.subBlobToSubNat8Arr(subBlob);
            to = if (subNetwork == "BTC") { CROWDFUNDNFT_ACCOUNT_BTC } else {Utils.accountIdToHex(Account.getAccountId(principal, Utils.defaultSubaccount()))};
            amount = if (subNetwork == "BTC") { amountInSubaccount} else { amountInSubaccount - FEE };
            network = subNetwork;
        }]);
    };

    public query func payoutInfo () : async (Nat, Nat, Nat, Nat, Bool) {
        (subaccountToRefund, subaccountsToRefund.size(), disbursementToDisburse, disbursements.size(), hasPaidOut);
    };

    public func resetHasPaidOut () : async () {
        hasPaidOut := false;
    };

    func payout () : async () {
        if (subaccountToRefund < subaccountsToRefund.size() or disbursementToDisburse < disbursements.size() or hasPaidOut) return;
        let defaultAccountIdICP = await defaultAccountId("ICP");
        let defaultAccountIdBTC = await defaultAccountId("BTC");
        let recipientAccountIdICP = Utils.accountIdToHex(Account.getAccountId(recipientICP, Utils.defaultSubaccount()));
        let recipientAccountIdBTC = recipientBTC;
        var expectedPayoutICP = Nat64.fromNat(0);
        var expectedPayoutBTC = Nat64.fromNat(0);
        for (tier in Iter.fromArray<NFTInfo>(nfts)) {
            switch (tier.priceE8S) {
                case (?priceE8S) {
                    expectedPayoutICP += Nat64.fromNat(Int.abs(Float.toInt(Float.fromInt(tier.number) * Float.fromInt(priceE8S) * 0.95))); // We take a 5% cut.
                };
                case null {};
            };
            switch (tier.priceSatoshi) {
                case (?priceSatoshi) {
                    expectedPayoutBTC += Nat64.fromNat(Int.abs(Float.toInt(Float.fromInt(tier.number) * Float.fromInt(priceSatoshi) * 0.95))); // We take a 5% cut.
                };
                case null {};
            };
        };
        
        let totalICP = await accountBalance(defaultAccountIdICP, "ICP");
        let totalBTC = await accountBalance(defaultAccountIdBTC, "BTC");
        var payoutICP = expectedPayoutICP;
        var payoutBTC = expectedPayoutBTC;
        
        if (totalICP < expectedPayoutICP) {
            payoutICP := totalICP;
        };
        if (totalBTC < expectedPayoutBTC) {
            payoutBTC := totalBTC;
        };
        
        if (payoutICP > 0) {
            addDisbursements([{
                info = "payout to project creator";
                from = null;
                to = recipientAccountIdICP;
                amount = payoutICP - FEE;
                network = "ICP";
            }]);
            // Our cut
            let ourCut : Nat64 = totalICP - payoutICP;
            if (ourCut > FEE) {
                addDisbursements([{
                    info = "crowdfundnft 5% cut";
                    from = null;
                    to = CROWDFUNDNFT_ACCOUNT_ICP;
                    amount = ourCut - FEE;
                    network = "ICP";
                }]);
            };
        };
        
        if (payoutBTC > 0) {
            addDisbursements([{
                info = "payout to project creator";
                from = ?[];
                to = recipientBTC;
                amount = payoutBTC;
                network = "BTC";
            }]);
            // Our cut
            let ourCut : Nat64 = totalBTC - payoutBTC;
            addDisbursements([{
                info = "crowdfundnft 5% cut";
                from = ?[];
                to = CROWDFUNDNFT_ACCOUNT_BTC;
                amount = ourCut;
                network = "BTC";
            }]);

            hasPaidOut := true;
        };
    };

    // LEDGER WRAPPERS
    func transfer (r: TransferRequest) : async Result.Result<Text, Text> {
        var error: Bool = false;
        var errorMessage: Text = "";
        var blockHeight: Nat64 = 0;
        var transactionId: [Nat8] = [0];
        if (r.network == "ICP") {
            try {
                blockHeight := await Ledger.send_dfx({
                    memo = Nat64.fromNat(0);
                    from_subaccount = r.from;
                    to = r.to;
                    amount = { e8s = r.amount };
                    fee = { e8s = FEE };
                    created_at_time = ?Time.now();
                });
            } catch (e) {
                error := true
            };
        } else if (r.network == "BTC") {
            try {
                switch (r.from) {
                    case (?from) {
                        transactionId := await BitcoinWallet.send(btcNetwork, [from], KEY_NAME, r.to, r.amount);
                    };
                    case null {error := true};
                };
            } catch (e) {
                Debug.print(Error.message(e));
                error := true;
                errorMessage := Error.message(e);
            };
        } else {
            return #err("Missing or unsupported network.");
        };
        if (error) {
            log({
                    info = r.info # errorMessage;
                    isIncoming = false;
                    from = r.from;
                    to = r.to;
                    amount = r.amount;
                    network = r.network;
                    blockHeight = 0 : Nat64;
                    transactionId = [0] : [Nat8];
                    worked = false;
                });
            return #err("Something went wrong.");
        };
        log({
            info = r.info;
            isIncoming = false;
            from = r.from;
            to = r.to;
            amount = r.amount;
            network = r.network;
            blockHeight = blockHeight;
            transactionId = transactionId;
            worked = true;
        });
        return #ok("Success")
    };

    // STATS

    type NFTStats = Types.NFTStats;
    type EscrowStats = Types.EscrowStats;
    public query func getStats () : async EscrowStats {
        var nftStats = Buffer.Buffer<NFTStats>(1);
        for (t in Iter.fromArray<NFTInfo>(nfts)) {
            nftStats.add({
                number = t.number;
                priceE8S = switch (t.priceE8S) {case (?priceE8S) {priceE8S}; case null {0};};
                priceSatoshi = switch (t.priceSatoshi) {case (?priceSatoshi) {priceSatoshi}; case null {0};};
                sold = 0;
                openSubaccounts = 0;
                oversellNumber = oversellNFTNumber(t.number);
            });
        };
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo)) {
            let status = ss.1.1;
            let nftInfoIndex = ss.1.3;
            if (status == #funded) {
                let curStats = nftStats.get(nftInfoIndex);
                nftStats.put(nftInfoIndex, {
                    number = curStats.number;
                    priceE8S = curStats.priceE8S;
                    priceSatoshi = curStats.priceSatoshi;
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
                    priceSatoshi = curStats.priceSatoshi;
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
        amount : Nat64;
        network: Text;
        blockHeight : Nat64;
        transactionId: [Nat8];
        worked: Bool;
    };
    func log (msg : Log) : () {
        var fromString = "";
        switch (msg.from) {
            case (?f) { fromString := Utils.accountIdToHex(Blob.fromArray(f)); };
            case null { fromString := "null"; };
        };
        logsCSV #= Int.toText(Time.now()) # ", " # msg.info # ", " # Bool.toText(msg.isIncoming) # ", " # fromString # ", " # msg.to # ", " # Nat64.toText(msg.amount) # ", " # msg.network # ", " # Nat64.toText(msg.blockHeight) # ", " # Utils.accountIdToHex(Blob.fromArray(msg.transactionId)) # ", " # Bool.toText(msg.worked) # "\n";
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
        var csv = "accountId,principal,subaccountStatus,subaccountBlob,nftIndex,subaccountNetwork\n";
        for (kv in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo)) {
            let accountIdText = kv.0;
            let principal = kv.1.0;
            let status = kv.1.1;
            let subBlob = kv.1.2;
            let nftIndex = kv.1.3;
            let subNetwork = kv.1.4;
            csv #= accountIdText # "," # Principal.toText(principal) # "," # statusToText(status) # "," # Utils.accountIdToHex(subBlob) # "," # Nat.toText(nftIndex) # "," # subNetwork # "\n";
        };
        return csv;
    };
    public query func getLogs () : async Text { logsCSV; };
    public query func getDisbursements () : async Text {
        var str : Text = "index, info, from, to, amount, network\n";
        var i = 0;
        for (d in disbursements.vals()) {
            var fromStr = "null";
            switch (d.from) {
                case (?f) { fromStr := Utils.accountIdToHex(Blob.fromArray(f)); };
                case null { };
            };
            str #= Nat.toText(i) # ", " # d.info # ", " # fromStr # ", " # d.to # ", " # Nat64.toText(d.amount) # ", " # d.network # "\n";
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
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo)) {
            let status = ss.1.1;
            if (status != #cancelled and ss.1.3 == nftInfoIndex) {
                count += 1;
            };
        };
        count;
    };

    func principalHasUncancelledSubaccount (p : Principal) : Bool {
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo)) {
            if (ss.1.0 == p and ss.1.1 != #cancelled) {
                return true;
            };
        };
        return false;
    };
    func principalNumSubaccounts (p : Principal) : Nat {
        var count : Nat = 0;
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo)) {
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

    // Results rounds to floor
    func oversellNFTNumber(number: Nat) : Int {
        let _number = Float.fromInt(number);
        let _oversellPercentage = Float.fromInt(oversellPercentage);
        let divisionPercentage = Float.div(_oversellPercentage, Float.fromInt(100));

        let floatValue = Float.mul(_number, divisionPercentage);
        return Float.toInt(floatValue);
    };

    func projectIsFullyFunded () : Bool {
        var count = 0;
        for (ss in Trie.iter<AccountIdText, (Principal, SubaccountStatus, SubaccountBlob, NFTInfoIndex, SubaccountNetwork)>(accountInfo)) {
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
