import { Blockfrost, Core, HotWallet, makeValue } from "@blaze-cardano/sdk";

import {
  BAN_ROOT_TOKEN_NAME,
  BOOTSTRAP_NONCE_LOVELACE,
  DEMO_FAULT_EPOCH,
  EMPTY_MPF_ROOT,
  REGISTRY_ROOT_TOKEN_NAME,
  TREASURY_BOOTSTRAP_LOVELACE,
} from "./constants.js";
import {
  addPreEvaluationChange,
  banNodeTokenName,
  capPlaceholderExUnits,
  faultProofTokenName,
  findFundingUtxo,
  findScriptUtxo,
  findScriptUtxoByRef,
  findWalletUtxo,
  ledgerInputIndex,
  outputRefWithAsset,
  scriptAddress,
  scriptCredential,
  scriptRewardAccount,
  unitOf,
  utxoRef,
  waitForWalletOutputsFromTx,
} from "./chain.js";
import {
  banBootstrapRedeemer,
  banMintRedeemer,
  banNodeDatum,
  banRootDatum,
  banSpendRedeemer,
  banWithdrawRedeemer,
  continuedBanRootDatum,
  continuedRegistryRootDatum,
  deregistrationMintRedeemer,
  faultProofBurnRedeemer,
  faultProofDatum,
  faultProofPublishRedeemer,
  hashOutputRef,
  registrationMintRedeemer,
  registrationNodeDatum,
  registrationSpendRedeemer,
  registryBootstrapRedeemer,
  registryRootDatum,
  treasuryDatum,
  treasuryDatumWithIdentityRoot,
  treasuryMintRedeemer,
  treasurySpendRedeemer,
} from "./plutus-data.js";
import { demoSpoIdentity, demoSpoRevocation, firstMpfInsertRoot } from "./identity.js";
import { saveState } from "./state.js";
import type {
  BlazeInstance,
  BootstrapNonces,
  DemoState,
  ParameterizedScripts,
} from "./types.js";

export async function createBootstrapNonceUtxos(
  blaze: BlazeInstance,
  wallet: HotWallet,
  state: DemoState,
): Promise<BootstrapNonces> {
  if (state.bootstrapNonces) {
    console.log("Bootstrap nonce UTxOs already recorded in state.json");
    return state.bootstrapNonces;
  }

  // Setup: create one-shot nonce UTxOs that parameterized policies consume.
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

export async function bootstrapTreasuryState(
  blaze: BlazeInstance,
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

  // Setup: mint the treasury state NFT and lock the initial identity root.
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
      makeValue(TREASURY_BOOTSTRAP_LOVELACE, [treasuryUnit, 1n]),
      Core.Datum.newInlineData(treasuryDatum()),
    )
    .complete();
  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  state.treasuryBootstrapTxHash = txHash;
  state.treasuryStateRef = outputRefWithAsset(
    signedTx,
    txHash,
    treasuryAddress,
    treasuryUnit,
  );
  await saveState(state);

  console.log(`Treasury bootstrap transaction submitted: ${txHash}`);
}

export async function bootstrapRegistryState(
  blaze: BlazeInstance,
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

  // Setup: initialize the registry linked-list root.
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
  state.registryRootRef = outputRefWithAsset(
    signedTx,
    txHash,
    registryAddress,
    registryUnit,
  );
  await saveState(state);
  await findScriptUtxo(provider, registryAddress, registryUnit);

  console.log(`SPO registry bootstrap transaction submitted: ${txHash}`);
}

export async function bootstrapBanState(
  blaze: BlazeInstance,
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

  // Setup: initialize the ban linked-list root.
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
  state.banRootRef = outputRefWithAsset(signedTx, txHash, bansAddress, banRootUnit);
  await saveState(state);
  await findScriptUtxo(provider, bansAddress, banRootUnit);

  console.log(`SPO ban-list bootstrap transaction submitted: ${txHash}`);
}

export async function registerBanWithdrawCredential(
  blaze: BlazeInstance,
  wallet: HotWallet,
  scripts: ParameterizedScripts,
  state: DemoState,
): Promise<void> {
  if (state.bansRewardRegistrationTxHash) {
    console.log("SPO ban withdraw credential already registered in state.json");
    return;
  }

  const bansPolicyId = scripts.bans.hash();

  // Setup: Conway rejects withdrawals from unregistered reward credentials.
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

export async function registerDemoSpo(
  blaze: BlazeInstance,
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
  const treasuryTokenUnit = unitOf(
    treasuryPolicyId,
    hashOutputRef(state.bootstrapNonces!.treasury),
  );

  // Showcase: insert one SPO node and update the treasury identity MPT root.
  const tx = await blaze
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
      Core.Datum.newInlineData(treasuryDatumWithIdentityRoot(updatedIdentityRoot)),
    )
    .complete();
  const signedTx = await blaze.signTransaction(tx);
  const txHash = String(await blaze.submitTransaction(signedTx));

  state.registrationTxHash = txHash;
  state.demoPoolId = spo.poolId;
  state.registryRootRef = outputRefWithAsset(
    signedTx,
    txHash,
    registryAddress,
    unitOf(registryPolicyId, REGISTRY_ROOT_TOKEN_NAME),
  );
  state.registrationNodeRef = outputRefWithAsset(
    signedTx,
    txHash,
    registryAddress,
    registrationUnit,
  );
  state.treasuryStateRef = outputRefWithAsset(
    signedTx,
    txHash,
    treasuryAddress,
    treasuryTokenUnit,
  );
  await saveState(state);
  await waitForWalletOutputsFromTx(wallet, signedTx, txHash);
  await findScriptUtxo(provider, registryAddress, registrationUnit);

  console.log(`Demo SPO registration transaction submitted: ${txHash}`);
}

export async function publishMockFaultProof(
  blaze: BlazeInstance,
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

  // Showcase: publish one mocked FaultProof token at the wallet address.
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

export async function applyFirstBan(
  blaze: BlazeInstance,
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
        Core.Datum.newInlineData(banNodeDatum(1, banIndexes.currentEpoch + 1)),
      )
      .complete();
  };

  // Showcase: burn the FaultProof and insert the first ban node.
  const tx = await buildTx(1);
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

export async function deregisterDemoSpo(
  blaze: BlazeInstance,
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

  // Showcase: burn the SPO registration node and restore the empty identity root.
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
