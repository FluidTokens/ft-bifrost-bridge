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
