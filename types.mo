import Time "mo:base/Time";

module {

    public type AccountId           = Blob;
    public type AccountIdText       = Text;
    public type Subaccount          = Nat;
    public type SubaccountBlob      = Blob;
    public type SubaccountStatus    = { 
        #empty;     // empty and waiting for a transfer
        #cancelled; // transfer has been cancelled
        #confirmed; // transfer has been confirmed by frontend, 
                    // now we need to check that we recieved the funds
        #funded;    // funds recieved
    };

    // LEDGER
    public type AccountBalanceArgs  = { account : AccountId };
    public type ICPTs               = { e8s     : Nat64     };
    public type SendArgs            = {
        memo            : Nat64;
        amount          : ICPTs;
        fee             : ICPTs;
        from_subaccount : ?SubaccountBlob;
        to              : AccountId;
        created_at_time : ?Time.Time;
    };

    // ESCROW STATS
    public type EscrowStats         = {
        nftNumber       : Nat;
        nftPriceE8S     : Nat;
        endTime         : Time.Time;
        nftsSold        : Nat;
        openSubaccounts : Nat;
    };

};