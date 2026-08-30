import { access, readFile } from "node:fs/promises";
import { dirname, resolve, sep } from "node:path";

import type { Abi, Hex } from "viem";

const artifactPattern = /^([A-Za-z_][A-Za-z0-9_]*)\.sol\/([A-Za-z_][A-Za-z0-9_]*)$/;

type FoundryArtifactJson = {
  abi?: Abi;
  bytecode?: { object?: Hex };
  deployedBytecode?: { object?: Hex };
  metadata?: {
    compiler?: { version?: string };
    language?: string;
    settings?: Record<string, unknown> & { compilationTarget?: Record<string, string> };
    sources?: Record<string, unknown>;
  };
  rawMetadata?: string;
};

export type FoundryArtifact = {
  artifactId: string;
  contractName: string;
  sourceName: string;
  abi: Abi;
  bytecode: Hex;
  deployedBytecode: Hex;
  compilerVersion: string;
  metadata: NonNullable<FoundryArtifactJson["metadata"]>;
  metadataJson: string;
  standardJsonInput: {
    language: "Solidity";
    sources: Record<string, { content: string }>;
    settings: Record<string, unknown>;
  };
};

async function findRepositoryRoot(start: string): Promise<string> {
  let current = resolve(start);
  for (let depth = 0; depth < 10; depth += 1) {
    try {
      await access(resolve(current, "contracts", "foundry.toml"));
      return current;
    } catch {
      const parent = dirname(current);
      if (parent === current) break;
      current = parent;
    }
  }
  throw new Error("CHAIN97_REPOSITORY_ROOT_NOT_FOUND");
}

export async function loadFoundryArtifact(artifactId: string, startDirectory = process.cwd()): Promise<FoundryArtifact> {
  const match = artifactPattern.exec(artifactId);
  if (!match) throw new Error(`CHAIN97_ARTIFACT_INVALID:${artifactId}`);
  const [, sourceFile, requestedContract] = match;
  const repositoryRoot = await findRepositoryRoot(startDirectory);
  const artifactRoot = resolve(repositoryRoot, "contracts", "out");
  const artifactPath = resolve(artifactRoot, `${sourceFile}.sol`, `${requestedContract}.json`);
  if (!artifactPath.startsWith(`${artifactRoot}${sep}`)) throw new Error(`CHAIN97_ARTIFACT_INVALID:${artifactId}`);

  let parsed: FoundryArtifactJson;
  try {
    parsed = JSON.parse(await readFile(artifactPath, "utf8")) as FoundryArtifactJson;
  } catch {
    throw new Error(`CHAIN97_ARTIFACT_MISSING:${artifactId}`);
  }
  const metadata = parsed.metadata;
  const compilationTarget = metadata?.settings?.compilationTarget;
  const target = compilationTarget ? Object.entries(compilationTarget)[0] : undefined;
  const sourceName = target?.[0];
  const contractName = target?.[1];
  if (
    !parsed.abi || !parsed.bytecode?.object?.match(/^0x[0-9a-fA-F]+$/) || !parsed.deployedBytecode?.object?.match(/^0x[0-9a-fA-F]+$/)
    || !metadata || metadata.language !== "Solidity" || !metadata.compiler?.version
    || !sourceName || contractName !== requestedContract || !metadata.sources
  ) throw new Error(`CHAIN97_ARTIFACT_MALFORMED:${artifactId}`);

  const contractsRoot = resolve(repositoryRoot, "contracts");
  const sources: Record<string, { content: string }> = {};
  for (const source of Object.keys(metadata.sources)) {
    const sourcePath = resolve(contractsRoot, source);
    if (!sourcePath.startsWith(`${contractsRoot}${sep}`)) throw new Error(`CHAIN97_ARTIFACT_SOURCE_INVALID:${artifactId}`);
    try {
      sources[source] = { content: await readFile(sourcePath, "utf8") };
    } catch {
      throw new Error(`CHAIN97_ARTIFACT_SOURCE_MISSING:${artifactId}:${source}`);
    }
  }

  const settings = { ...metadata.settings };
  delete settings.compilationTarget;
  settings.outputSelection = { "*": { "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "metadata"] } };
  return {
    artifactId,
    contractName: requestedContract!,
    sourceName: sourceName!,
    abi: parsed.abi,
    bytecode: parsed.bytecode.object,
    deployedBytecode: parsed.deployedBytecode.object,
    compilerVersion: metadata.compiler.version,
    metadata,
    metadataJson: parsed.rawMetadata ?? JSON.stringify(metadata),
    standardJsonInput: { language: "Solidity", sources, settings },
  };
}
