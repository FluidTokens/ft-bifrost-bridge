# fBTC Minting Policy Delegation – Design

**Date**: 2026-07-16
**Status**: Approved, not yet implemented
**Scope**: `onchain/validators/bitcoin/bridged-token.ak`, new
`onchain/validators/bitcoin/fbtc-mint-checker.ak`,
`onchain/lib/bifrost/types/config.ak`, off-chain binocular tx builders,
documentation

## Context

The fBTC minting policy (`bridged-token.ak`) is parameterized only by the
config NFT identity, so its policy id is already stable across validator
upgrades. It reads `peg_in_withdraw_script_hash` /
`peg_out_withdraw_script_hash` from the `ConfigDatum` at run time and requires
the right one to run. But three things are still hard-coded forever into the
immutable policy:

1. **Delegate redeemer casting.** The policy does
   `expect peg_in_redeemer: PegInWithdrawRedeemer = ...` and requires the
   action to be `CompletePegIn` (resp. `CompletePegOut`). The redeemer shapes
   of the supposedly-updatable peg-in/peg-out withdraw scripts are therefore
   frozen by the immutable policy: a future withdraw script with a different
   redeemer type breaks fBTC minting permanently.
2. **Mint XOR burn structure.** Exactly one asset-name entry under the policy
   per tx. A tx can never mint and burn fBTC together, and no future flow
   (migration, fees, re-mint after close) can be added.
3. **The peg-in=mint / peg-out=burn dichotomy** itself.

This design completes the delegation: the immutable policy keeps only the
config-NFT lookup and a presence check of a "mint checker" withdraw script
named in the `ConfigDatum`. All minting rules move into the checker, which
governance swaps via the authorized config `Update` path
(see `2026-07-16-config-update-auth-design.md`).

## Goals

- A forever-stable fBTC policy id with fully updatable minting logic: one
  authorized config `Update` swaps all mint/burn rules, no fBTC migration.
- Remove the frozen coupling between the immutable policy and the
  peg-in/peg-out withdraw redeemer types.
- V1 checker is behavior-preserving: the protocol's net minting rules are
  identical to today, just relocated into the updatable layer.
- No new trust assumptions beyond the already-documented config-update
  authority as root of trust.

## Non-goals (explicitly out of scope)

- Changing the actual minting rules (mint+burn in one tx, fees, migrations).
  The architecture permits them later via a checker swap; V1 does not add
  them.
- Governance sophistication (thresholds, timelocks). That lives in the
  `update_auth` target, per the config-update design.
- Back-compat or live-deployment migration: nothing is on mainnet, this is a
  clean cut. New deployments get the new shape at genesis.

## Design

### 1. Immutable core: `bridged-token.ak` rewrite

The policy becomes a minimal delegator:

```aiken
pub type MintRedeemer {
  config_ref_input_index: Int,
}

validator bridged_token(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  mint(redeemer: MintRedeemer, _policy_id: PolicyId, self: Transaction) {
    let config_fields =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let checker_hash =
      config.get_bridged_token_mint_checker_script_hash(config_fields)
    pairs.has_key(self.withdrawals, Script(checker_hash))
  }

  else(_) {
    False
  }
}
```

- No asset-name check, no redeemer casting, no mint/burn branching. The core
  never inspects `self.mint`: delegation is total by design.
- The validator is renamed from the copy-pasted misnomer
  `completed_peg_ins_merkle_tree_validator` to `bridged_token`.
- Parameters are unchanged (`configNFTPolicyId`, `configNFTAssetName`), so the
  policy id remains a pure function of the config NFT identity.
- `utils.get_config_as_data_list` already verifies the reference input holds
  the config NFT, which is the sole authentication of `checker_hash`.

### 2. V1 checker: new `onchain/validators/bitcoin/fbtc-mint-checker.ak`

A dedicated single-purpose validator, parameterized by the config NFT like its
peers, with only a `withdraw` handler (`else` fails). Invoked as a 0-ADA
withdrawal (stake-validator delegation pattern, as already used for
peg-in/peg-out withdraw scripts).

```aiken
pub type CheckerRedeemer {
  config_ref_input_index: Int,
  peg_withdraw_redeemer_index: Int,
}
```

V1 rules (a behavior-preserving port of today's `bridged-token.ak` logic):

- Read `bridged_token_policy_id`, `bridged_token_asset_name`,
  `peg_in_withdraw_script_hash`, `peg_out_withdraw_script_hash` from the
  config reference input.
- `expect [Pair(name, qty)] = dict.to_pairs(tokens(self.mint,
  bridged_token_policy_id))` and `name == bridged_token_asset_name`
  (single-entry, correct-name, unchanged from today).
- `qty > 0`: the redeemer at `peg_withdraw_redeemer_index` in
  `self.redeemers` must be keyed `Withdraw(Script(peg_in_withdraw_script_hash))`
  and its payload must cast to `PegInWithdrawRedeemer` with action
  `CompletePegIn`.
- `qty < 0`: same with `peg_out_withdraw_script_hash` /
  `PegOutWithdrawRedeemer` / `CompletePegOut`.
- Simplification while porting: the old policy's extra
  `list.any(self.withdrawals, ...)` presence scan is dropped. A
  `Withdraw(Script(h))`-keyed entry in `self.redeemers` exists iff that
  withdrawal executes in the tx, so the scan was redundant. (The checker is
  updatable, so this is reversible if ever regretted.)

**Soundness invariant**: every code path of the checker fully constrains the
fBTC mint value. "Checker ran" is only a sound proxy for "mint is valid"
because the checker has no action that ignores `self.mint` under the fBTC
policy. This is why presence-only delegation to the multi-action peg-in
script would be unsafe (`peg_in.withdraw(Cancel)` never looks at the fBTC
mint), and why the checker must remain single-purpose. Any future checker
version must preserve this invariant.

### 3. Config changes

- `ConfigDatum` (in `lib/bifrost/types/config.ak`) gains one field appended
  after `update_auth`:

  ```aiken
  bridged_token_mint_checker_script_hash: ByteArray,
  ```

- New positional getter `get_bridged_token_mint_checker_script_hash`
  (index 19), added in datum order per the getters convention, and pinned in
  the `config_getters_match_datum_fields` test.
- `update_auth` stays at index 18: `config.ak`'s spend handler is untouched.
- All `ConfigDatum` test fixtures gain the new field. Genesis carries it from
  day one (the bootstrap mint's `expect _genesis_datum: ConfigDatum` enforces
  the new shape).

`bridged_token_policy_id` (index 0) is deliberately NOT reused for the
checker: it holds the fBTC asset identity (the stable mint policy's own
script hash) and is load-bearing in peg-in completion
(`quantity_of(self.mint, bridged_token_policy_id, ...)`), recipient binding,
and peg-out burn accounting. The checker itself reads it to find the fBTC
entries in `self.mint`. Identity (index 0) and rules (index 19) are separate
fields by design: identity stays fixed while rules rotate underneath it.

### 4. Upgrade flow

1. Deploy the new checker script (publish a script ref).
2. Register the new checker's stake credential (needed for the 0-ADA
   withdrawal).
3. One authorized config `Update` writes the new hash into field 19.
4. New mints/burns validate under the new checker. fBTC policy id, existing
   fBTC, and all other validators are untouched. The old checker's stake
   credential can be deregistered.

### 5. Failure modes and security

All failure classes already exist today; this design adds no new trust
assumption:

- **Garbage or unregistered checker hash**: minting AND burning halt until a
  later config `Update` fixes the field. Same class as a bad
  `peg_in_withdraw_script_hash` today.
- **Malicious or always-true checker**: unlimited minting. The `update_auth`
  authority is already the documented root of trust and can already achieve
  the same today by swapping `peg_in_withdraw_script_hash` to an attacker
  script; unchanged threat model.
- **Config `Retire`** (NFT burned): the mint policy can never validate again;
  fBTC is permanently frozen (neither mintable nor burnable). Existing
  documented warning, unchanged.
- The core requires the config NFT in the reference input at
  `config_ref_input_index`, so the checker hash cannot be spoofed by a fake
  config UTxO.

### 6. Off-chain impact (binocular watchtower, Scala)

- `ConfigTypes.scala`: mirror the new `ConfigDatum` field; shrink
  `BridgedTokenMintRedeemer` to `configRefInputIndex`; add the checker's
  withdraw redeemer type (`configRefInputIndex`,
  `pegWithdrawRedeemerIndex`).
- `PegInCompleteTx.scala` / `PegOutCompleteTx.scala`: add a second 0-ADA
  withdrawal (the checker) with its redeemer. The "peg_in is the only
  withdrawal" index assumption (`PegInCompleteTx.scala:128`) breaks: with two
  withdrawals, redeemer indexes follow the protocol's withdrawal ordering
  (by script hash), so index computation must account for both.
- Genesis/setup tooling: deploy the checker, register its stake credential,
  include its hash in the genesis config datum, add a config entry for the
  checker script ref (alongside `bridged-token-script-ref`).

### 7. Testing

On-chain (`aiken check` green throughout):

- **Core policy**: happy path (checker withdrawal present); rejects missing
  checker withdrawal; rejects config ref input without the NFT; a
  delegation-is-total test (an arbitrary weird mint shape passes the core
  when the checker is present, documenting that the checker carries all
  responsibility).
- **Checker**: mint happy path (`CompletePegIn` redeemer present at the given
  index); burn happy path (`CompletePegOut`); rejects wrong asset name;
  rejects multiple asset names under the fBTC policy; rejects mint gated by
  the peg-out script; rejects `Cancel` action; rejects a redeemer index
  pointing at an unrelated redeemer entry. (The old policy had zero tests;
  this is a net gain.)
- **Config**: `config_getters_match_datum_fields` extended to pin index 19;
  existing config.ak tests updated for the new fixture field.

### 8. Documentation updates

`documentation/technical_documentation.md`:

- Config section: add field 19 to the `ConfigDatum` description; the Retire
  warning ("fBTC can never be minted or burned again") stays as is.
- fBTC minting policy section: describe the delegator/checker architecture,
  the soundness invariant (every checker path constrains the full fBTC mint
  value), and the upgrade flow.

## Decisions log

- **Presence-only core** (vs core asset-name guard, vs keeping two-script
  dispatch without redeemer casts): maximum future flexibility; governance is
  already the root of trust. Chosen by user 2026-07-16.
- **V1 checker replicates current rules** (vs relaxing mint/burn structure
  now): YAGNI; relaxations become checker swaps later.
- **Appended `ByteArray` hash field** (vs `Option<AuthorizationMethod>`): a
  signature-based mint authority is a footgun for a bridge token; matches the
  existing `*_withdraw_script_hash` field style. Reusing
  `bridged_token_policy_id` was considered and rejected (see §3).
- **New dedicated validator file** (vs folding the checker into an existing
  validator's withdraw handler): single-purpose lifetime and hash.
- **Clean cut** (vs live-config migration): nothing deployed on mainnet.
