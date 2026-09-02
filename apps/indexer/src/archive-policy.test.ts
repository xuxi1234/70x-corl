import { describe, expect, it } from "vitest";

import { validateArchiveRequest } from "./archive-policy";

const blockHash = `0x${"ab".repeat(32)}`;

describe("Chain 97 archive bridge policy", () => {
  it("allows only read calls inside the legacy checkpoint block window", () => {
    expect(validateArchiveRequest({
      method: "eth_call",
      first: { to: "0x1000000000000000000000000000000000000001", data: "0x8da5cb5b" },
      blockNumber: "128297492",
      blockHash,
    })).toMatchObject({ method: "eth_call", blockNumber: 128297492n });

    expect(() => validateArchiveRequest({ method: "eth_sendRawTransaction", first: "0x", blockNumber: "128297492", blockHash })).toThrow("CHAIN97_ARCHIVE_METHOD_FORBIDDEN");
    expect(() => validateArchiveRequest({ method: "eth_call", first: {}, blockNumber: "128297600", blockHash })).toThrow("CHAIN97_ARCHIVE_BLOCK_FORBIDDEN");
  });
});
