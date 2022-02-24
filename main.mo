import Account "./Account"
import Escrow "./escrow"
import Types "./types"
import Utils "./utils"

actor EscrowManager {

    type CanisterId = Text;
    type EscrowCanister = Types.EscrowCanister;
    type ProjectId = Nat;
    type ProjectIdText = Text;

    stable var escrowCanisters : Trie.Trie<ProjectIdText, EscrowCanister> = Trie.empty();

    // Canister management

    // public func getProjectEscowCanister (p: ProjectId) : async ?CanisterId {
    //     switch (Trie.get<ProjectIdText, EscrowCanister>(escrowCanisters, projectIdKey(p), Text.equal)) {
    //         case (?canister) { ?Principal.toText((await canister.getPrincipal())); };
    //         case (null) { return null; };
    //     };
    // };

    public func createEscrowCanister (p: ProjectId, recipient: Principal, nftNumber: Nat, nftPriceE8S : Nat) : async CanisterId {
        switch (await getProjectEscrowCanister(p)) {
            case (?canister) { return canister; };
            case (null) {
                let recipientAccountId = Account.getAccountId(recipient, Utils.defaultSubaccount());
                Cycles.add(1_000_000_000_000);
                let canister = await EscrowCanister(recipientAccountId, nftNumber, nftPriceE8S);
                nftCanisters := Trie.putFresh<ProjectIdText, EscrowCanister>(escrowCanisters, projectIdKey(p), Text.equal, canister);
                return Principal.toText(await canister.getPrincipal());
            };
        };
    };

    // Payment management

    public func requestSubaccount(p: ProjectId, from: Account) : async SubaccountBlob {

    }

    // helpers

    func projectIdKey (p: ProjectId) : Trie.Key<ProjectIdText> {
        { key = Nat.toText(p); hash = Text.hash(Nat.toText(p)) };
    };

}