import Time "mo:base/Time";

module {
    public type AccountId           = Blob;
    public type Subaccount          = Nat;
    public type SubaccountBlob      = Blob;
    public type SubaccountStatus    = { #empty; #cancelled; #funded };

    // LEDGER
    public type AccountBalanceArgs  = { account : AccountId };
    public type ICPTs               = { e8s : Nat64 };
    public type SendArgs            = {
        memo: Nat64;
        amount: ICPTs;
        fee: ICPTs;
        from_subaccount: ?SubaccountBlob;
        to: AccountId;
        created_at_time: ?Time.Time;
    };
}