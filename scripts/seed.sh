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
#   FUND=blueai SHARES=1 scripts/seed.sh --account deployer     # another fund (default: blue)
set -euo pipefail

cd "$(dirname "$0")/../contracts"
CHAIN_ID=${CHAIN_ID:-8453}
RPC_URL=${RPC_URL:-https://mainnet.base.org}
FUND=${FUND:-blue}
# BLUE keeps deployments/<chainId>.json; every other fund is deployments/<chainId>-<fund>.json.
if [[ $FUND == blue ]]; then DEPLOYMENT="deployments/${CHAIN_ID}.json"; else DEPLOYMENT="deployments/${CHAIN_ID}-${FUND}.json"; fi
[[ -f $DEPLOYMENT ]] || { echo "No $DEPLOYMENT. Deploy first." >&2; exit 1; }

FUND_ADDR=$(jq -r .fund "$DEPLOYMENT")
SYMBOL=$(jq -r '.symbol // "BLUE"' "$DEPLOYMENT")
SHARES_WEI=$(cast to-wei "${SHARES:-1}")
SIGNER=("$@")

if [[ $(cast call "$FUND_ADDR" "seeded()(bool)" --rpc-url "$RPC_URL") == "true" ]]; then
  echo "Fund $FUND_ADDR is already seeded." >&2
  exit 1
fi

preview=$(cast call "$FUND_ADDR" "previewMint(uint256)(address[],uint256[])" "$SHARES_WEI" --rpc-url "$RPC_URL" --json)
mapfile -t TOKENS < <(jq -r '.[0] | ltrimstr("[") | rtrimstr("]") | split(", ")[]' <<<"$preview")
mapfile -t AMOUNTS < <(jq -r '.[1] | ltrimstr("[") | rtrimstr("]") | split(", ")[]' <<<"$preview")
mapfile -t SYMBOLS < <(jq -r '.symbols[]' "$DEPLOYMENT")

echo "Seeding $SYMBOL ($FUND_ADDR) with ${SHARES:-1} $SYMBOL on chain $CHAIN_ID"
for i in "${!TOKENS[@]}"; do
  printf "  %-7s %s  %s units\n" "${SYMBOLS[$i]}" "${TOKENS[$i]}" "${AMOUNTS[$i]}"
done
[[ -n ${DRY_RUN:-} ]] && { echo "DRY_RUN set, nothing sent."; exit 0; }

ME=$(cast wallet address "${SIGNER[@]}")
# Count the nonce here instead of asking before each send: a load-balanced RPC can report a stale
# one right after the previous transaction ("nonce too low").
NONCE=$(cast nonce "$ME" --block pending --rpc-url "$RPC_URL")
send() {
  local receipt
  receipt=$(cast send "$@" --rpc-url "$RPC_URL" "${SIGNER[@]}" --nonce "$NONCE" --json)
  [[ $(jq -r .status <<<"$receipt") == 0x1 ]] || { echo "transaction failed: $*" >&2; exit 1; }
  NONCE=$((NONCE + 1))
  BLOCK=$(cast to-dec "$(jq -r .blockNumber <<<"$receipt")")
}

for i in "${!TOKENS[@]}"; do
  # A rerun after a stop skips the approvals that already went through.
  allowance=$(cast call "${TOKENS[$i]}" "allowance(address,address)(uint256)" "$ME" "$FUND_ADDR" --rpc-url "$RPC_URL" | awk '{print $1}')
  if python3 -c "import sys; sys.exit(0 if $allowance >= ${AMOUNTS[$i]} else 1)"; then
    echo "approve ${SYMBOLS[$i]}: already approved"
    continue
  fi
  echo "approve ${SYMBOLS[$i]}"
  send "${TOKENS[$i]}" "approve(address,uint256)" "$FUND_ADDR" "${AMOUNTS[$i]}"
done
echo "seed"
send "$FUND_ADDR" "seed(uint256)" "$SHARES_WEI"
# Read at the seed's block: the node answering next may not have it yet.
echo "Done in block $BLOCK. totalSupply: $(cast call "$FUND_ADDR" "totalSupply()(uint256)" --rpc-url "$RPC_URL" --block "$BLOCK")"
