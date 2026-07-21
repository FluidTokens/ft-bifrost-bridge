import { Core } from "@blaze-cardano/sdk";

import {
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

function listData(items: Core.PlutusData[]): Core.PlutusData {
  const list = new Core.PlutusList();

  for (const item of items) {
    list.add(item);
  }

  return Core.PlutusData.newList(list);
}

function emptyListData(): Core.PlutusData {
  return listData([]);
}

function boolData(value: boolean): Core.PlutusData {
  return constrData(value ? 1 : 0, []);
}

function bytesListData(values: string[]): Core.PlutusData {
  return listData(values.map(bytesData));
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
  banUntilTime: number,
  permanent: boolean,
  evidenceHashes: string[],
): Core.PlutusData {
  return linkedListNodeDatum(
    constrData(0, [
      intData(banCounter),
      intData(banUntilTime),
      boolData(permanent),
      bytesListData(evidenceHashes),
    ]),
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
  accusedPoolId: string;
  evidenceHash: string;
  banAnchorInputIndex: number;
  banAnchorOutputIndex: number;
  existingBanInputIndex?: number;
  banNodeOutputIndex: number;
}): Core.PlutusData {
  return constrData(0, [
    intData(args.faultInputIndex),
    intData(args.registrationRefInputIndex),
    bytesData(args.accusedPoolId),
    bytesData(args.evidenceHash),
    intData(args.banAnchorInputIndex),
    intData(args.banAnchorOutputIndex),
    args.existingBanInputIndex === undefined
      ? optionNoneData()
      : optionSomeInt(args.existingBanInputIndex),
    intData(args.banNodeOutputIndex),
  ]);
}

export function equivocationPublishRedeemer(args: {
  registrationRefInputIndex: number;
  poolId: string;
  payloadA: string;
  signatureA: string;
  payloadB: string;
  signatureB: string;
  evidenceHash: string;
}): Core.PlutusData {
  return constrData(0, [
    constrData(0, [
      intData(args.registrationRefInputIndex),
      bytesData(args.poolId),
      bytesData(args.payloadA),
      bytesData(args.signatureA),
      bytesData(args.payloadB),
      bytesData(args.signatureB),
      bytesData(args.evidenceHash),
    ]),
  ]);
}

export function faultProofBurnRedeemer(): Core.PlutusData {
  return constrData(1, []);
}
