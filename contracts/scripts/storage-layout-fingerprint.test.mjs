import assert from "node:assert/strict";
import test from "node:test";

import { storageLayoutFingerprint } from "./storage-layout-fingerprint.mjs";

const layout = {
  storage: [
    { astId: 100, contract: "src/A.sol:A", label: "config", slot: "0", offset: 0, type: "t_struct(Config)90_storage" },
  ],
  types: {
    t_address: { encoding: "inplace", label: "address", numberOfBytes: "20" },
    "t_uint32": { encoding: "inplace", label: "uint32", numberOfBytes: "4" },
    "t_struct(Config)90_storage": {
      encoding: "inplace",
      label: "struct A.Config",
      numberOfBytes: "32",
      members: [
        { astId: 91, contract: "src/A.sol:A", label: "owner", slot: "0", offset: 0, type: "t_address" },
        { astId: 92, contract: "src/A.sol:A", label: "limit", slot: "0", offset: 20, type: "t_uint32" },
      ],
    },
  },
};

const descriptorLayout = {
  storage: [
    { label: "balances", slot: "0", offset: 0, type: "t_mapping(t_uint32,t_address)" },
    { label: "recipients", slot: "1", offset: 0, type: "t_array(t_uint32)dyn_storage" },
  ],
  types: {
    t_address: { encoding: "inplace", label: "address", numberOfBytes: "20" },
    t_uint32: { encoding: "inplace", label: "uint32", numberOfBytes: "4" },
    t_uint64: { encoding: "inplace", label: "uint64", numberOfBytes: "8" },
    "t_mapping(t_uint32,t_address)": {
      encoding: "mapping",
      label: "mapping(uint32 => address)",
      numberOfBytes: "32",
      key: "t_uint32",
      value: "t_address",
    },
    "t_array(t_uint32)dyn_storage": {
      encoding: "dynamic_array",
      label: "uint32[]",
      numberOfBytes: "32",
      base: "t_uint32",
    },
  },
};

function copy(value) {
  return structuredClone(value);
}

test("ignores compiler ast IDs and generated type-map IDs", () => {
  const renumbered = {
    storage: [{ ...layout.storage[0], astId: 9001, type: "t_struct(Config)7090_storage" }],
    types: {
      t_address_77: { ...layout.types.t_address, astId: 701 },
      t_uint32_88: { ...layout.types.t_uint32, astId: 702 },
      "t_struct(Config)7090_storage": {
        ...layout.types["t_struct(Config)90_storage"],
        members: [
          { ...layout.types["t_struct(Config)90_storage"].members[0], astId: 703, type: "t_address_77" },
          { ...layout.types["t_struct(Config)90_storage"].members[1], astId: 704, type: "t_uint32_88" },
        ],
      },
    },
  };

  assert.equal(storageLayoutFingerprint(renumbered), storageLayoutFingerprint(layout));
});

test("detects storage slot, member layout, and type changes", () => {
  const changedSlot = copy(layout);
  changedSlot.storage[0].slot = "1";

  const changedMember = copy(layout);
  changedMember.types["t_struct(Config)90_storage"].members[1].offset = 21;

  const changedType = copy(layout);
  changedType.types.t_uint32.numberOfBytes = "8";
  changedType.types.t_uint32.label = "uint64";

  const fingerprint = storageLayoutFingerprint(layout);
  assert.notEqual(storageLayoutFingerprint(changedSlot), fingerprint);
  assert.notEqual(storageLayoutFingerprint(changedMember), fingerprint);
  assert.notEqual(storageLayoutFingerprint(changedType), fingerprint);
});

test("detects mapping key/value and array base descriptor changes", () => {
  const changedMappingKey = copy(descriptorLayout);
  changedMappingKey.types["t_mapping(t_uint32,t_address)"].key = "t_uint64";

  const changedMappingValue = copy(descriptorLayout);
  changedMappingValue.types["t_mapping(t_uint32,t_address)"].value = "t_uint64";

  const changedArrayBase = copy(descriptorLayout);
  changedArrayBase.types["t_array(t_uint32)dyn_storage"].base = "t_uint64";

  const fingerprint = storageLayoutFingerprint(descriptorLayout);
  assert.notEqual(storageLayoutFingerprint(changedMappingKey), fingerprint);
  assert.notEqual(storageLayoutFingerprint(changedMappingValue), fingerprint);
  assert.notEqual(storageLayoutFingerprint(changedArrayBase), fingerprint);
});
