# Treasury Movement Confirmed-Chain Design

Date: 2026-07-20
Status: Approved

## Problem

The Bitcoin treasury outpoint is currently configured locally in heimdall
(`heimdall.toml` `[bitcoin] treasury_txid/vout/amount_sat`) and the "current"
treasury on Cardano is resolved by picking the most recent datum-bearing UTxO at
the TM address (`blockfrost_chain.rs query_treasury`). Both are insecure:

- The on-chain `TreasuryMovementValidator` never verifies *which* Bitcoin UTXO a
  posted TM transaction spends (explicit TODO at
  `TreasuryMovementValidator.scala:104-111` and `:296`). A syntactically valid
  but unrelated Bitcoin tx with a valid inclusion proof can become `Confirmed`.
- TM posting is gated by the TMCTRL one-shot NFT plus a single
  `authorizedMinter` key, a centralized level-B stopgap.
- Heimdall's "latest UTxO at the address" resolution is attacker-influenceable
  once minting is opened up, and its `btc_confirmed` polling loop can be
  deadlocked by a fake Unconfirmed tip.

`technical_documentation.md:1590-1604` already describes the intended fix (a TM
chain anchored at a genesis outpoint, TMCTRL vestigial), but the Variant B
config rebuild dropped the `genesis_treasury_utxo_id` field and the validator
never implemented the chain.

## Design

### Core idea

Every Treasury Movement record proves, at mint time, that its embedded Bitcoin
transaction spends the protocol's treasury outpoint: either the initial anchor
stored in the Config UTXO (first TM) or output 0 of a referenced predecessor
`Confirmed` TM record (every subsequent TM). Minting becomes permissionless.

**Chain uniqueness is inherited from Bitcoin, not enforced on Cardano.** A
Bitcoin outpoint spends exactly once, so among all TM records chaining from a
given predecessor, at most one can ever produce a valid inclusion proof and
become `Confirmed`. The Confirmed chain cannot fork. Garbage records (unsigned
txs, stale predecessors) can be minted by anyone but can never confirm, and
off-chain consumers follow only the Confirmed chain. No on-chain "tip" tracking
is needed.

### 1. On-chain: `TreasuryMovementValidator` (Scalus, binocular)

Parameterization changes from `(oracleScriptHash, controlNftPolicy,
controlNftName)` to `(oracleScriptHash, configNftPolicy, configNftName)`.
Deleted: `TmControlDatum`, `findControlInput`, the `authorizedMinter` signature
check, and the TMCTRL one-shot mint in `DeployBridgeCommand`.

New mint redeemer:

```scala
enum TmMintRedeemer derives FromData, ToData:
    case Genesis                            // first TM: anchor from Config UTXO
    case Chain(prevTmRefInputIndex: BigInt) // subsequent: anchor from predecessor
```

Mint branch (`minted > 0`) checks, in order:

1. Exactly +1 of the TM NFT minted (empty asset name), as today.
2. Locate the unique transaction output carrying the TM NFT. Require its
   payment credential to be the TM script hash itself and its inline datum to
   decode as `Unconfirmed(signedBtcTx)`. This binding is implicit today via the
   minter key and must be explicit once minting is permissionless: without it, a
   minted NFT could ride an output whose datum embeds an unverified tx.
3. Parse the first input's outpoint from `signedBtcTx`: 36 bytes, txid in
   internal byte order followed by 4-byte little-endian vout. The treasury is
   input 0 by the deterministic TM layout (heimdall `tm_builder.rs`,
   technical documentation "Treasury Movement Transaction").
4. Linkage:
   - `Genesis`: find the config reference input by `(configNftPolicy,
     configNftName)`, read config field 11, require bytes-equality with the
     parsed outpoint.
   - `Chain(i)`: the reference input at index `i` must carry the TM NFT
     (own policy, empty asset name, qty 1) and a `Confirmed(btcTxid, _, _)`
     datum; require the parsed outpoint `== btcTxid ++ 0x00000000` (the
     treasury output is output 0 by convention).

Byte order needs no conversion: `BitcoinHelpers.getTxHash` returns internal
order txids, exactly what outpoint serialization uses.

Burn (`minted < 0`) stays permissionless cleanup, unchanged. The spend
(Confirm) path is unchanged: linkage is a property of the bytes committed at
mint, so re-checking at confirm is redundant. The step-6 TODO
("Treasury-State UTxO address check") is closed by mint-time linkage.

Out of scope (existing TODOs kept): burning the NFT of stale `Unconfirmed`
records (posters lock their own min-ADA; no protocol-security impact) and
cleanup of old `Confirmed` records.

### 2. On-chain: Aiken

- `onchain/lib/bifrost/types/config.ak`: append
  `initial_btc_treasury_utxo: ByteArray` as field 11 of `ConfigDatum` (36-byte
  outpoint, txid in internal byte order; display txid must be reversed when
  configuring). Add positional getter `get_initial_btc_treasury_utxo` at
  index 11 and extend the `config_getters_match_datum_fields` pin test.
- `onchain/validators/bitcoin/config.ak`: no source change. The Update path is
  shape-evolvable by design; the genesis bootstrap's typed parse simply expects
  the 12-field shape for fresh deployments.
- `onchain/validators/bitcoin/peg-in.ak`: no source change. Only the applied
  `tm_nft_policy_id` parameter value changes (the new TM script hash), which
  yields a new peg-in script hash and reward account.
- Peg-out, bridged-token (fSAT), CPI/CPO, and the oracle are untouched: they
  bind only to the config NFT and read hashes from config at runtime.

### 3. Off-chain: Binocular

- `ConfigTypes.scala`: mirror field 11 (`initialBtcTreasuryUtxo: ByteString`).
- `TreasuryMovementValidator.scala`: as in section 1, plus scaladoc rewrite.
- `BridgeConfig.scala`: drop `tmControlNftPolicy`, `tmControlNftName`,
  `tmAuthorizedMinter`; add the initial treasury outpoint setting for deploys.
- `DeployBridgeCommand`: drop the TMCTRL one-shot and control UTxO; genesis
  config datum gains field 11.
- New `UpdateConfigCommand`: builds the config `Update` transaction for the
  live migration (append field 11, swap field 4), signed by `update_auth`.
- `TmScriptCommand`: export with the new parameterization.
- `ConfirmTmtxCommand`: unchanged logic; optionally skip Unconfirmed records
  whose linkage cannot hold, to avoid wasted confirm attempts.
- `CreateTmtxCommand` (test scaffold): mint via the real policy with the new
  redeemer.

### 4. Off-chain: Heimdall

- `config.rs`: delete `[bitcoin] treasury_txid/vout/amount_sat` and
  `[cardano] tm_control_ref`; add config-NFT identification fields
  (policy id + asset name). `tm_script_cbor` stays (needed to mint). CLI
  commands that take explicit `--treasury-outpoint` flags keep them for manual
  use.
- `blockfrost_chain.rs query_treasury` rewrite: read the config UTXO (by config
  NFT) for the field-11 anchor; fetch TM-address UTxOs carrying the TM NFT with
  `Confirmed` datums; index them by the outpoint they spend (input 0 of the
  embedded tx, equal to `sweptPegInUtxoIds[0]`); walk the chain from the anchor
  to the tip. Current treasury = tip's `(btcTxid, vout 0)` with value
  `fulfilledPegOuts[0].amount`. The genesis amount comes from bitcoind
  `gettxout`. The "latest UTxO at the address" resolution is removed.
- `publish.rs`: mint with the `Genesis`/`Chain` redeemer and the corresponding
  reference input (config UTXO or predecessor Confirmed record) instead of the
  control ref.
- `machine.rs`: the `btc_confirmed` gate becomes "the chain tip is Confirmed"
  (same semantics, trustworthy source).

### 5. Migration of the deployed preprod bridge (no redeployment)

One config `Update` transaction, authorized by the current `update_auth`
(oracle owner key):

- appends field 11 set to the current actual unspent treasury outpoint on
  testnet4 (the anchor is "initial" from the new chain's perspective), and
- swaps field 4 (`peg_in_withdraw_script_hash`) to the new peg-in hash.

The same or a companion transaction registers the new peg-in reward account.
Config NFT, fSAT policy, CPI/CPO, peg-out, and the oracle keep their hashes and
UTxOs. Old TM records and the TMCTRL UTxO are abandoned.

Migration note: peg-ins swept by old-policy TM records must be completed before
the switch; the new peg-in script only recognizes the new TM NFT policy.

Recovery property: `update_auth` can re-point field 11 later (e.g. after an
emergency federation sweep), re-anchoring the chain without touching anything
else.

### 6. Testing

- Scalus unit tests for the mint branch: Genesis and Chain happy paths; wrong
  outpoint; missing or wrong reference input (no config NFT / no TM NFT /
  Unconfirmed predecessor); NFT not bound to a TM-address output; wrong datum
  on the NFT output; +2 mint; multi-output smuggling attempts.
- Confirm-path tests unchanged; keep passing.
- Aiken: pin test for getter index 11; `aiken check` green.
- Heimdall: unit tests for the chain walk (garbage Unconfirmed ignored,
  competing children of one predecessor, tip selection, genesis resolution).

### 7. Documentation

- `documentation/technical_documentation.md`: align the TM sections and config
  field list with the implemented scheme. The doc already describes the chain
  design; it gets the concrete datum/redeemer shapes and the 12-field config.
- Deliberate deviation from the current doc text: the `Confirmed` datum keeps
  the lean code shape (`btcTxid, sweptPegInUtxoIds, fulfilledPegOuts`), without
  `epoch`/`tm_sequence`/`poster`/`leader_reward`. The chain provides ordering,
  so the doc is aligned to the code, not vice versa.
- Heimdall `Design.md` update + new DecisionsLog entry (chain-walk treasury
  resolution, removal of local treasury config).
- Binocular docs where they mention TMCTRL / authorized minter.

## Addendum (2026-07-20): TM record provenance and grace-period GC

Supersedes the "out of scope" note above for Confirmed-record cleanup.

- `TmDatum` gains provenance on both variants: `creator` (the poster's payment
  key hash) and `created` (POSIX ms), carried verbatim through the Confirm
  transition.
- A `Confirmed` record becomes spendable by its creator after a 30-day grace
  period (`created + 30d`): the spend must burn the TM NFT, be signed by the
  creator, and have a validity interval entirely after the deadline. By then
  all swept peg-ins / fulfilled peg-outs are expected to be completed, so the
  record is no longer needed as proof material and its min-ADA is reclaimed.
- `created` is anchored at mint: it must EQUAL the tx's finite validity
  upper bound (`created == validRange.to`), making it a guaranteed upper
  bound on the real posting time — a permissionless poster cannot backdate
  `created` to shortcut the timer (future-dating only delays their own GC).
- The mint additionally requires the TM NFT (empty asset name) to be the ONLY
  asset name touched under the TM policy in the tx.
- Operational rule (accepted residual risk): the creator must not GC the
  chain-TIP record — the next TM's `Chain` mint references it. While active,
  a successor lands well within the grace period; after a >30-day quiet
  spell, recovery is a config Update re-anchoring `initial_btc_treasury_utxo`.
- Off-chain: heimdall posts `[signed_btc_tx, creator = wallet pkh,
  created = (latest block time + 1800) * 1000 ms]` with `invalid_hereafter =
  latest slot + 1800` (created equals the upper-bound slot's begin time
  exactly); binocular's confirm carries creator/created into the Confirmed
  datum; parsers accept the extended shapes.
- Stale `Unconfirmed` records remain unreclaimable (unchanged).
