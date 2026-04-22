# Remove 67% Threshold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the 67% FROST threshold from the Bifrost specification across all docs, diagrams, and Lean proofs. After completion, the protocol describes a two-mode signing flow: 51% FROST main line + federation emergency fallback.

**Architecture:** Documentation-only change. Treasury Taproot tree collapses from `key=Y₅₁ | leaves={Y₆₇, Y_fed+CSV}` to `key=Y₅₁ | leaf=Y_fed+CSV`. Phases collapse from 3 to 2. Signing cascade keeps its `mode` field but the value set shrinks to `{51, federation}`. Lean structures (`EpochKeys`, `Roster`, `QuorumLevel`) lose their 67-related fields/constructors.

**Tech Stack:** Markdown, Mermaid (.mmd), Lean 4 (proofs/BifrostProofs/), Aiken (no edits — verified zero references).

**Spec:** `docs/superpowers/specs/2026-04-21-remove-67-threshold-design.md`

---

## File Map

**Modified:**

- `documentation/technical_documentation.md` — main spec (~41 occurrences across glossary, notation, tables, narrative, Taproot construction, DKG, signing-path variants, size caps, rollout phases, epoch lifecycle).
- `documentation/bitcoin-bridge-comparison.md` — drop "Aspirational security" row in trust-assumptions table; rewrite F3.
- `documentation/formal_verification.md` — rewrite proof sketch (line 172), F3 (line 204), S4 (line 237); drop `threshold67` and `groupKey67` fields from the Roster type definition (section 6.2).
- `documentation/diagrams/epoch_lifecycle.mmd` — drop two "FROST sign 67%" tasks; shift 51% windows.
- `documentation/diagrams/epoch_lifecycle_realistic.mmd` — title and 4 task labels.
- `documentation/diagrams/utxo_flow.mmd` — Treasury UTxO label edits.
- `proofs/BifrostProofs/Basic.lean` — remove `y67`, `threshold67`, `groupKey67`, `q67`.
- `proofs/BifrostProofs/State.lean` — update one comment.
- `proofs/BifrostProofs/FailSafe.lean` — rewrite F3 theorem text and total-failure theorem text.

**Out of scope:** `onchain/` Aiken (verified no references), `documentation/demo_simplifications.md` (no references), external whitepaper PDF.

---

## Task 1: Baseline verification

**Files:** none modified.

- [ ] **Step 1: Capture pre-edit grep counts**

Run from repo root:

```bash
echo "=== technical_documentation.md ==="
rg -c '67%|Y_\{67\}|Y_67|aspirational' documentation/technical_documentation.md
echo "=== bitcoin-bridge-comparison.md ==="
rg -c '67%|Y_\{67\}|Y_67|aspirational' documentation/bitcoin-bridge-comparison.md
echo "=== formal_verification.md ==="
rg -c '67%|Y_67|threshold67|groupKey67|q67' documentation/formal_verification.md
echo "=== diagrams ==="
rg -c '67' documentation/diagrams/*.mmd
echo "=== Lean ==="
rg -c '67|y67|q67|threshold67|groupKey67' proofs/BifrostProofs/*.lean
```

Expected: nonzero counts in all listed files. This is the baseline. After all edits, the same greps must return zero (or only legitimate leftovers — see verification steps in Task 8).

---

## Task 2: technical_documentation.md — glossary, notation, lifecycle labels

**Files:**

- Modify: `documentation/technical_documentation.md`

- [ ] **Step 1: Update glossary entry — Mode**

Find (line ~90):

```
* **Mode (`67` / `51` / federation)**: active threshold path used for the current TM signing attempt.
```

Replace with:

```
* **Mode (`51` / federation)**: active threshold path used for the current TM signing attempt.
```

- [ ] **Step 2: Update glossary entry — Signing cascade**

Find (line ~103):

```
* **Signing cascade / Threshold failover**: sequential attempt order: 67% → 51% → federation.
```

Replace with:

```
* **Signing cascade / Threshold failover**: sequential attempt order: 51% → federation.
```

- [ ] **Step 3: Update notation table — Y row**

Find (line ~136):

```
| $Y_{51}$, $Y_{67}$                     | FROST group public keys at the 51% and 67% thresholds             |
```

Replace with:

```
| $Y_{51}$                               | FROST group public key at the 51% threshold                       |
```

- [ ] **Step 4: Drop Phase 3 from rollout phases table**

Find (line ~158):

```
| Phase 3 — 67% SPO Participation | Aspirational level at which $Y_{67}$ script-leaf signing becomes the preferred path for stronger on-chain security. |
```

Delete the entire line.

- [ ] **Step 5: Update Update-Y label**

Find (line ~167):

```
| Update Y               | Publication of the new roster's $Y_{67}$ and $Y_{51}$ to `treasury.ak`.                                     |
```

Replace with:

```
| Update Y               | Publication of the new roster's $Y_{51}$ to `treasury.ak`.                                                  |
```

- [ ] **Step 6: Update Signing-cascade label**

Find (line ~169):

```
| Signing cascade        | Threshold-failover signing sequence (67% → 51% → federation).                                               |
```

Replace with:

```
| Signing cascade        | Threshold-failover signing sequence (51% → federation).                                                     |
```

- [ ] **Step 7: Drop "67% quorum" row from spending-paths label table**

Find (line ~177):

```
| 67% quorum (aspirational) | Treasury spent via the $Y_{67}$ script leaf; peg-in inputs spent via $Y_{51}$ key path.                             |
```

Delete the entire line.

- [ ] **Step 8: Verify section**

Run:

```bash
rg -n '67%|Y_\{67\}|aspirational' documentation/technical_documentation.md | head -50
```

Confirm none of the matches above (lines 90, 103, 136, 158, 167, 169, 177) remain. Other matches still present — they're handled in subsequent tasks.

- [ ] **Step 9: Commit**

```bash
git add documentation/technical_documentation.md
git commit -m "Remove 67% references from glossary, notation, and lifecycle labels"
```

---

## Task 3: technical_documentation.md — components and narrative paragraphs

**Files:**

- Modify: `documentation/technical_documentation.md`

- [ ] **Step 1: Update treasury.ak component description**

Find (line ~205, search for `treasury.ak`):

```
  * **treasury.ak**: stores the Treasury state UTxO. It carries the currently available Treasury FROST group public keys (for the 67% and 51% modes when those DKGs completed), the federation fallback key $Y_{federation}$, a Merkle Patricia Trie of completed peg-ins, and a second Merkle Patricia Trie root for active Bifrost identity bindings `bifrost_id_pk -> pool_id`.
```

Replace `(for the 67% and 51% modes when those DKGs completed)` with `(for the 51% mode after DKG completes)`. Keep the rest of the bullet intact.

- [ ] **Step 2: Replace 3-step signing cascade with 2-step**

Find (lines ~229–234):

```
The signing cascade tries higher quorum levels first for stronger security:

1. **67% quorum ($Y_{67}$, aspirational)**: SPOs sign via the $Y_{67}$ script leaf in the Treasury Taproot tree. This proves the strongest security threshold on Bitcoin.
2. **51% quorum ($Y_{51}$, main line)**: SPOs sign via the $Y_{51}$ key path — the cheapest spending path. This is the primary operating mode.
3. **Federation ($Y_{federation}$, emergency)**: if neither SPO threshold mode yields a usable signature within its bounded setup and signing phases, the federation signs via the $Y_{federation}$ script leaf with timelock.
```

Replace with:

```
The signing cascade tries the SPO threshold first, then falls back to the federation:

1. **51% quorum ($Y_{51}$, main line)**: SPOs sign via the $Y_{51}$ key path — the cheapest spending path. This is the primary operating mode.
2. **Federation ($Y_{federation}$, emergency)**: if the 51% mode does not yield a usable signature within its bounded setup and signing phases, the federation signs via the $Y_{federation}$ script leaf with timelock.
```

- [ ] **Step 3: Update post-cascade narrative**

Find (line ~237):

```
In the 67% and 51% modes, the SPOs sign this transaction using FROST group signing and post the serialized signed transaction to Cardano (treasury_movement.ak). In the federation mode, the federation signs via the $Y_{federation}$ script path with timelock and the resulting signed transaction is posted to Cardano the same way.
```

Replace `In the 67% and 51% modes` with `In the 51% mode`.

- [ ] **Step 4: Update peg-in flow narrative**

Find (line ~260):

```
* Wait for the peg-in to be included in the Treasury Movement transaction at the next epoch boundary. In the normal 67% and 51% modes, SPOs sign this transaction with FROST and post it to Cardano (`treasury_movement.ak`); in the emergency mode, the federation satisfies the $Y_{federation}$ fallback script path instead.
```

Replace `In the normal 67% and 51% modes` with `In the normal 51% mode`.

- [ ] **Step 5: Update peg-out flow narrative**

Find (line ~396, in the user peg-out flow section):

```
* Wait for the peg-out to be included in the Treasury Movement transaction at the next epoch boundary. In the normal 67% and 51% modes, SPOs sign this transaction with FROST and post it to Cardano (`treasury_movement.ak`); in the emergency mode, the federation satisfies the $Y_{federation}$ fallback script path instead.
```

Replace `In the normal 67% and 51% modes` with `In the normal 51% mode`.

- [ ] **Step 6: Verify**

Run:

```bash
rg -n '67% and 51%|signing cascade tries higher' documentation/technical_documentation.md
```

Expected: no matches.

- [ ] **Step 7: Commit**

```bash
git add documentation/technical_documentation.md
git commit -m "Rewrite signing cascade narrative as 51% → federation"
```

---

## Task 4: technical_documentation.md — Taproot address construction

**Files:**

- Modify: `documentation/technical_documentation.md`

- [ ] **Step 1: Update intro paragraph**

Find (line ~269):

```
The Treasury address and peg-in addresses use different Taproot trees following BIP341 [4]. Both use $Y_{51}$ as the key-path internal key, making the 51% FROST threshold the primary ("main line") operating mode. The 67% threshold appears as a script leaf in the Treasury tree for aspirational stronger security, and the federation appears as a timelock-gated fallback in both trees.
```

Replace with:

```
The Treasury address and peg-in addresses use different Taproot trees following BIP341 [4]. Both use $Y_{51}$ as the key-path internal key, making the 51% FROST threshold the main-line operating mode. The federation appears as a timelock-gated fallback script leaf in both trees.
```

- [ ] **Step 2: Update Keys subsection**

Find (line ~273):

```
- $Y_{67}$ and $Y_{51}$ are FROST group public keys produced by **separate DKGs** with thresholds ensuring any signing subset controls ≥67% and ≥51% of delegated stake respectively. Both are stored in `treasury.ak`.
```

Replace with:

```
- $Y_{51}$ is the FROST group public key produced by DKG with a threshold ensuring any signing subset controls more than 51% of delegated stake. It is stored in `treasury.ak`.
```

- [ ] **Step 3: Update Treasury Taproot tree intro**

Find (line ~278):

```
The Treasury address (holding consolidated funds) uses $Y_{51}$ as the key-path internal key, with an aspirational stronger path and an emergency fallback:
```

Replace with:

```
The Treasury address (holding consolidated funds) uses $Y_{51}$ as the key-path internal key, with a single emergency fallback script leaf:
```

- [ ] **Step 4: Update Treasury Taproot tree table**

Find (lines ~280–284):

```
| Path          | Key              | Condition     | Use case                                            |
| ------------- | ---------------- | ------------- | --------------------------------------------------- |
| Key path | $Y_{51}$ | Immediate | Normal operation (main line): full TM |
| Script leaf 1 | $Y_{67}$ | Immediate | Aspirational: full TM with strongest security proof |
| Script leaf 2 | $Y_{federation}$ | After timeout | Emergency fallback: full TM |
```

Replace with:

```
| Path          | Key              | Condition     | Use case                              |
| ------------- | ---------------- | ------------- | ------------------------------------- |
| Key path      | $Y_{51}$         | Immediate     | Normal operation (main line): full TM |
| Script leaf   | $Y_{federation}$ | After timeout | Emergency fallback: full TM           |
```

- [ ] **Step 5: Drop "When 67% quorum is available" paragraph and Y_67 leaf script block**

Find (lines ~286–292):

```
When 67% quorum is available, SPOs prefer $Y_{67}$ (script leaf 1) to prove the stronger security threshold on-chain on Bitcoin, even though it costs slightly more than the key path. When 67% is not available, they fall back to $Y_{51}$ key path (main line, cheapest).

Script leaf 1 ($Y_{67}$ aspirational):
```
<Y_67> OP_CHECKSIG
```

Script leaf 2 (federation rescue):
```

Delete the prose paragraph and the entire "Script leaf 1" block (heading + fenced code). Then update the next heading from "Script leaf 2 (federation rescue)" to "Script leaf (federation rescue)". The federation script body itself is unchanged.

After edit, this section should read:

```
Script leaf (federation rescue):
```
<timeout_federation> OP_CHECKSEQUENCEVERIFY OP_DROP <Y_federation> OP_CHECKSIG
```
```

- [ ] **Step 6: Update Merkle tree diagram**

Find (lines ~298–303):

```
Merkle tree (2 leaves):
```
     root
    /    \
  Y_67  Y_federation
```
```

Replace with:

```
Merkle tree (single leaf):
```
     root
       |
  Y_federation
```
```

- [ ] **Step 7: Update epoch-rotation note**

Find (line ~307):

```
This address changes each epoch after DKG, since $Y_{67}$ and $Y_{51}$ are regenerated.
```

Replace with:

```
This address changes each epoch after DKG, since $Y_{51}$ is regenerated.
```

- [ ] **Step 8: Update post-table commentary on spending paths**

Find (line ~309):

```
When 67% quorum is available, SPOs spend the treasury via the $Y_{67}$ script leaf — proving the stronger security threshold on Bitcoin at a slightly higher cost. When only 51% quorum is available, SPOs use the $Y_{51}$ key path — a single 64-byte Schnorr signature with no script reveal, the cheapest spending path. In emergency (federation), the $Y_{federation}$ script path with timelock is used.
```

Replace with:

```
SPOs spend the treasury via the $Y_{51}$ key path — a single 64-byte Schnorr signature with no script reveal, the cheapest spending path. In emergency (federation), the $Y_{federation}$ script path with timelock is used.
```

- [ ] **Step 9: Verify**

Run:

```bash
rg -n 'Y_\{67\}|Y_67|aspirational' documentation/technical_documentation.md | head -30
```

Expected: matches only in sections covered by later tasks (TM signing variants table, size cap line, DKG section, epoch lifecycle, namespace_hash). The Taproot construction section should be clean.

- [ ] **Step 10: Commit**

```bash
git add documentation/technical_documentation.md
git commit -m "Collapse Treasury Taproot tree to single federation script leaf"
```

---

## Task 5: technical_documentation.md — TM size cap, signing-path variants, DKG

**Files:**

- Modify: `documentation/technical_documentation.md`

- [ ] **Step 1: Update size-cap row (line ~596)**

Find:

```
| **Size (est.)** | **Hard-capped at ~15 KB raw bytes** — the signed TM is carried in the Cardano Post-TM datum, which must fit the 16 KB Cardano tx limit. Per-variant max batch: ~100 peg-ins + ~100 peg-outs (51% key-path, ~107 B/input); ~98+98 (67% aspirational); ~57+57 (federation — script-path + CSV on every input, ~213 B/input). Beyond these, SPOs split across multiple TMs (see line above). |
```

Replace with:

```
| **Size (est.)** | **Hard-capped at ~15 KB raw bytes** — the signed TM is carried in the Cardano Post-TM datum, which must fit the 16 KB Cardano tx limit. Per-variant max batch: ~100 peg-ins + ~100 peg-outs (51% key-path, ~107 B/input); ~57+57 (federation — script-path + CSV on every input, ~213 B/input). Beyond these, SPOs split across multiple TMs (see line above). |
```

- [ ] **Step 2: Update TM signing-path variants table**

Find (lines ~600–604):

```
| Variant | Treasury input via | Peg-in inputs via | Chosen when |
|---------|--------------------|-------------------|-------------|
| **67% aspirational** | $Y_{67}$ script leaf | $Y_{51}$ key path | 67% quorum produced a valid aggregate signature |
| **51% main line** | $Y_{51}$ key path | $Y_{51}$ key path | 67% failed, 51% quorum succeeded |
| **Federation emergency** | $Y_{federation}$ script leaf + CSV | $Y_{federation}$ script leaf + CSV | both FROST modes exhausted |
```

Replace with:

```
| Variant | Treasury input via | Peg-in inputs via | Chosen when |
|---------|--------------------|-------------------|-------------|
| **51% main line** | $Y_{51}$ key path | $Y_{51}$ key path | 51% quorum produced a valid aggregate signature |
| **Federation emergency** | $Y_{federation}$ script leaf + CSV | $Y_{federation}$ script leaf + CSV | 51% mode exhausted |
```

- [ ] **Step 3: Find and update §Spending paths and Treasury Movement variants**

Find (lines ~358–366):

```
All quorum levels construct **full** Treasury Movement transactions (sweeping peg-in UTxOs, fulfilling peg-outs, and moving the treasury). The signing cascade tries higher quorums first:

**Script path on Treasury, key path on peg-in inputs (67% quorum — aspirational):**

[content of the aspirational paragraph]

**Key path on Treasury, key path on peg-in inputs (51% quorum — main line):**

If SPOs cannot collect enough partial signatures for the 67% threshold, they switch to the $Y_{51}$ path. The transaction covers the same peg-in/peg-out batch and treasury move, but uses the witness structure required by the 51% mode.
```

Read the file around lines 355-375 first to capture exact text, then:
- Delete the "Script path on Treasury, key path on peg-in inputs (67% quorum — aspirational):" subsection entirely (heading + body paragraph).
- In the surviving "51% quorum — main line" subsection, replace its body paragraph (which currently begins "If SPOs cannot collect enough partial signatures for the 67% threshold…") with:

```
SPOs sign the full peg-in/peg-out batch and treasury move via the $Y_{51}$ key path — a single 64-byte Schnorr aggregate signature with no script reveal. This is the cheapest and main-line spending path.
```

- [ ] **Step 4: Update §Flow of Bitcoin over epochs, ceremonies — step 8**

Find (line ~813):

```
8. **Threshold signing cascade** — the current roster attempts threshold signing with overlapping quorum levels. 67% signing starts first if the 67% DKG completed during setup; 51% mode opens immediately once 67% setup/signing has finished unsuccessfully, or immediately if the 67% key was never produced; federation opens immediately once both SPO threshold modes are unavailable or unsuccessful. The first mode to succeed wins.
```

Replace with:

```
8. **Threshold signing cascade** — the current roster attempts 51% threshold signing. The federation path opens immediately once 51% setup/signing has finished unsuccessfully. The first mode to succeed wins.
```

- [ ] **Step 5: Update epoch-lifecycle happy-path narrative**

Find (lines ~821–825):

```
The epoch lifecycle above shows generous time windows for the signing cascade (67% → 51% → federation). In the happy path, when 67% quorum is available, the epoch proceeds much faster:

- **DKG**: ~5 minutes (off-chain, SPOs communicate via `bifrost_url` endpoints).
- **FROST 67% signing**: ~1 minute per Treasury Movement transaction.
- **Multiple TM batches**: the roster processes peg requests in multiple batches throughout the epoch, each cycling through build → sign → broadcast → Bitcoin confirmation.
```

Replace with:

```
The epoch lifecycle above shows generous time windows for the signing cascade (51% → federation). In the happy path, when 51% quorum is available, the epoch proceeds much faster:

- **DKG**: ~5 minutes (off-chain, SPOs communicate via `bifrost_url` endpoints).
- **FROST 51% signing**: ~1 minute per Treasury Movement transaction.
- **Multiple TM batches**: the roster processes peg requests in multiple batches throughout the epoch, each cycling through build → sign → broadcast → Bitcoin confirmation.
```

- [ ] **Step 6: Update DKG section — namespace and URL**

Find (line ~1048):

```
blake2b_256(phase || epoch || threshold_or_mode || attempt || txid?)
```

Leave unchanged — the field still exists, value set just shrinks.

Find (line ~1154):

```
Where `<threshold>` is `67` or `51` (the two DKGs run concurrently), and `<attempt>` is the DKG namespace field for that threshold in the current epoch. In the normal protocol flow it remains `0`.
```

Replace with:

```
Where `<threshold>` is `51` (one DKG per epoch), and `<attempt>` is the DKG namespace field in the current epoch. In the normal protocol flow it remains `0`.
```

Find (line ~1174):

```
"bifrost-dkg-r1" || epoch (8B BE) || threshold (8B BE, 67 or 51) || attempt (8B BE) || pool_id (28B)
```

Replace with:

```
"bifrost-dkg-r1" || epoch (8B BE) || threshold (8B BE, 51) || attempt (8B BE) || pool_id (28B)
```

Find (line ~1215):

```
Where `<threshold>` is `67` or `51` (the two DKGs run concurrently), and `<attempt>` is the same namespace field as in Round 1.
```

Replace with:

```
Where `<threshold>` is `51` (one DKG per epoch), and `<attempt>` is the same namespace field as in Round 1.
```

Find (line ~1242):

```
"bifrost-dkg-r2" || epoch (8B BE) || threshold (8B BE, 67 or 51) || attempt (8B BE) || pool_id (28B)
```

Replace with:

```
"bifrost-dkg-r2" || epoch (8B BE) || threshold (8B BE, 51) || attempt (8B BE) || pool_id (28B)
```

- [ ] **Step 7: Drop "run twice" sentence in DKG section**

Find (line ~1276):

```
The above steps are run **twice** — once with a threshold $t_{67}$ (producing $Y_{67}$) and once with $t_{51}$ (producing $Y_{51}$). The two DKGs can run concurrently with the same candidate set.
```

Replace with:

```
The above steps are run once per epoch with threshold $t_{51}$, producing $Y_{51}$.
```

- [ ] **Step 8: Update next paragraph (Taproot derivation)**

Find (line ~1278):

```
4. Derives the Bitcoin Treasury Taproot address from the successfully derived threshold keys (`$Y_{67}$` and/or `$Y_{51}$`) together with $Y_{federation}$ (see **Taproot address construction**).
```

Replace with:

```
4. Derives the Bitcoin Treasury Taproot address from the successfully derived $Y_{51}$ together with $Y_{federation}$ (see **Taproot address construction**).
```

- [ ] **Step 9: Update §Rollout phases description (Phase 3 paragraph)**

Find (lines ~794–798):

```
**Phase 1 — Federation Launch**: The bridge launches with the federation as the only signing entity. SPOs begin registering. The federation key is the $Y_{federation}$ used in the Taproot fallback path. During this phase, all Treasury Movement transactions are signed via the federation script path with timelock.

**Phase 2 — 51% SPO Participation**: Once sufficient SPOs have registered and completed DKG, the 51% FROST threshold becomes operational. SPOs sign via key path ($Y_{51}$), and the federation becomes an emergency-only fallback. This is the "main line" operating mode — the protocol's primary steady-state.

**Phase 3 — 67% SPO Participation (aspirational)**: As more SPOs join, the bridge achieves the aspirational 67% participation level. This doesn't change the signing key (still $Y_{51}$ key path available) but provides stronger security: any signing subset now controls at least 67% of delegated stake, making attacks significantly more expensive. When 67% quorum is available, SPOs prefer to sign via the $Y_{67}$ script leaf to prove the stronger security threshold on-chain on Bitcoin.
```

Delete the Phase 3 paragraph entirely. Phases 1 and 2 remain unchanged.

- [ ] **Step 10: Verify**

Run:

```bash
rg -n '67%|Y_\{67\}|Y_67|aspirational|threshold_or_mode' documentation/technical_documentation.md
```

Expected: matches only in two places — the namespace_hash definition (intentionally retained, line ~1048) which uses generic `threshold_or_mode`, and possibly inside the §Rollout phases title or any remaining stragglers. Investigate any remaining hit; update or confirm intentional.

- [ ] **Step 11: Commit**

```bash
git add documentation/technical_documentation.md
git commit -m "Update TM size caps, signing variants, DKG to single 51% threshold"
```

---

## Task 6: bitcoin-bridge-comparison.md

**Files:**

- Modify: `documentation/bitcoin-bridge-comparison.md`

- [ ] **Step 1: Drop Aspirational security row**

Find (line ~343):

```
| **Aspirational security** | 67%+ stake threshold for stronger guarantees when enough SPOs participate |
```

Delete the entire line.

- [ ] **Step 2: Update F3 description**

Find (line ~380):

```
- **F3**: Federation can sign if both 67% and 51% quorums fail (timelocked emergency)
```

Replace with:

```
- **F3**: Federation can sign if 51% quorum fails (timelocked emergency)
```

- [ ] **Step 3: Verify**

Run:

```bash
rg -n '67|aspirational' documentation/bitcoin-bridge-comparison.md
```

Expected: zero matches.

- [ ] **Step 4: Commit**

```bash
git add documentation/bitcoin-bridge-comparison.md
git commit -m "Drop 67% references from bridge comparison"
```

---

## Task 7: formal_verification.md

**Files:**

- Modify: `documentation/formal_verification.md`

- [ ] **Step 1: Update peg-out liveness proof sketch**

Find (line ~172):

```
**Proof sketch**: With honest SPO majority, the FROST signing cascade (67% → 51% → federation) eventually produces a signed Treasury Movement transaction (signing cascade liveness). With 1 honest watchtower, the TM is relayed to Bitcoin and the Bitcoin confirmation eventually reaches the oracle (oracle liveness). Once confirmed, anyone can complete the peg-out on Cardano. If the treasury rotates before fulfillment, the withdrawer can cancel.
```

Replace `(67% → 51% → federation)` with `(51% → federation)`.

- [ ] **Step 2: Update F3 row**

Find (line ~204):

```
| F3 | Federation can sign TM if both 67% and 51% quorum fail | Axiom: federation key in Taproot tree, timelock expires |
```

Replace with:

```
| F3 | Federation can sign TM if 51% quorum fails | Axiom: federation key in Taproot tree, timelock expires |
```

- [ ] **Step 3: Update S4 row**

Find (line ~237):

```
| S4 | Signing cascade: 67% tried first, then 51%, then federation | State machine rule |
```

Replace with:

```
| S4 | Signing cascade: 51% tried first, then federation | State machine rule |
```

- [ ] **Step 4: Update Roster type definition (section 6.2)**

Find (lines ~469–475):

```
/-- Roster of SPOs for a given epoch -/
structure Roster where
  members           : Finset SPO
  threshold67       : Nat
  threshold51       : Nat
  securityThreshold : Nat  -- basis points (e.g. 5100 for 51%)
  groupKey67        : PublicKey
  groupKey51        : PublicKey
```

Replace with:

```
/-- Roster of SPOs for a given epoch -/
structure Roster where
  members           : Finset SPO
  threshold51       : Nat
  securityThreshold : Nat  -- basis points (e.g. 5100 for 51%)
  groupKey51        : PublicKey
```

- [ ] **Step 5: Verify**

Run:

```bash
rg -n '67|threshold67|groupKey67' documentation/formal_verification.md
```

Expected: zero matches.

- [ ] **Step 6: Commit**

```bash
git add documentation/formal_verification.md
git commit -m "Drop 67% from formal verification properties and Roster type"
```

---

## Task 8: Diagrams

**Files:**

- Modify: `documentation/diagrams/epoch_lifecycle.mmd`
- Modify: `documentation/diagrams/epoch_lifecycle_realistic.mmd`
- Modify: `documentation/diagrams/utxo_flow.mmd`

- [ ] **Step 1: Edit `epoch_lifecycle.mmd` — drop 67% Roster A task and shift 51%**

Find (line 20):

```
    FROST sign 67% (Roster A)              :n_s67, 2025-01-03 00:00, 2025-01-05 23:00
    FROST sign 51% fallback (Roster A)     :done, n_s51, 2025-01-04 00:00, 2025-01-05 23:00
```

Replace with:

```
    FROST sign 51% (Roster A)              :n_s51, 2025-01-03 00:00, 2025-01-05 23:00
```

Removed the `:done` styling and the "fallback" label; 51% now starts at the time the 67% window used to start.

- [ ] **Step 2: Edit `epoch_lifecycle.mmd` — same for Roster B**

Find (line 35):

```
    FROST sign 67% (Roster B)              :n1_s67, 2025-01-08 00:00, 2025-01-10 23:00
    FROST sign 51% fallback (Roster B)     :done, n1_s51, 2025-01-09 00:00, 2025-01-10 23:00
```

Replace with:

```
    FROST sign 51% (Roster B)              :n1_s51, 2025-01-08 00:00, 2025-01-10 23:00
```

- [ ] **Step 3: Edit `epoch_lifecycle_realistic.mmd` — title**

Find (line 3):

```
    title Bifrost Realistic Epoch — Happy Path (67% quorum)
```

Replace with:

```
    title Bifrost Realistic Epoch — Happy Path (51% quorum)
```

- [ ] **Step 4: Edit `epoch_lifecycle_realistic.mmd` — task labels**

Replace all four occurrences of:

```
    Build + FROST sign 67% (~6 min)
```

with:

```
    Build + FROST sign 51% (~6 min)
```

This applies to the lines for `tm1`, `tm2`, `tm3`, and `tm4` (lines 17, 22, 27, 32). Use a single Edit with `replace_all: true` for the substring `Build + FROST sign 67%`.

- [ ] **Step 5: Edit `utxo_flow.mmd` — OldTreasury label**

Find (line 10):

```
        OldTreasury["Old Treasury UTxO<br/>(key: Y<sub>51</sub> | leaves: Y<sub>67</sub>, Y<sub>fed</sub>+timelock)"]
```

Replace with:

```
        OldTreasury["Old Treasury UTxO<br/>(key: Y<sub>51</sub> | leaf: Y<sub>fed</sub>+timelock)"]
```

- [ ] **Step 6: Edit `utxo_flow.mmd` — TreasuryAK label**

Find (line 28):

```
        TreasuryAK["Treasury state UTxO<br/>Y<sub>67</sub>, Y<sub>51</sub><br/>Completed PegIns<br/>Bifrost identity root<br/>(reference UTxO)"]
```

Replace with:

```
        TreasuryAK["Treasury state UTxO<br/>Y<sub>51</sub><br/>Completed PegIns<br/>Bifrost identity root<br/>(reference UTxO)"]
```

- [ ] **Step 7: Verify**

Run:

```bash
rg -n '67' documentation/diagrams/*.mmd
```

Expected: zero matches.

- [ ] **Step 8: Commit**

```bash
git add documentation/diagrams/
git commit -m "Drop 67% tasks and Y_67 leaves from epoch and UTxO diagrams"
```

---

## Task 9: Lean proofs

**Files:**

- Modify: `proofs/BifrostProofs/Basic.lean`
- Modify: `proofs/BifrostProofs/State.lean`
- Modify: `proofs/BifrostProofs/FailSafe.lean`

- [ ] **Step 1: Edit `Basic.lean` — remove `y67` from EpochKeys**

Find (lines 115–119):

```lean
/-- Epoch keys produced by DKG -/
structure EpochKeys where
  y67 : PublicKey
  y51 : PublicKey
  deriving BEq, Repr, DecidableEq
```

Replace with:

```lean
/-- Epoch keys produced by DKG -/
structure EpochKeys where
  y51 : PublicKey
  deriving BEq, Repr, DecidableEq
```

- [ ] **Step 2: Edit `Basic.lean` — remove 67-related fields from Roster**

Find (lines 121–128):

```lean
/-- A roster of SPOs for a given epoch -/
structure Roster where
  members           : List SPO
  threshold67       : Nat
  threshold51       : Nat
  groupKey67        : PublicKey
  groupKey51        : PublicKey
  deriving Repr
```

Replace with:

```lean
/-- A roster of SPOs for a given epoch -/
structure Roster where
  members           : List SPO
  threshold51       : Nat
  groupKey51        : PublicKey
  deriving Repr
```

- [ ] **Step 3: Edit `Basic.lean` — remove `q67` constructor**

Find (lines 208–213):

```lean
/-- Quorum level used for signing -/
inductive QuorumLevel where
  | q67        : QuorumLevel
  | q51        : QuorumLevel
  | federation : QuorumLevel
  deriving BEq, Repr
```

Replace with:

```lean
/-- Quorum level used for signing -/
inductive QuorumLevel where
  | q51        : QuorumLevel
  | federation : QuorumLevel
  deriving BEq, Repr
```

- [ ] **Step 4: Edit `State.lean` — update comment**

Find (lines 36–40):

```lean
/-- Current treasury address -/
def ProtocolState.currentTreasuryAddress (s : ProtocolState) : TreasuryAddress :=
  -- In the real protocol, this is derived from epochKeys.y51, y67, and federation key
  -- via Taproot address construction. Here we model it abstractly.
  { scriptPubKey := s.epochKeys.y51.bytes }
```

Replace with:

```lean
/-- Current treasury address -/
def ProtocolState.currentTreasuryAddress (s : ProtocolState) : TreasuryAddress :=
  -- In the real protocol, this is derived from epochKeys.y51 and the federation key
  -- via Taproot address construction. Here we model it abstractly.
  { scriptPubKey := s.epochKeys.y51.bytes }
```

- [ ] **Step 5: Edit `FailSafe.lean` — F3 docstring**

Find (lines 33–37):

```lean
/-- F3: Federation can sign TM if both 67% and 51% quorum fail.

    The federation key is a script leaf in the Treasury Taproot tree
    with a CSV timelock. After the timelock expires, the federation
    can sign the same full Treasury Movement transaction. -/
```

Replace with:

```lean
/-- F3: Federation can sign TM if 51% quorum fails.

    The federation key is a script leaf in the Treasury Taproot tree
    with a CSV timelock. After the timelock expires, the federation
    can sign the same full Treasury Movement transaction. -/
```

- [ ] **Step 6: Edit `FailSafe.lean` — F3 inline comment**

Find (lines 38–43):

```lean
theorem federation_fallback (s : ProtocolState) (tm : TMTransaction) :
    -- If 67% and 51% quorums both fail
    -- (modeled as: the action with federation quorum is valid)
    (∃ s', step s (.TreasuryMovement tm .federation) = some s') →
    -- Then the bridge can still process the TM
    ∃ s', step s (.TreasuryMovement tm .federation) = some s' := by
  intro h; exact h
```

Replace with:

```lean
theorem federation_fallback (s : ProtocolState) (tm : TMTransaction) :
    -- If 51% quorum fails
    -- (modeled as: the action with federation quorum is valid)
    (∃ s', step s (.TreasuryMovement tm .federation) = some s') →
    -- Then the bridge can still process the TM
    ∃ s', step s (.TreasuryMovement tm .federation) = some s' := by
  intro h; exact h
```

- [ ] **Step 7: Edit `FailSafe.lean` — total-failure theorem docstring**

Find (lines 86–88):

```lean
/-- Total signing failure: no quorum (67%, 51%, or federation) can sign.
    This models the worst-case scenario where all SPOs are permanently offline
    or have lost their key shares. -/
```

Replace with:

```lean
/-- Total signing failure: no quorum (51% or federation) can sign.
    This models the worst-case scenario where all SPOs are permanently offline
    or have lost their key shares. -/
```

- [ ] **Step 8: Search for incidental usages of removed symbols**

Run:

```bash
rg -n 'y67|q67|threshold67|groupKey67' proofs/BifrostProofs/
```

Expected: zero matches. If any other file references these (e.g., `Action.lean`, `Transition.lean`, `Trace.lean`, `Liveness.lean`), inspect and update — they would break the build otherwise. The most likely place is wherever an `EpochKeys` literal is constructed or a `Roster` is constructed; replace `{ y67 := …, y51 := … }` patterns with `{ y51 := … }` and similar for `Roster`.

- [ ] **Step 9: Build the proofs**

Run from `proofs/`:

```bash
cd proofs && lake build 2>&1 | tail -40
```

Expected: build succeeds. If errors appear, the most common cause is a residual reference to a removed field or constructor — fix and re-run. The `sorry`-stubbed theorems remain `sorry`-stubbed; we are not introducing new proofs, only removing dead fields.

- [ ] **Step 10: Verify final state**

Run from repo root:

```bash
rg -n '67|y67|q67|threshold67|groupKey67' proofs/BifrostProofs/
```

Expected: zero matches.

- [ ] **Step 11: Commit**

```bash
git add proofs/
git commit -m "Drop y67, threshold67, groupKey67, q67 from Lean protocol model"
```

---

## Task 10: Final verification and PDF regeneration

**Files:** none modified.

- [ ] **Step 1: Final repo-wide grep**

Run from repo root:

```bash
rg -n '67%|Y_\{67\}|Y_67|y67|q67|threshold67|groupKey67|aspirational' \
   documentation/ proofs/
```

Expected: zero matches across all files in scope. Investigate any straggler.

- [ ] **Step 2: Confirm onchain Aiken still has zero references**

Run:

```bash
rg -n '67' onchain/
```

Expected: only matches in unrelated contexts (e.g., constants, hex strings, line numbers in plutus.json) — none referencing the 67% threshold or `Y_67`. Spot-check; should be clean.

- [ ] **Step 3: Run aiken check (smoke test that on-chain still builds)**

Run:

```bash
cd onchain && aiken check 2>&1 | tail -20
```

Expected: pass (no source changes were made).

- [ ] **Step 4: Regenerate PDFs**

Run from repo root:

```bash
./scripts/make-pdfs.sh
```

Expected: success. Review generated PDFs for any visual regressions in the affected sections.

- [ ] **Step 5: Final commit (if PDFs are tracked)**

If `./scripts/make-pdfs.sh` updates committed PDF files, stage and commit:

```bash
git status
# If PDFs are tracked and changed:
git add documentation/*.pdf
git commit -m "Regenerate PDFs after 67% threshold removal"
```

If PDFs are not tracked, skip this step.
