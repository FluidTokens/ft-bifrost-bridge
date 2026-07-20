# TM Confirmed-Chain Migration Runbook (preprod)

Migrates the deployed preprod bridge to the confirmed-chain treasury tracking scheme
(spec: `docs/superpowers/specs/2026-07-20-tm-confirmed-chain-design.md`) **without
redeploying the bridge**: the config NFT, fSAT policy, CPI/CPO, peg-out scripts and the
Binocular oracle keep their hashes and UTxOs. Only the TM validator and (via its NFT
policy parameter) the peg-in script get new hashes, and one config `Update` transaction
rewires the deployed Config UTxO.

Operator prerequisites: the binocular sponsor wallet (funds + the `oracle.owner-pkh`
`update_auth` key), bitcoind (testnet4) RPC, Blockfrost preprod access.

## 1. Export the new TM validator

```bash
binocular tm-script
```

Note the printed `policy_id` (= new TM NFT policy = new TM script hash) and `address`
(the new TM address), and save the `cbor` for heimdall. The script is parameterized by
`(oracle script hash, config NFT policy, config NFT asset name)` from the binocular
bridge config, so `bridge.config-nft-{policy-id,asset-name}` must already be set.

## 2. Compute the new peg-in hash and register its reward account

The TM NFT policy is `peg_in.ak`'s 4th parameter, so the peg-in script hash changes.
`binocular deploy-bridge --dry-run` prints the full derived hash chain, including
`peg_in withdraw hash`, without submitting. Register the new peg-in withdraw reward
account (deposit-less RegCert) before completions run, e.g. via `register-bridge-creds`.

## 3. Complete in-flight peg-ins under the OLD TM policy

Peg-ins already swept by old-policy Confirmed TM records must be completed BEFORE the
config swap in step 5: the new peg-in script only recognizes the new TM NFT policy, and
after field 4 is swapped the old peg-in withdraw script no longer gates fSAT minting.

## 4. Pick the treasury anchor

Determine the current unspent Bitcoin treasury outpoint on testnet4 (display txid +
vout). Verify it is unspent:

```bash
bitcoin-cli -testnet4 gettxout <TXID> <VOUT>
```

This becomes the chain's "initial" outpoint; the first post-migration TM must spend it.

## 5. Update the deployed Config UTxO

```bash
binocular update-config \
  --initial-btc-treasury-utxo <TXID>:<VOUT> \
  --peg-in-withdraw-hash <new peg-in hash from step 2>
```

One transaction, authorized by `update_auth` (the oracle owner key): appends field 11
(`initial_btc_treasury_utxo`, 36-byte outpoint) and swaps field 4
(`peg_in_withdraw_script_hash`). Dry-run first with `--dry-run`. The command is
re-runnable: on a 12-field config it replaces field 11 (re-anchoring path, e.g. after an
emergency federation sweep).

## 6. Reconfigure heimdall

In `heimdall.toml` `[cardano]`:

- `treasury_address` = the new TM address (step 1)
- `treasury_policy_id` = the new TM policy id (step 1), `treasury_asset_name` = `""`
- `tm_script_cbor` = the CBOR from step 1
- `config_address`, `config_nft_policy_id`, `config_nft_asset_name` = the deployed
  config values (from `binocular deploy-bridge` output / the config UTxO)

Deleted keys (remove if present): `[bitcoin] treasury_txid/treasury_vout/
treasury_amount_sat`, `[cardano] tm_control_ref`. Ensure `[bitcoin] rpc_url` is set:
the genesis anchor's value is fetched via `gettxout`.

## 7. Reconfigure binocular relay/confirm

`bridge.tm-control-nft-{policy,name}` and `bridge.tm-authorized-minter` no longer
exist. The relay/confirm/watchtower daemons derive the TM address from
`(oracle, config NFT)` automatically; no per-daemon TM settings beyond the bridge
config NFT values.

## 8. Verify end to end

1. Heimdall `query_treasury` resolves the anchor (log line
   `treasury = config anchor <txid>:<vout>`).
2. Heimdall builds, FROST-signs, broadcasts and posts the first TM
   (mint redeemer `Genesis`, config UTxO referenced).
3. Binocular `confirm-tmtx` confirms it after Bitcoin confirmation; the record becomes
   the chain tip.
4. Heimdall's next `query_treasury` reports `treasury = TM chain tip <btc_txid>:0` and
   the next TM posts with redeemer `Chain(0)` referencing the tip record.

Old TM records and the TMCTRL UTxO are abandoned in place; they are not on the new
chain and are never read.
