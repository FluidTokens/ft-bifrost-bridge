import "dotenv/config";

import { Blaze, Blockfrost, HotWallet } from "@blaze-cardano/sdk";

import {
  NETWORK,
  REQUIRED_VALIDATORS,
  SHOWCASE_STEPS,
  SUPPORTING_VALIDATORS,
} from "./constants.js";
import {
  deriveScriptHashes,
  loadBlueprint,
  parameterizeScripts,
  requireValidators,
} from "./scripts.js";
import { loadState, masterKeyFromSeedPhrase, readConfig, saveState } from "./state.js";
import {
  applyFirstBan,
  bootstrapBanState,
  bootstrapRegistryState,
  bootstrapTreasuryState,
  createBootstrapNonceUtxos,
  deregisterDemoSpo,
  publishEquivocationFaultProof,
  registerBanWithdrawCredential,
  registerDemoSpo,
} from "./transactions.js";

function printStepPlan(): void {
  console.log("SPO contract showcase transaction sequence:");
  SHOWCASE_STEPS.forEach((step, index) => {
    console.log(`${index + 1}. ${step}`);
  });
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

  // Setup phase: create the on-chain state that later txs consume and update.
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

  // Showcase phase: register, prove a direct fault, apply the ban, then deregister.
  await registerDemoSpo(blaze, provider, wallet, scripts, state);
  await publishEquivocationFaultProof(blaze, provider, wallet, scripts, state);
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
