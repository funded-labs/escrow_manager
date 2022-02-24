import Escrow "./escrow"

module {
    public type AccountId           = Blob;
    public type EscrowCanister      = Escrow.EscrowCanister;
    public type Subaccount          = Nat;
    public type SubaccountBlob      = Blob;
    public type SubaccountStatus    = variant { #empty; #cancelled; #funded };
}