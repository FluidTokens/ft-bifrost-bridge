import { schnorr } from "@noble/curves/secp256k1";
import { Core } from "@blaze-cardano/sdk";

import {
  DEMO_BIFROST_PRIVATE_KEY,
  DEMO_BIFROST_URL,
  DEMO_COLD_PRIVATE_KEY,
} from "./constants.js";

export function registrationMessage(
  poolId: string,
  bifrostIdPk: string,
  bifrostUrl: string,
): string {
  const domain = Buffer.from("bifrost-spo", "utf8").toString("hex");
  return `${domain}${poolId}${bifrostIdPk}${bifrostUrl}`;
}

function revocationMessage(poolId: string): string {
  return `${Buffer.from("bifrost-revoke", "utf8").toString("hex")}${poolId}`;
}

function utf8Hex(value: string): string {
  return Buffer.from(value, "utf8").toString("hex");
}

function u64beHex(value: bigint): string {
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64BE(value);
  return bytes.toString("hex");
}

function dkgRound1Payload(poolId: string, variant: number): string {
  const tag = utf8Hex("bifrost-dkg-r1");
  const epoch = u64beHex(1n);
  const threshold = u64beHex(51n);
  const attempt = u64beHex(0n);
  const commitment = `02${variant.toString(16).padStart(2, "0").repeat(32)}`;
  const sigma = variant.toString(16).padStart(2, "0").repeat(64);
  const evidenceHash = (variant + 16).toString(16).padStart(2, "0").repeat(32);
  return `${tag}${epoch}${threshold}${attempt}${poolId}${commitment}${sigma}${evidenceHash}`;
}

function lengthPrefixed(hex: string): string {
  return `${u64beHex(BigInt(hex.length / 2))}${hex}`;
}

function equivocationEvidenceHash(payloadA: string, payloadB: string): string {
  const domain = utf8Hex("bifrost-fault-equiv-v1");
  const [first, second] =
    Buffer.compare(Buffer.from(payloadA, "hex"), Buffer.from(payloadB, "hex")) >
    0
      ? [payloadB, payloadA]
      : [payloadA, payloadB];
  return Core.blake2b_256(`${domain}${lengthPrefixed(first)}${lengthPrefixed(second)}`);
}

async function signBifrostPayload(payload: string): Promise<string> {
  return Core.toHex(
    await schnorr.sign(Core.sha2_256(payload), DEMO_BIFROST_PRIVATE_KEY),
  );
}

export function firstMpfInsertRoot(key: string, value: string): string {
  const path = Core.blake2b_256(key);
  const valueHash = Core.blake2b_256(value);
  return Core.blake2b_256(`ff${path}${valueHash}`);
}

export async function demoSpoIdentity(): Promise<{
  bifrostIdPk: string;
  bifrostSig: string;
  coldSig: string;
  coldVkey: string;
  poolId: string;
}> {
  const coldVkey = Core.derivePublicKey(DEMO_COLD_PRIVATE_KEY);
  const poolId = Core.blake2b_224(coldVkey);
  const bifrostIdPk = Core.toHex(schnorr.getPublicKey(DEMO_BIFROST_PRIVATE_KEY));
  const message = registrationMessage(poolId, bifrostIdPk, DEMO_BIFROST_URL);
  const coldSig = Core.signMessage(message, DEMO_COLD_PRIVATE_KEY);
  const bifrostSig = Core.toHex(
    await schnorr.sign(Core.sha2_256(message), DEMO_BIFROST_PRIVATE_KEY),
  );

  return {
    bifrostIdPk,
    bifrostSig,
    coldSig,
    coldVkey,
    poolId,
  };
}

export async function demoSpoRevocation(): Promise<{
  coldSig: string;
  coldVkey: string;
  poolId: string;
}> {
  const coldVkey = Core.derivePublicKey(DEMO_COLD_PRIVATE_KEY);
  const poolId = Core.blake2b_224(coldVkey);
  const coldSig = Core.signMessage(
    revocationMessage(poolId),
    DEMO_COLD_PRIVATE_KEY,
  );

  return {
    coldSig,
    coldVkey,
    poolId,
  };
}

export async function demoDkgEquivocationEvidence(): Promise<{
  evidenceHash: string;
  payloadA: string;
  payloadB: string;
  poolId: string;
  signatureA: string;
  signatureB: string;
}> {
  const { poolId } = await demoSpoIdentity();
  const payloadA = dkgRound1Payload(poolId, 1);
  const payloadB = dkgRound1Payload(poolId, 2);

  return {
    evidenceHash: equivocationEvidenceHash(payloadA, payloadB),
    payloadA,
    payloadB,
    poolId,
    signatureA: await signBifrostPayload(payloadA),
    signatureB: await signBifrostPayload(payloadB),
  };
}
