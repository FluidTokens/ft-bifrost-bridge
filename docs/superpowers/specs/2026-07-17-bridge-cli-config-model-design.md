# Bridge CLI: Config Model + Command Skeleton – Design (sub-project 1 of 5)

**Date**: 2026-07-17
**Status**: Approved scope, not yet implemented
**Repo**: `../binocular` (the binocular project; the submodule ref in
ft-bifrost-bridge is bumped after each push). Specs live here in
ft-bifrost-bridge; code lands in binocular.

## Context

`DeployBridgeCommand` is a monolith: in one run it picks four one-shot wallet
UTxOs and mints the config NFT, the completed-peg-ins + completed-peg-outs MPF
NFTs, and the TM-control NFT, deriving the whole script-hash chain inline. The
operator then hand-copies ~10 printed values into `binocular.bridge.*` HOCON and
re-mints. `BridgeConfig` conflates four kinds of value: infra (`plutusJson`),
one-shot **seeds**, **derived** policy ids (`configNftPolicyId`,
`bridgedTokenPolicyId`, `tmControlNftPolicy`), and deployment **state** (script
refs). The derived values are a stale-prone cache of things computable from the
seeds + blueprint + oracle.

This sub-project is the foundation for the modular init commands (registry,
treasury, bans in later sub-projects): a shared derivation module, a
seeds-first config, the `DeployBridge` monolith split into per-artifact `init`
commands, and an `update-config` command.

## Goals

- **One derivation source.** A `BridgeDeployment` module that, given the seeds
  (one-shot outrefs + asset names) + blueprint + oracle policy, derives every
  policy id, script hash, address, and reconstructable script. `DeployBridge`'s
  inline hash chain moves here; every command reads from it.
- **Seeds-first config.** `BridgeConfig` holds only irreducible inputs: infra,
  one-shot outrefs, asset-name overrides, `tmAuthorizedMinter`, and the script-
  ref UTxOs (deployment state). Drop the three derived policy-id fields.
- **Modular init.** Split `DeployBridge` into `init-config`,
  `init-completed-pegs`, `init-tm-control`, each minting one artifact and
  printing the seed it consumed. Keep a thin `deploy-bridge` orchestrator that
  runs them in order for the common case.
- **`update-config`.** Spend the config UTxO (authorized by `update_auth` =
  `oracle.owner-pkh`) and write a new `ConfigDatum` (rotate a script hash, the
  token name, or `update_auth`; or Retire).

## Non-goals

- Wiring treasury / SPO-registry / ban-list (sub-projects 2–4).
- The operator runbook (sub-project 5).
- Changing on-chain validators or the `ConfigDatum` shape (Spec 0 fixed those).
- Auto-discovery of on-chain UTxOs by NFT (a possible later enhancement; this
  sub-project keeps the recorded-outref approach).

## Design

### 1. `BridgeDeployment` derivation module

New `binocular/watchtower/BridgeDeployment.scala`. Constructed from the seeds:

```scala
final case class BridgeSeeds(
    configOneShot: TxOutRef,
    completedPegInsOneShot: TxOutRef,
    completedPegOutsOneShot: TxOutRef,
    tmControlOneShot: TxOutRef,
    configAssetName: ByteString,        // default BIFCFG
    bridgedTokenAssetName: ByteString,  // default fSAT
    tmControlAssetName: ByteString,     // default TMCTRL
    tmAuthorizedMinter: ByteString,
    updateAuthPkh: ByteString           // = oracle.owner-pkh
)

final class BridgeDeployment(
    blueprint: BifrostBlueprint,
    oraclePolicy: ByteString,
    seeds: BridgeSeeds
) {
  // all derived, matching today's DeployBridge inline chain:
  val configPolicy: ScriptHash
  val bridgedTokenPolicy / pegInWithdrawHash / pegOutWithdrawHash: ScriptHash
  val cpiPolicy / cpoPolicy: ScriptHash        // cpi/cpo NFT names are the CPI/CPO constants
  val tmControlPolicy / tmNftPolicy: ScriptHash
  val producedVerifierHash / notProducedVerifierHash: ScriptHash
  val configDatum: ConfigDatum                 // the 11-field datum, assembled from the above
  // + the reconstructed Script objects and addresses each command needs
}
```

`DeployBridgeCommand`, `PegInCompleteCommand`, `PegOutCompleteCommand`,
`RegisterBridgeCredsCommand`, and `DeployScriptRefsCommand` all replace their
inline `Contract(...)` derivations with a single `BridgeDeployment` instance.

### 2. `BridgeConfig` reshaped (seeds-first)

Keep: `plutusJson`; the four one-shot outrefs
(`configOneShotRef`, `completedPegInsOneShotRef`, `completedPegOutsOneShotRef`,
`tmControlOneShotRef`); the asset-name overrides
(`configNftAssetName`, `bridgedTokenAssetName`, `tmControlNftName`);
`tmAuthorizedMinter`; the script-ref UTxOs (`pegInScriptRef`, …).

Drop (now derived): `configNftPolicyId`, `bridgedTokenPolicyId`,
`tmControlNftPolicy`. Readers switch to `deployment.configPolicy` etc.

`configOneShotRef` is added (today only the cpi/cpo one-shots are recorded; the
config + tm-control one-shots were consumed and only their *derived* policies
persisted). Recording the config + tm-control one-shots is what makes the
policies derivable and removes the hand-copied hashes.

### 3. Split `DeployBridge` into init commands

- **`init-config`**: pick a clean one-shot, mint the config NFT carrying the
  `deployment.configDatum`, print `configOneShotRef` + the config policy.
- **`init-completed-pegs`**: mint the cpi and cpo MPF NFTs (empty roots), print
  their one-shots + policies. (Kept as one command since both are MPF roots
  minted the same way; matches the on-chain pair.)
- **`init-tm-control`**: mint the TM-control NFT carrying `TmControlDatum`,
  print its one-shot + policy.
- **`deploy-bridge`** (orchestrator): run the three in order (config first, so
  the datum's script hashes are fixed before the MPF/TM artifacts reference the
  config identity), preserving today's one-command UX. The wallet-splitting
  pre-step (ensuring enough clean one-shot UTxOs) moves into a shared helper the
  init commands and the orchestrator both use.

Each init command records its one-shot into the config file section it owns, so
nothing is hand-copied between steps.

### 4. `update-config` command

New `UpdateConfigCommand`: locate the config UTxO by its NFT, spend it authorized
by `update_auth` (`oracle.owner-pkh`), and produce one continuing output at the
config address carrying the NFT (and no other own-policy token), the same
non-ADA value, and a new inline `ConfigDatum`. The new datum is the current one
with a caller-selected field changed (a `--set <field>=<hex>` style option, or
Retire via `--retire`). Signs with the owner key. This is the in-place
script-hash / token-name / `update_auth` rotation path.

## Testing

- `BridgeDeployment`: a known-answer test pinning the derived config/bridged-
  token/cpi/cpo/peg-in/peg-out hashes for fixed seeds (mirrors the existing
  `BifrostContractsTest` hash locks, which fold into this module).
- Each init command: a dry-run test asserting the tx it builds mints exactly the
  intended NFT to the intended address with the intended datum (using the
  existing dry-run plumbing).
- `update-config`: a builder test asserting the continuing output preserves the
  NFT + value + address and carries the mutated datum.
- Full `sbt test` green; blueprint drift check unaffected.

## Decisions log

- **Seeds-first config, derive the rest** (vs cache derived hashes): removes the
  hand-copy step and staleness; the on-chain `ConfigDatum` remains the live
  source of truth for readers.
- **Keep recorded script-ref outrefs** (vs discover-by-NFT now): smaller change;
  discovery is a later enhancement.
- **Keep a `deploy-bridge` orchestrator** (vs only granular commands): preserves
  one-command UX; granular commands enable partial re-runs and the later
  registry/treasury/bans additions.
- **`update-config` uses `--set`/`--retire`** (vs a bespoke command per field):
  one command covers all in-place datum edits.
