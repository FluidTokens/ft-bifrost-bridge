# On-chain Variant B + ConfigDatum Clean Rebuild – Design

**Date**: 2026-07-17
**Status**: Approved, not yet implemented
**Scope**: `onchain/` (config types + validators + constants), the binocular
off-chain mirror/commands, and blueprint/test refresh. Prerequisite for the
FluidTokens tx-migration doc and the CLI-restructuring work (each their own
later spec).

## Context

The just-merged fBTC mint delegation introduced a dedicated
`fbtc_mint_checker` withdraw validator named by `ConfigDatum` field 19.
Design review concluded that a leaner shape ("Variant B") gives the same
"stable policy id + swappable mint logic" guarantee by delegating directly to
the **existing** peg-in/peg-out withdraw scripts, with no separate checker
script, field, withdrawal, or stake registration.

In parallel, a field-usage audit of the 20-field `ConfigDatum` found:

- **6 truly-dead fields** (indices 2–5 source-chain/block-header MPF,
  superseded by the Binocular oracle `ChainState`; 15–16 treasury NFT,
  superseded by the `tm_nft_policy_id` validator parameter) – read by no
  validator, only set to dummies at deploy.
- **2 asset-name fields** (completed-peg-ins/outs) that should be **compile-time
  constants**, harmonizing with the existing `reg-root`/`ban-root` singleton
  convention; only their per-deploy *policy ids* need to stay in config.
- **field 19** (the checker) being removed by Variant B.

Nothing is deployed on mainnet, so this is the cheapest possible moment to
rebuild `ConfigDatum` cleanly rather than carry dead/dummy fields forever
under the append-only contract.

Finally, the bridged token is renamed **fBTC → fSAT**: 1 token = 1 satoshi
(peg amounts are in sats throughout), so `fSAT` is the accurate,
convention-matching (uppercase ticker, like `fBTC`) name. The asset name
stays a **config field**, not a constant, so the same compiled contracts can
run bridges for other chains (Dogecoin `fDOGE`, Litecoin `fLTC`, …), each
deploy choosing its own token name.

## Goals

- Stable fSAT policy id with fully swappable mint/burn logic, reusing the
  existing `peg_in_withdraw_script_hash` / `peg_out_withdraw_script_hash`
  config fields – no separate checker.
- fBTC-supply soundness: every action of `peg_in`/`peg_out` constrains the
  fSAT mint, so presence-only delegation from `bridged_token` is sound.
- A lean, honest `ConfigDatum` (11 fields) that FluidTokens integrates
  against with zero "ignore these" fields.
- Per-deployment token asset name (multi-bridge reuse of one architecture).

## Non-goals

- Building the F1–F6 close/cancel logic. The close-verifier (field 6) and
  not-produced-verifier (field 8) fields and the `Cancel` branches stay as
  **dormant, planned scaffolding** (F1–F6 is spec'd with Lean theorems,
  tracked as contract CR – not abandoned like the dropped fields).
- The CLI restructuring / seeds-only config and the FluidTokens migration doc
  (separate specs, sequenced after this lands).
- Fixing `general-spend.ak`, which reads `config[1]` as a `Credential` (it is
  the token asset name). Pre-existing, not wired into the bridge flow; flagged
  here, out of scope.

## Design

### 1. New `ConfigDatum` (11 fields, re-indexed)

```aiken
pub type ConfigDatum {
  bridged_token_policy_id: PolicyId,                                       // 0
  bridged_token_asset_name: AssetName,                                     // 1  (default "fSAT", per-deploy)
  completed_peg_ins_merkle_tree_policy_id: PolicyId,                       // 2
  completed_peg_outs_merkle_tree_policy_id: PolicyId,                      // 3
  peg_in_withdraw_script_hash: ByteArray,                                  // 4
  peg_out_withdraw_script_hash: ByteArray,                                 // 5
  peg_in_close_verifier_script_hash: ByteArray,                           // 6  (dormant, F1-F6)
  legit_treasury_movement_and_peg_out_produced_verifier_script_hash: ByteArray,     // 7
  legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: ByteArray, // 8  (dormant, F1-F6)
  min_stake: Int,                                                          // 9  (reserved, off-chain)
  update_auth: Option<AuthorizationMethod>,                               // 10
}
```

Removed vs the current shape: source-chain MPF (old 2–3), block-header MPF
(old 4–5), completed-peg-ins/outs **asset names** (old 7, 9 → now constants),
treasury NFT (old 15–16), and the mint checker (old 19). The completed-peg-ins/
outs **policy ids** are retained (fields 2, 3).

Getters in `lib/bifrost/types/config.ak` are rewritten to the new indices, and
the `config_getters_match_datum_fields` pin test is rebuilt for the 11 fields.
This is a **non-append-only reset**: the append-only evolution contract
restarts from this 11-field baseline (acceptable – nothing deployed).

### 2. Completed-peg-ins/outs asset names as constants

Add to `lib/bifrost/constants.ak`:

```aiken
pub const completed_peg_ins_root_asset_name = "cpi-root"
pub const completed_peg_outs_root_asset_name = "cpo-root"
```

Rewrite the `completed-peg-ins-merkle-tree.ak` (and `-outs-`) mint handler to
the standard one-shot pattern: consume the **validator's `one_shot_input_ref`
parameter** (currently the unused `_one_shot_input_ref`) and mint exactly one
token of the constant name:

```aiken
validator completed_peg_ins_merkle_tree_validator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  one_shot_input_ref: OutputReference,
) {
  mint(_redeemer: Data, policy_id: PolicyId, self: Transaction) {
    expect Some(_) = find_input(self.inputs, one_shot_input_ref)
    expect [Pair(minted_name, 1)] = dict.to_pairs(tokens(self.mint, policy_id))
    expect minted_name == constants.completed_peg_ins_root_asset_name
    // unchanged: exactly-one output at this script, empty-root datum, NFT there
    ...
  }
  ...
}
```

The `MintRedeemer { input_ref }` type is dropped (redeemer becomes unused);
consuming the parameterized one-shot is what guarantees the singleton, more
tightly than the old redeemer-hash scheme. `peg-in.ak` / `peg-out.ak` read the
constant for the asset name and the **policy id from config** (fields 2 / 3).

### 3. `bridged_token.mint` – presence delegator (Variant B)

```aiken
pub type MintRedeemer {
  config_ref_input_index: Int,
}

validator bridged_token(configNFTPolicyId: ByteArray, configNFTAssetName: ByteArray) {
  mint(redeemer: MintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config_fields =
      utils.get_config_as_data_list(
        utils.safe_list_at(self.reference_inputs, redeemer.config_ref_input_index),
        configNFTPolicyId, configNFTAssetName)
    // Anchor: the delegation targets constrain the mint of config[0]; it must be us.
    expect config.get_bridged_token_policy_id(config_fields) == policy_id
    let asset_name = config.get_bridged_token_asset_name(config_fields)
    // Single canonical asset name under our policy (multi-asset-name guard).
    expect [Pair(minted_name, minted_qty)] = dict.to_pairs(tokens(self.mint, policy_id))
    expect minted_name == asset_name
    if minted_qty > 0 {
      pairs.has_key(self.withdrawals, Script(config.get_peg_in_withdraw_script_hash(config_fields)))
    } else {
      pairs.has_key(self.withdrawals, Script(config.get_peg_out_withdraw_script_hash(config_fields)))
    }
  }
  else(_ctx: ScriptContext) { False }
}
```

No redeemer cast (so no frozen coupling to peg-in/peg-out redeemer shapes);
mint-sign dispatch to the existing withdraw hashes; the `config[0] == policy_id`
anchor and the single-asset-name check retained from the prior fix.

### 4. `peg_in` / `peg_out` `Cancel` guard

Both `withdraw` handlers already read `bridged_token_policy_id` /
`bridged_token_asset_name` at the top. Add to each `Cancel` branch:

```aiken
let no_bridged_token_mint =
  quantity_of(self.mint, bridged_token_policy_id, bridged_token_asset_name) == 0
```

and AND it into the branch result. `CompletePegIn`/`CompletePegOut` already pin
the mint/burn to the peg amount, so with this guard **every** action of both
validators constrains the fSAT mint – which is exactly what makes
`bridged_token`'s presence-only delegation sound (a `Cancel` can no longer be
used to smuggle an unconstrained mint).

### 5. Delete the checker

Remove `validators/bitcoin/fbtc-mint-checker.ak`,
`get_bridged_token_mint_checker_script_hash`, and every off-chain reference
(redeemer type, completion-tx withdrawal, deploy-datum field, credential
registration, contract wrapper, hash lock).

### 6. Rename fBTC → fSAT

The name is config data, so this is a **default-value** change, not a contract
constant: update the `DeployBridgeCommand` `BridgedTokenAssetName` default and
the `BridgeConfig.bridgedTokenAssetName` default to `fSAT`, plus `"fBTC"`
literals in tests/fixtures/docs. The validators are name-agnostic (they read
field 1).

## Off-chain impact (binocular)

- `ConfigTypes.scala`: `ConfigDatum` mirror → 11 fields in the new order;
  remove `FbtcMintCheckerRedeemer`; `BridgedTokenMintRedeemer` stays
  `{configRefInputIndex}`; completed-peg-ins/outs mint redeemers drop
  `input_ref`.
- `BifrostContracts.scala`: remove `FbtcMintCheckerContract`;
  `CompletedPegIns/OutsContract.assetName` become the constants
  (`cpi-root`/`cpo-root`), not `sha2_256(...)`.
- `PegInCompleteTx.scala` / `PegOutCompleteTx.scala`: remove the checker
  withdrawal and its reward-index handling (peg-in reverts to one script
  withdrawal; peg-out to two).
- `DeployBridgeCommand.scala`: build the 11-field datum with `fSAT`; drop the
  checker derivation/registration; cpi/cpo NFTs minted with the constant names.
- `RegisterBridgeCredsCommand.scala`: drop the `fbtc_mint_checker` credential.
- `BifrostContractsTest.scala` + `ConfigDatumEncodingTest.scala`: refresh the
  trimmed blueprint resource and all known-answer hash locks (every hash
  changes); assert the 11-field datum encoding.

## Testing

**Aiken** (`aiken check` green; `aiken build` regenerates `plutus.json`):

- `bridged_token`: mint accepts with peg-in withdrawal present; burn accepts
  with peg-out withdrawal; rejects wrong-sign dispatch (mint with only a
  peg-out withdrawal, and vice-versa); rejects missing withdrawal; rejects
  `config[0] != policy_id`; rejects a second asset name under the policy;
  rejects a ref input without the config NFT.
- `peg_in`/`peg_out` `Cancel`: rejects a `Cancel` tx that also mints/burns
  fSAT (the new guard); the existing `Cancel` happy path still passes with
  zero fSAT in the mint field.
- completed-peg-ins/outs: mint accepts with the constant name + one-shot
  consumed; rejects a wrong asset name; rejects without the one-shot.
- `config_getters_match_datum_fields` rebuilt for 11 fields.

**Scala**: `ConfigDatumEncodingTest` (11 positional fields, `update_auth` at
10); `BifrostContractsTest` hash locks refreshed; full `sbt test` green.

## Deployment / migration note

Every script hash changes (ConfigDatum shape, `bridged_token`, cpi/cpo,
peg-in/peg-out all recompile), so this requires a fresh
`deploy-bridge` → `register-bridge-creds` → `deploy-script-refs` cycle and a
binocular submodule blueprint resync. No on-chain migration (nothing on
mainnet).

## Decisions log

- **Variant B over the dedicated checker**: reuse the existing peg-in/peg-out
  withdraw hashes; fewer fields/scripts/withdrawals/registrations; soundness
  moved into the (now single-action-safe) peg validators via the `Cancel`
  guard. (User, 2026-07-17.)
- **Clean-rebuild ConfigDatum** (drop 6 dead fields + checker; re-index):
  nothing on mainnet, cheapest cleanup moment.
- **cpi/cpo asset names → constants** (`cpi-root`/`cpo-root`): harmonize with
  the existing `reg-root`/`ban-root` singleton convention; only policy ids are
  per-deploy.
- **`bridged_token_asset_name` stays a config field**: per-deployment token
  name enables one architecture to serve Bitcoin/Dogecoin/Litecoin bridges.
- **Keep close/cancel scaffolding** (fields 6 & 8, `Cancel` branches + Variant
  B guards): F1–F6 is planned, spec'd work (contract CR), not abandoned.
- **fBTC → fSAT**: 1 token = 1 satoshi; accurate, uppercase-ticker convention
  consistent with `fBTC`.
