# Remove 67% threshold from Bifrost specification

**Date:** 2026-04-21
**Status:** Approved

## Motivation

The 67% threshold was an aspirational path that added a second DKG, a
signing-cascade tier, a Taproot script leaf, and mode-field overhead — for a
security improvement that is not needed in practice. The formal guarantee that
any 51%-mode signing subset controls more than 51% of total delegated stake
stands on its own. Removing 67% simplifies the protocol without weakening its
security story.

## Scope

Update the following to describe a two-mode protocol (51% FROST main line +
federation emergency fallback):

- `documentation/technical_documentation.md`
- `documentation/bitcoin-bridge-comparison.md`
- `documentation/formal_verification.md`
- `documentation/diagrams/epoch_lifecycle.mmd`
- `documentation/diagrams/epoch_lifecycle_realistic.mmd`
- `documentation/diagrams/utxo_flow.mmd`
- `proofs/BifrostProofs/Basic.lean`
- `proofs/BifrostProofs/State.lean`
- `proofs/BifrostProofs/FailSafe.lean`

**Out of scope:**

- `onchain/` Aiken code (no 67% references).
- `documentation/demo_simplifications.md` (no 67% references).
- External references (Hydrozoa whitepaper, community explainers, prior
  committed PDFs). These get separate follow-up.

## Protocol changes

### 1. Treasury Taproot tree

Before:

- Key path: $Y_{51}$
- Script leaf 1: $Y_{67}$ (aspirational stronger security)
- Script leaf 2: $Y_{federation}$ + CSV timelock (emergency)

After:

- Key path: $Y_{51}$
- Single script leaf: $Y_{federation}$ + CSV timelock (emergency)

The peg-in Taproot tree is unchanged; it never referenced $Y_{67}$.

### 2. Operating phases

Drop Phase 3 entirely. The protocol has two phases:

1. **Federation Launch** — federation signs everything; SPOs begin
   registering.
2. **51% SPO Participation** — once enough SPOs have completed DKG, $Y_{51}$
   becomes the main-line signing key; federation is emergency-only. This is
   the terminal steady state.

### 3. Signing cascade

Two modes remain: `51` and `federation`. The cascade machinery is preserved:

- The protocol namespace still carries a `mode` field.
- Attempt counter is still scoped per `(epoch, mode)` for DKG instances and
  per `(epoch, txid, mode)` for signing instances.
- The only change is that the set of mode values is `{51, federation}`
  instead of `{67, 51, federation}`.

The cascade sequence becomes: **51% → federation**. If 51% signing does not
yield a valid aggregate signature within its bounded setup and signing phases,
the federation signs via the $Y_{federation}$ script leaf with CSV timelock.

### 4. DKG

One FROST DKG per epoch, producing $Y_{51}$. The `<threshold>` URL segment
and the `threshold` field inside Round 1 and Round 2 payloads are retained
for minimal mechanical churn, but take only the value `51`. Federation does
not DKG (unchanged — it was never a DKG participant).

## Terminology

- Drop "aspirational" throughout the spec.
- Keep "main line" for 51% — still meaningfully contrasts with the federation
  emergency path.
- Keep "signing cascade" and "threshold failover" — these describe the 51% →
  federation transition.

## Table edits (technical_documentation.md)

### Notation table (§Notation)

- Remove the $Y_{67}$ row; keep $Y_{51}$ and $Y_{federation}$.
- Anywhere $Y_{67}$ is mentioned in surrounding prose, remove or rewrite.

### Operating phases table

Two rows:

| Phase 1 — Federation Launch | Bridge runs with $Y_{federation}$ as the only signer; SPOs begin registering. |
| Phase 2 — 51% SPO Participation | Once enough SPOs have completed DKG, $Y_{51}$ becomes the main-line key; federation is emergency-only. |

### Spending paths / TM variants table

Two rows:

| 51% main line      | Treasury + peg-in inputs spent via $Y_{51}$ key path.                          |
| Federation (emergency) | All inputs spent via $Y_{federation}$ script leaf with CSV timelock.         |

### TM signing-path variants table

Two rows:

| 51% main line          | $Y_{51}$ key path         | $Y_{51}$ key path         | 51% quorum produced a valid aggregate signature |
| Federation emergency   | $Y_{federation}$ leaf + CSV | $Y_{federation}$ leaf + CSV | 51% mode exhausted                             |

### Per-variant size caps (line ~596)

Two variants remain:

- 51% key path: ~100 peg-ins + ~100 peg-outs (~107 B/input).
- Federation: ~57 + ~57 (script path + CSV on every input, ~213 B/input).

Hard cap of ~15 KB raw bytes is unchanged.

## Narrative edits (technical_documentation.md)

Sections requiring rewrites:

- **Glossary**: update "Attempt counter", "Mode", "Protocol namespace",
  "Signing cascade / Threshold failover" definitions to reflect
  `{51, federation}` only.
- **§Taproot address construction** — rewrite the Treasury tree description;
  the key-path paragraph retains $Y_{51}$; the aspirational/67 paragraph is
  deleted; the federation script-leaf paragraph stays.
- **§Spending paths** — the "When 67% quorum is available…" sentences are
  deleted. Keep "When 51% quorum is available, SPOs spend via the $Y_{51}$
  key path. In emergency, the $Y_{federation}$ script path with timelock is
  used."
- **§Flow of Bitcoin over epochs, ceremonies** — step 8 ("Threshold signing
  cascade") simplifies to "51% signing runs; federation opens once 51%
  setup/signing has finished unsuccessfully. The first mode to succeed wins."
- **§Epoch lifecycle (happy path)** — drop "when 67% quorum is available";
  frame happy path around 51%.
- **§DKG** — delete "the above steps are run twice, once with $t_{67}$ and
  once with $t_{51}$"; one DKG per epoch.
- **§Peg-in / §Peg-out** — replace "in the normal 67% and 51% modes" with
  "in 51% mode".

## Lean proof edits

### `proofs/BifrostProofs/Basic.lean`

- Remove `y67` field (line 117).
- Remove `threshold67` and `groupKey67` fields (lines 124, 126).
- Remove `q67` constructor from `QuorumLevel` (line 210).
- Update any theorems, lemmas, or definitions that destructure these fields
  or pattern-match on `q67`.

### `proofs/BifrostProofs/State.lean`

- Update the comment at line 38 to reference only `y51` and federation.

### `proofs/BifrostProofs/FailSafe.lean`

- Rewrite F3 theorem text (lines 33, 39) to read "Federation can sign TM if
  51% quorum fails".
- Update the total-signing-failure theorem (line 86) to say "no quorum (51%
  or federation) can sign".
- Remove the `q67` case from `federation_fallback` if present.

All Lean proofs must still build (`lake build` or equivalent) after these
edits.

## Diagram edits

### `documentation/diagrams/epoch_lifecycle.mmd`

- Drop the "FROST sign 67% (Roster A)" task (line 20).
- Drop the "FROST sign 67% (Roster B)" task (line 35).
- Shift the 51% signing windows earlier to cover the reclaimed time, keeping
  the overall epoch boundaries intact.

### `documentation/diagrams/epoch_lifecycle_realistic.mmd`

- Title → "Bifrost Realistic Epoch — Happy Path (51% quorum)" (line 3).
- Task labels → "Build + FROST sign 51% (~6 min)" for all four TM batches
  (lines 17, 22, 27, 32).

### `documentation/diagrams/utxo_flow.mmd`

- OldTreasury label (line 10) → `Old Treasury UTxO<br/>(key: Y<sub>51</sub> | leaf: Y<sub>fed</sub>+timelock)`.
- TreasuryAK label (line 28) → drop `Y<sub>67</sub>`, keep `Y<sub>51</sub>`.

## Bitcoin-bridge-comparison.md edits

- Drop the "Aspirational security" row (line 343) from the Bifrost summary
  table.
- Update the F3 line (line 380) to "Federation can sign if 51% quorum fails
  (timelocked emergency)".

## Formal-verification.md edits

- Proof sketch (line 172): replace "FROST signing cascade (67% → 51% →
  federation)" with "FROST signing cascade (51% → federation)".
- F3 row (line 204): rewrite to "Federation can sign TM if 51% quorum fails".
- S4 row (line 237): rewrite to "Signing cascade: 51% tried first, then
  federation".

## Verification

After the edits:

- `aiken check` in `onchain/` still passes (no source changes expected, but
  confirm).
- PDF generation (`./scripts/make-pdfs.sh`) produces consistent output.
- Lean proofs still build.
- A final grep for `67%`, `Y_67`, `y67`, `q67`, `threshold67`,
  `aspirational` across the repo returns zero hits in the files listed in
  Scope.

## Risks and considerations

- The cascade abstraction with only two modes feels slightly overweight,
  but keeping the `mode` field and URL segment minimizes churn to the DKG /
  signing / fault-proof machinery. This is a deliberate trade-off.
- External documents (whitepaper PDF, comparison explainers) will drift from
  the spec until separately updated. Flag during rollout.
