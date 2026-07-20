# TM Confirmed-Chain Treasury Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Anchor the Bitcoin treasury outpoint in the Config UTXO and verify at TM mint time that every posted TM spends the previous treasury outpoint, removing the TM Control NFT.

**Architecture:** The Scalus `TreasuryMovementValidator` mint branch gains a `Genesis | Chain` redeemer verifying the embedded BTC tx's input 0 against the config anchor (field 11) or a referenced predecessor `Confirmed` record. Chain uniqueness is inherited from Bitcoin's spend-once semantics. Heimdall resolves the current treasury by walking the Confirmed chain instead of "latest UTxO at address". The deployed bridge migrates via one config `Update` tx.

**Tech Stack:** Aiken v1.1.17 (onchain), Scala 3 + Scalus (binocular), Rust (heimdall).

**Spec:** `docs/superpowers/specs/2026-07-20-tm-confirmed-chain-design.md`

## Global Constraints

- Outpoint encoding everywhere: 36 bytes = txid (internal byte order, 32) ++ vout (4-byte LE). Config field 11 uses this exact encoding.
- The treasury input is input 0 of the TM tx; the treasury change output is output 0.
- `TmDatum` shapes are frozen: `Unconfirmed` = Constr 0 `[bytes]`, `Confirmed` = Constr 1 `[btcTxid, swept, fulfilled]`.
- Config evolution is append-only; getters are positional; field 11 is the new `initial_btc_treasury_utxo`.
- No em dashes in committed text. No Claude co-author trailers in commits.
- Test commands: `aiken check` (from `onchain/`), `sbt test` (from `offchain/bitcoin-watchtower/binocular/`), `cargo test` (from `offchain/SPO/heimdall/`).

---

### Task 1: Aiken config field 11 + getter + pin test

**Files:**
- Modify: `onchain/lib/bifrost/types/config.ak`

**Interfaces:**
- Produces: `ConfigDatum.initial_btc_treasury_utxo: ByteArray` (field index 11), `get_initial_btc_treasury_utxo(config_fields: List<Data>) -> ByteArray`.

- [x] **Step 1: Add the field, getter, and pin-test line**

In `ConfigDatum`, after `update_auth`:

```aiken
  //Authority allowed to Update/Retire the config UTxO. None = frozen.
  update_auth: Option<AuthorizationMethod>,
  //The initial (anchor) Bitcoin treasury outpoint the first Treasury Movement
  //must spend: 36 bytes = txid (internal byte order) ++ vout (4-byte LE).
  //Subsequent TMs chain from the previous Confirmed TM record instead.
  //Re-pointable via config Update (e.g. after an emergency federation sweep).
  initial_btc_treasury_utxo: ByteArray,
}
```

After `get_update_auth`:

```aiken
pub fn get_initial_btc_treasury_utxo(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 11))
}
```

In `config_getters_match_datum_fields`, add to the datum literal
`initial_btc_treasury_utxo: #"aa11",` and to the `and { }` block
`get_initial_btc_treasury_utxo(fields) == datum.initial_btc_treasury_utxo,`.

- [x] **Step 2: Run checks**

Run: `cd onchain && aiken check`
Expected: all tests pass, including the pin test. Fix any fixture in the repo that constructs `ConfigDatum` (search: `rg -l 'ConfigDatum {' onchain`) by appending the new field.

- [x] **Step 3: `aiken build` and commit**

Run: `cd onchain && aiken build` (regenerates `plutus.json`).

```bash
git add onchain && git commit -m "feat(onchain): config field 11 initial_btc_treasury_utxo + getter"
```

---

### Task 2: TreasuryMovementValidator rewrite (Scalus)

**Files:**
- Modify: `offchain/bitcoin-watchtower/binocular/src/main/scala/binocular/watchtower/TreasuryMovementValidator.scala`
- Test: `offchain/bitcoin-watchtower/binocular/src/test/scala/binocular/TreasuryMovementValidatorTest.scala`

**Interfaces:**
- Produces: `enum TmMintRedeemer { Genesis; Chain(prevTmRefInputIndex: BigInt) }`;
  `TreasuryMovementContract.contract(oracleScriptHash, configNftPolicy, configNftName)`;
  `TreasuryMovementValidator.validate(oracleScriptHash, configNftPolicy, configNftName, scData)`.
- Deletes: `TmControlDatum`, `findControlInput`, `signedByAuthority`, control-NFT params.

- [x] **Step 1: Write failing tests**

Rewrite the mint fixtures/tests in `TreasuryMovementValidatorTest.scala`. Replace `controlNftPolicy`/`controlNftName`/`authorityPkh`/`controlRefInput`/`mintContext` and the five mint tests with:

```scala
    private val configNftPolicy = filled(0xc0, 28)
    private val configNftName = ByteString.fromHex("434f4e464947") // "CONFIG"

    // The anchor outpoint = in0 of rawTm: aa*32 ++ 00000000.
    private val anchorOutpoint = ByteString.fromHex(("aa" * 32) + "00000000")

    // A minimal 12-field config datum: only field 11 (initial_btc_treasury_utxo) matters here.
    private def configDatum(anchor: ByteString): Data =
        Data.Constr(
          0,
          List(
            Data.B(ByteString.empty), Data.B(ByteString.empty), Data.B(ByteString.empty),
            Data.B(ByteString.empty), Data.B(ByteString.empty), Data.B(ByteString.empty),
            Data.B(ByteString.empty), Data.B(ByteString.empty), Data.B(ByteString.empty),
            Data.I(0), Data.Constr(1, List.empty), Data.B(anchor)
          )
        )

    private def configRefInput(
        anchor: ByteString = anchorOutpoint,
        withNft: Boolean = true
    ): TxInInfo = TxInInfo(
      outRef = TxOutRef(TxId(filled(0x03, 32)), BigInt(0)),
      resolved = TxOut(
        address = Address(Credential.ScriptCredential(filled(0xc1, 28)), Option.None),
        value =
            if withNft then
                Value.unsafeFromList(PList((configNftPolicy, PList((configNftName, BigInt(1))))))
            else Value.lovelace(2_000_000),
        datum = OutputDatum.OutputDatum(configDatum(anchor)),
        referenceScript = Option.None
      )
    )

    /** A predecessor Confirmed TM record whose btcTxid makes `spentOutpoint` its output-0 outpoint. */
    private def predecessorRefInput(
        prevTxid: ByteString,
        withNft: Boolean = true,
        confirmed: Boolean = true
    ): TxInInfo = TxInInfo(
      outRef = TxOutRef(TxId(filled(0x04, 32)), BigInt(0)),
      resolved = TxOut(
        address = Address(Credential.ScriptCredential(tmPolicy), Option.None),
        value =
            if withNft then
                Value.unsafeFromList(
                  PList(
                    (ByteString.empty, PList((ByteString.empty, BigInt(2_000_000)))),
                    (tmPolicy, PList((ByteString.empty, BigInt(1))))
                  )
                )
            else Value.lovelace(2_000_000),
        datum = OutputDatum.OutputDatum(
          if confirmed then
              (TmDatum.Confirmed(prevTxid, PList.Nil, PList.Nil): TmDatum).toData
          else unconfirmedDatum
        ),
        referenceScript = Option.None
      )
    )

    /** The freshly-posted Unconfirmed TM output the mint must bind the NFT to. */
    private def mintedTmOutput(
        datum: Data = unconfirmedDatum,
        credential: Credential = Credential.ScriptCredential(tmPolicy)
    ): TxOut = TxOut(
      address = Address(credential, Option.None),
      value = Value.unsafeFromList(
        PList(
          (ByteString.empty, PList((ByteString.empty, BigInt(2_000_000)))),
          (tmPolicy, PList((ByteString.empty, BigInt(1))))
        )
      ),
      datum = OutputDatum.OutputDatum(datum),
      referenceScript = Option.None
    )

    private def mintContext(
        nftQty: BigInt,
        rdmr: Data,
        refInputs: PList[TxInInfo],
        outputs: PList[TxOut]
    ): ScriptContext =
        ScriptContext(
          txInfo = TxInfo(
            inputs = PList.Nil,
            referenceInputs = refInputs,
            outputs = outputs,
            mint = Value.unsafeFromList(PList((tmPolicy, PList((ByteString.empty, nftQty))))),
            id = TxId(filled(0x00, 32))
          ),
          redeemer = rdmr,
          scriptInfo = ScriptInfo.MintingScript(tmPolicy)
        )

    private val genesisRdmr: Data = (TmMintRedeemer.Genesis: TmMintRedeemer).toData
    private def chainRdmr(i: BigInt): Data = (TmMintRedeemer.Chain(i): TmMintRedeemer).toData
```

Note: `tmPolicy` must now be defined BEFORE these fixtures (it is used in
`predecessorRefInput`/`mintedTmOutput`); keep `compiled`/`program`/`tmPolicy` as
`lazy val`s and change `compiled` to
`TreasuryMovementContract.contract(oracleHash, configNftPolicy, configNftName)`.
Also note `tmScriptHash` (the spend-side stand-in address) stays as-is for the
confirm tests; the mint tests use the REAL script hash `tmPolicy` for the
NFT-bound output credential because the mint branch compares against its own
`ownPolicyId`.

Mint tests (replace the old five):

```scala
    test("TM mint Genesis: +1 bound to Unconfirmed output, tx spends config anchor - succeeds") {
        val sc = mintContext(BigInt(1), genesisRdmr,
          PList.from(List(configRefInput())), PList.from(List(mintedTmOutput())))
        val result = program.applyArg(sc.toData).evaluateDebug
        assert(result.isSuccess, s"Expected success, got: $result")
    }

    test("TM mint Genesis: wrong anchor outpoint fails") {
        val sc = mintContext(BigInt(1), genesisRdmr,
          PList.from(List(configRefInput(anchor = filled(0xee, 36)))),
          PList.from(List(mintedTmOutput())))
        assert(!program.applyArg(sc.toData).evaluateDebug.isSuccess)
    }

    test("TM mint Genesis: config ref input without the config NFT fails") {
        val sc = mintContext(BigInt(1), genesisRdmr,
          PList.from(List(configRefInput(withNft = false))),
          PList.from(List(mintedTmOutput())))
        assert(!program.applyArg(sc.toData).evaluateDebug.isSuccess)
    }

    test("TM mint Chain: predecessor Confirmed(txid=aa*32), tx spends (aa*32, 0) - succeeds") {
        val sc = mintContext(BigInt(1), chainRdmr(0),
          PList.from(List(predecessorRefInput(prevTxid = filled(0xaa, 32)))),
          PList.from(List(mintedTmOutput())))
        val result = program.applyArg(sc.toData).evaluateDebug
        assert(result.isSuccess, s"Expected success, got: $result")
    }

    test("TM mint Chain: wrong predecessor txid fails") {
        val sc = mintContext(BigInt(1), chainRdmr(0),
          PList.from(List(predecessorRefInput(prevTxid = filled(0xbb, 32)))),
          PList.from(List(mintedTmOutput())))
        assert(!program.applyArg(sc.toData).evaluateDebug.isSuccess)
    }

    test("TM mint Chain: predecessor without the TM NFT fails") {
        val sc = mintContext(BigInt(1), chainRdmr(0),
          PList.from(List(predecessorRefInput(prevTxid = filled(0xaa, 32), withNft = false))),
          PList.from(List(mintedTmOutput())))
        assert(!program.applyArg(sc.toData).evaluateDebug.isSuccess)
    }

    test("TM mint Chain: Unconfirmed predecessor fails") {
        val sc = mintContext(BigInt(1), chainRdmr(0),
          PList.from(List(predecessorRefInput(prevTxid = filled(0xaa, 32), confirmed = false))),
          PList.from(List(mintedTmOutput())))
        assert(!program.applyArg(sc.toData).evaluateDebug.isSuccess)
    }

    test("TM mint: NFT output at a foreign credential fails") {
        val sc = mintContext(BigInt(1), genesisRdmr,
          PList.from(List(configRefInput())),
          PList.from(List(mintedTmOutput(credential = Credential.ScriptCredential(filled(0x99, 28))))))
        assert(!program.applyArg(sc.toData).evaluateDebug.isSuccess)
    }

    test("TM mint: NFT output with a Confirmed datum fails") {
        val sc = mintContext(BigInt(1), genesisRdmr,
          PList.from(List(configRefInput())),
          PList.from(List(mintedTmOutput(datum = confirmedDatum()))))
        assert(!program.applyArg(sc.toData).evaluateDebug.isSuccess)
    }

    test("TM mint: minting more than one fails") {
        val sc = mintContext(BigInt(2), genesisRdmr,
          PList.from(List(configRefInput())), PList.from(List(mintedTmOutput())))
        assert(!program.applyArg(sc.toData).evaluateDebug.isSuccess)
    }

    test("TM NFT burn: -1 is permissionless") {
        val sc = mintContext(BigInt(-1), Data.unit, PList.Nil, PList.Nil)
        assert(program.applyArg(sc.toData).evaluateDebug.isSuccess)
    }
```

- [x] **Step 2: Run tests, verify the new ones fail to compile**

Run: `cd offchain/bitcoin-watchtower/binocular && sbt "testOnly binocular.TreasuryMovementValidatorTest"`
Expected: compile error (`TmMintRedeemer` not found).

- [x] **Step 3: Implement the validator changes**

In `TreasuryMovementValidator.scala`:

1. Delete `TmControlDatum` + its `@Compile object`, `findControlInput`, `signedByAuthority`.
2. Add after `TmConfirmRedeemer`:

```scala
/** Mint redeemer: which anchor the posted TM chains from.
  *
  *   - [[Genesis]] — the FIRST Treasury Movement: the embedded BTC tx's input 0 must spend the
  *     initial treasury outpoint stored in the Config UTxO (field 11), located among reference
  *     inputs by the config NFT.
  *   - [[Chain]] — every subsequent TM: the reference input at `prevTmRefInputIndex` must be a
  *     `Confirmed` TM record (authenticated by the TM NFT), and the embedded BTC tx's input 0 must
  *     spend that record's treasury output `(btcTxid, vout 0)`.
  *
  * Minting is PERMISSIONLESS: anyone may post a TM chaining from any anchor, but a Bitcoin
  * outpoint spends exactly once, so at most one such TM can ever confirm — the Confirmed chain
  * cannot fork. Uniqueness is inherited from Bitcoin, not enforced here.
  */
enum TmMintRedeemer derives FromData, ToData {
    case Genesis
    case Chain(prevTmRefInputIndex: BigInt)
}

@Compile
object TmMintRedeemer
```

3. Add helpers inside `TreasuryMovementValidator`:

```scala
    /** The unique tx output carrying the freshly minted TM NFT. Fails on zero or multiple. */
    def outputWithNft(outputs: ScalusList[TxOut], policy: ByteString): TxOut = {
        def loop(remaining: ScalusList[TxOut], acc: Option[TxOut]): TxOut =
            remaining match
                case ScalusList.Nil =>
                    acc match
                        case Option.Some(o) => o
                        case Option.None    => fail("No output carries the TM NFT")
                case ScalusList.Cons(out, tail) =>
                    if out.value.quantityOf(policy, ByteString.empty) == BigInt(1) then
                        acc match
                            case Option.Some(_) => fail("TM NFT on multiple outputs")
                            case Option.None    => loop(tail, Option.Some(out))
                    else loop(tail, acc)
        loop(outputs, Option.None)
    }

    /** Reference input at `index` (0-based). */
    def refInputAt(refInputs: ScalusList[TxInInfo], index: BigInt): TxOut = {
        def loop(remaining: ScalusList[TxInInfo], i: BigInt): TxOut =
            remaining match
                case ScalusList.Nil => fail("TM predecessor reference input index out of range")
                case ScalusList.Cons(input, tail) =>
                    if i == BigInt(0) then input.resolved else loop(tail, i - 1)
        loop(refInputs, index)
    }

    /** Find the Config UTxO among reference inputs by the config NFT. */
    def findConfigInput(
        refInputs: ScalusList[TxInInfo],
        configNftPolicy: ByteString,
        configNftName: ByteString
    ): TxOut = {
        def search(remaining: ScalusList[TxInInfo]): TxOut =
            remaining match
                case ScalusList.Nil => fail("Config reference input (NFT) not found")
                case ScalusList.Cons(input, tail) =>
                    val resolved = input.resolved
                    if resolved.value.quantityOf(configNftPolicy, configNftName) == BigInt(1) then
                        resolved
                    else search(tail)
        search(refInputs)
    }

    /** Config field 11 = initial_btc_treasury_utxo: 36 bytes, txid (internal) ++ vout (LE). */
    def initialTreasuryOutpoint(configDatum: Data): ByteString = {
        def at(fields: ScalusList[Data], i: BigInt): Data =
            fields match
                case ScalusList.Nil => fail("Config datum too short")
                case ScalusList.Cons(h, t) =>
                    if i == BigInt(0) then h else at(t, i - 1)
        unBData(at(unConstrData(configDatum).snd, BigInt(11)))
    }
```

(`unConstrData`/`unBData` come from the already-imported `Builtins.*`; if the
prelude's Data view differs, use the project's established raw-Data accessors —
match how `ChainState` handling decodes raw fields elsewhere in the file.)

4. Replace `mint` with:

```scala
    /** Minting policy for the TM NFT — permissionless, gated by chain linkage: the freshly posted
      * `Unconfirmed` TM must embed a BTC tx whose input 0 spends the protocol treasury outpoint —
      * the config anchor ([[TmMintRedeemer.Genesis]]) or the referenced predecessor `Confirmed`
      * record's output 0 ([[TmMintRedeemer.Chain]]). See [[TmMintRedeemer]] for why permissionless
      * minting is safe. Burning is permissionless cleanup.
      */
    def mint(
        configNftPolicy: ByteString,
        configNftName: ByteString,
        ownPolicyId: ByteString,
        tx: TxInfo,
        redeemer: Datum
    ): Unit = {
        val minted = tx.mint.quantityOf(ownPolicyId, ByteString.empty)
        if minted > BigInt(0) then {
            require(minted == BigInt(1), "TM mint: must mint exactly one TM NFT")
            // Bind the NFT to a TM-address output whose datum embeds the tx being verified.
            val tmOut = outputWithNft(tx.outputs, ownPolicyId)
            tmOut.address.credential match
                case Credential.ScriptCredential(h) =>
                    require(h == ownPolicyId, "TM mint: NFT output not at the TM script address")
                case _ => fail("TM mint: NFT output not at a script address")
            val signedBtcTx = (tmOut.datum match
                case OutputDatum.OutputDatum(d) => d.to[TmDatum]
                case _                          => fail("TM mint: NFT output needs an inline datum")
            ) match
                case TmDatum.Unconfirmed(rawTx) => rawTx
                case _ => fail("TM mint: NFT output datum is not Unconfirmed")
            // The outpoint the embedded BTC tx spends first: input 0 is the treasury by the
            // deterministic TM layout.
            val spent = allInputOutpoints(signedBtcTx) match
                case ScalusList.Cons(first, _) => first
                case ScalusList.Nil            => fail("TM mint: embedded BTC tx has no inputs")
            val expected = redeemer.to[TmMintRedeemer] match
                case TmMintRedeemer.Genesis =>
                    initialTreasuryOutpoint(
                      findConfigInput(tx.referenceInputs, configNftPolicy, configNftName).datum match
                          case OutputDatum.OutputDatum(d) => d
                          case _ => fail("Config UTxO needs an inline datum")
                    )
                case TmMintRedeemer.Chain(i) =>
                    val prev = refInputAt(tx.referenceInputs, i)
                    require(
                      prev.value.quantityOf(ownPolicyId, ByteString.empty) == BigInt(1),
                      "TM mint: predecessor lacks the TM NFT"
                    )
                    (prev.datum match
                        case OutputDatum.OutputDatum(d) => d.to[TmDatum]
                        case _ => fail("TM mint: predecessor needs an inline datum")
                    ) match
                        case TmDatum.Confirmed(btcTxid, _, _) =>
                            appendByteString(btcTxid, ByteString.fromHex("00000000"))
                        case _ => fail("TM mint: predecessor is not Confirmed")
            require(spent == expected, "TM mint: BTC tx does not spend the treasury outpoint")
        } else
            require(minted < BigInt(0), "TM mint: nothing minted/burned under the TM policy")
    }
```

5. `validate`: rename params `controlNftPolicy/controlNftName` to
   `configNftPolicy/configNftName`; pass `ctx.redeemer` to `mint`:
   `mint(configNftPolicy, configNftName, ownPolicyId, ctx.txInfo, ctx.redeemer)`.
6. `TreasuryMovementContract`: rename the curried params the same way; update the
   scaladoc (address still stable, now bound to oracle + config NFT); in
   `blueprint`, rename the corresponding parameter titles.
7. Update the file's top scaladoc: delete step 6 "NOT YET ENFORCED" and describe
   mint-time linkage instead.

- [x] **Step 4: Run tests until green**

Run: `cd offchain/bitcoin-watchtower/binocular && sbt "testOnly binocular.TreasuryMovementValidatorTest"`
Expected: PASS (all confirm-path tests unchanged and passing too).

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(tm): permissionless TM mint gated by confirmed-chain linkage"
```

(binocular is a separate git repo under `offchain/bitcoin-watchtower/binocular` — commit there.)

---

### Task 3: Binocular off-chain wiring

**Files:**
- Modify: `src/main/scala/binocular/watchtower/ConfigTypes.scala`
- Modify: `src/main/scala/binocular/watchtower/BridgeConfig.scala`
- Modify: `src/main/scala/binocular/cli/commands/DeployBridgeCommand.scala`
- Modify: `src/main/scala/binocular/cli/commands/TmScriptCommand.scala`
- Modify: `src/main/scala/binocular/cli/commands/CreateTmtxCommand.scala`
- Modify: `src/main/scala/binocular/cli/commands/ConfirmTmtxCommand.scala` (only if it names TM params)
- Modify: `src/main/resources/*.conf` (any config referencing tm-control / authorized-minter)

**Interfaces:**
- Consumes: `TreasuryMovementContract.contract(oracleScriptHash, configNftPolicy, configNftName)` from Task 2.
- Produces: `ConfigDatum.initialBtcTreasuryUtxo: ByteString` (12th field); `BridgeConfig.initialBtcTreasuryUtxo: String` (`TXID:VOUT` display form); helper `outpointFromDisplay(s: String): ByteString` that reverses the txid hex to internal order and appends the 4-byte LE vout.

- [x] **Step 1: ConfigDatum + BridgeConfig**

Append to `ConfigDatum` (and extend the layout comment: "11 initial_btc_treasury_utxo"):

```scala
    updateAuth: scalus.cardano.onchain.plutus.prelude.Option[AuthorizationMethod],
    // 36-byte anchor outpoint the first TM must spend: txid (internal order) ++ vout (LE).
    initialBtcTreasuryUtxo: ByteString
```

In `BridgeConfig`: delete `tmControlNftPolicy`, `tmControlNftName`,
`tmAuthorizedMinter`; add:

```scala
    // The initial Bitcoin treasury outpoint written into config field 11 at deploy, in display
    // form "TXID:VOUT" (TXID as shown by explorers; converted to internal byte order internally).
    initialBtcTreasuryUtxo: String = "",
```

Add the conversion helper (object `BridgeConfig` companion or a small util next to it):

```scala
object BridgeConfig {
    /** "TXID:VOUT" (display txid) -> 36-byte outpoint (txid internal order ++ vout LE). */
    def outpointFromDisplay(s: String): scalus.uplc.builtin.ByteString = {
        val Array(txidHex, voutStr) = s.split(':')
        require(txidHex.length == 64, s"txid must be 64 hex chars: $txidHex")
        val txidInternal = txidHex.grouped(2).toSeq.reverse.mkString
        val vout = voutStr.toLong
        val voutLe = f"${vout & 0xff}%02x${(vout >> 8) & 0xff}%02x${(vout >> 16) & 0xff}%02x${(vout >> 24) & 0xff}%02x"
        scalus.uplc.builtin.ByteString.fromHex(txidInternal + voutLe)
    }
}
```

- [x] **Step 2: DeployBridgeCommand**

- Remove the TMCTRL one-shot ref, `TmControlAssetName` const, control-UTxO output
  (`TmControlDatum(...)`), and the `--authorized-minter` option/validation.
- TM script construction becomes
  `TreasuryMovementContract.script(oraclePolicyId, configPolicyId, configAssetName)` where
  `configPolicyId`/`configAssetName` are the config NFT values already computed in the command.
- Genesis `ConfigDatum` gains
  `initialBtcTreasuryUtxo = BridgeConfig.outpointFromDisplay(bridgeConfig.initialBtcTreasuryUtxo)`
  (fail fast with a clear message when unset).

- [x] **Step 3: TmScriptCommand / CreateTmtxCommand / ConfirmTmtxCommand**

- `TmScriptCommand`: build the script from `(oracle hash, config NFT policy, config NFT name)`;
  replace the "tm-control-nft-policy unset" warning with a config-NFT-unset warning.
- `CreateTmtxCommand`: pay to the new-params TM address; when minting under the real policy pass
  redeemer `(TmMintRedeemer.Genesis: TmMintRedeemer).toData` (scaffold path unchanged otherwise).
- `ConfirmTmtxCommand` and `TreasuryMovementTx`: compile-fix any renamed parameters; confirm logic
  itself is unchanged.
- Sweep `src/main/resources` and `example/` configs for `tm-control` / `tm-authorized-minter`
  keys: delete them, add `initial-btc-treasury-utxo = ""` where bridge config lives.

- [x] **Step 4: Full test run and commit**

Run: `cd offchain/bitcoin-watchtower/binocular && sbt test`
Expected: PASS. `BinocularBlueprintTest`/`BifrostContractsTest` may pin script hashes or blueprint
params: update the expected values (the TM validator legitimately changed).

```bash
git add -A && git commit -m "feat(bridge): config-anchored TM deploy, drop TM control NFT"
```

---

### Task 4: Binocular UpdateConfigCommand (live migration tx)

**Files:**
- Create: `src/main/scala/binocular/cli/commands/UpdateConfigCommand.scala`
- Modify: `src/main/scala/binocular/cli/CliApp.scala` (register the subcommand)

**Interfaces:**
- Consumes: `ConfigDatum` (12 fields) from Task 3; the deployed config UTxO located by config NFT.
- Produces: CLI `update-config --initial-btc-treasury-utxo TXID:VOUT --peg-in-withdraw-hash HEX`.

- [x] **Step 1: Implement the command**

Follow the structure of `ConfirmTmtxCommand`/`TreasuryMovementTx.buildAndSubmitConfirm` for wallet,
provider, and submission plumbing, and `DeployBridgeCommand` for locating the config script/NFT:

1. Locate the config UTxO by `(configNftPolicyId, configNftAssetName)`.
2. Read its inline datum as raw `Data`; take the Constr field list `fields`.
3. New datum = Constr 0 with: `fields.updated(4, Data.B(newPegInWithdrawHash))` if
   `--peg-in-withdraw-hash` given, then append `Data.B(outpoint)` if the list has 11 fields
   (or replace index 11 if it already has 12 — makes the command re-runnable / re-anchorable).
4. Spend the config UTxO with redeemer `ConfigSpendRedeemer.Update` (Constr 0, no fields:
   `Data.Constr(0, List.empty)`), recreate at the same address with the same non-ADA value
   (the config NFT) and the new inline datum; sign with the `update_auth` key
   (`oracle.owner-pkh` wallet — same signing setup the deploy command uses).
5. Print the old and new datum hex and the tx hash.

- [x] **Step 2: Test**

`sbt compile` + a unit test for the datum rewrite function (pure: fields list in, fields list
out) in `src/test/scala/binocular/cli/`:

```scala
test("update-config datum rewrite appends field 11 and swaps field 4") {
    val fields = (0 to 10).map(i => Data.B(ByteString.fromHex(f"$i%02x"))).toList
    val out = UpdateConfigCommand.rewriteFields(fields,
      newPegInHash = Some(ByteString.fromHex("ff")), anchor = ByteString.fromHex("ee"))
    assert(out.size == 12 && out(4) == Data.B(ByteString.fromHex("ff"))
      && out(11) == Data.B(ByteString.fromHex("ee")))
}
```

(Expose the pure rewrite as `UpdateConfigCommand.rewriteFields(fields, newPegInHash, anchor)`.)

- [x] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(cli): update-config command - append treasury anchor, swap peg-in hash"
```

---

### Task 5: Heimdall - config + chain walk + publish

**Files:**
- Create: `src/cardano/tm_chain.rs` (pure chain-walk logic + tests)
- Modify: `src/config.rs`, `src/cardano/blockfrost_chain.rs`, `src/cardano/publish.rs`,
  `src/cardano/treasury_datum.rs`, `src/main.rs`, `heimdall.toml`, `heimdall.testnet4.toml`
- Test: inline `#[cfg(test)]` in `tm_chain.rs`

**Interfaces:**
- Consumes: on-chain `Confirmed` datum = Constr tag 122, fields
  `[BoundedBytes btcTxid, Array<BoundedBytes> swept, Array<Constr(scriptPubKey, amount)> fulfilled]`.
- Produces: `tm_chain::ConfirmedTm { btc_txid: [u8; 32], spent_outpoint: [u8; 36], treasury_value_sat: u64, cardano_utxo: (String, u32) }`;
  `tm_chain::walk_chain(anchor: [u8; 36], records: &[ConfirmedTm]) -> Option<&ConfirmedTm>`;
  `tm_chain::parse_confirmed_datum(data: &PlutusData) -> Option<([u8; 32], [u8; 36], u64)>`;
  `outpoint_bytes(op: &bitcoin::OutPoint) -> [u8; 36]`.

- [x] **Step 1: Write failing tests in `tm_chain.rs`**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn rec(spent: u8, txid: u8, val: u64) -> ConfirmedTm {
        let mut spent_outpoint = [spent; 36];
        spent_outpoint[32..].copy_from_slice(&0u32.to_le_bytes());
        ConfirmedTm {
            btc_txid: [txid; 32],
            spent_outpoint,
            treasury_value_sat: val,
            cardano_utxo: (format!("{txid:02x}"), 0),
        }
    }

    fn op(b: u8) -> [u8; 36] {
        let mut o = [b; 36];
        o[32..].copy_from_slice(&0u32.to_le_bytes());
        o
    }

    #[test]
    fn walk_empty_chain_returns_none() {
        assert!(walk_chain(op(0xaa), &[]).is_none());
    }

    #[test]
    fn walk_follows_anchor_to_tip() {
        // anchor aa -> tm1 (txid bb) -> tm2 (txid cc); a garbage record dd->ee is ignored.
        let records = vec![rec(0xaa, 0xbb, 100), rec(0xbb, 0xcc, 90), rec(0xdd, 0xee, 1)];
        let tip = walk_chain(op(0xaa), &records).unwrap();
        assert_eq!(tip.btc_txid, [0xcc; 32]);
        assert_eq!(tip.treasury_value_sat, 90);
    }

    #[test]
    fn competing_children_of_one_predecessor_cannot_both_exist() {
        // Two Confirmed records spending the same outpoint is impossible on Bitcoin; the walk
        // takes the first and documents the invariant.
        let records = vec![rec(0xaa, 0xbb, 100), rec(0xaa, 0xcc, 90)];
        let tip = walk_chain(op(0xaa), &records).unwrap();
        assert_eq!(tip.btc_txid, [0xbb; 32]);
    }

    #[test]
    fn outpoint_bytes_is_txid_internal_plus_vout_le() {
        let txid: bitcoin::Txid =
            "1111111111111111111111111111111111111111111111111111111111111100".parse().unwrap();
        let b = outpoint_bytes(&bitcoin::OutPoint { txid, vout: 1 });
        // display txid is reversed: internal order starts with the LAST display byte pair.
        assert_eq!(b[0], 0x00);
        assert_eq!(&b[32..], &[1, 0, 0, 0]);
    }
}
```

- [x] **Step 2: Run tests, verify failure**

Run: `cd offchain/SPO/heimdall && cargo test tm_chain`
Expected: compile error (module not found). Add `pub mod tm_chain;` to `src/cardano/mod.rs` first
so the failure is the missing types, not the missing module.

- [x] **Step 3: Implement `tm_chain.rs`**

```rust
//! Walk the Treasury Movement Confirmed chain.
//!
//! Every Confirmed TM record proves (at mint) that its BTC tx spends the previous treasury
//! outpoint. The current treasury is found by walking records from the config anchor: each
//! record is indexed by the outpoint it spends (swept[0]); the tip's (btc_txid, 0) with value
//! fulfilled[0].amount is the current treasury. Records not on the chain (garbage posts that
//! can never confirm, or abandoned pre-migration records) are simply never visited.

use pallas_primitives::PlutusData;

/// A parsed on-chain `Confirmed` TM record.
#[derive(Debug, Clone)]
pub struct ConfirmedTm {
    /// btcTxid, internal byte order (as stored on-chain).
    pub btc_txid: [u8; 32],
    /// The outpoint this TM's BTC tx spent = swept[0] (txid internal ++ vout LE).
    pub spent_outpoint: [u8; 36],
    /// fulfilled[0].amount = the value of the new treasury output (output 0).
    pub treasury_value_sat: u64,
    /// The Cardano UTxO (tx_hash, index) holding this record - the mint reference input for
    /// the NEXT TM.
    pub cardano_utxo: (String, u32),
}

/// 36-byte outpoint encoding: txid internal order ++ vout LE.
#[must_use]
pub fn outpoint_bytes(op: &bitcoin::OutPoint) -> [u8; 36] {
    use bitcoin::hashes::Hash;
    let mut out = [0u8; 36];
    out[..32].copy_from_slice(op.txid.as_raw_hash().as_byte_array());
    out[32..].copy_from_slice(&op.vout.to_le_bytes());
    out
}

/// Walk from `anchor` to the chain tip. Returns `None` when no record spends the anchor
/// (genesis state: the first TM has not confirmed yet).
#[must_use]
pub fn walk_chain<'a>(anchor: [u8; 36], records: &'a [ConfirmedTm]) -> Option<&'a ConfirmedTm> {
    let mut tip: Option<&ConfirmedTm> = None;
    let mut current = anchor;
    // Bounded by records.len() hops - a cycle is impossible (each hop consumes a distinct
    // Bitcoin outpoint) but the bound keeps a malformed record set from looping.
    for _ in 0..=records.len() {
        let Some(next) = records.iter().find(|r| r.spent_outpoint == current) else {
            return tip;
        };
        let mut op = [0u8; 36];
        op[..32].copy_from_slice(&next.btc_txid);
        op[32..].copy_from_slice(&0u32.to_le_bytes());
        current = op;
        tip = Some(next);
    }
    tip
}

/// Parse a `Confirmed` TM datum: Constr tag 122 with fields
/// `[BoundedBytes btcTxid, Array<BoundedBytes> swept, Array<Constr(scriptPubKey, amount)>]`.
/// Returns `(btc_txid, spent_outpoint = swept[0], treasury_value_sat = fulfilled[0].amount)`,
/// or `None` for anything else (Unconfirmed records, garbage datums).
#[must_use]
pub fn parse_confirmed_datum(data: &PlutusData) -> Option<([u8; 32], [u8; 36], u64)> {
    let PlutusData::Constr(c) = data else { return None };
    if c.tag != 122 || c.fields.len() != 3 {
        return None;
    }
    let PlutusData::BoundedBytes(txid_b) = &c.fields[0] else { return None };
    let btc_txid: [u8; 32] = Vec::<u8>::from(txid_b.clone()).try_into().ok()?;
    let PlutusData::Array(swept) = &c.fields[1] else { return None };
    let PlutusData::BoundedBytes(spent_b) = swept.first()? else { return None };
    let spent_outpoint: [u8; 36] = Vec::<u8>::from(spent_b.clone()).try_into().ok()?;
    let PlutusData::Array(fulfilled) = &c.fields[2] else { return None };
    let PlutusData::Constr(out0) = fulfilled.first()? else { return None };
    let PlutusData::BigInt(amount) = out0.fields.get(1)? else { return None };
    let sats: u64 = match amount {
        pallas_primitives::BigInt::Int(i) => u64::try_from(i128::from(*i)).ok()?,
        _ => return None,
    };
    Some((btc_txid, spent_outpoint, sats))
}
```

(Adjust the `BigInt`/`Array` pattern names to the pallas version in `Cargo.lock`; `swept.first()`
on a `MaybeIndefArray` may need `.iter().next()`.)

- [x] **Step 4: Run tests until green**

Run: `cargo test tm_chain`
Expected: PASS.

- [x] **Step 5: config.rs + toml cleanup**

- Delete from `BitcoinConfig`: `treasury_txid`, `treasury_vout`, `treasury_amount_sat` (+ defaults).
  Fix all usages: `rg 'treasury_txid|treasury_vout|treasury_amount_sat' src/` - the SPO daemon
  wiring now has no local treasury override (CLI commands with explicit `--treasury-outpoint`
  flags keep their own args).
- Delete from `CardanoConfig`: `tm_control_ref`.
- Add to `CardanoConfig`:

```rust
    /// Bech32 address of the bridge Config UTxO (the config script address).
    pub config_address: Option<String>,
    /// Config NFT policy id (28-byte hex) + asset name (hex): locates the Config UTxO whose
    /// field 11 anchors the treasury movement chain.
    pub config_nft_policy_id: Option<String>,
    pub config_nft_asset_name: Option<String>,
```

- `heimdall.toml` / `heimdall.testnet4.toml`: remove the deleted keys and their comment blocks;
  add the three new `[cardano]` keys with comments.

- [x] **Step 6: blockfrost_chain.rs rewrite of `query_treasury` + submit tracking**

- Struct: drop `tm_control_ref`; add `config_address: Option<String>`,
  `config_nft_unit: Option<String>` (policy+name concatenated), and
  `last_submitted_txid: Mutex<Option<bitcoin::Txid>>`.
- `with_tm_policy(script_cbor)` loses the control args; add
  `with_config_utxo(address, nft_unit)`.
- New private helper `query_config_anchor(&self) -> EpochResult<[u8; 36]>`: fetch UTxOs at
  `config_address`, find the one whose `amount` contains `config_nft_unit`, decode the inline
  datum Constr, take field 11 as `BoundedBytes` (error if fewer than 12 fields: "config has no
  treasury anchor - run update-config").
- New private helper `query_confirmed_records(&self) -> EpochResult<Vec<tm_chain::ConfirmedTm>>`:
  fetch UTxOs at `treasury_address` whose amount contains the TM NFT unit
  (`treasury_policy_id` + empty name), parse each inline datum with
  `tm_chain::parse_confirmed_datum`, skip `None`s, record `(tx_hash, output_index)` as
  `cardano_utxo`.
- `query_treasury` becomes:

```rust
    async fn query_treasury(&self) -> EpochResult<TreasuryUtxo> {
        use bitcoin::hashes::Hash;
        let anchor = self.query_config_anchor().await?;
        let records = self.query_confirmed_records().await?;
        let tip = tm_chain::walk_chain(anchor, &records);

        let (outpoint, value_sat) = match tip {
            Some(t) => {
                let txid = bitcoin::Txid::from_byte_array(t.btc_txid);
                (bitcoin::OutPoint { txid, vout: 0 }, t.treasury_value_sat)
            }
            None => {
                // Genesis: no TM confirmed yet - the treasury IS the anchor outpoint.
                let txid = bitcoin::Txid::from_byte_array(anchor[..32].try_into().unwrap());
                let vout = u32::from_le_bytes(anchor[32..].try_into().unwrap());
                let sat = self.query_btc_outpoint_value(&txid, vout).await?;
                (bitcoin::OutPoint { txid, vout }, sat)
            }
        };

        // Confirmed gate: our last-submitted TM (if any) must have become the chain tip.
        let last = *self.last_submitted_txid.lock().unwrap();
        let btc_confirmed = match last {
            None => true,
            Some(t) => outpoint.txid == t,
        };

        let maybe_key = *self.treasury_y_51.lock().unwrap();
        Ok(TreasuryUtxo {
            outpoint,
            value: bitcoin::Amount::from_sat(value_sat),
            y_51: maybe_key.unwrap_or(self.treasury_config.y_51),
            y_fed: maybe_key.unwrap_or(self.treasury_config.y_fed),
            federation_csv_blocks: self.treasury_config.federation_csv_blocks,
            fee_rate_sat_per_vb: self.treasury_config.fee_rate_sat_per_vb,
            per_pegout_fee: self.treasury_config.per_pegout_fee,
            btc_confirmed,
        })
    }
```

  `query_btc_outpoint_value` uses the existing `btc_rpc` config
  (`gettxout(txid, vout)` via `crate::cardano::btc_rpc`; add the RPC call there if only
  `sendrawtransaction` exists). Error clearly when `btc_rpc` is unset at genesis.
- In `submit_signed_tm`, after a successful BTC broadcast/publish, record the txid:
  `*self.last_submitted_txid.lock().unwrap() = Some(deserialize::<Transaction>(tx_bytes)... .compute_txid());`
  and pass the mint reference to `build_oracle_update_tx` (next step): the config UTxO
  `(tx_hash, index)` when `walk_chain` returned `None`, else the tip's `cardano_utxo`. Fetch
  these fresh inside `submit_signed_tm` (one `query_config_anchor`-style lookup returning also
  the UTxO ref; extend the helper to return `(anchor, (tx_hash, index))`).

- [x] **Step 7: publish.rs redeemer + reference input**

Replace the `control_ref` parameter of `build_oracle_update_tx` with:

```rust
    // The chain-linkage mint reference: `(tx_hash, index, is_genesis)`. Genesis -> the Config
    // UTxO (redeemer Constr(0, [])); else the predecessor Confirmed TM record (redeemer
    // Constr(1, [0]) - the tx has exactly one reference input, so its sorted index is 0).
    mint_ref: Option<(&str, u32, bool)>,
```

- `reference_inputs`: built from `mint_ref` exactly as before (single `RefTxIn`).
- The mint redeemer data replaces `UNIT_REDEEMER_HEX` when `tm_script_cbor` is `Some`:

```rust
    let mint_redeemer_hex = match (tm_script_cbor, mint_ref) {
        (Some(_), Some((_, _, true))) => {
            hex::encode(minicbor::to_vec(&crate::cardano::plutus::constr(0, vec![])).unwrap())
        }
        (Some(_), Some((_, _, false))) => {
            hex::encode(minicbor::to_vec(&crate::cardano::plutus::constr(1,
                vec![crate::cardano::plutus::int(0)])).unwrap())
        }
        _ => UNIT_REDEEMER_HEX.to_string(),
    };
```

  (Add `plutus::int` if `crate::cardano::plutus` lacks it; mirror `plutus::bytes`.)
- Update the module doc comment: the marker is the real TM NFT gated by chain linkage; the
  always-ok scaffold remains the no-script fallback.

- [x] **Step 8: main.rs wiring**

`apply_tm_policy` (src/main.rs:776-795): drop the `tm_control_ref` pairing logic; when
`tm_script_cbor` is set, require `config_address`/`config_nft_policy_id` set too and call
`chain.with_tm_policy(cbor).with_config_utxo(addr, unit)`.

- [x] **Step 9: Full test run and commit**

Run: `cargo test` and `cargo clippy --all-targets`
Expected: PASS; fix fallout (MockCardanoChain in `src/epoch/` implements the same trait - it
needs no change since `TreasuryUtxo` is unchanged, but any test constructing the removed config
fields does).

```bash
git add -A && git commit -m "feat(treasury): resolve treasury via confirmed TM chain from config anchor"
```

(heimdall may be part of the ft-bifrost-bridge repo - commit wherever `git -C offchain/SPO/heimdall rev-parse --git-dir` points.)

---

### Task 6: Documentation

**Files:**
- Modify: `documentation/technical_documentation.md` (TM sections + config field list)
- Modify: `offchain/SPO/heimdall/Design.md`, `offchain/SPO/heimdall/DecisionsLog.md`
- Modify: binocular docs mentioning TMCTRL / authorized minter (`rg -l 'TMCTRL|authorized.minter' docs/ *.md`)

- [x] **Step 1: technical_documentation.md**

- "Post signed TM": replace the authorized-minter/level-B text with the permissionless
  chain-linkage mint (Genesis/Chain redeemer, checks list from the spec).
- Config datum section: 12-field layout with field 11 `initial_btc_treasury_utxo`.
- TM chain note (around line 1590): now implemented; reference the mint-time enforcement.
- Remove remaining TMCTRL references (the design already calls it vestigial).
- Keep the lean `Confirmed` shape as normative (drop `epoch`/`tm_sequence`/`poster`/
  `leader_reward` from the datum descriptions; note ordering comes from the chain).

- [x] **Step 2: Heimdall Design.md + DecisionsLog.md**

- Design.md section 6.2/4.x: treasury input source is the Confirmed-chain tip (config anchor at
  genesis), not local config.
- New DecisionsLog entry `DEC-022: Treasury resolution via Confirmed TM chain` - context (the
  insecure latest-UTxO scan), decision (chain walk from config field 11; permissionless mint;
  TM Control NFT removed), consequences (local treasury config deleted; `btc_confirmed` =
  own-submitted txid reached the tip).

- [x] **Step 3: Commit**

```bash
git add -A && git commit -m "docs: TM confirmed-chain treasury tracking"
```

---

### Task 7: Preprod migration runbook

**Files:**
- Create: `documentation/tm-chain-migration-runbook.md`

- [x] **Step 1: Write the runbook**

Operator steps (not executable in this session - requires keys):

1. `binocular tm-script` - export the new TM validator; note its script hash (= new TM NFT policy).
2. Apply it as `peg-in.ak`'s `tm_nft_policy_id` parameter; compute the new peg-in script hash and
   withdraw reward account; register the reward account (existing deploy/register tx path).
3. Determine the current unspent treasury outpoint on testnet4 (display txid:vout).
4. `binocular update-config --initial-btc-treasury-utxo TXID:VOUT --peg-in-withdraw-hash <new peg-in hash>`
   signed by the `update_auth` key (oracle owner).
5. Update heimdall config: set `[cardano] config_address`, `config_nft_policy_id`,
   `config_nft_asset_name`, new `treasury_policy_id` (= new TM script hash), `treasury_address`
   (= new TM script address), `tm_script_cbor`; delete removed keys.
6. Complete or re-mint any in-flight peg-ins swept by old-policy TM records BEFORE step 4
   (the new peg-in script only recognizes the new TM NFT policy).
7. Verify: heimdall `query_treasury` resolves the anchor (genesis state), post a TM, watch
   binocular confirm it, verify the next epoch chains from the Confirmed record.

- [x] **Step 2: Commit**

```bash
git add documentation/tm-chain-migration-runbook.md && git commit -m "docs: TM chain preprod migration runbook"
```
