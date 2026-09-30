#!/usr/bin/env bash
# Seed a deployed fund: approve each stock for exactly previewMint(SHARES), then seed(SHARES).
#
# Uses `cast send`, which is simulated by the real node. Forge's own EVM can't execute the Base
# B20 stock tokens (they are chain-native precompiles), so `forge script` can't do this step.
#
# The signing wallet must be the fund owner and hold the basket (buy the stocks on Bankr first).
#
#   SHARES=1 scripts/seed.sh --account deployer                 # Base mainnet, Foundry keystore
#   CHAIN_ID=31337 RPC_URL=http://127.0.0.1:8545 SHARES=10 scripts/seed.sh --private-key 0x...
#   DRY_RUN=1 SHARES=1 scripts/seed.sh                          # print amounts, send nothing
set -euo pipefail

cd "$(dirname "$0")/../contracts"
CHAIN_ID=${CHAIN_ID:-8453}
RPC_URL=${RPC_URL:-https://mainnet.base.org}
DEPLOYMENT="deployments/${CHAIN_ID}.json"
[[ -f $DEPLOYMENT ]] || { echo "No $DEPLOYMENT. Deploy first." >&2; exit 1; }

FUND=$(jq -r .fund "$DEPLOYMENT")
SHARES_WEI=$(cast to-wei "${SHARES:-1}")
SIGNER=("$@")

if [[ $(cast call "$FUND" "seeded()(bool)" --rpc-url "$RPC_URL") == "true" ]]; then
  echo "Fund $FUND is already seeded." >&2
  exit 1
fi

preview=$(cast call "$FUND" "previewMint(uint256)(address[],uint256[])" "$SHARES_WEI" --rpc-url "$RPC_URL" --json)
mapfile -t TOKENS < <(jq -r '.[0] | ltrimstr("[") | rtrimstr("]") | split(", ")[]' <<<"$preview")
mapfile -t AMOUNTS < <(jq -r '.[1] | ltrimstr("[") | rtrimstr("]") | split(", ")[]' <<<"$preview")
mapfile -t SYMBOLS < <(jq -r '.symbols[]' "$DEPLOYMENT")

echo "Seeding $FUND with ${SHARES:-1} BLUE on chain $CHAIN_ID"
for i in "${!TOKENS[@]}"; do
  printf "  %-7s %s  %s units\n" "${SYMBOLS[$i]}" "${TOKENS[$i]}" "${AMOUNTS[$i]}"
done
[[ -n ${DRY_RUN:-} ]] && { echo "DRY_RUN set, nothing sent."; exit 0; }

for i in "${!TOKENS[@]}"; do
  echo "approve ${SYMBOLS[$i]}"
  cast send "${TOKENS[$i]}" "approve(address,uint256)" "$FUND" "${AMOUNTS[$i]}" --rpc-url "$RPC_URL" "${SIGNER[@]}" >/dev/null
done
echo "seed"
cast send "$FUND" "seed(uint256)" "$SHARES_WEI" --rpc-url "$RPC_URL" "${SIGNER[@]}" >/dev/null
echo "Done. totalSupply: $(cast call "$FUND" "totalSupply()(uint256)" --rpc-url "$RPC_URL")"
