# SPO Contract Showcase

This script demonstrates the zkFold-owned SPO contract flows on Cardano Preprod:

- SPO registration
- SPO deregistration
- FaultProof publication
- SPO banning

The treasury script is used only as supporting protocol state where the registry
contracts require it.

The script is resumable. It records submitted transaction references in
`state.json`, which is ignored by Git, and skips completed steps on the next run.

## Configuration

Copy `.env.example` to `.env` and fill in the local values:

```sh
cp .env.example .env
```

Required values:

- `BLOCKFROST_PREPROD_PROJECT_ID`: local Blockfrost project token.
- `PAYMENT_SEED_PHRASE`: funded Preprod wallet seed phrase used to submit demo transactions.

`PAYMENT_SEED_PHRASE` is the wallet mnemonic as words separated by spaces, with
no commas. Quotes are optional in `.env`.

Do not commit `.env`. The repository ignores local `.env` files.

## Run

```sh
npm install
npm run demo
```

The script is intentionally linear and commented so each transaction maps back to
one protocol step.

## Code Layout

- `src/demo.ts`: top-level setup and showcase orchestration.
- `src/transactions.ts`: transaction builders for each protocol step.
- `src/plutus-data.ts`: datum and redeemer constructors.
- `src/chain.ts`: Cardano/Blockfrost utility helpers.
- `src/scripts.ts`: blueprint loading and validator parameterization.
