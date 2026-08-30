#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

/**
 * Convert Solidity's storage-layout output into a value whose hash represents
 * layout semantics rather than compiler implementation identifiers.  In
 * particular, `astId` and the keys in `types` are intentionally omitted:
 * both can be renumbered by an unrelated compilation unit.
 */
export function canonicalizeStorageLayout(layout) {
  if (!layout || !Array.isArray(layout.storage) || !layout.types || typeof layout.types !== "object") {
    throw new TypeError("Expected a Solidity storage-layout JSON object");
  }

  const types = layout.types;
  const resolved = new Map();
  const resolving = new Set();

  const typeDescriptor = (type) => ({
    label: required(type, "label", "type"),
    encoding: required(type, "encoding", "type"),
    numberOfBytes: required(type, "numberOfBytes", "type"),
  });

  const canonicalType = (typeId) => {
    if (resolved.has(typeId)) return resolved.get(typeId);

    const type = types[typeId];
    if (!type || typeof type !== "object") {
      throw new TypeError(`Storage layout references unknown type ${JSON.stringify(typeId)}`);
    }

    // Recursive mapping types are legal.  A stable, descriptive marker keeps
    // their identity semantic without leaking the compiler-generated key.
    if (resolving.has(typeId)) return { circular: typeDescriptor(type) };

    resolving.add(typeId);
    const canonical = typeDescriptor(type);
    if (type.key !== undefined) canonical.key = canonicalType(type.key);
    if (type.value !== undefined) canonical.value = canonicalType(type.value);
    if (type.base !== undefined) canonical.base = canonicalType(type.base);
    if (type.members !== undefined) {
      if (!Array.isArray(type.members)) throw new TypeError("Storage-layout type members must be an array");
      canonical.members = type.members.map((member) => ({
        label: required(member, "label", "member"),
        slot: required(member, "slot", "member"),
        offset: required(member, "offset", "member"),
        type: canonicalType(required(member, "type", "member")),
      }));
    }
    resolving.delete(typeId);
    resolved.set(typeId, canonical);
    return canonical;
  };

  return {
    storage: layout.storage.map((entry) => ({
      label: required(entry, "label", "storage entry"),
      slot: required(entry, "slot", "storage entry"),
      offset: required(entry, "offset", "storage entry"),
      type: canonicalType(required(entry, "type", "storage entry")),
    })),
  };
}

export function storageLayoutFingerprint(layout) {
  return createHash("sha256")
    .update(JSON.stringify(canonicalizeStorageLayout(layout)))
    .digest("hex");
}

function required(value, key, kind) {
  if (value[key] === undefined) throw new TypeError(`Storage-layout ${kind} is missing ${key}`);
  return value[key];
}

function main() {
  const input = process.argv[2] ? readFileSync(process.argv[2], "utf8") : readFileSync(0, "utf8");
  process.stdout.write(`${storageLayoutFingerprint(JSON.parse(input))}\n`);
}

if (import.meta.main) main();
