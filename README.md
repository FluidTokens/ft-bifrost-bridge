# bifrost-bridge

Bitcoin desperately needs a safe and expressive DeFi layer. Cardano, thanks to its properties such as the eUTxO architecture and being highly decentralised, is strongly well-positioned to become the best BTC Defi Layer among the top 10 blockchains.

Bitcoin users and Liquidity Providers strongly require that the bridge between Bitcoin and Cardano must be practically unbreakable, must not suffer from liveness problems, and must not add additional security assumptions.

The current most known bridge implementation is Cardinal by IOG, a superb implementation of the BitVM framework into the Cardano ecosystem. While an incredible work of art, it suffers of the following pain points: there’s a 1-of-n trust assumption where the 1 honest player must burn his secret key (extremely difficult to prove); only a finite set of pre-chosen operators can execute the peg-out process (liveness problems); you can only peg-out the exact same amount of BTC that you have pegged-in.

After almost 2 years of research and trials, we propose a similar but alternative product whose approach aims to remove these pain points, leveraging the unique properties of Cardano: eUTxO-model, SPOs consensus and being an independent strong Layer 1.
