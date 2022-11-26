import Array    "mo:base/Array";
import Blob     "mo:base/Blob";
import Nat8     "mo:base/Nat8";
import Nat32    "mo:base/Nat32";

import Hex      "./hex";
import Types    "./types";
import Result "mo:base/Result";
import Debug "mo:base/Debug";
import Iter "mo:base/Iter";
import Prelude "mo:base/Prelude";
import Text "mo:base/Text";

module {

    type AccountId = Types.AccountId;
    type AccountIdText = Types.AccountIdText;
    type Subaccount = Types.Subaccount;
    type SubaccountBlob = Types.SubaccountBlob;
    type SubaccountNat8Arr = Types.SubaccountNat8Arr;

    // Account helpers 

    public func accountIdToHex (a : AccountId) : AccountIdText {
        Hex.encode(Blob.toArray(a));
    };

    public func hexToAccountId (h : AccountIdText) : AccountId {
        Blob.fromArray(Hex.decode(h));
    };    

    public func defaultSubaccount () : SubaccountBlob {
        Blob.fromArrayMut(Array.init(32, 0 : Nat8))
    };

    public func natToBytes (n : Nat) : [Nat8] {
        nat32ToBytes(Nat32.fromNat(n));
    };

    public func nat32ToBytes (n : Nat32) : [Nat8] {
        func byte(n: Nat32) : Nat8 {
            Nat8.fromNat(Nat32.toNat(n & 0xff))
        };
        [byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)]
    };

    public func subToSubBlob (sub : Subaccount) : SubaccountBlob {
        let n_byte = func(i : Nat) : Nat8 {
            assert(i < 32);
            let shift : Nat = 8 * (32 - 1 - i);
            Nat8.fromIntWrap(sub / 2**shift)
        };
        Blob.fromArray(Array.tabulate<Nat8>(32, n_byte))
    };

    public func subBlobToSubNat8Arr (sub : SubaccountBlob) : SubaccountNat8Arr {
        let subZero : [var Nat8] = [var 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
        let subArray = Blob.toArray(sub);
        let sizeDiff = subZero.size()-subArray.size();
        var i = 0;
        while (i < subZero.size()) {
            if (i >= sizeDiff) {
                subZero[i] := subArray[i - sizeDiff];
            };
            i += 1;
        };
        Array.freeze<Nat8>(subZero);
    };

    //For Bitcoin Integration

    type Result<Ok, Err> = Result.Result<Ok, Err>;

    /// Returns the value of the result and traps if there isn't any value to return.
    public func get_ok<T, U>(result : Result<T, U>) : T {
        switch result {
            case (#ok value)
                value;
            case (#err error)
                Debug.trap("pattern failed");
        }
    };

    /// Returns the value of the result and traps with a custom message if there isn't any value to return.
    public func get_ok_except<T, U>(result : Result<T, U>, expect : Text) : T {
        switch result {
            case (#ok value)
                value;
            case (#err error) {
                Debug.print("pattern failed");
                Debug.trap(expect);
            };
        }
    };

    /// Unwraps the value of the option.
    public func unwrap<T>(option : ?T) : T {
        switch option {
            case (?value)
                value;
            case null
                Prelude.unreachable();
        }
    };

    // Returns the hexadecimal representation of a `Nat8` considered as a `Nat4`.
    func nat4ToText(nat4 : Nat8) : Text {
        Text.fromChar(switch nat4 {
            case 0 '0';
            case 1 '1';
            case 2 '2';
            case 3 '3';
            case 4 '4';
            case 5 '5';
            case 6 '6';
            case 7 '7';
            case 8 '8';
            case 9 '9';
            case 10 'a';
            case 11 'b';
            case 12 'c';
            case 13 'd';
            case 14 'e';
            case 15 'f';
            case _ Prelude.unreachable();
        })
    };

    /// Returns the hexadecimal representation of a `Nat8`.
    func nat8ToText(byte : Nat8) : Text {
        let leftNat4 = byte >> 4;
        let rightNat4 = byte & 15;
        nat4ToText(leftNat4) # nat4ToText(rightNat4)
    };

    /// Returns the hexadecimal representation of a byte array.
    public func bytesToText(bytes : [Nat8]) : Text {
        Text.join("", Iter.map<Nat8, Text>(Iter.fromArray(bytes), func (n) { nat8ToText(n) }))
    };
}
