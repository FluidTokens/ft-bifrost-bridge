import "dotenv/config";

import { readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { schnorr } from "@noble/curves/secp256k1";
import { Type } from "@sinclair/typebox";
import {
  Blaze,
  Blockfrost,
  Core,
  HotWallet,
  applyParamsToScript,
  cborToScript,
  makeValue,
  type NetworkName,
} from "@blaze-cardano/sdk";

const NETWORK: NetworkName = "cardano-preprod";

const REQUIRED_VALIDATORS = [
  "bitcoin/spos_registry.spo_registry.mint",
  "bitcoin/spos_registry.spo_registry.spend",
  "bitcoin/fault_verifier.fault_verifier.mint",
  "bitcoin/spo_bans.spo_bans.mint",
  "bitcoin/spo_bans.spo_bans.spend",
  "bitcoin/spo_bans.spo_bans.withdraw",
] as const;

const SUPPORTING_VALIDATORS = [
  "bitcoin/treasury.treasury_info.mint",
  "bitcoin/treasury.treasury_info.spend",
] as const;

const SHOWCASE_STEPS = [
  "Create bootstrap nonce UTxOs",
  "Parameterize registry, treasury, fault verifier, and ban scripts",
  "Bootstrap supporting treasury state",
  "Bootstrap SPO registry state",
  "Bootstrap SPO ban-list state",
  "Register SPO ban withdraw credential",
  "Register demo SPO",
  "Publish mocked FaultProof",
  "Apply first ban",
  "Deregister demo SPO",
] as const;

const BOOTSTRAP_NONCE_LOVELACE = 3_000_000n;
const TREASURY_BOOTSTRAP_LOVELACE = 3_000_000n;
const UTXO_POLL_INTERVAL_MS = 5_000;
const UTXO_POLL_ATTEMPTS = 24;
const EMPTY_MPF_ROOT = "00".repeat(32);
const DEMO_TREASURY_ADDRESS = "01".repeat(32);
const DEMO_TREASURY_UTXO_ID = "02".repeat(32);
const DEMO_SPOS_FROST_KEY = "03".repeat(32);
const REGISTRY_ROOT_TOKEN_NAME = Buffer.from("reg-root", "utf8").toString("hex");
const BAN_ROOT_TOKEN_NAME = Buffer.from("ban-root", "utf8").toString("hex");
const DEMO_COLD_PRIVATE_KEY = "11".repeat(32);
const DEMO_BIFROST_PRIVATE_KEY = "04".repeat(32);
const DEMO_BIFROST_URL = Buffer.from(
  "https://spo.demo.zkfold.io",
  "utf8",
).toString("hex");
const DEMO_FAULT_EPOCH = 0;
const DEMO_FAULT_NAMESPACE_HASH = "05".repeat(32);
const DEMO_FAULT_EVIDENCE_HASH = "06".repeat(32);
const BAN_NODE_TOKEN_PREFIX = Buffer.from("ban/", "utf8").toString("hex");

type Config = {
  blockfrostProjectId: string;
  paymentSeedPhrase: string;
};

type BlueprintValidator = {
  title: string;
  compiledCode: string;
  hash: string;
};

type Blueprint = {
  validators: BlueprintValidator[];
};

type OutputRef = {
  txHash: string;
  outputIndex: number;
};

type BootstrapNonces = {
  registry: OutputRef;
  bans: OutputRef;
  treasury: OutputRef;
};

type ScriptHashes = {
  registryPolicyId: string;
  faultProofPolicyId: string;
  treasuryPolicyId: string;
  bansPolicyId: string;
};

type ParameterizedScripts = {
  registry: Core.Script;
  faultVerifier: Core.Script;
  treasury: Core.Script;
  bans: Core.Script;
};

type DemoState = {
  bootstrapNonces?: BootstrapNonces;
  scriptHashes?: ScriptHashes;
  treasuryBootstrapTxHash?: string;
  treasuryStateRef?: OutputRef;
  registryBootstrapTxHash?: string;
  registryRootRef?: OutputRef;
  bansBootstrapTxHash?: string;
  bansRewardRegistrationTxHash?: string;
  banRootRef?: OutputRef;
  registrationTxHash?: string;
  registrationNodeRef?: OutputRef;
  demoPoolId?: string;
  faultProofTxHash?: string;
  faultProofRef?: OutputRef;
  faultProofEpoch?: number;
  banTxHash?: string;
  banNodeRef?: OutputRef;
  deregistrationTxHash?: string;
};

const registryParamsType = Type.Tuple([Type.String(), Type.Number()]);
const treasuryParamsType = Type.Tuple([Type.String()]);
const bansParamsType = Type.Tuple([
  Type.String(),
  Type.String(),
  Type.String(),
  Type.Number(),
]);

function applyScriptParams(
  compiledCode: string,
  typeSchema: unknown,
  params: unknown,
): string {
  // Blaze's generic schema type is narrower than TypeBox tuples in TS 5.8.
  const applyParams = applyParamsToScript as (
    plutusScript: string,
    type: unknown,
    params: unknown,
  ) => string;

  return applyParams(compiledCode, typeSchema, params);
}

function bytesData(hex: string): Core.PlutusData {
  return Core.PlutusData.newBytes(Core.fromHex(hex));
}

function intData(value: number | bigint): Core.PlutusData {
  return Core.PlutusData.newInteger(BigInt(value));
}

function constrData(
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

function outputRefData(outputRef: OutputRef): Core.PlutusData {
  return constrData(0, [
    bytesData(outputRef.txHash),
    intData(outputRef.outputIndex),
  ]);
}

function hashOutputRef(outputRef: OutputRef): string {
  return Core.sha2_256(outputRefData(outputRef).toCbor());
}

function treasuryMintRedeemer(inputRef: OutputRef): Core.PlutusData {
  return constrData(0, [
    outputRefData(inputRef),
    bytesData(DEMO_TREASURY_ADDRESS),
    bytesData(DEMO_TREASURY_UTXO_ID),
    bytesData(DEMO_SPOS_FROST_KEY),
  ]);
}

function treasuryDatum(): Core.PlutusData {
  return constrData(0, [
    bytesData(EMPTY_MPF_ROOT),
    bytesData(DEMO_TREASURY_ADDRESS),
    bytesData(DEMO_TREASURY_UTXO_ID),
    bytesData(DEMO_SPOS_FROST_KEY),
  ]);
}

function optionNoneData(): Core.PlutusData {
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

function registryBootstrapRedeemer(): Core.PlutusData {
  return constrData(0, []);
}

function registryRootDatum(): Core.PlutusData {
  return linkedListRootDatum(constrData(0, []));
}

function continuedRegistryRootDatum(poolId: string): Core.PlutusData {
  return linkedListRootDatum(constrData(0, []), optionSomeBytes(poolId));
}

function registrationSpendRedeemer(): Core.PlutusData {
  return constrData(0, []);
}

function registrationNodeDatum(bifrostIdPk: string): Core.PlutusData {
  return linkedListNodeDatum(
    constrData(0, [bytesData(bifrostIdPk), bytesData(DEMO_BIFROST_URL)]),
  );
}

function banBootstrapRedeemer(inputRef: OutputRef): Core.PlutusData {
  return constrData(0, [outputRefData(inputRef)]);
}

function banRootDatum(): Core.PlutusData {
  return linkedListRootDatum(constrData(0, []));
}

function continuedBanRootDatum(poolId: string): Core.PlutusData {
  return linkedListRootDatum(constrData(0, []), optionSomeBytes(poolId));
}

function banNodeDatum(
  banCounter: number,
  banUntilEpoch: number,
): Core.PlutusData {
  return linkedListNodeDatum(
    constrData(0, [intData(banCounter), intData(banUntilEpoch)]),
  );
}

function faultProofDatum(): Core.PlutusData {
  return constrData(0, [
    constrData(0, []),
    bytesData(DEMO_FAULT_NAMESPACE_HASH),
    bytesData(DEMO_FAULT_EVIDENCE_HASH),
  ]);
}

function faultProofPublishRedeemer(args: {
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

function faultProofBurnRedeemer(): Core.PlutusData {
  return constrData(1, []);
}

function banMintRedeemer(args: {
  withdrawRedeemerIndex: number;
  poolId: string;
}): Core.PlutusData {
  return constrData(1, [
    intData(args.withdrawRedeemerIndex),
    bytesData(args.poolId),
  ]);
}

function banSpendRedeemer(withdrawRedeemerIndex: number): Core.PlutusData {
  return constrData(0, [intData(withdrawRedeemerIndex)]);
}

function banWithdrawRedeemer(args: {
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

function treasurySpendRedeemer(newIdentityRoot: string): Core.PlutusData {
  return constrData(0, [
    intData(0),
    bytesData(newIdentityRoot),
    bytesData(DEMO_TREASURY_ADDRESS),
    bytesData(DEMO_TREASURY_UTXO_ID),
    bytesData(DEMO_SPOS_FROST_KEY),
  ]);
}

function treasuryDatumWithIdentityRoot(identityRoot: string): Core.PlutusData {
  return constrData(0, [
    bytesData(identityRoot),
    bytesData(DEMO_TREASURY_ADDRESS),
    bytesData(DEMO_TREASURY_UTXO_ID),
    bytesData(DEMO_SPOS_FROST_KEY),
  ]);
}

function registrationMintRedeemer(args: {
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

function deregistrationMintRedeemer(args: {
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

function scriptAddress(scriptHash: string): Core.Address {
  const credential = Core.Credential.fromCore({
    hash: scriptHash,
    type: Core.Cardano.CredentialType.ScriptHash,
  });

  return Core.addressFromCredential(Core.NetworkId.Testnet, credential);
}

function utxoRef(utxo: Core.TransactionUnspentOutput): OutputRef {
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

function ledgerInputIndex(inputs: OutputRef[], target: OutputRef): number {
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

function unitOf(policyId: string, assetName: string): string {
  return `${policyId}${assetName}`;
}

function faultProofTokenName(poolId: string, epoch: number): string {
  if (epoch < 0 || epoch > 0xffffffff) {
    throw new Error(`FaultProof epoch does not fit in 4 bytes: ${epoch}`);
  }

  return `${poolId}${epoch.toString(16).padStart(8, "0")}`;
}

function banNodeTokenName(poolId: string): string {
  return `${BAN_NODE_TOKEN_PREFIX}${poolId}`;
}

function registrationMessage(
  poolId: string,
  bifrostIdPk: string,
  bifrostUrl: string,
): string {
  return `${Buffer.from("bifrost-spo", "utf8").toString("hex")}${poolId}${bifrostIdPk}${bifrostUrl}`;
}

function revocationMessage(poolId: string): string {
  return `${Buffer.from("bifrost-revoke", "utf8").toString("hex")}${poolId}`;
}

function firstMpfInsertRoot(key: string, value: string): string {
  const path = Core.blake2b_256(key);
  const valueHash = Core.blake2b_256(value);
  return Core.blake2b_256(`ff${path}${valueHash}`);
}

async function demoSpoIdentity(): Promise<{
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
  const messageHash = Core.sha2_256(message);
  const bifrostSig = Core.toHex(
    await schnorr.sign(messageHash, DEMO_BIFROST_PRIVATE_KEY),
  );

  return {
    bifrostIdPk,
    bifrostSig,
    coldSig,
    coldVkey,
    poolId,
  };
}

async function demoSpoRevocation(): Promise<{
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

function outputHasAsset(output: Core.TransactionOutput, unit: string): boolean {
  return output.amount().toCore().assets?.get(unit) === 1n;
}

function outputRefWithAsset(
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

function scriptOutputRef(
  tx: Core.Transaction,
  txHash: string,
  address: Core.Address,
  unit: string,
): OutputRef {
  return outputRefWithAsset(tx, txHash, address, unit);
}

function scriptRewardAccount(scriptHash: string): Core.RewardAccount {
  return Core.RewardAccount.fromCredential(
    {
      hash: scriptHash,
      type: Core.Cardano.CredentialType.ScriptHash,
    },
    Core.NetworkId.Testnet,
  );
}

function scriptCredential(scriptHash: string): Core.Credential {
  return Core.Credential.fromCore({
    hash: scriptHash,
    type: Core.Cardano.CredentialType.ScriptHash,
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function requireEnv(name: string): string {
  const value = process.env[name]?.trim();

  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }

  return value;
}

function readConfig(): Config {
  return {
    blockfrostProjectId: requireEnv("BLOCKFROST_PREPROD_PROJECT_ID"),
    paymentSeedPhrase: requireEnv("PAYMENT_SEED_PHRASE"),
  };
}

function masterKeyFromSeedPhrase(seedPhrase: string) {
  const entropy = Core.mnemonicToEntropy(seedPhrase, Core.wordlist);
  return Core.Bip32PrivateKey.fromBip39Entropy(Buffer.from(entropy), "");
}

function statePath(): string {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  return resolve(scriptDir, "../state.json");
}

async function loadState(): Promise<DemoState> {
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

async function saveState(state: DemoState): Promise<void> {
  await writeFile(`${statePath()}.tmp`, `${JSON.stringify(state, null, 2)}\n`);
  await rename(`${statePath()}.tmp`, statePath());
}

async function loadBlueprint(): Promise<Blueprint> {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const blueprintPath = resolve(scriptDir, "../../../onchain/plutus.json");
  const rawBlueprint = await readFile(blueprintPath, "utf8");
  return JSON.parse(rawBlueprint) as Blueprint;
}

function requireValidators(
  blueprint: Blueprint,
  titles: readonly string[],
): BlueprintValidator[] {
  return titles.map((title) => {
    const validator = blueprint.validators.find((item) => item.title === title);

    if (!validator) {
      throw new Error(`Missing validator in plutus.json: ${title}`);
    }

    return validator;
  });
}

function validatorByTitle(
  blueprint: Blueprint,
  title: string,
): BlueprintValidator {
  return requireValidators(blueprint, [title])[0];
}

function printStepPlan(): void {
  console.log("SPO contract showcase transaction sequence:");
  SHOWCASE_STEPS.forEach((step, index) => {
    console.log(`${index + 1}. ${step}`);
  });
}

async function createBootstrapNonceUtxos(
  blaze: Awaited<ReturnType<typeof Blaze.from>>,
  wallet: HotWallet,
  state: DemoState,
): Promise<BootstrapNonces> {
  if (state.bootstrapNonces) {
    console.log("Bootstrap nonce UTxOs already recorded in state.json");
    return state.bootstrapNonces;
  }

  // These UTxOs are spent once during protocol setup to anchor one-shot scripts.
  const tx = await blaze
    .newTransaction()
    .payLovelace(wallet.address, BOOTSTRAP_NONCE_LOVELACE)
    .payLovelace(wallet.address, BOOTSTRAP_NONCE_LOVELACE)
    .payLovelace(wallet.address, BOOTSTRAP_NONCE_LOVELACE)
    .complete();
  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  const bootstrapNonces = {
    registry: { txHash, outputIndex: 0 },
    bans: { txHash, outputIndex: 1 },
    treasury: { txHash, outputIndex: 2 },
  };

  state.bootstrapNonces = bootstrapNonces;
  await saveState(state);

  console.log(`Bootstrap nonce transaction submitted: ${txHash}`);
  return bootstrapNonces;
}

function deriveScriptHashes(
  scripts: ParameterizedScripts,
): ScriptHashes {
  return {
    registryPolicyId: scripts.registry.hash(),
    faultProofPolicyId: scripts.faultVerifier.hash(),
    treasuryPolicyId: scripts.treasury.hash(),
    bansPolicyId: scripts.bans.hash(),
  };
}

function parameterizeScripts(
  blueprint: Blueprint,
  bootstrapNonces: BootstrapNonces,
): ParameterizedScripts {
  const registryCode = applyScriptParams(
    validatorByTitle(blueprint, "bitcoin/spos_registry.spo_registry.mint")
      .compiledCode,
    registryParamsType,
    [bootstrapNonces.registry.txHash, bootstrapNonces.registry.outputIndex],
  );
  const registry = cborToScript(registryCode, "PlutusV3");

  const faultVerifier = cborToScript(
    validatorByTitle(blueprint, "bitcoin/fault_verifier.fault_verifier.mint")
      .compiledCode,
    "PlutusV3",
  );

  const treasuryCode = applyScriptParams(
    validatorByTitle(blueprint, "bitcoin/treasury.treasury_info.mint")
      .compiledCode,
    treasuryParamsType,
    [registry.hash()],
  );
  const treasury = cborToScript(treasuryCode, "PlutusV3");

  const bansCode = applyScriptParams(
    validatorByTitle(blueprint, "bitcoin/spo_bans.spo_bans.mint").compiledCode,
    bansParamsType,
    [
      registry.hash(),
      faultVerifier.hash(),
      bootstrapNonces.bans.txHash,
      bootstrapNonces.bans.outputIndex,
    ],
  );
  const bans = cborToScript(bansCode, "PlutusV3");

  return {
    registry,
    faultVerifier,
    treasury,
    bans,
  };
}

async function findWalletUtxo(
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

    console.log(
      `Waiting for UTxO ${outputRef.txHash}#${outputRef.outputIndex} (${attempt}/${UTXO_POLL_ATTEMPTS})`,
    );
    await sleep(UTXO_POLL_INTERVAL_MS);
  }

  throw new Error(
    `Missing expected wallet UTxO ${outputRef.txHash}#${outputRef.outputIndex}`,
  );
}

async function waitForWalletOutputsFromTx(
  wallet: HotWallet,
  tx: Core.Transaction,
  txHash: string,
): Promise<void> {
  for (const outputRef of outputRefsAtAddress(tx, txHash, wallet.address)) {
    await findWalletUtxo(wallet, outputRef);
  }
}

async function findFundingUtxo(
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

function addPreEvaluationChange() {
  return async (txBuilder: unknown): Promise<void> => {
    const builder = txBuilder as {
      getAssetSurplus: () => Core.Value;
      adjustChangeOutput: (value: Core.Value) => void;
    };

    builder.adjustChangeOutput(builder.getAssetSurplus());
  };
}

async function capPlaceholderExUnits(txBuilder: unknown): Promise<void> {
  const builder = txBuilder as { redeemers: Core.Redeemers };

  for (const redeemer of builder.redeemers.values()) {
    redeemer.setExUnits(new Core.ExUnits(2_000_000n, 1_000_000_000n));
  }
}

async function findScriptUtxo(
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

async function findScriptUtxoByRef(
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

    console.log(
      `Waiting for script UTxO ${outputRef.txHash}#${outputRef.outputIndex} (${attempt}/${UTXO_POLL_ATTEMPTS})`,
    );
    await sleep(UTXO_POLL_INTERVAL_MS);
  }

  throw new Error(
    `Missing expected script UTxO ${outputRef.txHash}#${outputRef.outputIndex}`,
  );
}

async function bootstrapTreasuryState(
  blaze: Awaited<ReturnType<typeof Blaze.from>>,
  provider: Blockfrost,
  wallet: HotWallet,
  scripts: ParameterizedScripts,
  bootstrapNonces: BootstrapNonces,
  state: DemoState,
): Promise<void> {
  const inputRef = bootstrapNonces.treasury;
  const treasuryPolicyId = scripts.treasury.hash();
  const treasuryTokenName = hashOutputRef(inputRef);
  const treasuryUnit = unitOf(treasuryPolicyId, treasuryTokenName);
  const treasuryAddress = scriptAddress(treasuryPolicyId);

  if (state.treasuryStateRef) {
    console.log("Treasury state already bootstrapped in state.json");
    return;
  }

  if (state.treasuryBootstrapTxHash) {
    const treasuryUtxo = await findScriptUtxo(
      provider,
      treasuryAddress,
      treasuryUnit,
    );
    state.treasuryStateRef = utxoRef(treasuryUtxo);
    await saveState(state);
    console.log("Treasury state UTxO recorded:", state.treasuryStateRef);
    return;
  }

  const treasuryNonceUtxo = await findWalletUtxo(wallet, inputRef);

  // The treasury NFT name is the on-chain hash of the consumed nonce UTxO.
  const tx = await blaze
    .newTransaction()
    .addInput(treasuryNonceUtxo)
    .provideScript(scripts.treasury)
    .addMint(
      Core.PolicyId(treasuryPolicyId),
      new Map([[Core.AssetName(treasuryTokenName), 1n]]),
      treasuryMintRedeemer(inputRef),
    )
    .lockAssets(
      treasuryAddress,
      makeValue(
        TREASURY_BOOTSTRAP_LOVELACE,
        [treasuryUnit, 1n],
      ),
      Core.Datum.newInlineData(treasuryDatum()),
    )
    .complete();
  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  state.treasuryBootstrapTxHash = txHash;
  state.treasuryStateRef = scriptOutputRef(
    signedTx,
    txHash,
    treasuryAddress,
    treasuryUnit,
  );
  await saveState(state);

  console.log(`Treasury bootstrap transaction submitted: ${txHash}`);
}

async function bootstrapRegistryState(
  blaze: Awaited<ReturnType<typeof Blaze.from>>,
  provider: Blockfrost,
  wallet: HotWallet,
  scripts: ParameterizedScripts,
  bootstrapNonces: BootstrapNonces,
  state: DemoState,
): Promise<void> {
  if (state.registryRootRef) {
    console.log("SPO registry state already bootstrapped in state.json");
    return;
  }

  const registryPolicyId = scripts.registry.hash();
  const registryUnit = unitOf(registryPolicyId, REGISTRY_ROOT_TOKEN_NAME);
  const registryAddress = scriptAddress(registryPolicyId);
  const registryNonceUtxo = await findWalletUtxo(
    wallet,
    bootstrapNonces.registry,
  );

  const tx = await blaze
    .newTransaction()
    .addInput(registryNonceUtxo)
    .provideScript(scripts.registry)
    .addMint(
      Core.PolicyId(registryPolicyId),
      new Map([[Core.AssetName(REGISTRY_ROOT_TOKEN_NAME), 1n]]),
      registryBootstrapRedeemer(),
    )
    .lockAssets(
      registryAddress,
      makeValue(TREASURY_BOOTSTRAP_LOVELACE, [registryUnit, 1n]),
      Core.Datum.newInlineData(registryRootDatum()),
    )
    .complete();
  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  state.registryBootstrapTxHash = txHash;
  state.registryRootRef = scriptOutputRef(
    signedTx,
    txHash,
    registryAddress,
    registryUnit,
  );
  await saveState(state);
  await findScriptUtxo(provider, registryAddress, registryUnit);

  console.log(`SPO registry bootstrap transaction submitted: ${txHash}`);
}

async function bootstrapBanState(
  blaze: Awaited<ReturnType<typeof Blaze.from>>,
  provider: Blockfrost,
  wallet: HotWallet,
  scripts: ParameterizedScripts,
  bootstrapNonces: BootstrapNonces,
  state: DemoState,
): Promise<void> {
  if (state.banRootRef) {
    console.log("SPO ban-list state already bootstrapped in state.json");
    return;
  }

  const bansPolicyId = scripts.bans.hash();
  const banRootUnit = unitOf(bansPolicyId, BAN_ROOT_TOKEN_NAME);
  const bansAddress = scriptAddress(bansPolicyId);
  const bansNonceUtxo = await findWalletUtxo(wallet, bootstrapNonces.bans);

  const tx = await blaze
    .newTransaction()
    .addInput(bansNonceUtxo)
    .provideScript(scripts.bans)
    .addMint(
      Core.PolicyId(bansPolicyId),
      new Map([[Core.AssetName(BAN_ROOT_TOKEN_NAME), 1n]]),
      banBootstrapRedeemer(bootstrapNonces.bans),
    )
    .lockAssets(
      bansAddress,
      makeValue(TREASURY_BOOTSTRAP_LOVELACE, [banRootUnit, 1n]),
      Core.Datum.newInlineData(banRootDatum()),
    )
    .complete();
  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  state.bansBootstrapTxHash = txHash;
  state.banRootRef = scriptOutputRef(signedTx, txHash, bansAddress, banRootUnit);
  await saveState(state);
  await findScriptUtxo(provider, bansAddress, banRootUnit);

  console.log(`SPO ban-list bootstrap transaction submitted: ${txHash}`);
}

async function registerBanWithdrawCredential(
  blaze: Awaited<ReturnType<typeof Blaze.from>>,
  wallet: HotWallet,
  scripts: ParameterizedScripts,
  state: DemoState,
): Promise<void> {
  if (state.bansRewardRegistrationTxHash) {
    console.log("SPO ban withdraw credential already registered in state.json");
    return;
  }

  const bansPolicyId = scripts.bans.hash();
  const tx = await blaze
    .newTransaction()
    .addRegisterStake(scriptCredential(bansPolicyId))
    .complete();
  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  state.bansRewardRegistrationTxHash = txHash;
  await saveState(state);
  await waitForWalletOutputsFromTx(wallet, signedTx, txHash);

  console.log(`SPO ban withdraw credential registration submitted: ${txHash}`);
}

async function registerDemoSpo(
  blaze: Awaited<ReturnType<typeof Blaze.from>>,
  provider: Blockfrost,
  wallet: HotWallet,
  scripts: ParameterizedScripts,
  state: DemoState,
): Promise<void> {
  if (state.registrationNodeRef) {
    console.log("Demo SPO already registered in state.json");
    return;
  }

  if (!state.registryRootRef || !state.treasuryStateRef) {
    throw new Error("Registry and treasury states must be bootstrapped first");
  }

  const registryPolicyId = scripts.registry.hash();
  const treasuryPolicyId = scripts.treasury.hash();
  const registryAddress = scriptAddress(registryPolicyId);
  const treasuryAddress = scriptAddress(treasuryPolicyId);
  const registryRootUtxo = await findScriptUtxoByRef(
    provider,
    registryAddress,
    state.registryRootRef,
  );
  const treasuryUtxo = await findScriptUtxoByRef(
    provider,
    treasuryAddress,
    state.treasuryStateRef,
  );
  const spo = await demoSpoIdentity();
  const fundingUtxo = await findFundingUtxo(wallet);
  const inputRefs = [
    utxoRef(fundingUtxo),
    state.registryRootRef,
    state.treasuryStateRef,
  ];
  const registrationUnit = unitOf(registryPolicyId, spo.poolId);
  const updatedIdentityRoot = firstMpfInsertRoot(spo.bifrostIdPk, spo.poolId);
  const indexes = {
    registrationAnchorInputIndex: ledgerInputIndex(
      inputRefs,
      state.registryRootRef,
    ),
    treasuryInputIndex: ledgerInputIndex(inputRefs, state.treasuryStateRef),
  };

  const buildTx = async (indexes: {
    registrationAnchorInputIndex: number;
    treasuryInputIndex: number;
  }) => {
    const treasuryTokenUnit = unitOf(
      treasuryPolicyId,
      hashOutputRef(state.bootstrapNonces!.treasury),
    );

    return blaze
      .newTransaction()
      .addInput(fundingUtxo)
      .addInput(registryRootUtxo, registrationSpendRedeemer())
      .addInput(treasuryUtxo, treasurySpendRedeemer(updatedIdentityRoot))
      .addPreCompleteHook(addPreEvaluationChange())
      .addPreCompleteHook(capPlaceholderExUnits)
      .provideScript(scripts.registry)
      .provideScript(scripts.treasury)
      .addMint(
        Core.PolicyId(registryPolicyId),
        new Map([[Core.AssetName(spo.poolId), 1n]]),
        registrationMintRedeemer({
          ...spo,
          registrationAnchorInputIndex: indexes.registrationAnchorInputIndex,
          registrationAnchorOutputIndex: 0,
          treasuryInputIndex: indexes.treasuryInputIndex,
          treasuryOutputIndex: 2,
        }),
      )
      .lockAssets(
        registryAddress,
        registryRootUtxo.output().amount(),
        Core.Datum.newInlineData(continuedRegistryRootDatum(spo.poolId)),
      )
      .lockAssets(
        registryAddress,
        makeValue(TREASURY_BOOTSTRAP_LOVELACE, [registrationUnit, 1n]),
        Core.Datum.newInlineData(registrationNodeDatum(spo.bifrostIdPk)),
      )
      .lockAssets(
        treasuryAddress,
        treasuryUtxo.output().amount(),
        Core.Datum.newInlineData(
          treasuryDatumWithIdentityRoot(updatedIdentityRoot),
        ),
      )
      .complete();
  };

  const tx = await buildTx(indexes);

  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  state.registrationTxHash = txHash;
  state.demoPoolId = spo.poolId;
  state.registryRootRef = scriptOutputRef(
    signedTx,
    txHash,
    registryAddress,
    unitOf(registryPolicyId, REGISTRY_ROOT_TOKEN_NAME),
  );
  state.registrationNodeRef = scriptOutputRef(
    signedTx,
    txHash,
    registryAddress,
    registrationUnit,
  );
  state.treasuryStateRef = scriptOutputRef(
    signedTx,
    txHash,
    treasuryAddress,
    unitOf(treasuryPolicyId, hashOutputRef(state.bootstrapNonces!.treasury)),
  );
  await saveState(state);
  await waitForWalletOutputsFromTx(wallet, signedTx, txHash);
  await findScriptUtxo(provider, registryAddress, registrationUnit);

  console.log(`Demo SPO registration transaction submitted: ${txHash}`);
}

async function publishMockFaultProof(
  blaze: Awaited<ReturnType<typeof Blaze.from>>,
  wallet: HotWallet,
  scripts: ParameterizedScripts,
  state: DemoState,
): Promise<void> {
  if (state.faultProofRef) {
    console.log("Mocked FaultProof already published in state.json");
    return;
  }

  if (!state.demoPoolId) {
    throw new Error("Demo SPO must be registered before publishing FaultProof");
  }

  const faultProofPolicyId = scripts.faultVerifier.hash();
  const fundingUtxo = await findFundingUtxo(wallet);
  const inputRef = utxoRef(fundingUtxo);
  const faultTokenName = faultProofTokenName(
    state.demoPoolId,
    DEMO_FAULT_EPOCH,
  );
  const faultProofUnit = unitOf(faultProofPolicyId, faultTokenName);

  const tx = await blaze
    .newTransaction()
    .addInput(fundingUtxo)
    .provideScript(scripts.faultVerifier)
    .addMint(
      Core.PolicyId(faultProofPolicyId),
      new Map([[Core.AssetName(faultTokenName), 1n]]),
      faultProofPublishRedeemer({
        inputRef,
        poolId: state.demoPoolId,
        epoch: DEMO_FAULT_EPOCH,
      }),
    )
    .payAssets(
      wallet.address,
      makeValue(TREASURY_BOOTSTRAP_LOVELACE, [faultProofUnit, 1n]),
      Core.Datum.newInlineData(faultProofDatum()),
    )
    .complete();
  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  state.faultProofTxHash = txHash;
  state.faultProofEpoch = DEMO_FAULT_EPOCH;
  state.faultProofRef = outputRefWithAsset(
    signedTx,
    txHash,
    wallet.address,
    faultProofUnit,
  );
  await saveState(state);
  await waitForWalletOutputsFromTx(wallet, signedTx, txHash);
  await findWalletUtxo(wallet, state.faultProofRef);

  console.log(`Mocked FaultProof transaction submitted: ${txHash}`);
}

async function applyFirstBan(
  blaze: Awaited<ReturnType<typeof Blaze.from>>,
  provider: Blockfrost,
  wallet: HotWallet,
  scripts: ParameterizedScripts,
  state: DemoState,
): Promise<void> {
  if (state.banNodeRef) {
    console.log("Demo SPO ban already applied in state.json");
    return;
  }

  if (
    !state.demoPoolId ||
    !state.registrationNodeRef ||
    !state.faultProofRef ||
    !state.banRootRef
  ) {
    throw new Error("Registration, FaultProof, and ban root states are required");
  }

  const registryPolicyId = scripts.registry.hash();
  const faultProofPolicyId = scripts.faultVerifier.hash();
  const bansPolicyId = scripts.bans.hash();
  const registryAddress = scriptAddress(registryPolicyId);
  const bansAddress = scriptAddress(bansPolicyId);
  const faultTokenName = faultProofTokenName(
    state.demoPoolId,
    state.faultProofEpoch ?? DEMO_FAULT_EPOCH,
  );
  const faultProofUnit = unitOf(faultProofPolicyId, faultTokenName);
  const banNodeName = banNodeTokenName(state.demoPoolId);
  const banNodeUnit = unitOf(bansPolicyId, banNodeName);
  const registrationNodeUtxo = await findScriptUtxoByRef(
    provider,
    registryAddress,
    state.registrationNodeRef,
  );
  const banRootUtxo = await findScriptUtxoByRef(
    provider,
    bansAddress,
    state.banRootRef,
  );
  const faultProofUtxo = await findWalletUtxo(wallet, state.faultProofRef);
  const fundingUtxo = await findFundingUtxo(wallet, [state.faultProofRef]);
  const inputRefs = [
    utxoRef(fundingUtxo),
    state.faultProofRef,
    state.banRootRef,
  ];
  const banIndexes = {
    faultInputIndex: ledgerInputIndex(inputRefs, state.faultProofRef),
    registrationRefInputIndex: 0,
    banAnchorInputIndex: ledgerInputIndex(inputRefs, state.banRootRef),
    banAnchorOutputIndex: 0,
    banNodeOutputIndex: 1,
    currentEpoch: DEMO_FAULT_EPOCH,
  };

  const buildTx = async (withdrawRedeemerIndex: number) => {
    return blaze
      .newTransaction()
      .addInput(fundingUtxo)
      .addInput(faultProofUtxo)
      .addInput(banRootUtxo, banSpendRedeemer(withdrawRedeemerIndex))
      .addReferenceInput(registrationNodeUtxo)
      .addPreCompleteHook(addPreEvaluationChange())
      .addPreCompleteHook(capPlaceholderExUnits)
      .provideScript(scripts.bans)
      .provideScript(scripts.faultVerifier)
      .addMint(
        Core.PolicyId(faultProofPolicyId),
        new Map([[Core.AssetName(faultTokenName), -1n]]),
        faultProofBurnRedeemer(),
      )
      .addMint(
        Core.PolicyId(bansPolicyId),
        new Map([[Core.AssetName(banNodeName), 1n]]),
        banMintRedeemer({
          withdrawRedeemerIndex,
          poolId: state.demoPoolId!,
        }),
      )
      .addWithdrawal(
        scriptRewardAccount(bansPolicyId),
        0n,
        banWithdrawRedeemer(banIndexes),
      )
      .lockAssets(
        bansAddress,
        banRootUtxo.output().amount(),
        Core.Datum.newInlineData(continuedBanRootDatum(state.demoPoolId!)),
      )
      .lockAssets(
        bansAddress,
        makeValue(TREASURY_BOOTSTRAP_LOVELACE, [banNodeUnit, 1n]),
        Core.Datum.newInlineData(
          banNodeDatum(1, banIndexes.currentEpoch + 1),
        ),
      )
      .complete();
  };

  let tx: Core.Transaction | undefined;
  let lastError: unknown;

  for (const withdrawRedeemerIndex of [3, 2, 1, 0]) {
    try {
      tx = await buildTx(withdrawRedeemerIndex);
      break;
    } catch (error: unknown) {
      lastError = error;
    }
  }

  if (!tx) {
    throw lastError instanceof Error
      ? lastError
      : new Error(String(lastError));
  }

  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  state.banTxHash = txHash;
  state.banRootRef = outputRefWithAsset(
    signedTx,
    txHash,
    bansAddress,
    unitOf(bansPolicyId, BAN_ROOT_TOKEN_NAME),
  );
  state.banNodeRef = outputRefWithAsset(
    signedTx,
    txHash,
    bansAddress,
    banNodeUnit,
  );
  await saveState(state);
  await waitForWalletOutputsFromTx(wallet, signedTx, txHash);
  await findScriptUtxo(provider, bansAddress, banNodeUnit);

  console.log(`First SPO ban transaction submitted: ${txHash}`);
}

async function deregisterDemoSpo(
  blaze: Awaited<ReturnType<typeof Blaze.from>>,
  provider: Blockfrost,
  wallet: HotWallet,
  scripts: ParameterizedScripts,
  state: DemoState,
): Promise<void> {
  if (state.deregistrationTxHash) {
    console.log("Demo SPO already deregistered in state.json");
    return;
  }

  if (
    !state.demoPoolId ||
    !state.registrationNodeRef ||
    !state.registryRootRef ||
    !state.treasuryStateRef ||
    !state.bootstrapNonces
  ) {
    throw new Error("Registry node, root, and treasury states are required");
  }

  const registryPolicyId = scripts.registry.hash();
  const treasuryPolicyId = scripts.treasury.hash();
  const registryAddress = scriptAddress(registryPolicyId);
  const treasuryAddress = scriptAddress(treasuryPolicyId);
  const registryRootUtxo = await findScriptUtxoByRef(
    provider,
    registryAddress,
    state.registryRootRef,
  );
  const registrationNodeUtxo = await findScriptUtxoByRef(
    provider,
    registryAddress,
    state.registrationNodeRef,
  );
  const treasuryUtxo = await findScriptUtxoByRef(
    provider,
    treasuryAddress,
    state.treasuryStateRef,
  );
  const fundingUtxo = await findFundingUtxo(wallet);
  const inputRefs = [
    utxoRef(fundingUtxo),
    state.registryRootRef,
    state.registrationNodeRef,
    state.treasuryStateRef,
  ];
  const spo = await demoSpoRevocation();
  const registrationUnit = unitOf(registryPolicyId, state.demoPoolId);
  const treasuryUnit = unitOf(
    treasuryPolicyId,
    hashOutputRef(state.bootstrapNonces.treasury),
  );
  const indexes = {
    registrationInputIndex: ledgerInputIndex(
      inputRefs,
      state.registrationNodeRef,
    ),
    registrationAnchorInputIndex: ledgerInputIndex(
      inputRefs,
      state.registryRootRef,
    ),
    treasuryInputIndex: ledgerInputIndex(inputRefs, state.treasuryStateRef),
  };

  if (spo.poolId !== state.demoPoolId) {
    throw new Error("Demo cold key does not match the registered pool id");
  }

  const tx = await blaze
    .newTransaction()
    .addInput(fundingUtxo)
    .addInput(registryRootUtxo, registrationSpendRedeemer())
    .addInput(registrationNodeUtxo, registrationSpendRedeemer())
    .addInput(treasuryUtxo, treasurySpendRedeemer(EMPTY_MPF_ROOT))
    .addPreCompleteHook(addPreEvaluationChange())
    .addPreCompleteHook(capPlaceholderExUnits)
    .provideScript(scripts.registry)
    .provideScript(scripts.treasury)
    .addMint(
      Core.PolicyId(registryPolicyId),
      new Map([[Core.AssetName(state.demoPoolId), -1n]]),
      deregistrationMintRedeemer({
        ...spo,
        registrationInputIndex: indexes.registrationInputIndex,
        registrationAnchorInputIndex: indexes.registrationAnchorInputIndex,
        registrationAnchorOutputIndex: 0,
        treasuryInputIndex: indexes.treasuryInputIndex,
        treasuryOutputIndex: 1,
      }),
    )
    .lockAssets(
      registryAddress,
      registryRootUtxo.output().amount(),
      Core.Datum.newInlineData(registryRootDatum()),
    )
    .lockAssets(
      treasuryAddress,
      treasuryUtxo.output().amount(),
      Core.Datum.newInlineData(treasuryDatumWithIdentityRoot(EMPTY_MPF_ROOT)),
    )
    .complete();
  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  state.deregistrationTxHash = txHash;
  state.registryRootRef = outputRefWithAsset(
    signedTx,
    txHash,
    registryAddress,
    unitOf(registryPolicyId, REGISTRY_ROOT_TOKEN_NAME),
  );
  state.treasuryStateRef = outputRefWithAsset(
    signedTx,
    txHash,
    treasuryAddress,
    treasuryUnit,
  );
  await saveState(state);
  await waitForWalletOutputsFromTx(wallet, signedTx, txHash);
  await findScriptUtxo(
    provider,
    registryAddress,
    unitOf(registryPolicyId, REGISTRY_ROOT_TOKEN_NAME),
  );

  console.log(`Demo SPO deregistration transaction submitted: ${txHash}`);
}

async function main(): Promise<void> {
  const config = readConfig();
  const state = await loadState();
  const blueprint = await loadBlueprint();

  const showcaseValidators = requireValidators(blueprint, REQUIRED_VALIDATORS);
  const supportingValidators = requireValidators(blueprint, SUPPORTING_VALIDATORS);

  const provider = new Blockfrost({
    network: NETWORK,
    projectId: config.blockfrostProjectId,
  });
  const wallet = await HotWallet.fromMasterkey(
    masterKeyFromSeedPhrase(config.paymentSeedPhrase).hex(),
    provider,
  );
  const blaze = await Blaze.from(provider, wallet);

  console.log(`Network: ${NETWORK}`);
  console.log(`Demo wallet: ${wallet.address.toBech32()}`);
  console.log(`Protocol params loaded: ${Boolean(blaze.params)}`);
  console.log(`Showcase validators: ${showcaseValidators.length}`);
  console.log(`Supporting validators: ${supportingValidators.length}`);
  printStepPlan();

  const bootstrapNonces = await createBootstrapNonceUtxos(blaze, wallet, state);
  console.log("Bootstrap nonce refs:", bootstrapNonces);

  const scripts = parameterizeScripts(blueprint, bootstrapNonces);
  state.scriptHashes = deriveScriptHashes(scripts);
  await saveState(state);
  console.log("Derived script hashes:", state.scriptHashes);

  await bootstrapTreasuryState(
    blaze,
    provider,
    wallet,
    scripts,
    bootstrapNonces,
    state,
  );
  await bootstrapRegistryState(
    blaze,
    provider,
    wallet,
    scripts,
    bootstrapNonces,
    state,
  );
  await bootstrapBanState(
    blaze,
    provider,
    wallet,
    scripts,
    bootstrapNonces,
    state,
  );
  await registerBanWithdrawCredential(blaze, wallet, scripts, state);
  await registerDemoSpo(blaze, provider, wallet, scripts, state);
  await publishMockFaultProof(blaze, wallet, scripts, state);
  await applyFirstBan(blaze, provider, wallet, scripts, state);
  await deregisterDemoSpo(blaze, provider, wallet, scripts, state);

  console.log("SPO contract showcase completed.");
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(message);

  if (error instanceof Error && error.stack) {
    console.error(error.stack);
  }

  process.exitCode = 1;
});
