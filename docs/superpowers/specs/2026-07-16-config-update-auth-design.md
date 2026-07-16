# Config Update Authorization – Design

**Date**: 2026-07-16
**Status**: Approved for implementation
**Scope**: `onchain/validators/bitcoin/config.ak`, `onchain/lib/bifrost/types/config.ak`, documentation

## Context

The config UTxO (singleton NFT at `config.ak`) carries the `ConfigDatum` that all
other validators read via reference inputs. In particular, `bridged-token.ak`
(the fBTC minting policy) is parameterized only by the config NFT identity and
reads the current `peg_in_withdraw_script_hash` / `peg_out_withdraw_script_hash`
from the datum at run time. This means updating the `ConfigDatum` is sufficient
to swap out protocol validators while keeping the fBTC policyId stable, so
existing fBTC stays in circulation across upgrades.

Today `config.ak`'s spend handler is hard-coded `False`: the datum can never
change. This design adds an authorized update path.

This follows the production-standard Cardano pattern (config/settings NFT +
reference-input indirection) used by Wanchain's Cardano bridge, Minswap V2, and
SundaeSwap V3. Survey of audits (CertiK/Minswap, Vacuumlabs/FluidTokens and
WingRiders, MLabs/Indigo) shows the config-update authority is treated as the
protocol's root of trust: whoever can change script hashes in the config can,
in effect, mint unlimited fBTC. The design therefore keeps the immutable
validator logic minimal and delegates all governance sophistication to a
swappable authorization target.

## Goals

- Authorized `ConfigDatum` updates for demo/testnet, keeping the fBTC policyId
  stable across validator upgrades.
- The same compiled code on all networks; only the authorization *data*
  differs. Mainnet upgrades then use a procedure already rehearsed on testnet.
- A progressive-decentralization path: dev key → SPO governance script →
  frozen, all as datum rotations, no redeploys.
- An authorized decommission (burn) path that recovers the min-ADA.

## Non-goals (explicitly out of scope)

- The SPO governance withdraw script itself (FROST group signature over the
  new datum hash + spent out-ref, timelock with peg-out exit window, per-field
  tiering). It plugs in later as a plain `update_auth` rotation; nothing in
  this design needs to change to enable it.
- Pause/guardian machinery and mint rate limits.
- Any changes to `bridged-token.ak` or other validators.

## Design

### 1. Datum change (`lib/bifrost/types/config.ak`)

Append one field at the **end** of `ConfigDatum`:

```aiken
update_auth: Option<AuthorizationMethod>
```

- `AuthorizationMethod` already exists in `bifrost/types/general` (signature,
  spend script, withdraw script, mint script, NFT ownership).
- Appending last keeps positional reads stable: `bridged-token.ak` and others
  use `get_config_as_data_list` with fixed indices (1, 10, 11, ...).
- `None` means the config is permanently frozen (today's behavior).

Intended values per environment:

| Environment | `update_auth` |
|---|---|
| testnet4 / preprod / demo | `Some(CardanoSignature(dev_pkh))` |
| mainnet at launch | `Some(CardanoWithdrawScript(spo_governance_script_hash))` |
| mainnet end-state (optional) | `None` (renounced) |

### 2. Spend handler (`config.ak`)

New redeemer type:

```aiken
pub type ConfigSpendRedeemer {
  Update
  Retire
}
```

Common to both actions:

- `expect Some(datum) = datum_opt` and
  `expect Some(update_auth) = datum.update_auth`. A `None` authority makes the
  UTxO unspendable, exactly like today's `False`.
- Locate own input via `own_ref`; the own script hash is taken from the input's
  payment credential. Mint policy and spend script share this hash, so the
  config NFT policy is the own hash and `config_asset_name` is already a
  validator parameter.
- Authorization: `authorizer.create_auth(update_auth, inputs, ref_inputs,
  withdrawals, extra_signatories, mint) |> authorize_action`. This reuses the
  existing `authorizer.ak` module wholesale and needs no redeemer indices.

`Update` action:

- Exactly one output at the config payment credential carrying the config NFT
  (`quantity == 1` of `(own_hash, config_asset_name)`, and total own-policy
  quantity in that output is 1).
- That output has an `InlineDatum` that parses as `ConfigDatum`.
- **Pinned fields**: the new `bridged_token_policy_id` and
  `bridged_token_asset_name` must equal the old values. The bridged-token
  identity can never be swapped out from under holders, even by the authority.
- Everything else is the authority's to change: script hashes, merkle-tree
  policy ids and asset names, treasury NFT identity, `min_stake`, and
  `update_auth` itself. Rotating `update_auth` is the progressive-
  decentralization mechanism (including setting it to `None` to renounce).

`Retire` action:

- The tx burns exactly the config NFT: total minted quantity under the own
  policy is −1, and it is −1 of `config_asset_name`.
- No continuing output is required. The min-ADA is released to wherever the
  authority directs it.
- Consequence (must be documented loudly): with the config NFT gone, the fBTC
  minting policy can never validate again. No further fBTC can be minted *or
  burned*. Retire is a true end-of-life action for a deployment.

### 3. Mint handler (`config.ak`)

Two paths, disambiguated by mint sign:

- **Bootstrap (+1)**: existing logic unchanged (one-shot `OutputReference`
  spent, exactly one token minted, NFT lands in output 0 at the config
  credential), plus one hardening: output 0 must carry an `InlineDatum` that
  parses as `ConfigDatum`. This makes the spend handler's assumptions hold
  from genesis.
- **Burn (−1)**: total own-policy mint quantity is −1 and it is −1 of
  `config_asset_name`. No authorization check here: the NFT only ever sits at
  the config script address (enforced at bootstrap and by `Update`), so
  burning necessarily spends the config UTxO, which runs the spend handler's
  `Retire` authorization.

### 4. Design decisions and notes

- **Spurious UTxOs**: ADA-only UTxOs sent to the config address by third
  parties are not spendable (their datum will not parse, or they fail the
  NFT rules). This is accepted; the funds are the donor's loss and the
  validator stays minimal.
- **Why a datum field and not a validator parameter**: a parameter would give
  mainnet zero updatability (contradicting SPO-set governance and the
  `fee_rate_sat_per_vb` "updated by governance" requirement in the technical
  documentation), and would make the frozen code path the one never exercised
  on testnet. A datum field keeps one compiled artifact for all networks.
- **Why governance sophistication lives outside `config.ak`**: whatever goes
  into `config.ak` is immutable forever. With
  `update_auth = CardanoWithdrawScript(...)`, the governance script runs in
  the same transaction and can inspect the old and new config datums itself,
  enforcing SPO thresholds, per-field rules, timelocks, and exit windows.
  These can evolve by rotating `update_auth`; `config.ak` stays minimal.
  This mirrors SundaeSwap V3's swappable multisig conditions and Wanchain's
  datum-carried MintCheck script.
- **Deployment constraint**: adding spend logic changes the `config.ak` script
  hash, hence a new config NFT policy, hence a new fBTC policyId. This change
  must land **before** the testnet4/preprod deployment whose policyId is meant
  to be kept. It cannot be retrofitted onto an existing deployment.

## Security considerations

- The `update_auth` holder can point `peg_in_withdraw_script_hash` at a
  permissive script and mint unlimited fBTC. The authority is the root of
  trust, equivalent in blast radius to the FROST quorum stealing the BTC
  treasury. Mainnet's SPO-set governance aligns both powers with the same
  trust set users already accept.
- Industry best practice for the mainnet governance script (future work):
  threshold authorization with cross-org key custody, an on-chain timelock
  with a user exit window (users can burn fBTC and peg out before new script
  hashes take effect), and separation of a pause power from the upgrade power.
- The upgrade path itself is attack surface (Nomad, 2022): testnet and mainnet
  intentionally share the same machinery so mainnet updates are rehearsed.

## Testing plan (`aiken check`)

Spend / `Update`:
- Happy path with `CardanoSignature` auth: datum updated, NFT continues.
- Happy path with `CardanoWithdrawScript` auth.
- Rotating `update_auth` to a new authority; renouncing to `None`.
- Rejects: missing signature; NFT not returned to config credential; NFT
  quantity ≠ 1 in continuing output; changed `bridged_token_policy_id`;
  changed `bridged_token_asset_name`; malformed new datum; datum with
  `update_auth = None` (unspendable).

Spend / `Retire`:
- Happy path: authorized burn of exactly −1, no continuing output.
- Rejects: unauthorized; burn quantity ≠ −1; wrong asset name.

Mint:
- Bootstrap rejects an output 0 datum that does not parse as `ConfigDatum`.
- Burn path accepts −1 of `config_asset_name`; rejects −1 of a different
  asset name and mixed mint/burn under the policy.

## Ripple effects

- `documentation/technical_documentation.md`: document the new field, the
  Update/Retire semantics, the progressive-decentralization path, and the
  Retire end-of-life warning.
- Off-chain code that constructs `ConfigDatum` (deploy scripts, SPO and
  watchtower programs where applicable) appends the new field.
- Fresh deployment required (new config policy → new fBTC policyId).
