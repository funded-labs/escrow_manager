import Blob         "mo:base/Blob";
import Cycles       "mo:base/ExperimentalCycles";
import Error        "mo:base/Error";
import Nat          "mo:base/Nat";
import Principal    "mo:base/Principal";
import Text         "mo:base/Text";
import Trie         "mo:base/Trie";

import Account      "./account";
import Escrow       "./escrow";
import Hex          "./hex";
import Types        "./types";
import Utils        "./utils";

actor EscrowManager {

    let admin : Principal = Principal.fromText("sqvf2-x3s5d-3a5m3-czni6-2zuda-rg4bk-7le4o-md733-uc75o-yihay-4ae");

    type AccountId      = Text;
    type CanisterId     = Principal;
    type ProjectId      = Nat;
    type ProjectIdText  = Text;
    type SubaccountBlob = Types.SubaccountBlob;

    stable var escrowCanisters : Trie.Trie<ProjectIdText, CanisterId> = Trie.empty();

    // Canister management

    public query func getProjectEscrowCanisterPrincipal(p: ProjectId) : async ?CanisterId {
        getProjectEscrowCanister(p);
    };

    public shared(msg) func createEscrowCanister (p: ProjectId, recipient: Principal, nftNumber: Nat, nftPriceE8S : Nat) : async () {
        assert(msg.caller == admin);
        switch (getProjectEscrowCanister(p)) {
            case (?canister) { };
            case (null) {
                Cycles.add(1000000000000);
                let canister = await Escrow.EscrowCanister(recipient, nftNumber, nftPriceE8S);
                escrowCanisters := Trie.putFresh<ProjectIdText, CanisterId>(escrowCanisters, projectIdKey(p), Text.equal, Principal.fromActor(canister));
            };
        };
    };

    func getProjectEscrowCanister (p: ProjectId) : ?CanisterId {
        Trie.get<ProjectIdText, CanisterId>(escrowCanisters, projectIdKey(p), Text.equal);
    };

    // Payment management

    public func requestSubaccount(p: ProjectId, from: Principal) : async AccountId { //SubaccountBlob {
        switch (getProjectEscrowCanister(p)) {
            case (?canister) { 
                let a = actor (Principal.toText(canister)) : actor {
                    getNewAccountId : shared Principal -> async SubaccountBlob;
                };
                Hex.encode(Blob.toArray(await a.getNewAccountId(from)));
            };
            case null {
                throw Error.reject("Project escrow canister not found");
            };
        };
    };

    // Utils

    // func getEscrowCanisterActor(c: CanisterId) : actor {
    //      : actor {
    //         getNewAccountId : shared Principal -> async SubaccountBlob;
    //     };
    // };

    // helpers

    func projectIdKey (p: ProjectId) : Trie.Key<ProjectIdText> {
        { key = Nat.toText(p); hash = Text.hash(Nat.toText(p)) };
    };

}