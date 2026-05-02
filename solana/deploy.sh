#!/usr/bin/env bash
# Deploy all BharatSetu Anchor programs to devnet (or localnet).
# Usage: ./solana/deploy.sh [devnet|localnet]
set -euo pipefail

CLUSTER="${1:-devnet}"
SOLANA_DIR="$(cd "$(dirname "$0")" && pwd)"

case "$CLUSTER" in
  devnet)    URL="https://api.devnet.solana.com" ;;
  localnet)  URL="http://localhost:8899" ;;
  *)         echo "Unknown cluster: $CLUSTER"; exit 1 ;;
esac

echo "==> Building Anchor programs (cluster: $CLUSTER)"
cd "$SOLANA_DIR"
anchor build

echo ""
echo "==> Deploying programs to $URL"

PROGRAMS=(lock_vault mint_bridge nft_vault nft_mint_bridge)

for PROG in "${PROGRAMS[@]}"; do
  echo ""
  echo "--- Deploying $PROG ---"
  anchor deploy \
    --program-name "$PROG" \
    --provider.cluster "$URL"
done

echo ""
echo "==> All programs deployed. Copy program IDs from above into .env"
echo "    Then set SOLANA_LOCK_VAULT_PROGRAM_ID, SOLANA_MINT_BRIDGE_PROGRAM_ID,"
echo "    SOLANA_NFT_VAULT_PROGRAM_ID, SOLANA_NFT_MINT_BRIDGE_PROGRAM_ID"
