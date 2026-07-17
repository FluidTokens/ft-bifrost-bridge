# fSAT Mint + Config: Transaction-Building Migration (for FluidTokens)

This is a delta doc for teams that already build bridge transactions against the
earlier contracts. It covers what changed under the **updatable config** and the
**stable, delegated fSAT monetary policy**. Bitcoin-side depositor auth (BIP-322)
is a separate change and is out of scope here (see the bottom note).

## TL;DR: what you must change

1. **Token rename fBTC → fSAT.** The asset name is a config value (`ConfigDatum`
   field 1). Read it from the config datum; do not hardcode. The genesis default
   is `"fSAT"` (hex `66534154`). 1 token = 1 satoshi.
2. **`bridged_token` mint redeemer shrank** to `{ config_ref_input_index }`
   (the old `wanted_peg_withdraw_redeemer_index` field is gone).
3. **`ConfigDatum` was rebuilt** from ~20 fields to **11**, re-indexed. If you
   read any hash by positional index, or construct the datum at deploy, update to
   the table below.
4. **cpi/cpo root NFT asset names are now constants** `"CPI"` / `"CPO"`
   (previously `sha256(one_shot_ref)`).
5. **Read every script hash from the live config datum**, not from a cached copy
   or a blueprint-derived value: the config is now updatable in place.

Your completion transactions otherwise keep the **same withdrawals they already
had** (peg-in: the `peg_in` withdrawal; peg-out: `peg_out` + produced-verifier).
No new withdrawal was added.

## The delegated fSAT policy (why the redeemer shrank)

`bridged_token` (the fSAT policy) is now a thin **presence delegator**. On a mint
it reads the `ConfigDatum` from the referenced config UTxO and requires:

- `config[0] == its own policy id` (identity anchor);
- exactly one asset name under its policy, equal to `config[1]`;
- if minting (qty > 0): a **withdrawal from `config[4]` (peg-in withdraw script)**
  is present in the tx;
- if burning (qty < 0): a **withdrawal from `config[5]` (peg-out withdraw
  script)** is present.

It does not cast or inspect the peg redeemer anymore, so its redeemer is just
`{ config_ref_input_index }`. The actual amount/authorization checks live in
`peg_in` / `peg_out` completion, which your tx already invokes. Net: the fSAT
policy id is stable across upgrades, and the mint rules can be swapped via a
config update without changing the token.

## New `ConfigDatum` (11 fields, positional)

| idx | field | note |
|----|----|----|
| 0 | `bridged_token_policy_id` | fSAT policy id (stable) |
| 1 | `bridged_token_asset_name` | e.g. `fSAT`; per-deploy |
| 2 | `completed_peg_ins_merkle_tree_policy_id` | asset name is the constant `CPI` |
| 3 | `completed_peg_outs_merkle_tree_policy_id` | asset name is the constant `CPO` |
| 4 | `peg_in_withdraw_script_hash` | peg-in completion script (mint delegate) |
| 5 | `peg_out_withdraw_script_hash` | peg-out completion script (burn delegate) |
| 6 | `peg_in_close_verifier_script_hash` | dormant (F1–F6) |
| 7 | `legit_tm_and_peg_out_produced_verifier_script_hash` | peg-out completion |
| 8 | `legit_tm_and_peg_out_not_produced_verifier_script_hash` | dormant (F1–F6) |
| 9 | `min_stake` | Int; off-chain use |
| 10 | `update_auth` | `Option<AuthorizationMethod>`; None = frozen |

Removed vs the old datum: source-chain/block-header MPF policy+name, treasury
NFT policy+name, the completed-peg-ins/outs **asset-name** fields (now constants),
and the short-lived mint-checker field. Everything shifted; do not assume old
indices.

**Read hashes from the datum, live.** The config UTxO is now spendable by its
`update_auth` (Update or Retire), so its script hashes can change between
deployments in place. Locate the config UTxO by its NFT, read the inline
`ConfigDatum`, and take the peg/MPF/verifier hashes from it. Do not cache them or
re-derive from a pinned blueprint.

## Peg-in completion (mint) – what changes

- **Mint:** `+peg_in_amount` fSAT under the `bridged_token` policy, asset name =
  `config[1]`.
- **`bridged_token` redeemer:** `{ config_ref_input_index }` (dropped the second
  field).
- **Withdrawals:** unchanged – the single `peg_in` withdrawal
  (`CompletePegIn`). `bridged_token` only requires this withdrawal is present.
- **Reference inputs:** unchanged – config NFT UTxO + the confirmed-TM UTxO.
- **completed-peg-ins UTxO:** located by `config[2]` policy + the **`CPI`**
  constant asset name (was a sha256 name).

## Peg-out completion (burn) – what changes

- **Mint:** `-peg_out_amount` fSAT (burn).
- **`bridged_token` redeemer:** `{ config_ref_input_index }`.
- **Withdrawals:** unchanged – `peg_out` (`CompletePegOut`) + the produced
  verifier (`config[7]`). `bridged_token` only requires the `peg_out` withdrawal
  is present.
- **completed-peg-outs UTxO:** located by `config[3]` policy + the **`CPO`**
  constant asset name.

## Config Update / Retire (new tx types)

The config UTxO is no longer immutable. If you operate a bridge:

- **Update:** spend the config UTxO authorized by `update_auth`, with exactly one
  continuing output at the config address carrying the NFT (and no other
  own-policy token) and a new inline `ConfigDatum`. The full address and the
  non-ADA value must be preserved.
- **Retire:** burn the config NFT (mint −1). After Retire, fSAT can never be
  minted or burned again – it is an end-of-life action.

For building peg-in/peg-out txs you still only **reference** the config UTxO; you
never spend it.

## Deployment note

Every script hash changed in this revision, so a live bridge is orphaned and
needs a fresh deploy. Pending Bitcoin deposits are re-created as new PegInRequests
under the new scripts; the completed-peg-ins tree is keyed by the deposit outpoint
(not the peg-in hash), so double-mint protection carries across the redeploy.

## Out of scope: BIP-322 depositor auth

Peg-in completion now verifies the depositor's authorization via a **BIP-322**
key-path signature rather than a raw Schnorr signature (the depositor signs
`"BFR-mint-v1:" ++ hex(binding_digest)`, and `user_source_chain_pub_key` is the
taproot output key). That is a separate change from the config/monetary-policy
work covered here; ask for the BIP-322 note if you need the signing details.
