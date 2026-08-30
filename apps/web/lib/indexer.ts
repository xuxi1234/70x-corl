import { templateIds, type TemplateId } from "@70x/protocol";
import { z } from "zod";

export type IndexedProject = { address: string; templateId: string; version: number; configHash: string; verification: "Pending" | "Verified" | "Failed" };
export type DirectProjectRead = { configHash: string };

export function reconcileProject(indexed: IndexedProject, direct: DirectProjectRead) {
  const consistent = indexed.configHash.toLowerCase() === direct.configHash.toLowerCase();
  const knownVersion = templateIds.includes(indexed.templateId as TemplateId) && indexed.version === 1;
  return {
    ...indexed,
    consistent,
    readOnly: !knownVersion || !consistent,
    verification: consistent ? indexed.verification : "Mismatch" as const,
  };
}

export async function fetchIndexedProject(baseUrl: string, address: string): Promise<IndexedProject> {
  const response = await fetch(`${baseUrl.replace(/\/$/, "")}/projects/${address}`);
  if (!response.ok) throw new Error(`INDEXER_${response.status}`);
  return IndexedProjectResponse.parse(await response.json());
}

const IndexedProjectResponse = z.object({
  address: z.string(), templateId: z.string(), version: z.number().int().positive(), configHash: z.string(), verification: z.enum(["Pending", "Verified", "Failed"]),
});
