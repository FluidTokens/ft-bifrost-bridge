import type { NetworkName } from "@blaze-cardano/sdk";

export const NETWORK: NetworkName = "cardano-preprod";

export const REQUIRED_VALIDATORS = [
  "bitcoin/spos_registry.spo_registry.mint",
  "bitcoin/spos_registry.spo_registry.spend",
  "bitcoin/fault_verifier.fault_verifier.mint",
  "bitcoin/spo_bans.spo_bans.mint",
  "bitcoin/spo_bans.spo_bans.spend",
  "bitcoin/spo_bans.spo_bans.withdraw",
] as const;

export const SUPPORTING_VALIDATORS = [
  "bitcoin/treasury.treasury_info.mint",
  "bitcoin/treasury.treasury_info.spend",
] as const;

export const SHOWCASE_STEPS = [
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

export const BOOTSTRAP_NONCE_LOVELACE = 3_000_000n;
export const TREASURY_BOOTSTRAP_LOVELACE = 3_000_000n;
export const UTXO_POLL_INTERVAL_MS = 5_000;
export const UTXO_POLL_ATTEMPTS = 24;
export const DEMO_BASE_BAN_DURATION_MS = 86_400_000;
export const DEMO_MAX_FAULTS_BEFORE_PERMANENT = 3;
export const DEMO_MAX_BAN_VALIDITY_WINDOW_MS = 600_000;
export const DEMO_BAN_TX_VALIDITY_WINDOW_MS = 300_000;
export const DEMO_BAN_TX_VALIDITY_LOWER_SLACK_MS = 120_000;

export const EMPTY_MPF_ROOT = "00".repeat(32);
export const DEMO_TREASURY_ADDRESS = "01".repeat(32);
export const DEMO_TREASURY_UTXO_ID = "02".repeat(32);
export const DEMO_SPOS_FROST_KEY = "03".repeat(32);
export const DEMO_COLD_PRIVATE_KEY = "11".repeat(32);
export const DEMO_BIFROST_PRIVATE_KEY = "04".repeat(32);
export const DEMO_BIFROST_URL = Buffer.from(
  "https://spo.demo.zkfold.io",
  "utf8",
).toString("hex");
export const DEMO_FAULT_NAMESPACE_HASH = "05".repeat(32);
export const DEMO_FAULT_EVIDENCE_HASH = "06".repeat(32);
export const DEMO_UNUSED_FAULT_POLICY_ID_1 = "07".repeat(28);
export const DEMO_UNUSED_FAULT_POLICY_ID_2 = "08".repeat(28);

export const REGISTRY_ROOT_TOKEN_NAME = Buffer.from(
  "reg-root",
  "utf8",
).toString("hex");
export const BAN_ROOT_TOKEN_NAME = Buffer.from("ban-root", "utf8").toString(
  "hex",
);
export const BAN_NODE_TOKEN_PREFIX = Buffer.from("ban/", "utf8").toString(
  "hex",
);
