import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Type } from "@sinclair/typebox";
import { Core, applyParamsToScript, cborToScript } from "@blaze-cardano/sdk";

import type {
  Blueprint,
  BlueprintValidator,
  BootstrapNonces,
  ParameterizedScripts,
  ScriptHashes,
} from "./types.js";
import {
  DEMO_BASE_BAN_DURATION_MS,
  DEMO_MAX_BAN_VALIDITY_WINDOW_MS,
  DEMO_MAX_FAULTS_BEFORE_PERMANENT,
  DEMO_UNUSED_FAULT_POLICY_ID_1,
  DEMO_UNUSED_FAULT_POLICY_ID_2,
} from "./constants.js";

const registryParamsType = Type.Tuple([Type.String(), Type.Number()]);
const treasuryParamsType = Type.Tuple([Type.String()]);
const bansParamsType = Type.Tuple([
  Type.String(),
  Type.Array(Type.String()),
  Type.Number(),
  Type.Number(),
  Type.Number(),
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

export async function loadBlueprint(): Promise<Blueprint> {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const blueprintPath = resolve(scriptDir, "../../../onchain/plutus.json");
  const rawBlueprint = await readFile(blueprintPath, "utf8");
  return JSON.parse(rawBlueprint) as Blueprint;
}

export function requireValidators(
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

export function deriveScriptHashes(
  scripts: ParameterizedScripts,
): ScriptHashes {
  return {
    registryPolicyId: scripts.registry.hash(),
    faultProofPolicyId: scripts.faultVerifier.hash(),
    treasuryPolicyId: scripts.treasury.hash(),
    bansPolicyId: scripts.bans.hash(),
  };
}

export function parameterizeScripts(
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
      [
        faultVerifier.hash(),
        DEMO_UNUSED_FAULT_POLICY_ID_1,
        DEMO_UNUSED_FAULT_POLICY_ID_2,
      ],
      DEMO_BASE_BAN_DURATION_MS,
      DEMO_MAX_FAULTS_BEFORE_PERMANENT,
      DEMO_MAX_BAN_VALIDITY_WINDOW_MS,
      bootstrapNonces.bans.txHash,
      bootstrapNonces.bans.outputIndex,
    ],
  );
  const bans = cborToScript(bansCode, "PlutusV3");

  return {
    registry: registry as Core.Script,
    faultVerifier: faultVerifier as Core.Script,
    treasury: treasury as Core.Script,
    bans: bans as Core.Script,
  };
}
