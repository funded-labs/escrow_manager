import HashMap "mo:base/HashMap";
import Types "./types";

module {

    type EscrowCanister = Types.EscrowCanister;

    // Each project gets its owner escrow canister to store its funds.
    let projectToEscrowCanister = HashMap.HashMap<ProjectId, EscrowCanister>(1, isEqProjectId, Text.hash);

    // Comparators 

    func isEqProjectId(x: ProjectId, y: ProjectId): Bool { x == y };
}