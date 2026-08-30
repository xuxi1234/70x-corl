process.stderr.write(
  "PLAYWRIGHT_ACCEPTANCE_GATE_NOT_CONFIGURED: install @playwright/test, add browser lifecycle specs, and replace this fail-closed gate before Chain 97 transaction execution.\n",
);
process.exitCode = 1;
