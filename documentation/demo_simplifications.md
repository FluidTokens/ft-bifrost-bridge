# Demo Simplifications

Simplifications of the specificaion to make the testnet demo easier to understand and use. These are not intended to be permanent changes to the specification, but rather temporary simplifications for the purpose of the demo.

## Pegin Taproot

$Y_federation || $Alice_vk + 5 days timeout (720 blocks)

## Treasury Taproot

$Y_federation

## fBTC minting policy

1. Check TMTx inclusion
2. Check Alice's signature
3. Check PIR amount to mint
4. Check PIR non-inclusion? (Raul, is this necessary?)
5. Check update of completed PIRs (Raul, is this necessary?)