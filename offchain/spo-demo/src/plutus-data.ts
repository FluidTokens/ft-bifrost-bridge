import { Core } from "@blaze-cardano/sdk";

import {
  DEMO_FAULT_EVIDENCE_HASH,
  DEMO_FAULT_NAMESPACE_HASH,
  DEMO_BIFROST_URL,
  DEMO_SPOS_FROST_KEY,
  DEMO_TREASURY_ADDRESS,
  DEMO_TREASURY_UTXO_ID,
  EMPTY_MPF_ROOT,
} from "./constants.js";
import type { OutputRef } from "./types.js";

export function bytesData(hex: string): Core.PlutusData {
  return Core.PlutusData.newBytes(Core.fromHex(hex));
}

export function intData(value: number | bigint): Core.PlutusData {
  return Core.PlutusData.newInteger(BigInt(value));
}

export function constrData(
  alternative: number,
  fields: Core.PlutusData[],
): Core.PlutusData {
  const list = new Core.PlutusList();

  for (const field of fields) {
    list.add(field);
  }

  return Core.PlutusData.newConstrPlutusData(
    new Core.ConstrPlutusData(BigInt(alternative), list),
  );
}

export function outputRefData(outputRef: OutputRef): Core.PlutusData {
  return constrData(0, [
    bytesData(outputRef.txHash),
    intData(outputRef.outputIndex),
  ]);
}

export function hashOutputRef(outputRef: OutputRef): string {
  return Core.sha2_256(outputRefData(outputRef).toCbor());
}

export function optionNoneData(): Core.PlutusData {
  return constrData(1, []);
}

function optionSomeBytes(value: string): Core.PlutusData {
  return constrData(0, [bytesData(value)]);
}

function optionSomeInt(value: number): Core.PlutusData {
  return constrData(0, [intData(value)]);
}

function emptyListData(): Core.PlutusData {
  return Core.PlutusData.newList(new Core.PlutusList());
}

function linkedListRootDatum(
  rootData: Core.PlutusData,
  link: Core.PlutusData = optionNoneData(),
): Core.PlutusData {
  return constrData(0, [constrData(0, [rootData]), link]);
}

function linkedListNodeDatum(
  nodeData: Core.PlutusData,
  link: Core.PlutusData = optionNoneData(),
): Core.PlutusData {
  return constrData(0, [constrData(1, [nodeData]), link]);
}

export function treasuryMintRedeemer(inputRef: OutputRef): Core.PlutusData {
  return constrData(0, [
    outputRefData(inputRef),
    bytesData(DEMO_TREASURY_ADDRESS),
    bytesData(DEMO_TREASURY_UTXO_ID),
    bytesData(DEMO_SPOS_FROST_KEY),
  ]);
}

export function treasuryDatum(): Core.PlutusData {
  return constrData(0, [
    bytesData(EMPTY_MPF_ROOT),
    bytesData(DEMO_TREASURY_ADDRESS),
    bytesData(DEMO_TREASURY_UTXO_ID),
    bytesData(DEMO_SPOS_FROST_KEY),
  ]);
}

export function treasurySpendRedeemer(
  newIdentityRoot: string,
): Core.PlutusData {
  return constrData(0, [
    intData(0),
    bytesData(newIdentityRoot),
    bytesData(DEMO_TREASURY_ADDRESS),
    bytesData(DEMO_TREASURY_UTXO_ID),
    bytesData(DEMO_SPOS_FROST_KEY),
  ]);
}

export function treasuryDatumWithIdentityRoot(
  identityRoot: string,
): Core.PlutusData {
  return constrData(0, [
    bytesData(identityRoot),
    bytesData(DEMO_TREASURY_ADDRESS),
    bytesData(DEMO_TREASURY_UTXO_ID),
    bytesData(DEMO_SPOS_FROST_KEY),
  ]);
}

export function registryBootstrapRedeemer(): Core.PlutusData {
  return constrData(0, []);
}

export function registryRootDatum(): Core.PlutusData {
  return linkedListRootDatum(constrData(0, []));
}

export function continuedRegistryRootDatum(poolId: string): Core.PlutusData {
  return linkedListRootDatum(constrData(0, []), optionSomeBytes(poolId));
}

export function registrationSpendRedeemer(): Core.PlutusData {
  return constrData(0, []);
}

export function registrationNodeDatum(bifrostIdPk: string): Core.PlutusData {
  return linkedListNodeDatum(
    constrData(0, [bytesData(bifrostIdPk), bytesData(DEMO_BIFROST_URL)]),
  );
}

export function registrationMintRedeemer(args: {
  coldVkey: string;
  coldSig: string;
  bifrostSig: string;
  registrationAnchorInputIndex: number;
  registrationAnchorOutputIndex: number;
  treasuryInputIndex: number;
  treasuryOutputIndex: number;
}): Core.PlutusData {
  return constrData(1, [
    bytesData(args.coldVkey),
    bytesData(args.coldSig),
    bytesData(args.bifrostSig),
    intData(args.registrationAnchorInputIndex),
    intData(args.registrationAnchorOutputIndex),
    intData(args.treasuryInputIndex),
    intData(args.treasuryOutputIndex),
    emptyListData(),
  ]);
}

export function deregistrationMintRedeemer(args: {
  coldVkey: string;
  coldSig: string;
  registrationInputIndex: number;
  registrationAnchorInputIndex: number;
  registrationAnchorOutputIndex: number;
  treasuryInputIndex: number;
  treasuryOutputIndex: number;
}): Core.PlutusData {
  return constrData(2, [
    bytesData(args.coldVkey),
    bytesData(args.coldSig),
    intData(args.registrationInputIndex),
    intData(args.registrationAnchorInputIndex),
    intData(args.registrationAnchorOutputIndex),
    intData(args.treasuryInputIndex),
    intData(args.treasuryOutputIndex),
    emptyListData(),
  ]);
}

export function banBootstrapRedeemer(inputRef: OutputRef): Core.PlutusData {
  return constrData(0, [outputRefData(inputRef)]);
}

export function banRootDatum(): Core.PlutusData {
  return linkedListRootDatum(constrData(0, []));
}

export function continuedBanRootDatum(poolId: string): Core.PlutusData {
  return linkedListRootDatum(constrData(0, []), optionSomeBytes(poolId));
}

export function banNodeDatum(
  banCounter: number,
  banUntilEpoch: number,
): Core.PlutusData {
  return linkedListNodeDatum(
    constrData(0, [intData(banCounter), intData(banUntilEpoch)]),
  );
}

export function banMintRedeemer(args: {
  withdrawRedeemerIndex: number;
  poolId: string;
}): Core.PlutusData {
  return constrData(1, [
    intData(args.withdrawRedeemerIndex),
    bytesData(args.poolId),
  ]);
}

export function banSpendRedeemer(
  withdrawRedeemerIndex: number,
): Core.PlutusData {
  return constrData(0, [intData(withdrawRedeemerIndex)]);
}

export function banWithdrawRedeemer(args: {
  faultInputIndex: number;
  registrationRefInputIndex: number;
  banAnchorInputIndex: number;
  banAnchorOutputIndex: number;
  existingBanInputIndex?: number;
  banNodeOutputIndex: number;
  currentEpoch: number;
}): Core.PlutusData {
  return constrData(0, [
    intData(args.faultInputIndex),
    intData(args.registrationRefInputIndex),
    intData(args.banAnchorInputIndex),
    intData(args.banAnchorOutputIndex),
    args.existingBanInputIndex === undefined
      ? optionNoneData()
      : optionSomeInt(args.existingBanInputIndex),
    intData(args.banNodeOutputIndex),
    intData(args.currentEpoch),
  ]);
}

export function faultProofDatum(): Core.PlutusData {
  return constrData(0, [
    constrData(0, []),
    bytesData(DEMO_FAULT_NAMESPACE_HASH),
    bytesData(DEMO_FAULT_EVIDENCE_HASH),
  ]);
}

export function faultProofPublishRedeemer(args: {
  inputRef: OutputRef;
  poolId: string;
  epoch: number;
}): Core.PlutusData {
  return constrData(0, [
    outputRefData(args.inputRef),
    bytesData(args.poolId),
    intData(args.epoch),
    faultProofDatum(),
  ]);
}

export function faultProofBurnRedeemer(): Core.PlutusData {
  return constrData(1, []);
}
