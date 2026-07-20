# Bifrost Bridge – new preprod deployment (for the FluidTokens demo)

**Date:** 2026-07-17 · **Cardano:** preprod · **Bitcoin:** testnet4

We redeployed the bridge on preprod with the **updatable config** + **delegated
fSAT** model. This note gives you everything needed to point the demo at the new
bridge. The full transaction-building delta (mint redeemer, datum layout, peg-in
/ peg-out flows) is in [`fsat-config-tx-migration.md`](./fsat-config-tx-migration.md) –
this note is the concrete deployment on top of it.

## The one rule: read hashes from the live config datum

Do not hardcode script hashes or policy ids. Locate the **config UTxO by its
NFT**, read the inline `ConfigDatum` (11 positional fields), and take every
peg / MPF / verifier hash from it. The config is updatable in place, so a cached
or blueprint-derived hash can go stale. The identifiers below are the current
values so you can bootstrap and sanity-check.

- **Config NFT:** policy `f3ef1414e881dd501a2d25350f6d24c4a2c2cd0f1e5ccfd4d7be143f`,
  asset name `424946434647` (`"BIFCFG"`)
- **Config address:** `addr_test1wre779q5azqa65q695jn2rmdynz29skdpu09en7567lpg0c4swv42`

Find the UTxO at that address holding that NFT, decode its inline datum, and use
its fields. For peg-in / peg-out txs you only **reference** this UTxO (never spend it).

## Deployed identifiers (preprod, 2026-07-17)

| Component | Policy id / script hash | Asset name (hex) | Address |
|---|---|---|---|
| Config NFT | `f3ef1414e881dd501a2d25350f6d24c4a2c2cd0f1e5ccfd4d7be143f` | `424946434647` (BIFCFG) | `addr_test1wre779q5azqa65q695jn2rmdynz29skdpu09en7567lpg0c4swv42` |
| **fSAT** (bridged_token) | `2c7d729c70de0d2d6f093dfee86f48edbea1dfce167cdeb79ecb8d19` | `66534154` (fSAT) | – (minting policy) |
| completed-peg-ins (MPF) | `c4800f2c3ccb2ae2e62386415f45d2cb54ab8374d722f68a0db67df1` | `435049` (CPI) | `addr_test1wrzgqrev8n9j4chxywryzh696t94f2urwntj9a52pkm8mugjnvxnf` |
| completed-peg-outs (MPF) | `4689c54beb1978cf3f869ab406e70588098e0d713944ccee8a168175` | `43504f` (CPO) | `addr_test1wprgn32tavvh3nels6dtgph8qkyqnrsdwyu5fn8w3gtgzag44zaam` |
| peg_in withdraw script | `665b33b752eceeae9b5fa77efcaba1341e847dfe2941a8f384264b87` | – | reward account (registered) |
| peg_out withdraw script | `0a89de7a3970b87c75810b0d4770b2061cae92ea444a9466439e1b5d` | – | reward account (registered) |
| peg_out produced verifier | `015c0539b554593ffcccb9678ebf5d37940d05df466a6ce2892b301e` | – | reward account (registered) |
| TM-control NFT | `690823ae40e8b1bbfab5291a24f5256e25ce18bdc94f1aa0de9f6865` | `544d4354524c` (TMCTRL) | at the config address |

These map onto the `ConfigDatum` fields as: `[0]` fSAT policy, `[1]` fSAT asset
name, `[2]` cpi policy, `[3]` cpo policy, `[4]` peg_in withdraw, `[5]` peg_out
withdraw, `[7]` produced verifier. `[6]`/`[8]` are dormant (a dummy hash with no
reward account, so their `Cancel` paths are unsatisfiable). `[10]` `update_auth`
is a Cardano signature by `9c87f0a90fcedee0a3b0fbbb6102c8e504b7e0459cf01ee4a31d63ac`.

Bootstrap tx (all 4 NFTs minted in one atomic tx):
`97153ce17a7c08177309b8e0769f8068224b28bb95eac78be62af6ee6ef259ef`.

## Reference scripts (CIP-33) – use these to keep txs small

| Script | Reference UTxO |
|---|---|
| peg_in | `3b32e89fcde21291b651f07c1a4382df6d22347ea20ef69855d51a605c905386#0` |
| bridged_token (fSAT) | `a248781068ed119d81a9f998c35e283c6ed26847755d90d7267be8cf4739c651#0` |
| completed_peg_ins | `25c5cccab0a66fbdd6dd6de8ea9ab577891f0ccbd8e19e953797278db243c63c#0` |
| peg_out | `b4b3bb51dc7b44a69d932d2b4f3d70efc69dd04bfd65b215bb10788f757cbe98#0` |
| completed_peg_outs | `37a5f27270b619389e9ddc17ba61eb66e93fb69065e533bf7845b3ac93dbffcd#0` |

## Binocular oracle (Bitcoin inclusion proofs)

- **Oracle policy:** `83d66490b8660a266fb663c3362a2ad0da3cb5ad339036305045bb3c`
- **Oracle address:** `addr_test1wzpaveyshpnq5fn0ke3uxd329tgd509445eeqd3s2pzmk0qg9xn5l`
- **Confirmed range:** testnet4 blocks **136600 → 144450** are committed in the
  oracle's confirmed root, so a deposit in any of those blocks is provable now.
  The oracle advances forward from there as it syncs.

Peg-in completion still references the config UTxO + the confirmed-TM UTxO and
proves the deposit against the oracle's confirmed-blocks MPF – unchanged in shape.

## What the demo must change vs the old bridge

1. **Token: fBTC → fSAT.** Asset name comes from `config[1]` (`66534154`). 1 token
   = 1 satoshi. Don't hardcode.
2. **`bridged_token` mint redeemer** is `{ config_ref_input_index: Int }` – a single
   field pointing at the config reference input. The old
   `wanted_peg_withdraw_redeemer_index` is gone. `bridged_token` is a presence
   delegator: minting requires the `peg_in` withdrawal present (config[4]),
   burning requires the `peg_out` withdrawal present (config[5]). It does not
   inspect the peg redeemer.
3. **cpi/cpo asset names are the constants `"CPI"` / `"CPO"`** (`435049` / `43504f`),
   not `sha256(one_shot)`. Locate the MPF UTxOs by `config[2]`/`config[3]` policy +
   these constant names.
4. **All new policy ids / addresses** – swap in the table above (or, better, derive
   them from the config datum + these anchors).
5. **Peg-out burns the full locked amount** (`mint == −(locked fSAT)`), gated by the
   `peg_out` withdrawal + the produced verifier (config[7]).

Withdrawals are otherwise unchanged: peg-in uses the single `peg_in` withdrawal
(`CompletePegIn`); peg-out uses `peg_out` (`CompletePegOut`) + the produced verifier.

## Networks / endpoints

- Cardano **preprod**; Bitcoin **testnet4**.
- The config is updatable (`update_auth` = the bridge owner key), so treat the
  on-chain datum as the source of truth and refresh from it rather than pinning a
  blueprint.

Ping us if you want the datum CBOR of the live config UTxO, or a worked
peg-in / peg-out example against these addresses.
