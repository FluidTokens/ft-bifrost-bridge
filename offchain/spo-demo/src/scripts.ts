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
} from "./constants.js";

const registryParamsType = Type.Tuple([Type.String(), Type.Number()]);
const scriptHashParamsType = Type.Tuple([Type.String()]);
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
    faultProofRound1PolicyId: scripts.faultVerifierRound1.hash(),
    faultProofRound2PolicyId: scripts.faultVerifierRound2.hash(),
    faultProofEquivocationPolicyId: scripts.faultVerifierEquivocation.hash(),
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

  const faultVerifierRound1Code = applyScriptParams(
    validatorByTitle(
      blueprint,
      "bitcoin/fault_verifier_round1.fault_verifier_round1.mint",
    ).compiledCode,
    scriptHashParamsType,
    [registry.hash()],
  );
  const faultVerifierRound1 = cborToScript(
    faultVerifierRound1Code,
    "PlutusV3",
  );

  const faultVerifierRound2Code = applyScriptParams(
    validatorByTitle(
      blueprint,
      "bitcoin/fault_verifier_round2.fault_verifier_round2.mint",
    ).compiledCode,
    scriptHashParamsType,
    [registry.hash()],
  );
  const faultVerifierRound2 = cborToScript(
    faultVerifierRound2Code,
    "PlutusV3",
  );

  const faultVerifierEquivocationCode = applyScriptParams(
    validatorByTitle(
      blueprint,
      "bitcoin/fault_verifier_equivocation.fault_verifier_equivocation.mint",
    ).compiledCode,
    scriptHashParamsType,
    [registry.hash()],
  );
  const faultVerifierEquivocation = cborToScript(
    faultVerifierEquivocationCode,
    "PlutusV3",
  );

  const treasuryCode = applyScriptParams(
    validatorByTitle(blueprint, "bitcoin/treasury.treasury_info.mint")
      .compiledCode,
    scriptHashParamsType,
    [registry.hash()],
  );
  const treasury = cborToScript(treasuryCode, "PlutusV3");

  const bansCode = applyScriptParams(
    validatorByTitle(blueprint, "bitcoin/spo_bans.spo_bans.mint").compiledCode,
    bansParamsType,
    [
      registry.hash(),
      [
        faultVerifierRound1.hash(),
        faultVerifierRound2.hash(),
        faultVerifierEquivocation.hash(),
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
    faultVerifierRound1: faultVerifierRound1 as Core.Script,
    faultVerifierRound2: faultVerifierRound2 as Core.Script,
    faultVerifierEquivocation: faultVerifierEquivocation as Core.Script,
    treasury: treasury as Core.Script,
    bans: bans as Core.Script,
  };
}
