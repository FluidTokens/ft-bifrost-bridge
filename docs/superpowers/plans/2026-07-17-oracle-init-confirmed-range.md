# Oracle init confirmed-range Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every code step shows real Scala to type; there are no placeholders.

**Goal:** Add `--confirmed-until <height>` to the Binocular oracle `init` command so a single init tx can seed `confirmedBlocksRoot` as the MPF over the canonical block hashes `[start-height, confirmed-until]`, with `ctx` anchored at the confirmed tip. Implements the approved design `docs/superpowers/specs/2026-07-17-oracle-init-confirmed-range-design.md` (approach A: trust-the-node, off-chain only). When `--confirmed-until` is omitted, behavior is byte-identical to today's single-block init.

**Architecture:** The range→root MPF walk currently living inline in `Command.rebuildMpf` (`binocular.cli`) becomes a single shared helper `BitcoinChainState.mpfForRange` (`binocular.oracle`). Both `rebuildMpf` and the new range-aware `getInitialChainState` overload call it, so the seeded root and every later rebuild are byte-identical by construction. `InitOracleCommand` gains a `confirmedUntil: Option[Long]` field; validation of `start <= confirmedTip <= tip` plus the non-blocking reorg-depth warning is factored into a pure, unit-testable helper. `CliApp` adds the `--confirmed-until` decline option and threads it through `Cmd.Init` into `InitOracleCommand`.

**Tech Stack:** Scala 3 + Scalus, sbt (binocular repo root at `../binocular`). CLI parsing via `com.monovore.decline`. MPF via `scalus.crypto.trie.MerklePatriciaForestry` (imported as `OffChainMPF`). Tests: ScalaTest `AnyFunSuite` (`org.scalatest` 3.2.19), fixture-backed `MockBitcoinRpc`.

## Global Constraints

Binding rules copied from the design spec and repo conventions. Apply to every task:

- **Off-chain only.** No Aiken / validator / mint-policy change is required or permitted by this plan. The oracle NFT mint policy does not inspect the `ChainState` datum (`BitcoinValidator.scala:1404-1436`); the initial confirmed state is owner-trusted (same trust model as `SetState`). All work lands in the `binocular` Scala project.
- **Seed == rebuild, byte-identical (core correctness invariant).** The seeded `confirmedBlocksRoot` MUST equal the MPF that `rebuildMpf` produces over the same `[start, confirmedUntil]` range. Guarantee this by construction: the range→root walk exists in exactly one place (`BitcoinChainState.mpfForRange`) and both init and `rebuildMpf` call it. Do not duplicate the insert loop.
- **Single-block behavior preserved.** When `--confirmed-until` is omitted, `confirmedTip == startHeight`, the walk yields the one-element MPF identical to today's `mpfRootForSingleBlock`, and the produced `ChainState` is unchanged.
- **No new persistence.** There is no on-disk MPF store. The watchtower rebuilds from bitcoind on demand; a range-seeded oracle needs zero new persistence.
- **Scala 3 syntax.** Match the surrounding style (4-space indent, brace style already in these files).
- **This is the user's repo. Avoid fully-qualified names where an import works.** Prefer adding/using imports over inline `a.b.c.Type` spellings.
- **No em dashes in any output** (code comments, console strings, commit messages, this plan). Use an en dash (–) instead.
- **Frequent commits.** One commit per completed step group as shown. NEVER add a `Co-Authored-By: Claude` trailer.
- Run `sbt scalafmtAll` before each commit (binocular convention). All commands run from the `binocular` repo root unless stated.

### Deviations from the spec's assumptions (found in the real code)

- Test framework is **ScalaTest `AnyFunSuite`**, not munit.
- RPC is stubbed in tests via **`MockBitcoinRpc`** (reads JSON fixtures under `src/test/resources/bitcoin_blocks`, contiguous heights 864800–865167). It serves `getBlockHash`/`getBlockHeader` by height/hash.
- `MockBitcoinRpc` **cannot** exercise the full `getInitialChainState`: that method also fetches the difficulty-adjustment block at `blockHeight - (blockHeight % 2016)` (≈ 862848 for the fixture range), which is outside the fixtures. Full `getInitialChainState` (ctx construction) therefore stays covered by the existing real-node `ManualTest`. The **new** logic (the range `confirmedBlocksRoot`) is fully covered here through `mpfForRange`, which only needs `getBlockHash`.
- `Command.rebuildMpf` currently takes the concrete `SimpleBitcoinRpc`. Task 1 widens its first parameter to the `BitcoinRpc` trait (safe: `SimpleBitcoinRpc <: BitcoinRpc`; the only caller, `reconstructMpf`, passes a `SimpleBitcoinRpc`) so it can delegate to the shared helper and be tested with `MockBitcoinRpc`.

---

### Task 1: Shared range→root MPF helper (`mpfForRange`) + refactor `rebuildMpf`

**Files:**
- Modify: `src/main/scala/binocular/oracle/BitcoinChainState.scala` (add helper after `mpfRootForSingleBlock`, ~line 22-23)
- Modify: `src/main/scala/binocular/cli/Command.scala` (`rebuildMpf`, lines 360-397)
- Create: `src/test/scala/binocular/MpfForRangeTest.scala`

**Interfaces:**
- Produces: `BitcoinChainState.mpfForRange(rpc: BitcoinRpc, startHeight: Long, endHeight: Long)(using ExecutionContext): Future[OffChainMPF]` – inserts each canonical block hash in `[startHeight, endHeight]` (keyed by and valued as its own internal-order hash), returns the built MPF. Consumed by `rebuildMpf` (Task 1) and `getInitialChainState` (Task 2).
- Modifies: `Command.rebuildMpf(rpc: BitcoinRpc, startHeight: Long, endHeight: Long, expectedRoot: ByteString)(using ExecutionContext): Either[String, OffChainMPF]` – first param widened from `SimpleBitcoinRpc` to `BitcoinRpc`; body delegates the walk to `mpfForRange`.
- Consumes: `BitcoinRpc.getBlockHash(height: Int): Future[String]`, `OffChainMPF.empty`, `OffChainMPF.insert(key, value)`, `ByteString.fromArray`, `String.hexToBytes`.

- [ ] **Step 1: Write the failing helper test**

Create `src/test/scala/binocular/MpfForRangeTest.scala`. The test builds an independent reference MPF inline (the oracle we compare against), asserts `mpfForRange` matches it over a small range, and asserts the single-element case equals `mpfRootForSingleBlock`:

```scala
package binocular

import binocular.bitcoin.*
import binocular.oracle.*

import org.scalatest.funsuite.AnyFunSuite
import scalus.crypto.trie.MerklePatriciaForestry as OffChainMPF
import scalus.uplc.builtin.ByteString
import scalus.utils.await
import scalus.utils.Hex.hexToBytes

import scala.concurrent.ExecutionContext

class MpfForRangeTest extends AnyFunSuite {
    private given ec: ExecutionContext = ExecutionContext.global
    private val rpc = new MockBitcoinRpc()

    // Independent reference: reversed (internal-order) canonical hash, keyed by itself.
    private def refRoot(start: Long, end: Long): ByteString = {
        val mpf = (start to end).foldLeft(OffChainMPF.empty) { (acc, h) =>
            val hex = rpc.getBlockHash(h.toInt).await()
            val hash = ByteString.fromArray(hex.hexToBytes.reverse)
            acc.insert(hash, hash)
        }
        mpf.rootHash
    }

    test("mpfForRange matches an independent walk over the same range") {
        val start = 864800L
        val end = 864805L
        val root = BitcoinChainState.mpfForRange(rpc, start, end).await().rootHash
        assert(root == refRoot(start, end))
    }

    test("mpfForRange with start == end equals mpfRootForSingleBlock") {
        val h = 864800L
        val hex = rpc.getBlockHash(h.toInt).await()
        val hash = ByteString.fromArray(hex.hexToBytes.reverse)
        val root = BitcoinChainState.mpfForRange(rpc, h, h).await().rootHash
        assert(root == BitcoinChainState.mpfRootForSingleBlock(hash))
    }
}
```

- [ ] **Step 2: Run the test – expect FAIL (does not compile: `mpfForRange` is not a member)**

```
sbt "testOnly binocular.MpfForRangeTest"
```

Expected: compilation error `value mpfForRange is not a member of object binocular.oracle.BitcoinChainState` (FAIL).

- [ ] **Step 3: Implement `mpfForRange` in `BitcoinChainState`**

In `src/main/scala/binocular/oracle/BitcoinChainState.scala`, immediately after `mpfRootForSingleBlock` (after line 23), add:

```scala
    /** Build the confirmed-blocks MPF over the canonical hashes in `[startHeight, endHeight]`.
      *
      * Single source of the range→root walk: both oracle init (seeding `confirmedBlocksRoot`)
      * and [[binocular.cli.Command.rebuildMpf]] call this, so a seed can never diverge from a
      * later rebuild. Each block hash is stored in internal (little-endian) order, keyed by and
      * valued as itself – identical to `mpfRootForSingleBlock` for a one-element range.
      */
    def mpfForRange(
        rpc: BitcoinRpc,
        startHeight: Long,
        endHeight: Long
    )(using ec: ExecutionContext): Future[OffChainMPF] = {
        def loop(heights: scala.List[Long], mpf: OffChainMPF): Future[OffChainMPF] =
            heights match {
                case Nil => Future.successful(mpf)
                case h :: tail =>
                    for {
                        hashHex <- rpc.getBlockHash(h.toInt)
                        blockHash = ByteString.fromArray(hashHex.hexToBytes.reverse)
                        rest <- loop(tail, mpf.insert(blockHash, blockHash))
                    } yield rest
            }
        loop((startHeight to endHeight).toList, OffChainMPF.empty)
    }
```

(`BitcoinRpc`, `OffChainMPF`, `ByteString`, `hexToBytes`, `ExecutionContext`, `Future` are all already imported in this file.)

- [ ] **Step 4: Run the test – expect PASS**

```
sbt "testOnly binocular.MpfForRangeTest"
```

Expected: both tests green (PASS).

- [ ] **Step 5: Refactor `rebuildMpf` to delegate to `mpfForRange` (widen param, no behavior change)**

In `src/main/scala/binocular/cli/Command.scala`, replace the whole `rebuildMpf` method (lines 360-397) with:

```scala
    /** Reconstruct off-chain MPF from Bitcoin RPC by re-inserting all confirmed block hashes.
      *
      * The range→root walk lives in [[binocular.oracle.BitcoinChainState.mpfForRange]] so this
      * rebuild and oracle init share one implementation and can never diverge.
      */
    def rebuildMpf(
        rpc: BitcoinRpc,
        startHeight: Long,
        endHeight: Long,
        expectedRoot: ByteString
    )(using ExecutionContext): Either[String, OffChainMPF] = {
        try {
            val rebuilt = BitcoinChainState.mpfForRange(rpc, startHeight, endHeight).await(120.seconds)
            if rebuilt.rootHash != expectedRoot then
                Left(
                  s"Rebuilt MPF root does not match on-chain confirmedBlocksRoot. " +
                      s"Expected: ${expectedRoot.toHex}, got: ${rebuilt.rootHash.toHex}. " +
                      s"The oracle's confirmed history (${startHeight}..${endHeight}) commits " +
                      s"to block hashes that differ from this bitcoind's current canonical " +
                      s"chain in that range. Likely cause: a reorg below the oracle's confirmed " +
                      s"tip orphaned one or more committed blocks. The on-chain root is a " +
                      s"hash commitment, so the exact divergence height cannot be recovered " +
                      s"from chain state alone – manual recovery required (re-init the oracle " +
                      s"from a current canonical height)."
                )
            else Right(rebuilt)
        } catch {
            case e: Exception => Left(s"Error rebuilding MPF: ${e.getMessage}")
        }
    }
```

(`BitcoinChainState` is in scope via the existing `import binocular.oracle.*` at line 5. Note the em dash in the original message string was replaced with an en dash.)

- [ ] **Step 6: Add a `rebuildMpf`-level seed==rebuild test**

Append to `src/test/scala/binocular/MpfForRangeTest.scala` (proves `rebuildMpf` agrees with the seed root and rejects a wrong root):

```scala
    test("rebuildMpf returns Right when expectedRoot equals the range root, Left otherwise") {
        val start = 864800L
        val end = 864805L
        val seedRoot = BitcoinChainState.mpfForRange(rpc, start, end).await().rootHash

        assert(binocular.cli.Command.rebuildMpf(rpc, start, end, seedRoot).isRight)

        val wrong = BitcoinChainState.mpfRootForSingleBlock(
          ByteString.fromArray(Array.fill[Byte](32)(0))
        )
        assert(binocular.cli.Command.rebuildMpf(rpc, start, end, wrong).isLeft)
    }
```

Confirm `rebuildMpf` is defined on the `object Command` companion (it is – it sits at file scope alongside `reconstructMpf`); reference it as `binocular.cli.Command.rebuildMpf`. If the surrounding object is named differently, use that name and note it.

- [ ] **Step 7: Run the full suite for this file, then commit**

```
sbt "testOnly binocular.MpfForRangeTest"
sbt scalafmtAll
```

Expected: all tests in `MpfForRangeTest` PASS. Then:

```
git add -A
git commit -m "refactor(oracle): single shared range→root MPF walk (mpfForRange)

Extract the rebuildMpf insert loop into BitcoinChainState.mpfForRange and
have rebuildMpf delegate to it, so oracle init and rebuild share one
implementation and cannot diverge. Widen rebuildMpf to the BitcoinRpc trait."
```

---

### Task 2: Range-aware `getInitialChainState` (seed `confirmedBlocksRoot` over `[start, confirmedTip]`)

**Files:**
- Modify: `src/main/scala/binocular/oracle/BitcoinChainState.scala` (`getInitialChainState`, lines 92-154)
- Modify: `src/test/scala/binocular/MpfForRangeTest.scala` (add regression assertion)

**Interfaces:**
- Produces: `BitcoinChainState.getInitialChainState(rpc: BitcoinRpc, startHeight: Int, confirmedTip: Int)(using ExecutionContext): Future[ChainState]` – ctx built at `confirmedTip` (unchanged construction), `confirmedBlocksRoot = mpfForRange(rpc, startHeight, confirmedTip).rootHash`, `forkTree = End`.
- Preserves: `BitcoinChainState.getInitialChainState(rpc: BitcoinRpc, blockHeight: Int)(using ExecutionContext): Future[ChainState]` – now delegates to the range overload with `startHeight == confirmedTip == blockHeight`; produces the current single-block `ChainState` unchanged.
- Consumes: `mpfForRange` (Task 1); `ChainState`, `TraversalCtx`, `ForkTree.End` (`BitcoinValidator.scala:199-204, 245-252`).

- [ ] **Step 1: Write the failing regression test (single-block root unchanged via the range path)**

Append to `src/test/scala/binocular/MpfForRangeTest.scala`. This is the only part of the seeded datum that changed; the ctx path is exercised by the real-node `ManualTest` (see Deviations). The assertion proves the range walk reduces to today's single-block root:

```scala
    test("range walk with confirmedTip == startHeight reproduces the single-block root") {
        val h = 864800L
        val hex = rpc.getBlockHash(h.toInt).await()
        val singleBlockHash = ByteString.fromArray(hex.hexToBytes.reverse)

        // What getInitialChainState(rpc, h, h) will store as confirmedBlocksRoot:
        val rangeSeedRoot = BitcoinChainState.mpfForRange(rpc, h, h).await().rootHash

        assert(rangeSeedRoot == BitcoinChainState.mpfRootForSingleBlock(singleBlockHash))
    }
```

- [ ] **Step 2: Run – expect PASS already for this assertion (guard), then implement the overload it documents**

```
sbt "testOnly binocular.MpfForRangeTest"
```

This guard passes on Task 1 code (it asserts the invariant the overload relies on). The overload itself is verified by compilation + the existing `ManualTest`; implement it next.

- [ ] **Step 3: Implement the range overload and make the old entry point delegate**

In `src/main/scala/binocular/oracle/BitcoinChainState.scala`, change the `getInitialChainState` signature (line 92-95) to take `confirmedTip`, and add a delegating single-argument overload just above it. Replace the header lines:

```scala
    def getInitialChainState(
        rpc: BitcoinRpc,
        blockHeight: Int
    )(using ec: ExecutionContext): Future[ChainState] = {
        val interval = BitcoinHelpers.DifficultyAdjustmentInterval.toInt
        val adjustmentBlockHeight = blockHeight - (blockHeight % interval)
```

with:

```scala
    /** Single-block init – preserved entry point. Delegates to the range overload with
      * `startHeight == confirmedTip`, producing the same `ChainState` as before.
      */
    def getInitialChainState(
        rpc: BitcoinRpc,
        blockHeight: Int
    )(using ec: ExecutionContext): Future[ChainState] =
        getInitialChainState(rpc, blockHeight, blockHeight)

    /** Range-seeded init: ctx anchored at `confirmedTip`, `confirmedBlocksRoot` = MPF over the
      * canonical hashes `[startHeight, confirmedTip]`. When `startHeight == confirmedTip` this is
      * byte-identical to the previous single-block behavior.
      */
    def getInitialChainState(
        rpc: BitcoinRpc,
        startHeight: Int,
        confirmedTip: Int
    )(using ec: ExecutionContext): Future[ChainState] = {
        val blockHeight = confirmedTip
        val interval = BitcoinHelpers.DifficultyAdjustmentInterval.toInt
        val adjustmentBlockHeight = blockHeight - (blockHeight % interval)
```

Everything from `val medianTimeSpan = ...` down to the `for {`/`yield` block stays as-is (it already builds ctx at `blockHeight`, which is now `confirmedTip`), except the `confirmedBlocksRoot` line. In the `for` comprehension, add a binding that runs the range walk alongside the existing fetches, then use it in the yielded `ChainState`. Change the `yield` (lines 143-153) so that:

```scala
        } yield ChainState(
          confirmedBlocksRoot = mpfRootForSingleBlock(blockHash), // MPF trie with single block
```

becomes a range walk. Add, inside the `for { ... }` block (e.g. right after the `recentTimestampsSeq <- { ... }` block, before the `bits = ...` bindings), a monadic binding:

```scala
            confirmedRoot <- mpfForRange(rpc, startHeight, confirmedTip)
```

and change the yield's first field to:

```scala
        } yield ChainState(
          confirmedBlocksRoot = confirmedRoot.rootHash, // MPF over [startHeight, confirmedTip]
```

Leave `ctx = TraversalCtx(...)` and `forkTree = ForkTree.End` unchanged.

- [ ] **Step 4: Run tests and compile – expect PASS**

```
sbt "testOnly binocular.MpfForRangeTest"
sbt compile
```

Expected: `MpfForRangeTest` green; project compiles (the single-arg overload keeps every existing caller – `InitOracleCommand`, `ManualTest` – working).

- [ ] **Step 5: Commit**

```
sbt scalafmtAll
git add -A
git commit -m "feat(oracle): range-seeded getInitialChainState confirmedBlocksRoot

Add getInitialChainState(rpc, startHeight, confirmedTip): ctx at confirmedTip,
confirmedBlocksRoot = mpfForRange over [startHeight, confirmedTip]. The old
single-arg entry point delegates with startHeight == confirmedTip, so
single-block init is byte-identical."
```

---

### Task 3: `--confirmed-until` CLI option, `InitOracleCommand` wiring, validation + reorg warning

**Files:**
- Modify: `src/main/scala/binocular/cli/CliApp.scala` (`Cmd.Init` line 20; `CliParsers` add option after line 80; `initCommand` line 138-140; routing line 449-450)
- Modify: `src/main/scala/binocular/cli/commands/InitOracleCommand.scala` (case class line 20; validation + build-state + dry-run in `execute`)
- Create/Modify test: `src/test/scala/binocular/InitOracleCommandTest.scala` (pure validation helper + decline parse)

**Interfaces:**
- Produces: `Cmd.Init(startBlock: Option[Long], confirmedUntil: Option[Long], dryRun: Boolean)`.
- Produces: `InitOracleCommand(startBlock: Option[Long], confirmedUntil: Option[Long], dryRun: Boolean = false)`.
- Produces (pure, testable): `InitOracleCommand.validateConfirmedRange(startHeight: Long, confirmedTip: Long, tip: Long, maturationConfirmations: Long): Either[String, Option[String]]` – `Left(err)` = fatal (stop), `Right(Some(warn))` = proceed with a warning, `Right(None)` = clean.
- Consumes: `startBlockOpt`, `dryRunFlag` (`CliApp.CliParsers`); `Opts.option[Long]` (decline); `BitcoinChainState.getInitialChainState(rpc, startHeight.toInt, confirmedTip.toInt)`; `oracleConf.maturationConfirmations: Int`; `info.blocks` (tip).

- [ ] **Step 1: Write the failing tests (pure validation + parser wiring)**

Create `src/test/scala/binocular/InitOracleCommandTest.scala`:

```scala
package binocular

import binocular.cli.CliApp
import binocular.cli.commands.InitOracleCommand

import org.scalatest.funsuite.AnyFunSuite

class InitOracleCommandTest extends AnyFunSuite {

    test("validateConfirmedRange: clean when confirmedTip is deep enough") {
        val r = InitOracleCommand.validateConfirmedRange(
          startHeight = 100L, confirmedTip = 200L, tip = 1000L, maturationConfirmations = 12L
        )
        assert(r == Right(None))
    }

    test("validateConfirmedRange: error when start > confirmedTip") {
        val r = InitOracleCommand.validateConfirmedRange(300L, 200L, 1000L, 12L)
        assert(r.isLeft)
    }

    test("validateConfirmedRange: error when confirmedTip > tip") {
        val r = InitOracleCommand.validateConfirmedRange(100L, 1100L, 1000L, 12L)
        assert(r.isLeft)
    }

    test("validateConfirmedRange: warns (but proceeds) when shallower than maturation") {
        val r = InitOracleCommand.validateConfirmedRange(100L, 995L, 1000L, 12L)
        assert(r.exists(_.isDefined)) // Right(Some(warning))
    }

    test("init parses --start-block, --confirmed-until, --dry-run") {
        val parsed = CliApp.command.parse(
          List("init", "--start-block", "136600", "--confirmed-until", "144450", "--dry-run")
        )
        assert(
          parsed == Right(
            (None, CliApp.Cmd.Init(Some(136600L), Some(144450L), true))
          )
        )
    }

    test("init without --confirmed-until leaves it None") {
        val parsed = CliApp.command.parse(List("init", "--start-block", "136600"))
        assert(parsed == Right((None, CliApp.Cmd.Init(Some(136600L), None, false))))
    }
}
```

- [ ] **Step 2: Run – expect FAIL (compile errors: new arity + `validateConfirmedRange` missing)**

```
sbt "testOnly binocular.InitOracleCommandTest"
```

Expected: does not compile (`Cmd.Init` takes 2 args, `InitOracleCommand.validateConfirmedRange` unknown) – FAIL.

- [ ] **Step 3: Add the `--confirmed-until` option and thread it through `CliApp`**

In `src/main/scala/binocular/cli/CliApp.scala`:

Change the enum case (line 20):

```scala
        case Init(startBlock: Option[Long], confirmedUntil: Option[Long], dryRun: Boolean)
```

Add a parser in `CliParsers`, right after `dryRunFlag` (after line 80):

```scala
        val confirmedUntilOpt: Opts[Option[Long]] = Opts
            .option[Long](
              "confirmed-until",
              help = "Seed confirmed blocks up to this height (default: single block at start)"
            )
            .orNone
```

Update `initCommand` (line 138-140):

```scala
        val initCommand = Opts.subcommand("init", "Initialize new oracle") {
            (startBlockOpt, confirmedUntilOpt, dryRunFlag).mapN(Cmd.Init.apply)
        }
```

Update routing (line 449-450):

```scala
                        case Cmd.Init(startBlock, confirmedUntil, dryRun) =>
                            InitOracleCommand(startBlock, confirmedUntil, dryRun)
```

- [ ] **Step 4: Add the `confirmedUntil` field and pure validation helper to `InitOracleCommand`**

In `src/main/scala/binocular/cli/commands/InitOracleCommand.scala`, change the case class header (line 20):

```scala
case class InitOracleCommand(
    startBlock: Option[Long],
    confirmedUntil: Option[Long],
    dryRun: Boolean = false
) extends Command {
```

Add a companion object with the pure helper (place directly below the class):

```scala
object InitOracleCommand {

    /** Validate the seeded confirmed range against the node tip.
      *
      *   - `Left(err)`  – fatal, abort init.
      *   - `Right(Some(warn))` – proceed, but surface a reorg-depth warning.
      *   - `Right(None)` – clean.
      */
    def validateConfirmedRange(
        startHeight: Long,
        confirmedTip: Long,
        tip: Long,
        maturationConfirmations: Long
    ): Either[String, Option[String]] =
        if startHeight > confirmedTip then
            Left(s"--confirmed-until ($confirmedTip) must be >= --start-block ($startHeight)")
        else if confirmedTip > tip then
            Left(s"--confirmed-until ($confirmedTip) is beyond the node tip ($tip)")
        else if confirmedTip > tip - maturationConfirmations then
            Right(
              Some(
                s"confirmed-until ($confirmedTip) is shallower than the maturation depth " +
                    s"($maturationConfirmations) below tip ($tip). A reorg could orphan these " +
                    s"seeded blocks and re-poison the append-only confirmed root – the exact " +
                    s"failure this seeds to recover from. Consider a deeper --confirmed-until."
              )
            )
        else Right(None)
}
```

- [ ] **Step 5: Run the tests – expect PASS**

```
sbt "testOnly binocular.InitOracleCommandTest"
```

Expected: all six tests green (PASS).

- [ ] **Step 6: Wire the helper and range build into `execute`**

In `InitOracleCommand.execute`, after the `blockHeight` is resolved (line 42-46) rename it to `startHeight` for clarity and compute `confirmedTip`, then call the validator after the RPC `info` is known (after line 70, where `info.blocks` is available). Replace the single-block state fetch (Step 2 block, lines 74-87) so it uses the range overload and validates first.

Concretely, after `val blockHeight = startBlock.orElse(oracleConf.startHeight).getOrElse { ... }` add:

```scala
        val confirmedTip = confirmedUntil.getOrElse(blockHeight)
```

After the "Connected to ..." success line (line 68-70), add validation using the live tip:

```scala
        InitOracleCommand.validateConfirmedRange(
          startHeight = blockHeight,
          confirmedTip = confirmedTip,
          tip = info.blocks.toLong,
          maturationConfirmations = oracleConf.maturationConfirmations.toLong
        ) match {
            case Left(err) =>
                Console.error(err)
                break(1)
            case Right(maybeWarn) =>
                maybeWarn.foreach(Console.warn)
        }
```

Change the state fetch (line 78) from:

```scala
                BitcoinChainState.getInitialChainState(rpc, blockHeight.toInt).await(30.seconds)
```

to:

```scala
                BitcoinChainState
                    .getInitialChainState(rpc, blockHeight.toInt, confirmedTip.toInt)
                    .await(30.seconds)
```

In the dry-run block (line 107-113), also print the seeded root and confirmed tip so the operator can eyeball what would be committed:

```scala
        if dryRun then {
            println()
            Console.success("Dry-run complete. Transaction would initialize oracle with:")
            Console.info("Start Height", f"$blockHeight%,d")
            Console.info("Confirmed Tip", f"$confirmedTip%,d")
            Console.info("Height", initialState.ctx.height)
            Console.info("Hash", initialState.ctx.lastBlockHash.toHex)
            Console.info("Confirmed Root", initialState.confirmedBlocksRoot.toHex)
            break(0)
        }
```

- [ ] **Step 7: Compile + full suite green, then commit**

```
sbt compile
sbt test
sbt scalafmtAll
```

Expected: project compiles; `sbt test` green (existing suites unaffected; new suites pass). Then:

```
git add -A
git commit -m "feat(cli): init --confirmed-until seeds a confirmed block range

Add --confirmed-until to the init subcommand, threaded through Cmd.Init into
InitOracleCommand. Validate start <= confirmedTip <= tip, warn (non-blocking)
when confirmedTip is shallower than the maturation depth, and build the
seeded state via getInitialChainState(rpc, start, confirmedTip). Dry-run
prints the seeded root and confirmed tip. Omitting the flag keeps single-block
init unchanged."
```

---

## Self-review checklist (run before returning / merging)

- [ ] **Spec coverage.** Every spec item is realized: `--confirmed-until` option (Task 3); range `confirmedBlocksRoot` with ctx at confirmedTip (Task 2); single-block behavior preserved (Task 2 delegating overload + regression assertion); shared range→root helper so seed == rebuild (Task 1, `mpfForRange` is the sole walk); validation `start <= confirmedTip <= tip` + non-blocking reorg-depth warning (Task 3 `validateConfirmedRange`); dry-run prints seeded root + confirmedTip (Task 3 Step 6). No on-chain change. No new persistence.
- [ ] **Placeholder scan.** No `???`, `TODO`, `<...>`, or invented symbols. Every referenced symbol is real: `mpfRootForSingleBlock`, `mpfForRange`, `getInitialChainState`, `ChainState`, `TraversalCtx`, `ForkTree.End`, `rebuildMpf`, `reconstructMpf`, `MockBitcoinRpc`, `CliApp.command`, `Cmd.Init`, `CliParsers.{startBlockOpt,dryRunFlag}`, `Opts.option`/`Opts.flag`, `oracleConf.{startHeight,maturationConfirmations}`, `info.blocks`, `Console.{warn,error,info,success}`, `break`.
- [ ] **Type consistency.** `mpfForRange` returns `Future[OffChainMPF]`; `.rootHash: ByteString`. `startHeight`/`confirmedTip`/`tip` are `Long` in validation; `.toInt` only at RPC boundaries (`getBlockHash`, `getInitialChainState`). `maturationConfirmations: Int` → `.toLong` at the call site. `confirmedUntil: Option[Long]` matches `startBlock: Option[Long]`. `rebuildMpf`/`mpfForRange` first param is the `BitcoinRpc` trait so `MockBitcoinRpc` and `SimpleBitcoinRpc` both satisfy it. `Cmd.Init` arity (3) matches `InitOracleCommand` arity (3) and the routing pattern.
- [ ] **Style.** No em dashes anywhere (the one in the original `rebuildMpf` message and the enum comments are converted to en dashes). No new fully-qualified names where an import exists (test files fully-qualify `binocular.cli.Command.rebuildMpf`/`CliApp.command` only because they are cross-package references without a local import – acceptable, or add imports). `sbt scalafmtAll` before each commit. No `Co-Authored-By` trailer.
