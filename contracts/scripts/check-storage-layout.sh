#!/usr/bin/env bash
set -euo pipefail

check_layout() {
  local contract_name="$1"
  local expected_hash="$2"
  local actual_hash
  actual_hash="$(forge inspect "$contract_name" storage-layout --json | sha256sum | cut -d' ' -f1)"
  if [[ "$actual_hash" != "$expected_hash" ]]; then
    echo "Storage layout drift: $contract_name expected $expected_hash, got $actual_hash" >&2
    exit 1
  fi
}

check_layout LaunchFactory d925d88743a1bca6a8b2ba769f4f883aaac64c96186dc9847e6351d65d62680f
check_layout TemplateRegistry 4cfc4cfb51dd39bd2d9b005cc7ddfa8c92e778fd3b97b7d69b7232a718dafc4c
check_layout PlatformConfig 705a39900e5f8ec2b1fbad155a41c16345864e1cc5c92310b0a2a808d07c008e
check_layout MintVault bf8f145febf62726044fd981d31b77c63d2137421bdebf09ccde897237f660af
check_layout RewardVault e1cb4f64c84228819a9eaf4bfe5ff8e008afa1a33e6c0a15536a760659ed3cd2
check_layout BuybackVault f96cbd433424b873991cf7449cb5a638d5d9f0a73e8159ad8eb78fed7e75238f
check_layout FinanceVault 59c8cca8b1a2f2b97f6e9dc50e247df51c22ccc32051a813e75c67cfe2956567
check_layout FlapMintVault a53cab0ef81edacd90d5641009754fa3fe920c8c8eb37ca91f4fa26dcc7eb72a
