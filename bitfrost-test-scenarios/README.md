# bitfrost-test-scenarios

Cross-project end-to-end test harness for the Bifrost bridge: **4 heimdall SPO
instances + 1 binocular watchtower ("bitfrost") + yaci-devkit (local Cardano)
+ bitcoind (regtest)**, driven by scenario scripts. Charter: *turn the runbooks
into automated tests* — every real bridge flow spans heimdall + binocular +
the Aiken contracts + Bitcoin + Cardano, and until now all of it lived as
prose in `experiments/*.md`, executed by hand. This is the only layer where
the spec's consensus claims (deterministic TM reconstruction, byte-identical
txs across SPOs, forkless TM chain) can actually be proven.

```
                 ┌────────────┐   blockfrost-compatible API   ┌──────────────┐
  heimdall-spo1..4 ───────────►│ yaci-devkit │◄───────────────│  bitfrost    │
       │  ▲                    │  (Cardano)  │    deploys +   │ (binocular   │
       │  │ /health + DKG      └────────────┘    oracle txs   │  watchtower) │
       │  │ payloads (HTTP,                                   └──────┬───────┘
       ▼  │ pull-only)                                               │ headers
  heimdall-spoN ────────────── JSON-RPC ──────────► ┌──────────┐ ◄───┘
                                                    │ bitcoind │
                                                    │ regtest  │
                                                    └──────────┘
```

## Why bitcoind (regtest) is IN the compose, not an external node

Decision 2026-07-20. Three reasons:

1. **Scenario 3 requires it.** The federation switch spends the treasury via
   the CSV timelock leaf (`federation_csv_blocks`, default 144). On regtest
   you mine 144 blocks in one RPC call; on testnet4 you wait ~24 h of real
   time. There is no automated federation-fallback test without regtest.
2. **Both sides already support regtest.** binocular's oracle implements the
   `fPowAllowMinDifficultyBlocks` rule for testnet3/testnet4/regtest
   (`BitcoinValidator.scala`), and heimdall's `bitcoin.network = "regtest"`
   is a first-class value (`config.rs::parsed_network`).
3. **Reproducibility.** Regtest gives deterministic funding, instant
   confirmations, no faucet, no public-chain state leaking into assertions —
   the properties a CI-able suite needs.

An external running node is still supported for testnet4 smoke runs: set
`BITCOIN_RPC_URL` (+ credentials) in `.env` and start compose without the
`bitcoind` service (`docker compose up --scale bitcoind=0 ...`). The scenario
scripts read the same variables. Scenario 3 is regtest-only by nature.

## Version pinning (the risk that kills harnesses like this)

Three moving repos. Pins live in `.env` (`HEIMDALL_REF`, `BINOCULAR_REF`) and
`scripts/00-lib.sh::check_pins` warns when a source checkout's `HEAD` differs
from its pin. Contract identity is pinned by the **blueprint**: the deploy
step uses `onchain/plutus.json` from THIS repo checkout (CI enforces that the
committed blueprint reproduces from source — see
`.github/workflows/continuous-integration.yml`), so script hashes are pinned
transitively by the git ref of this repo. Do not pin hashes by hand in
scripts; they change with every compiler bump.

## Layout

- `docker-compose.yml` — the 7 services (bitcoind, yaci-devkit, bitfrost,
  heimdall-spo1..4).
- `docker/heimdall.Dockerfile`, `docker/binocular.Dockerfile` — multi-stage
  builds from sibling checkouts (paths via `.env`; binocular's in-repo
  Dockerfile is stale — no sbt in its build image, wrong jar name — so the
  working one lives here until fixed upstream).
- `config/heimdall-spo{1..4}.toml` — per-SPO configs: regtest, yaci-devkit
  blockfrost URL, container-name bifrost URLs, DKG window/health-gate tuned
  for compose (window 90 s > round2 offset 60 s + retry backoff — the
  self-healing inequality, see heimdall `EpochConfig::dkg_window`).
- `scripts/` — the scenarios:

| # | Script | Flow | Status |
|---|---|---|---|
| 1 | `01-bootstrap-dkz.sh` | Devnet up → fund wallet (faucet) → genesis treasury outpoint on regtest → 4 real stake pools (`register_pool`, 2-epoch activation + `active_stake` gate) → registry bootstrap (`bootstrap-treasury-info` → `bootstrap-registry` → `deploy-registry-ref`) → `register-spo` ×4 → `show-roster` → heimdall ×4 registry-driven DKG → assert identical `Y_51` across all 4 | **PASSING** (2026-07-20, ~80 s warm: stake-weighted 3-of-4 off the real on-chain registry, anchored ceremony window, all four SPOs converged on one `Y_51`). Automates run-dkz's "local yaci devnet / WI-024" path. Needed two heimdall fixes against yaci-store quirks: map-form cost_models and the `/epochs/latest` boundary-time fallback. |
| 2 | `02-fraud-dkz.sh` | DKG with one misbehaving/absent SPO → exclusion evidence + equivocation detection → ceremony completes 3-of-4 → (ban pipeline) | partially blocked: on-chain fault proofs are **N4** (mock verifier today); evidence + reduced-rerun assertions work now |
| 3 | `03-federation-switch.sh` | Mine past `federation_csv_blocks` → federation key spends treasury via script leaf → oracle proves the spend → key rotated to `y_federation` | Bitcoin-side spend testable now; on-chain federation-reset is **N10b** (+ witness-walker reuse **N15**) |

First target when picked up (per plan §4): the y51 peg-in → sweep → peg-out
playbook, which has a known-good trace to assert against — after scenario 1
lands.

## Usage

```bash
cp .env.example .env          # adjust source paths / pins
docker compose build
./scripts/01-bootstrap-dkz.sh
```

`keys/` and `data/` are volumes (gitignored — `keys/` holds generated demo
secrets, never commit).
