#!/usr/bin/env bash
set -euo pipefail

check_layout() {
  local contract_name="$1"
  local expected_hash="$2"
  local actual_hash
  actual_hash="$(forge inspect "$contract_name" storage-layout --json | node "$(dirname "$0")/storage-layout-fingerprint.mjs")"
  if [[ "$actual_hash" != "$expected_hash" ]]; then
    echo "Storage layout drift: $contract_name expected $expected_hash, got $actual_hash" >&2
    exit 1
  fi
}

check_layout LaunchFactory 4ada79a8fcadbac3b456e195c65da0d0c68516f4a029d39e65c874fb8d5cac00
check_layout TemplateRegistry 94a956e23e461de6513bc18f9644d26a5c06a9848b661eee813b9d8051e058d3
check_layout PlatformConfig c649b3489145cc5fa74d3b9cda19b1395974952319e1cba9a050c5f35e31bb83
check_layout MintVault 0a4d27cefde6ad6894c20aabd6d3d9763c1ae01c73ee35ba424962c3a1698f60
check_layout RewardVault c60182933c403bf09098d0b0c66bc3ec458982796cf333b75ec0eba09f946aec
check_layout BuybackVault c6a83b0c9c189f31743809bb9b105d4e3f6c0b67b69a5f13be3dfae86782f8e3
check_layout FinanceVault 375ee6b4f560cf1bdda6452918d81e1223046208b97cb43c307d745fd9a3d1fa
check_layout FlapMintVault 358bcccac6c0989aabb9dc2f236c99ddc6b8836d5dd6bbb5d3514141bff392ab
