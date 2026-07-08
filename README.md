# Bifrost Bridge

Bitcoin desperately needs a safe and expressive DeFi layer. Cardano, thanks to its properties such as the eUTxO architecture and being highly decentralised, is strongly well-positioned to become the best BTC Defi Layer among the top 10 blockchains.

Bitcoin users and Liquidity Providers strongly require that the bridge between Bitcoin and Cardano must be practically unbreakable, must not suffer from liveness problems, and must not add additional security assumptions.

The current most known bridge implementation is Cardinal by IOG, a superb implementation of the BitVM framework into the Cardano ecosystem. While an incredible work of art, it suffers of the following pain points: there’s a 1-of-n trust assumption where the 1 honest player must burn his secret key (extremely difficult to prove); only a finite set of pre-chosen operators can execute the peg-out process (liveness problems); you can only peg-out the exact same amount of BTC that you have pegged-in.

After almost 2 years of research and trials, we propose a similar but alternative product whose approach aims to remove these pain points, leveraging the unique properties of Cardano: eUTxO-model, SPOs consensus and being an independent strong Layer 1.

## Cloning

This repository uses git submodules:

- the [binocular](https://github.com/lantr-io/binocular) watchtower lives at `offchain/bitcoin-watchtower/binocular`
- the [heimdall](https://github.com/lantr-io/heimdall) SPO program lives at `offchain/SPO/heimdall`

Clone with submodules included:

```bash
git clone --recurse-submodules https://github.com/FluidTokens/ft-bifrost-bridge
```

If you already cloned without `--recurse-submodules`, initialize them with:

```bash
git submodule update --init --recursive
```
## Regarding Milestone 3 Proof of Achievement

Initially, we aimed to submit "Code of Zero Knowledge logic to prove the Bitcoin transactions". During the development of Bifrost, we discovered that Zero Knowledge proofs were not needed to prove Bitcoin transactions. Instead we use a more efficient system of Merkle Tree Proof Inclusions/Exclusions, basically proving that a Bitcoin transaction has happened only if its hash has been added to the Merkle Tree of Bitcoin Transactions.

Merkle Tree proofs are much more easy to understand, a standard in the crypto industry and require less resources than any possible Zero Knowledge proof.

We still do use Zero Knowledge proofs to prove SPOs bad behaviour and to punish them accordingly.

This is NOT a change of the scope of Catalyst project, it's a design choice. ZK proofs and Merkle Tree inclusion proofs are in this case equivalent, except that MerkleTree proofs are much more efficient and fast. The output is the same to what was promised, and as said we still use ZK proofs in another part of the protocol.
Therefore NO Change Request is necessary.
