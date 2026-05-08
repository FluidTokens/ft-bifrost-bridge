import { Blaze, Core } from "@blaze-cardano/sdk";

export type Config = {
  blockfrostProjectId: string;
  paymentSeedPhrase: string;
};

export type BlueprintValidator = {
  title: string;
  compiledCode: string;
  hash: string;
};

export type Blueprint = {
  validators: BlueprintValidator[];
};

export type OutputRef = {
  txHash: string;
  outputIndex: number;
};

export type BootstrapNonces = {
  registry: OutputRef;
  bans: OutputRef;
  treasury: OutputRef;
};

export type ScriptHashes = {
  registryPolicyId: string;
  faultProofPolicyId: string;
  treasuryPolicyId: string;
  bansPolicyId: string;
};

export type ParameterizedScripts = {
  registry: Core.Script;
  faultVerifier: Core.Script;
  treasury: Core.Script;
  bans: Core.Script;
};

export type DemoState = {
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

export type BlazeInstance = Awaited<ReturnType<typeof Blaze.from>>;
