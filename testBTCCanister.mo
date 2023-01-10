import Text "mo:base/Text";
import Principal "mo:base/Principal";

import BitcoinWallet "./BitcoinWallet";
import BitcoinApi "./BitcoinApi";
import Types "./types";
import Utils "./utils"

actor class TestBTCCanister() = this {
  type GetUtxosResponse = Types.GetUtxosResponse;
  type MillisatoshiPerByte = Types.MillisatoshiPerByte;
  type SendRequest = Types.SendRequest;
  type Network = Types.Network;
  type BitcoinAddress = Types.BitcoinAddress;
  type Satoshi = Types.Satoshi;

  stable let NETWORK : Network = #Regtest;

  let DERIVATION_PATH : [[Nat8]] = [];

  let KEY_NAME : Text = switch NETWORK {
    case (#Regtest) "dfx_test_key";
    case _ "test_key_1"
  };

  /// Returns the balance of the canister's wallet
  public func get_balance() : async Satoshi {
    let defaultAddress = await get_p2pkh_address();
    await BitcoinApi.get_balance(NETWORK, defaultAddress)
  };

  /// Returns the P2PKH address of this canister at a specific derivation path.
  public func get_p2pkh_address() : async BitcoinAddress {
    await BitcoinWallet.get_p2pkh_address(NETWORK, KEY_NAME, DERIVATION_PATH)
  };

  /// Send btc to a projects escrow subaccount from this canister, to act as the
  /// btc transfer until mainnet / plug works
  public func supportCrowdFund(btcAddress: Text, amount: Nat64) : async Text {
    Utils.bytesToText(await BitcoinWallet.send(NETWORK, DERIVATION_PATH, KEY_NAME, btcAddress, amount))
  };

  public func get_principal() : async Principal {
    let princ = Principal.fromActor(this);
    return princ;
  };
};