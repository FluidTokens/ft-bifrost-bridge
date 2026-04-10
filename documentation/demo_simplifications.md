# Demo Simplifications

Simplifications of the specificaion to make the testnet demo easier to understand and use. These are not intended to be permanent changes to the specification, but rather temporary simplifications for the purpose of the demo.

## Federation Verification Key

$Y_{federation}$ = 02b1e15a532a4e816ec75af608256b0808e36fb7d22560605178850885e53f2854

## Pegin Taproot

$Y_{federation}$ || Alice_vk + 5 days timeout (720 blocks)

## Treasury Taproot

$Y_{federation}$

## Cardano Treasury Movement UTxO

Minting policy: ??? (alwaysOK script for demo purposes)
Asset Name: "TMTx"

## fBTC minting policy

1. Check TMTx inclusion
2. Check Alice's signature
3. Check PIR amount to mint
4. Check PIR non-inclusion? (Raul, is this necessary?)
5. Check update of completed PIRs (Raul, is this necessary?)
