# Bifrost — Bitcoin transaction construction (peg-in & peg-out)

Self-contained wire-level specification for building the two Bitcoin transactions of the Bifrost
bridge **with standard Bitcoin libraries only** — no Bifrost tooling required. If you can build a
Taproot output and sign a SegWit input, you can build these from this document alone.

A worked example with every intermediate value is given at the end so you can validate your
implementation byte-for-byte before broadcasting.

> **Standards used:** BIP141 (segwit v0 funding inputs), BIP340 (Schnorr), BIP341 (Taproot output
> key tweak), BIP342 (tapscript), BIP112 (`OP_CHECKSEQUENCEVERIFY`), BIP350 (bech32m addresses).

---

## 0. Network constants (this demo deployment)

| name | value | notes |
|---|---|---|
| Bitcoin network | **testnet4** | bech32m HRP `tb` |
| **Y_fed** (federation x-only pubkey) | `0ce472ae5d8993e7609ee4ef33b344f6b8499a1259374bdf528f82240985bf03` | the Taproot **internal key** of every peg-in P2TR. Demo key (derived from the all-`0xfe` seed); in production it comes from the on-chain treasury oracle. |
| `refund_timeout` | **720** | relative-timelock (blocks) of the depositor's refund leaf |
| beacon tag | `BFR` = `0x42 0x46 0x52` | marks a peg-in to the watchtower |

You do **not** need any Cardano value (config-NFT policy/asset name, fBTC policy, etc.) to build the
Bitcoin transaction — those live only on the Cardano side and are irrelevant here.

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

The watchtower identifies your deposit by the **BFR beacon** and the **federation P2TR**; build the
outputs in the order above (the reference depositor does).

### 1.1 The depositor key

Pick a secp256k1 keypair you control; let `D` = its 32-byte **x-only** public key. The **same** key
is used in three places, so keep its private key — you will need it again to complete the peg-in:

1. the refund leaf (below),
2. the OP_RETURN beacon (below),
3. a BIP340 signature at completion time (the bridge operator gives you a 32-byte digest to sign;
   the message is `sha256("BFR-mint-v1" ‖ tm_txid ‖ peg_in_utxo_id ‖ recipient)`).

The funding inputs may use any P2WPKH key(s); only `D` must match across the three places above.

### 1.2 Output 0 — the peg-in P2TR

A Taproot output with internal key **Y_fed** and a single tapleaf = your refund script.

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
t         = taggedHash("TapTweak", Y_fed ‖ leaf_hash)             # 32 bytes, as scalar
Q         = lift_x(Y_fed) + t·G                                   # output point
output_key = x_only(Q)                                            # 32 bytes
```

`taggedHash(tag, m) = SHA256(SHA256(tag) ‖ SHA256(tag) ‖ m)`.

**Output 0 scriptPubKey** = `OP_1 OP_PUSHBYTES_32 <output_key>` = `5120 ‖ output_key`.
(Equivalently the bech32m address `tb1p…` of `output_key`.)

### 1.3 Output 1 — the OP_RETURN beacon

```
scriptPubKey = OP_RETURN OP_PUSHBYTES_35 ("BFR" ‖ D)
             = 6a 23 42 46 52 ‖ D            (37 bytes)
value        = 0
```

`23` = 35 = 3 ("BFR") + 32 (the depositor x-only key). This is how the watchtower finds the peg-in
and learns `D`.

### 1.4 Inputs, change, fee

Standard: spend P2WPKH UTXO(s) you control, sign each with `SIGHASH_ALL` (BIP143). Send the
remainder minus fee to a change output. Keep `deposit_amount + fee ≤ inputs`.

### 1.5 After broadcast

1. Wait until the deposit block is **40-confirmations matured** in the binocular oracle (the bridge's
   challenge window). 2. The bridge operator mints the Cardano `PegInRequest`, an SPO sweeps your
deposit into the treasury, the sweep matures, and the operator asks you for the BIP340 signature
(§1.1). fBTC equal to your deposit (minus protocol fee) is then minted to your Cardano address.

---

## 2. Peg-out payout transaction (the federation builds this; you receive + verify)

A peg-out is **initiated on Cardano** (you lock fBTC at the `peg_out.ak` script with a destination
Bitcoin scriptPubKey). That step needs Cardano tooling — it is not a Bitcoin transaction. The
**Bitcoin** side is the **Treasury Movement (TM)**: one transaction the federation builds and
FROST-signs that both rolls the treasury forward and pays every pending peg-out. You cannot build it
(it spends the federation treasury), but its structure is fully determined so you can verify your
payout:

```
Input  0    : current treasury UTXO — P2TR(Y_fed), spent KEY-PATH (BIP341 key spend, FROST Schnorr)
            : (+ any peg-in deposits being swept in the same TM)
Output 0    : new treasury  P2TR(Y_fed)   ← change; absorbs the Bitcoin miner fee
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
Y_fed (internal key)  : 0ce472ae5d8993e7609ee4ef33b344f6b8499a1259374bdf528f82240985bf03
depositor key  D      : 65ebd441bb9cb02321d0c4f7c522bc39fe45af64b80a1a51a454735b2d06740f

refund leaf script    : 02d002b2752065ebd441bb9cb02321d0c4f7c522bc39fe45af64b80a1a51a454735b2d06740fac
TapLeaf hash (= root) : cf3d9b05de39d0d25323fc4991eabcb5bb7ffbc40c6ad5b0dd553d6a8a818888
TapTweak  t           : 4657d3f908b7bce83b0ca8c823fd94d07ce0ee62263331dca934ae7df4d916e9
output key            : 6956768857b4d72e146afafd9f2835210dd558788ca50933431af27488ab5162

Output 0 scriptPubKey : 51206956768857b4d72e146afafd9f2835210dd558788ca50933431af27488ab5162
Output 0 address      : tb1pd9t8dzzhkntju9r2lt7e72p4yyxa2krc3jjsjv6rrte8fz9t293qerys8g
Output 1 scriptPubKey : 6a2342465265ebd441bb9cb02321d0c4f7c522bc39fe45af64b80a1a51a454735b2d06740f
```

If your code reproduces `output key` / `Output 0 address` from `Y_fed`, `D`, and `refund_timeout =
720`, your peg-in P2TR construction is correct. (A second independent confirmation: the live demo
deposit `e3adb511…` paid the analogous P2TR derived from depositor `karl`.)

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

Edit the constants at the top (`Y_FED`, `RPC_URL`/creds, `HRP`) for a different deployment/network.
