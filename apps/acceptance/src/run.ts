import { mkdir, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { validateEvidence, writeEvidence, type EvidenceBundle } from "./evidence";
import { scenarios } from "./scenarios";

type ExecutorModule = {
  runAcceptance(input: { scenarioIds: string[]; releaseCommit: string }): Promise<unknown[]>;
};

type RunnerEnvironment = Record<string, string | undefined>;

const importExecutor = async (specifier: string): Promise<unknown> => {
  const target = specifier.startsWith(".") || isAbsolute(specifier)
    ? pathToFileURL(resolve(process.cwd(), specifier)).href
    : specifier;
  return import(target);
};

const persistEvidence = async (path: string, content: string) => {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, content, { encoding: "utf8", flag: "wx" });
};
const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

export function selectedScenarios(argv: readonly string[]) {
  if (argv.includes("--all")) return scenarios;
  const requested = argv.find((argument) => !argument.startsWith("-"));
  if (!requested) throw new Error("SCENARIO_OR_ALL_REQUIRED");
  const match = scenarios.find((scenario) => scenario.id === requested);
  if (!match) throw new Error(`UNKNOWN_SCENARIO:${requested}`);
  return [match];
}

export async function runConfiguredAcceptance(input: {
  argv: readonly string[];
  env: RunnerEnvironment;
  loadModule?: (specifier: string) => Promise<unknown>;
  persist?: (path: string, content: string) => Promise<void>;
}) {
  const chosen = selectedScenarios(input.argv);
  const moduleSpecifier = input.env.CHAIN97_EXECUTOR_MODULE;
  if (!moduleSpecifier) throw new Error(`CHAIN97_EXECUTOR_NOT_CONFIGURED:${chosen.map((item) => item.id).join(",")}`);
  const releaseCommit = input.env.RELEASE_COMMIT ?? input.env.GITHUB_SHA;
  if (!releaseCommit) throw new Error("RELEASE_COMMIT_NOT_CONFIGURED");
  if (input.env.RELEASE_COMMIT && input.env.GITHUB_SHA && input.env.RELEASE_COMMIT.toLowerCase() !== input.env.GITHUB_SHA.toLowerCase()) {
    throw new Error("RELEASE_COMMIT_GITHUB_SHA_MISMATCH");
  }

  const loaded = await (input.loadModule ?? importExecutor)(moduleSpecifier) as Partial<ExecutorModule>;
  if (typeof loaded.runAcceptance !== "function") throw new Error("INVALID_CHAIN97_EXECUTOR_MODULE");
  const rawBundles = await loaded.runAcceptance({ scenarioIds: chosen.map((item) => item.id), releaseCommit });
  if (!Array.isArray(rawBundles)) throw new Error("INVALID_CHAIN97_EXECUTOR_RESULT");

  const bundles = rawBundles as EvidenceBundle[];
  const byScenario = new Map<string, EvidenceBundle>();
  for (const bundle of bundles) {
    validateEvidence(bundle);
    if (bundle.releaseCommit !== releaseCommit) throw new Error(`RELEASE_COMMIT_MISMATCH:${bundle.scenario}`);
    if (byScenario.has(bundle.scenario)) throw new Error(`DUPLICATE_SCENARIO_EVIDENCE:${bundle.scenario}`);
    byScenario.set(bundle.scenario, bundle);
  }

  const write = input.persist ?? ((path: string, content: string) => persistEvidence(resolve(repositoryRoot, path), content));
  for (const selected of chosen) {
    const bundle = byScenario.get(selected.id);
    if (!bundle) throw new Error(`MISSING_SCENARIO_EVIDENCE:${selected.id}`);
    await write(`docs/acceptance/evidence/${releaseCommit}/${selected.id}.json`, writeEvidence(bundle));
  }
  return chosen.map((item) => byScenario.get(item.id)!);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await runConfiguredAcceptance({ argv: process.argv.slice(2), env: process.env });
}
