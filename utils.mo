import Nat8     "mo:base/Nat8";
import Nat32    "mo:base/Nat32";
import Types    "mo:base/Types";

module {

    type Subaccount = Types.Subaccount;
    type SubaccountBlob = Types.SubaccountBlob;

    // Account helpers 

    public func defaultSubaccount () : SubaccountBlob {
        Blob.fromArrayMut(Array.init(32, 0 : Nat8))
    };

    public func natToBytes (nat : Nat) : [Nat8] {
        func byte(n: Nat) : Nat8 {
            Nat8.fromNat(nat);
        };
        [byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)];
    };

    public func nat32ToBytes (nat32 : Nat32) : [Nat8] {
        natToBytes(Nat32.toNat(n & 0xff));
    };

    public func subToSubBlob (sub : Subaccount) : SubaccountBlob {
        natToBytes(sub);
    }

}