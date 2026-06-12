import { Blockfrost, Core, HotWallet } from "@blaze-cardano/sdk";

import {
  BAN_NODE_TOKEN_PREFIX,
  UTXO_POLL_ATTEMPTS,
  UTXO_POLL_INTERVAL_MS,
} from "./constants.js";
import type { OutputRef } from "./types.js";

export function scriptAddress(scriptHash: string): Core.Address {
  const credential = Core.Credential.fromCore({
    hash: scriptHash,
    type: Core.Cardano.CredentialType.ScriptHash,
  });

  return Core.addressFromCredential(Core.NetworkId.Testnet, credential);
}

export function scriptCredential(scriptHash: string): Core.Credential {
  return Core.Credential.fromCore({
    hash: scriptHash,
    type: Core.Cardano.CredentialType.ScriptHash,
  });
}

export function scriptRewardAccount(scriptHash: string): Core.RewardAccount {
  return Core.RewardAccount.fromCredential(
    {
      hash: scriptHash,
      type: Core.Cardano.CredentialType.ScriptHash,
    },
    Core.NetworkId.Testnet,
  );
}

export function utxoRef(utxo: Core.TransactionUnspentOutput): OutputRef {
  return {
    txHash: String(utxo.input().transactionId()),
    outputIndex: Number(utxo.input().index()),
  };
}

function compareOutputRefs(left: OutputRef, right: OutputRef): number {
  const txHashOrder = left.txHash.localeCompare(right.txHash);

  if (txHashOrder !== 0) {
    return txHashOrder;
  }

  return left.outputIndex - right.outputIndex;
}

export function ledgerInputIndex(inputs: OutputRef[], target: OutputRef): number {
  const index = [...inputs].sort(compareOutputRefs).findIndex((input) => {
    return (
      input.txHash === target.txHash && input.outputIndex === target.outputIndex
    );
  });

  if (index < 0) {
    throw new Error(`Input ${target.txHash}#${target.outputIndex} missing`);
  }

  return index;
}

export function unitOf(policyId: string, assetName: string): string {
  return `${policyId}${assetName}`;
}

export function faultProofTokenName(
  poolId: string,
  evidenceHash: string,
): string {
  return Core.blake2b_256(Core.HexBlob(`${poolId}${evidenceHash}`));
}

export function banNodeTokenName(poolId: string): string {
  return `${BAN_NODE_TOKEN_PREFIX}${poolId}`;
}

function outputHasAsset(output: Core.TransactionOutput, unit: string): boolean {
  return output.amount().toCore().assets?.get(unit) === 1n;
}

export function outputRefWithAsset(
  tx: Core.Transaction,
  txHash: string,
  address: Core.Address,
  unit: string,
): OutputRef {
  const addressBech32 = address.toBech32();
  const outputIndex = tx
    .body()
    .outputs()
    .findIndex(
      (output) =>
        output.address().toBech32() === addressBech32 &&
        outputHasAsset(output, unit),
    );

  if (outputIndex < 0) {
    throw new Error(`Could not find transaction output containing ${unit}`);
  }

  return { txHash, outputIndex };
}

function outputRefsAtAddress(
  tx: Core.Transaction,
  txHash: string,
  address: Core.Address,
): OutputRef[] {
  const addressBech32 = address.toBech32();

  return tx
    .body()
    .outputs()
    .flatMap((output, outputIndex) =>
      output.address().toBech32() === addressBech32
        ? [{ txHash, outputIndex }]
        : [],
    );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

export async function findWalletUtxo(
  wallet: HotWallet,
  outputRef: OutputRef,
): Promise<Core.TransactionUnspentOutput> {
  for (let attempt = 1; attempt <= UTXO_POLL_ATTEMPTS; attempt += 1) {
    const utxos = await wallet.getUnspentOutputs();
    const utxo = utxos.find((candidate) => {
      const candidateRef = utxoRef(candidate);
      return (
        candidateRef.txHash === outputRef.txHash &&
        candidateRef.outputIndex === outputRef.outputIndex
      );
    });

    if (utxo) {
      return utxo;
    }

    const label = `${outputRef.txHash}#${outputRef.outputIndex}`;
    console.log(`Waiting for UTxO ${label} (${attempt}/${UTXO_POLL_ATTEMPTS})`);
    await sleep(UTXO_POLL_INTERVAL_MS);
  }

  throw new Error(
    `Missing expected wallet UTxO ${outputRef.txHash}#${outputRef.outputIndex}`,
  );
}

export async function waitForWalletOutputsFromTx(
  wallet: HotWallet,
  tx: Core.Transaction,
  txHash: string,
): Promise<void> {
  for (const outputRef of outputRefsAtAddress(tx, txHash, wallet.address)) {
    await findWalletUtxo(wallet, outputRef);
  }
}

export async function findFundingUtxo(
  wallet: HotWallet,
  excludedRefs: OutputRef[] = [],
): Promise<Core.TransactionUnspentOutput> {
  const excluded = new Set(
    excludedRefs.map((ref) => `${ref.txHash}#${ref.outputIndex}`),
  );
  const utxos = await wallet.getUnspentOutputs();
  const [utxo] = utxos
    .filter((candidate) => {
      const ref = utxoRef(candidate);
      return !excluded.has(`${ref.txHash}#${ref.outputIndex}`);
    })
    .sort((left, right) =>
      left.output().amount().coin() > right.output().amount().coin() ? -1 : 1,
    );

  if (!utxo) {
    throw new Error("Could not find a wallet UTxO for fees");
  }

  if (utxo.output().amount().coin() <= 10_000_000n) {
    throw new Error("Funding UTxO is too small for the showcase transaction");
  }

  return utxo;
}

export function addPreEvaluationChange() {
  return async (txBuilder: unknown): Promise<void> => {
    const builder = txBuilder as {
      getAssetSurplus: () => Core.Value;
      adjustChangeOutput: (value: Core.Value) => void;
    };

    builder.adjustChangeOutput(builder.getAssetSurplus());
  };
}

export async function capPlaceholderExUnits(txBuilder: unknown): Promise<void> {
  const builder = txBuilder as { redeemers: Core.Redeemers };

  for (const redeemer of builder.redeemers.values()) {
    redeemer.setExUnits(new Core.ExUnits(2_000_000n, 1_000_000_000n));
  }
}

export async function findScriptUtxo(
  provider: Blockfrost,
  address: Core.Address,
  unit: string,
): Promise<Core.TransactionUnspentOutput> {
  for (let attempt = 1; attempt <= UTXO_POLL_ATTEMPTS; attempt += 1) {
    const utxos = await provider.getUnspentOutputs(address).catch((error) => {
      const message = error instanceof Error ? error.message : String(error);

      if (message.includes("has not been found")) {
        return [];
      }

      throw error;
    });
    const utxo = utxos.find((candidate) =>
      outputHasAsset(candidate.output(), unit),
    );

    if (utxo) {
      return utxo;
    }

    console.log(
      `Waiting for script UTxO ${unit} (${attempt}/${UTXO_POLL_ATTEMPTS})`,
    );
    await sleep(UTXO_POLL_INTERVAL_MS);
  }

  throw new Error(`Missing expected script UTxO containing ${unit}`);
}

export async function findScriptUtxoByRef(
  provider: Blockfrost,
  address: Core.Address,
  outputRef: OutputRef,
): Promise<Core.TransactionUnspentOutput> {
  for (let attempt = 1; attempt <= UTXO_POLL_ATTEMPTS; attempt += 1) {
    const utxos = await provider.getUnspentOutputs(address).catch((error) => {
      const message = error instanceof Error ? error.message : String(error);

      if (message.includes("has not been found")) {
        return [];
      }

      throw error;
    });
    const utxo = utxos.find((candidate) => {
      const candidateRef = utxoRef(candidate);
      return (
        candidateRef.txHash === outputRef.txHash &&
        candidateRef.outputIndex === outputRef.outputIndex
      );
    });

    if (utxo) {
      return utxo;
    }

    const label = `${outputRef.txHash}#${outputRef.outputIndex}`;
    console.log(
      `Waiting for script UTxO ${label} (${attempt}/${UTXO_POLL_ATTEMPTS})`,
    );
    await sleep(UTXO_POLL_INTERVAL_MS);
  }

  throw new Error(
    `Missing expected script UTxO ${outputRef.txHash}#${outputRef.outputIndex}`,
  );
}
