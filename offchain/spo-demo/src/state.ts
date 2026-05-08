import { readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Core } from "@blaze-cardano/sdk";

import type { Config, DemoState } from "./types.js";

function requireEnv(name: string): string {
  const value = process.env[name]?.trim();

  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }

  return value;
}

export function readConfig(): Config {
  return {
    blockfrostProjectId: requireEnv("BLOCKFROST_PREPROD_PROJECT_ID"),
    paymentSeedPhrase: requireEnv("PAYMENT_SEED_PHRASE"),
  };
}

export function masterKeyFromSeedPhrase(seedPhrase: string) {
  const entropy = Core.mnemonicToEntropy(seedPhrase, Core.wordlist);
  return Core.Bip32PrivateKey.fromBip39Entropy(Buffer.from(entropy), "");
}

function statePath(): string {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  return resolve(scriptDir, "../state.json");
}

export async function loadState(): Promise<DemoState> {
  try {
    return JSON.parse(await readFile(statePath(), "utf8")) as DemoState;
  } catch (error: unknown) {
    if (error && typeof error === "object" && "code" in error) {
      const code = (error as { code?: string }).code;

      if (code === "ENOENT") {
        return {};
      }
    }

    throw error;
  }
}

export async function saveState(state: DemoState): Promise<void> {
  await writeFile(`${statePath()}.tmp`, `${JSON.stringify(state, null, 2)}\n`);
  await rename(`${statePath()}.tmp`, statePath());
}
