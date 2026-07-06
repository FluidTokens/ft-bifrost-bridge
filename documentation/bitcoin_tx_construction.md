# Bifrost — Bitcoin transaction construction (peg-in & peg-out)

Self-contained wire-level specification for building the two Bitcoin transactions of the Bifrost
bridge **with standard Bitcoin libraries only** — no Bifrost tooling required. If you can build a
Taproot output and sign a SegWit input, you can build these from this document alone.

A worked example with every intermediate value is given at the end so you can validate your
implementation byte-for-byte before broadcasting.

> **Standards used:** BIP141 (segwit v0 funding inputs), BIP340 (Schnorr), BIP341 (Taproot output
> key tweak), BIP342 (tapscript), BIP112 (`OP_CHECKSEQUENCEVERIFY`), BIP350 (bech32m addresses),
> BIP322 (simple message signing — depositor authorization at completion).

---

## 0. Deployment values (this bridge instance — Cardano preprod / Bitcoin testnet4)

### 0.1 Bitcoin side — all you need for the peg-in deposit (§1)

| name | value | notes |
|---|---|---|
| Bitcoin network | **testnet4** | bech32m HRP `tb` |
| **Y_51** (FROST group x-only pubkey) | `b1e15a532a4e816ec75af608256b0808e36fb7d22560605178850885e53f2854` | Taproot **internal key** of every peg-in P2TR — the bridge's FROST group key, read from the on-chain treasury state. (Future: the internal key becomes a `Y_fed`/`Y_51` multisig — still published as one aggregate key.) |
| `refund_timeout` | **720** | relative-timelock (blocks) of the depositor's refund leaf |
| beacon tag | `BFR` = `0x42 0x46 0x52` | marks a peg-in to the watchtower |
| BTC treasury | `Taproot(Y_51, Y_fed fallback leaf)` | where the federation sweeps your deposit — *informational*; not needed to build the deposit |

The §1 deposit needs **only** the Bitcoin-side values above. Note `Y_fed` (the federation
fallback key) is **not** among them: a depositor builds the peg-in and PegInRequest from `Y_51` +
their own key alone — `Y_fed` is federation-side only (it appears solely as the treasury fallback
leaf in §2).

### 0.2 Cardano side — for the peg-in Cardano txs (PegInRequest → pegin-complete)

A party without binocular builds these with a Cardano SDK (e.g. **Mesh**); they need every script
hash / policy id / asset name / address below. (Aiken multi-purpose validators: policy id == script
hash == validator hash — one hash per contract. These are the **applied** hashes, i.e. on-chain.)

| contract / value | hash · policy id | asset name (hex) | script address |
|---|---|---|---|
| oracle `BitcoinValidator` | `9d2eaf5737f7552c3e38cabc0f7d0e9b4258c0ee9e913dfbbc51dd85` | — | — |
| `config.config` (bridge identity) | `d15dfdeb263cb49a386a42c0072129638f8d0ab311e1790c1de301af` | `424946434647` (BIFCFG) | `addr_test1wrg4ml0tyc7tfx3cdfpvqpep993clrg2kvg7z7gvrh3srtc8d4099` |
| `bridged_token` (fBTC) | `2a8be579950b9df37fa611daeaecedd0ebb69b40278ff01e6fc5763a` | `66425443` (fBTC) | — |
| `peg_in_validator` | `d4104c6acc86c39378058dbd207df49c2ad84bb8d926db8034f2e628` | NFT = `sha2_256(serialiseData(input_ref))` | `addr_test1wr2pqnr2ejrv8ymcqkxm6gra7jwz4kzthrvjdkuqxnewv2qqrj525` |
| `peg_out_validator` | `5ab900beafc455418076a6c41f08db2271f9dfb2c8b1d6fa419fa799` | — | — |
| peg-out produced-verifier | `015c0539b554593ffcccb9678ebf5d37940d05df466a6ce2892b301e` | — | — |
| `completed_peg_ins_merkle_tree` | `53911d1a926314f3071dc047d13eba1d56b08fc8fe0a25c4f70071a1` | `08b9c5306ecbd482aa444d557a0d9e4c4349698bd8998fbb40683887bb1bc1e2` | `addr_test1wpfez8g6jf33fuc8rhqy05f7hgw4dvy0erlq5fwy7uq8rggeznz75` |
| `completed_peg_outs_merkle_tree` | `a2cecef8314bfbed5c55c96c37390728a9ca541bba68faf076d9cbd1` | `302950984b9116b8380618f0b74d3ddaaca9ba67088f46c330736e97968caba3` | `addr_test1wz3vanhcx99lhm2u2hykcdeequ52njj5rwax37hswmvuh5gnzx3l7` |
| `treasury_movement` (TM NFT) | `4c40ffd5746c87c6fc84fa7785e20c36ac87c948fea009baa7b2154b` | — | — |
| `tm_control` | `9cfb3edc2da0d77bbca40bb441b566fa7f3db2c2b72a42518154dc10` | `544d4354524c` (TMCTRL) | — |

**CIP-33 reference-script UTxOs** (attach as reference inputs instead of inlining the scripts):
`peg_in 0250b6c3199c421de92d3d3fb949f55c3da73df6f8e625f28e8fe6358aecac86#0` ·
`bridged_token 909b17d198a233182d6d4afff0452facf1aba19bc032093ae68a5899826d372c#0` ·
`completed_peg_ins 3a50e643e482b84bbe471b0691bf545095017da82933b77c66bbd270c36a762d#0` ·
`peg_out 6cded3ffae43813d8b883eff264924c792ac63f50bb758653ee8d0b6a79d32b9#0` ·
`completed_peg_outs 1c3f3abafb6ddd69e9f9143a9290b7c7fd068b08833755d894f08f5ab47b1ada#0`

**MPF one-shot seeds** (parameterize the two MPF policies; their NFT asset name =
`sha2_256(serialiseData(outpoint))`): `completed_peg_ins 84478f05…#3` · `completed_peg_outs deaf1c33…#1`.

---

## 1. Peg-in deposit transaction (you build this)

A peg-in deposit is an ordinary Bitcoin transaction you fund and sign yourself, with a specific
output layout:

```
Input  0..N : your funding UTXO(s) — P2WPKH you control (standard segwit-v0 signing)
Output 0    : peg-in P2TR  (value = deposit_amount_sat)        ← the locked funds
Output 1    : OP_RETURN beacon  (value = 0)                     ← marks it as a peg-in
Output 2    : change back to you  (optional)
```

The watchtower identifies your deposit by the **BFR beacon** and the **Y_51 peg-in P2TR**; build the
outputs in the order above (the reference depositor does).

### 1.1 The depositor key

Pick a secp256k1 keypair you control. Let `D` = its 32-byte **x-only** public key, and let `Q_auth`
= the **key-path Taproot output key** of that key (BIP341/BIP86 tweak, empty script tree):

```
t       = taggedHash("TapTweak", D)
Q_auth  = x_only( lift_x(D) + t·G )      # the witness program of your tb1p… Taproot address
```

Keep the private key — you will need it to complete the peg-in. It is used in three places:

1. the refund leaf (below) — uses **`D`** (the raw x-only key);
2. the OP_RETURN beacon (below) — carries **`Q_auth`** (the Taproot output key);
3. a **BIP-322** signature at completion time, made **from your Taproot address whose output key is
   `Q_auth`** (e.g. UniSat's `signMessage(text, "bip322-simple")`). The bridge operator gives you the
   exact text to sign — of the form `BFR-mint-v1:<64-hex>`, where the hex is
   `sha256("BFR-mint-v1" ‖ tm_txid ‖ peg_in_utxo_id ‖ recipient)`. The contract verifies that
   BIP-322 signature against `Q_auth` (read from the beacon). No raw-key access needed — any wallet
   that signs BIP-322 for a Taproot address works.

The funding inputs may use any P2WPKH key(s); only `D` / `Q_auth` must match across the places above.

> **Decoupling auth from funding.** By default `Q_auth` is the funding key's own Taproot output key.
> To authorize the mint from a *different* wallet (e.g. a UniSat Taproot you'll BIP-322-sign with),
> pass its output key: `pegin_deposit.py --auth-output-key <Q_auth-hex>`. The beacon then carries
> that key (so completion is signed by that wallet), while the refund leaf + funding stay with `D`.

### 1.2 Output 0 — the peg-in P2TR

A Taproot output with internal key **Y_51** (the bridge's FROST group key) and a single tapleaf =
your refund script. (Today the internal key is `Y_51` alone; a future revision makes it a
`Y_fed`/`Y_51` multisig, published as one aggregate internal key — so this construction is unchanged.)

**Refund leaf script** (lets *you* reclaim the funds after `refund_timeout` blocks if the federation
never sweeps them):

```
<refund_timeout>  OP_CHECKSEQUENCEVERIFY  OP_DROP  <D>  OP_CHECKSIG
```

Encoded (leaf version **0xc0**, tapscript):

| bytes | meaning |
|---|---|
| `02 d0 02` | push minimal `CScriptNum(720)` (LE `d0 02`, 2 bytes, pushed with `OP_PUSHBYTES_2`) |
| `b2` | `OP_CHECKSEQUENCEVERIFY` |
| `75` | `OP_DROP` |
| `20` ‖ `D` | `OP_PUSHBYTES_32` ‖ 32-byte depositor x-only key |
| `ac` | `OP_CHECKSIG` |

**Tweak to the output key** (BIP341, single-leaf tree → merkle root = the leaf hash):

```
leaf_hash = taggedHash("TapLeaf",  0xc0 ‖ compactSize(len(leaf)) ‖ leaf)
t         = taggedHash("TapTweak", Y_51 ‖ leaf_hash)              # 32 bytes, as scalar
Q         = lift_x(Y_51) + t·G                                    # output point
output_key = x_only(Q)                                            # 32 bytes
```

`taggedHash(tag, m) = SHA256(SHA256(tag) ‖ SHA256(tag) ‖ m)`.

**Output 0 scriptPubKey** = `OP_1 OP_PUSHBYTES_32 <output_key>` = `5120 ‖ output_key`.
(Equivalently the bech32m address `tb1p…` of `output_key`.)

### 1.3 Output 1 — the OP_RETURN beacon

```
scriptPubKey = OP_RETURN OP_PUSHBYTES_35 ("BFR" ‖ Q_auth)
             = 6a 23 42 46 52 ‖ Q_auth       (37 bytes)
value        = 0
```

`23` = 35 = 3 ("BFR") + 32 (the depositor **Taproot output key** `Q_auth`). This is how the watchtower
finds the peg-in and learns the key that must authorize completion (via BIP-322). Note the beacon
carries `Q_auth`, while the refund leaf above carries the raw x-only `D` — both are derived from
your one private key.

### 1.4 Inputs, change, fee

Standard: spend P2WPKH UTXO(s) you control, sign each with `SIGHASH_ALL` (BIP143). Send the
remainder minus fee to a change output. Keep `deposit_amount + fee ≤ inputs`.

### 1.5 After broadcast

1. Wait until the deposit block is **40-confirmations matured** in the binocular oracle (the bridge's
   challenge window). 2. The bridge operator mints the Cardano `PegInRequest`, an SPO sweeps your
deposit into the treasury, the sweep matures, and the operator asks you for the BIP-322 signature
(§1.1) — `signMessage("BFR-mint-v1:<64-hex>", "bip322-simple")` from your `Q_auth` Taproot address.
fBTC equal to your deposit (minus protocol fee) is then minted to your Cardano address.

---

## 2. Peg-out payout transaction (the federation builds this; you receive + verify)

A peg-out is **initiated on Cardano** (you lock fBTC at the `peg_out.ak` script with a destination
Bitcoin scriptPubKey). That step needs Cardano tooling — it is not a Bitcoin transaction. The
**Bitcoin** side is the **Treasury Movement (TM)**: one transaction the federation builds and
FROST-signs that both rolls the treasury forward and pays every pending peg-out. You cannot build it
(it spends the federation treasury), but its structure is fully determined so you can verify your
payout:

```
Input  0    : current treasury UTXO — Taproot(Y_51, Y_fed fallback leaf), spent KEY-PATH under Y_51 (FROST Schnorr)
            : (+ any peg-in deposits being swept in the same TM)
Output 0    : new treasury  Taproot(Y_51, Y_fed fallback leaf)   ← change; absorbs the Bitcoin miner fee
Output 1..k : one per peg-out:  <destination_scriptPubKey>  value = gross − per_pegout_protocol_fee
```

- **Treasury output is always index 0.**
- Peg-out outputs are emitted in a **deterministic order** (sorted by destination scriptPubKey, then
  amount) so every SPO produces byte-identical TM bytes — a hard requirement for FROST signing. See
  technical_documentation.md §"Treasury Movement" for the exact fee parameters.
- Your payout = the gross amount you locked on Cardano, minus the fixed per-peg-out protocol fee; the
  treasury change absorbs the miner fee.

To take part in a peg-out you therefore supply only a **destination address** and verify the TM pays
it; the fBTC burn + completion happen on Cardano.

---

## 3. Worked example (validate your implementation against this)

Demo depositor `bob`, refund_timeout 720, testnet4:

```
Y_51 (internal key)   : b1e15a532a4e816ec75af608256b0808e36fb7d22560605178850885e53f2854
depositor key  D      : 65ebd441bb9cb02321d0c4f7c522bc39fe45af64b80a1a51a454735b2d06740f

refund leaf script    : 02d002b2752065ebd441bb9cb02321d0c4f7c522bc39fe45af64b80a1a51a454735b2d06740fac
TapLeaf hash (= root) : cf3d9b05de39d0d25323fc4991eabcb5bb7ffbc40c6ad5b0dd553d6a8a818888
TapTweak  t           : 0aff914a006659e2fd4df5097289d01aa0f344a6c56ea804d1b05fdf240af070
output key            : 86d66ec42088de122a3b2b8d28eac3fc6bd629b214964a37bb63d6ac55efde32

Output 0 scriptPubKey : 512086d66ec42088de122a3b2b8d28eac3fc6bd629b214964a37bb63d6ac55efde32
Output 0 address      : tb1psmtxa3pq3r0py23m9wxj36krl34av2djzjty5damv0t2c400mceqhw5r3y
auth output key Q_auth: 0f8ace03f92db5cc44e558e350278cda0917a02d968bcac801f89d9e000fd164
auth P2TR address     : tb1pp79vuqle9k6uc389tr34qfuvmgy30gpdj69u4jqplzweuqq069jqh4zu8n
Output 1 scriptPubKey : 6a234246520f8ace03f92db5cc44e558e350278cda0917a02d968bcac801f89d9e000fd164
```

If your code reproduces `output key` / `Output 0 address` from `Y_51`, `D`, and `refund_timeout =
720` — and `Q_auth` / the beacon from `D` — your peg-in construction is correct. `Q_auth` is the
key-path tweak of bob's `D`; the depositor signs the BIP-322 completion from `auth P2TR address`.
(The earlier live demo deposit `e3adb511…` carried the legacy raw-`D` beacon, before BIP-322.)

---

## 4. Reference implementation

`pegin_deposit.py` (this directory) is a ~220-line **pure-stdlib** Python implementation of §1 — it
derives the peg-in P2TR, builds the deposit, signs the P2WPKH input (BIP143), and broadcasts it. It
was validated against this document: it reproduces bob's `tb1pd9t8dzz…` address, and its signed
transaction passes `bitcoind testmempoolaccept` (`allowed: true`).

```sh
python3 pegin_deposit.py --wif-file your.wif --amount 3000 --fee 1000 --test    # build + validate, no broadcast
python3 pegin_deposit.py --wif-file your.wif --amount 3000 --fee 1000 --submit  # broadcast
```

Edit the constants at the top (the internal-key constant — set it to the **Y_51** group key —
`RPC_URL`/creds, `HRP`) for a different deployment/network.

---

## 5. Example transactions (this deployment — inspect real ones)

Explorers: Bitcoin `https://mempool.space/testnet4/tx/<hash>` · Cardano
`https://preprod.cardanoscan.io/transaction/<hash>`.

### Peg-in
| step | chain | txid | status |
|---|---|---|---|
| deposit (§1) | testnet4 | `e3adb511c105f5b9a82ba13b0420e30408bebe2f4873d9c7d063a0f27b0ebeca` | ✅ confirmed (2,500 sat to peg-in P2TR + BFR beacon) |
| PegInRequest mint | preprod | `← pending (deposit maturing, 40 confs)` | |
| sweep Treasury Movement | testnet4 | `← pending` | |
| pegin-complete (fBTC mint) | preprod | `← pending` | |

### Peg-out
| step | chain | txid | status |
|---|---|---|---|
| peg-out-request (lock fBTC) | preprod | `← pending` | |
| payout Treasury Movement | testnet4 | `← pending` | |
| peg-out-complete (burn fBTC) | preprod | `← pending` | |

### Bridge setup (for reference)
Config NFT mint `1bd21ea5baf2dc98dfd026c895af72d12acd01aa40bab1d40371827028186103` (the deploy); the
fBTC/peg-in/peg-out/MPF policies and the 5 CIP-33 reference-script UTxOs are listed in §0.2. Full
11-tx setup ledger: see the internal runbook `2026-06-23-pegin-create-runbook.md`.

> The `← pending` rows fill in as the live run clears each maturation gate; the deposit above is a
> complete, inspectable peg-in §1 example today.
