# Oracle `init`: seed a confirmed block range – Design

**Date**: 2026-07-17
**Status**: Approved (approach A), not yet implemented
**Repo**: `../binocular` (code lands in binocular; spec lives here per project convention)

## Context

The Binocular oracle `init` command anchors the oracle at a **single** Bitcoin
block: `BitcoinChainState.getInitialChainState(rpc, startHeight)` builds a
`ChainState` whose `confirmedBlocksRoot` is a one-element MPF
(`mpfRootForSingleBlock`). To make a wide range of blocks provable for peg-ins,
the operator must then sync forward with `update-oracle`/`run` – batched at
`max-headers-per-tx` (40) and gated by maturation (12 deep) + `challenge-aging`
(~1h) promotion, i.e. ~200 txs and hours for a ~7.8k-block range.

We want a re-init to seed a whole confirmed range in the single init tx:
`init --start-block 136600 --confirmed-until 144450`.

### Why this is safe and cheap (from code exploration)

- The oracle NFT mint policy **does not inspect the `ChainState` datum**
  (`BitcoinValidator.scala:1404-1436`): it checks only that the one-shot
  `TxOutRef` is consumed and exactly one NFT goes to the script address. The
  initial confirmed state is entirely **owner-trusted** – the same trust model
  `SetState` documents ("consensus validity … deliberately NOT checked … exactly
  like the init datum"). **No on-chain change is required.**
- `ChainState.confirmedBlocksRoot` is a fixed **32-byte MPF root**
  (`BitcoinValidator.scala:199-204`); the full block set lives off-chain. A
  range of any size yields the **same datum size**. `forkTree = End` at init.
- There is **no on-disk MPF store**. The watchtower rebuilds the MPF from
  bitcoind on demand by walking `start-height..confirmed-height` and verifying
  against the on-chain root (`rebuildMpf`, `Command.scala:360-397`;
  `reconstructMpf`, `Command.scala:798-852`). Peg-in proofs
  (`TmProofBundle.produce`) use that reconstructed MPF. So a range-seeded oracle
  needs **zero new persistence** – provided the seeded root equals the MPF of
  exactly the canonical hashes in `[start-height, confirmed-until]`, every later
  rebuild and proof works unchanged.

## Goals

- Add `--confirmed-until <height>` to `init` (reusable, general-purpose).
- Seed `confirmedBlocksRoot` = MPF over canonical hashes `[start, confirmedUntil]`
  and set `ctx` at the `confirmedUntil` tip, in the single init tx.
- Preserve today's single-block behavior exactly when `--confirmed-until` is omitted.

## Non-goals

- Any on-chain validator / mint-policy change (none needed).
- New on-disk MPF persistence (rebuild-from-node already covers ranges).
- PoW / continuity re-verification of the seeded range (approach B, rejected):
  inconsistent with `rebuildMpf`, which trusts the node; the root is re-verified
  on every future rebuild regardless.
- Changing the sync/promotion path (`update-oracle`, `run`).

## Design (approach A: trust-the-node, mirror `rebuildMpf`)

### 1. CLI

`CliApp`: add an optional `--confirmed-until <height>` option to the `init`
subcommand, threaded into `InitOracleCommand(startBlock, confirmedUntil, dryRun)`.

### 2. `InitOracleCommand`

- `startHeight = startBlock.orElse(oracleConf.startHeight)` (unchanged).
- `confirmedTip = confirmedUntil.getOrElse(startHeight)`.
- Validate: `startHeight <= confirmedTip <= tip` (tip from `getBlockchainInfo`);
  clear errors otherwise.
- **Reorg-depth warning (non-blocking):** if `confirmedTip > tip - maturationConfirmations`,
  warn that seeding confirmed blocks shallower than the maturation depth risks a
  reorg orphaning them and re-poisoning the append-only confirmed root (the exact
  failure this recovers from), and suggest a deeper `confirmed-until`. Proceed if
  the operator continues.
- Build the initial state for `confirmedTip` (below), then Steps 3–6 (one-shot,
  parameterize, deploy ref script, submit init tx) are unchanged. The init datum
  carries the seeded `ChainState` verbatim.

### 3. `BitcoinChainState`

Extend initial-state construction to a range:

- `ctx` (`TraversalCtx`) is built **at `confirmedTip`** – `height = confirmedTip`,
  `lastBlockHash`, `currentBits`, the 11 median-time-past `timestamps`, and
  `prevDiffAdjTimestamp` all taken at `confirmedTip` (this is exactly what the
  current `getInitialChainState(rpc, confirmedTip)` already computes for a tip).
- `confirmedBlocksRoot` = MPF built by inserting `rpc.getBlockHash(h)` (keyed by
  and valued as its own hash) for every `h` in `[startHeight, confirmedTip]`,
  then `.rootHash`. This reuses the exact insert sequence of `rebuildMpf`
  (`Command.scala:360-397`) so the seed is byte-identical to a later rebuild.
  Factor the range→root walk into a shared helper so `rebuildMpf` and init use
  one implementation (no divergence).
- `forkTree = End`.
- When `startHeight == confirmedTip`, the walk yields the one-element MPF –
  identical to today's `mpfRootForSingleBlock`, preserving current behavior.

### 4. Config

The operator sets `oracle.start-height = startHeight` (already their
responsibility) so `reconstructMpf`/`rebuildMpf` walk the same range the seed
covered. `deploy-script-refs`/bridge are unaffected.

## Testing

- **Seed == rebuild:** for a small fixed range, assert the seeded
  `confirmedBlocksRoot` equals an independent `rebuildMpf` over the same range
  (shared helper makes this a strong invariant). Use a stub/recorded RPC.
- **Degenerate regression:** `confirmedUntil` omitted (== start) reproduces the
  current single-block root exactly.
- **Validation:** `startHeight > confirmedTip` and `confirmedTip > tip` error
  cleanly; `confirmedTip > tip - maturation` emits the warning but proceeds.
- **Dry-run:** `init --start-block X --confirmed-until Y --dry-run` prints the
  seeded root + `confirmedTip` and does not submit.
- Full `sbt test` green.

## Decisions log

- **Off-chain only, trust the node (A)** vs verify-the-range (B): matches
  `rebuildMpf`'s existing trust model; the root self-verifies on every rebuild.
- **`--confirmed-until` flag** (reusable) vs auto `tip - maturation`: explicit
  operator control over the confirmed tip; omitting it keeps single-block init.
- **Shared range→root helper** for init and `rebuildMpf`: guarantees the seed
  matches later rebuilds by construction (the core correctness invariant).
- **Non-blocking reorg-depth warning**: surfaces the testnet4 deep-reorg risk
  without overriding the operator's chosen `confirmed-until`.
