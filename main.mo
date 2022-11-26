import Array        "mo:base/Array";
import Blob         "mo:base/Blob";
import Cycles       "mo:base/ExperimentalCycles";
import Error        "mo:base/Error";
import Nat          "mo:base/Nat";
import Option       "mo:base/Option";
import Principal    "mo:base/Principal";
import Text         "mo:base/Text";
import Time         "mo:base/Time";
import Trie         "mo:base/Trie";

import Account      "./account";
import Escrow       "./escrow";
import Hex          "./hex";
import Types        "./types";
import Utils        "./utils";

actor EscrowManager {

    let admins : [Principal] = [
        Principal.fromText("sqvf2-x3s5d-3a5m3-czni6-2zuda-rg4bk-7le4o-md733-uc75o-yihay-4ae"),
        Principal.fromText("imptf-t7jg2-g5akw-v4vai-u4qiy-ayepe-7a3vi-tf4hu-pe37j-iqcis-hqe"),
        Principal.fromText("krpk7-5knvf-l2jy3-mfzbr-6arys-xhrc5-5k76j-hfszl-mlm37-pqsd2-eqe"),
        Principal.fromText("is7gy-jgfpp-4fnpe-da4au-xbb5e-iflz6-kuqge-wef4p-fpeo4-gftlc-mae")
    ];

    type canister_id = Principal;
    type user_id = Principal;
    type wasm_module = Blob;

    type canister_settings = {
        controllers : ?[Principal];
        compute_allocation : ?Nat;
        memory_allocation : ?Nat;
        freezing_threshold : ?Nat;
    };

    type definite_canister_settings = {
        controllers : ?[Principal];
        compute_allocation : Nat;
        memory_allocation : Nat;
        freezing_threshold : Nat;
    };

    // We want to eventually make all escrow canister "black hole" canisters,
    // which means they have no controllers, and hence their code cannot be
    // altered. Until then, since we have at times had to update an escrow
    // canister's code due to a glitch, we use this function to temporarily take
    // control of the escrow canister.
    // TODO: Remove this function.
    public func takeover (canister : Text) : async definite_canister_settings {
        let ManagementCanister = actor "aaaaa-aa" : actor {
            canister_status : shared { canister_id : canister_id } -> async {
                status : { #running; #stopping; #stopped };
                settings: definite_canister_settings;
                module_hash: ?Blob;
                memory_size: Nat;
                cycles: Nat;
            };
            update_settings : shared {
                canister_id : Principal;
                settings : canister_settings
            } -> async ();
        };
        let canister_id = Principal.fromText(canister);
        let newControllers = [
            Principal.fromText("3fhg4-qiaaa-aaaak-aajiq-cai"),
            Principal.fromText("xohn2-daaaa-aaaak-aadvq-cai")
        ];
        await ManagementCanister.update_settings({ canister_id = canister_id; settings = {
            controllers = ?newControllers;
            compute_allocation = ?(0 : Nat);
            memory_allocation = ?(0 : Nat);
            freezing_threshold = ?(2_592_000 : Nat);
        }});
        return (await ManagementCanister.canister_status({ canister_id = canister_id })).settings;
    };

    type AccountIdText  = Types.AccountIdText;
    type CanisterId     = Principal;
    type CanisterIdText = Text;
    type NFTInfo        = Types.NFTInfo;
    type ProjectId      = Types.ProjectId;
    type ProjectIdText  = Text;
    type SubaccountBlob = Types.SubaccountBlob;

    stable var escrowCanisters : Trie.Trie<ProjectIdText, CanisterId> = Trie.empty();
    stable var maxOversellPercentage : Nat = 20;

    // Canister management

    public query func getProjectEscrowCanisterPrincipal(p: ProjectId) : async ?CanisterIdText {
        switch (getProjectEscrowCanister(p)) {
            case (?canister) ?Principal.toText(canister);
            case (null) null;
        };
    };

    // TODO: Remove self as controller of created escrow canister to turn the canister into true "black hole" canister.
    public shared(msg) func createEscrowCanister (p: ProjectId, recipientICP: Principal, recipientBTC: Text, nfts: [NFTInfo], endTime : Time.Time, maxNFTsPerWallet : Nat, oversellPercentage: Nat) : async () {
        assert(isAdmin(msg.caller));
        switch (getProjectEscrowCanister(p)) {
            case (?canister) { throw Error.reject("Project already has an escrow canister: " # Principal.toText(canister)); };
            case (null) {
                if (oversellPercentage > maxOversellPercentage) {
                    throw Error.reject("Oversell percentage can't exceed " # Nat.toText(maxOversellPercentage) # "%");
                } else {
                Cycles.add(1000000000000);
                let canister = await Escrow.EscrowCanister(p, recipientICP, recipientBTC, nfts, endTime, maxNFTsPerWallet, oversellPercentage);
                escrowCanisters := Trie.putFresh<ProjectIdText, CanisterId>(escrowCanisters, projectIdKey(p), Text.equal, Principal.fromActor(canister));
                };
            };
        };
    };

    public shared({caller}) func setMaxOversellPercentage(percentage: Nat): async () {
        assert(isAdmin(caller));
        maxOversellPercentage := percentage;
    };

    public query func getMaxOversellPercentage(): async Nat {
        maxOversellPercentage;
    };

    func getProjectEscrowCanister (p: ProjectId) : ?CanisterId {
        Trie.get<ProjectIdText, CanisterId>(escrowCanisters, projectIdKey(p), Text.equal);
    };

    public shared(msg) func dissociateEscrowCanister (p: ProjectId) : async () {
        assert(isAdmin(msg.caller));
        switch (getProjectEscrowCanister(p)) {
            case (?canister) {
                escrowCanisters := Trie.remove<ProjectIdText, CanisterId>(escrowCanisters, projectIdKey(p), Text.equal).0;
            };
            case (null) { throw Error.reject("Project has no escrow canister"); };
        };
    };

    // helpers

    func projectIdKey (p: ProjectId) : Trie.Key<ProjectIdText> {
        { key = Nat.toText(p); hash = Text.hash(Nat.toText(p)) };
    };

    // cycles management

    //Internal cycle management - good general case
    type RecieveOptions = {
        memo: ?Text;
    };
    public func wallet_receive() : async () {
        let available = Cycles.available();
        let accepted = Cycles.accept(available);
        assert (accepted == available);
    };
    public func acceptCycles() : async () {
        let available = Cycles.available();
        let accepted = Cycles.accept(available);
        assert (accepted == available);
    };
    public query func availableCycles() : async Nat {
        return Cycles.balance();
    };

    private func isAdmin(p: Principal): Bool {
        func identity(x: Principal): Bool { x == p };
        Option.isSome(Array.find<Principal>(admins,identity));
    };

}
