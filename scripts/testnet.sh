#!/usr/bin/env bash
# Live end-to-end test on Base Sepolia, with mock stocks, feeds and DEX:
#   deploy -> mint -> redeem -> CHIP claim -> index timelock -> a rebalancing trade
#
# Each run deploys a fresh set (about 60 transactions of testnet gas) and writes
# contracts/deployments/84532.json, which the site uses with VITE_CHAIN=baseSepolia. The rebalancer
# starts with the last stock's float +20%, so there is a trade to make without the 7-day index
# delay. Trades only run in the US session (Mon-Fri 14:30-20:00 UTC); outside it that step is
# skipped, and REUSE=1 reruns the checks on the same deployment later.
#
#   scripts/testnet.sh                        # keystore account mhaas, asks for its password once
#   PASSWORD_FILE=~/.pw scripts/testnet.sh    # or read the password from a file
#   ACCOUNT=other RPC_URL=https://... scripts/testnet.sh
#   KEYSTORE=path/to/keystore scripts/testnet.sh   # a keystore file instead of a named account
#   REUSE=1 scripts/testnet.sh                # skip the deploy, test deployments/<chain>.json
#   BRAKE=1 scripts/testnet.sh                # also test disableRebalancer (leaves it off)
#   PRIVATE_KEY=0x... RPC_URL=http://127.0.0.1:8545 scripts/testnet.sh   # local anvil
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=${RPC_URL:-https://sepolia.base.org}
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
DEPLOYMENT=contracts/deployments/$CHAIN_ID.json
[[ $CHAIN_ID == 8453 ]] && { echo "Refusing to run on Base mainnet." >&2; exit 1; }

# The password goes only to the commands that sign, as a file: exported as ETH_PASSWORD, Foundry
# would treat every read-only `cast call` as a keystore call too.
if [[ -n ${PRIVATE_KEY:-} ]]; then
  SIGNER=(--private-key "$PRIVATE_KEY")
else
  if [[ -n ${KEYSTORE:-} ]]; then
    SIGNER=(--keystore "$KEYSTORE")
  else
    SIGNER=(--account "${ACCOUNT:-mhaas}")
  fi
  if [[ -z ${PASSWORD_FILE:-} ]]; then
    read -rsp "Password for keystore '${KEYSTORE:-${ACCOUNT:-mhaas}}': " password
    echo
    PASSWORD_FILE=$(mktemp) # created readable by you only
    trap 'rm -f "$PASSWORD_FILE"' EXIT
    printf '%s' "$password" >"$PASSWORD_FILE"
    unset password
  fi
  SIGNER+=(--password-file "$PASSWORD_FILE")
fi
unset ETH_PASSWORD
ME=$(cast wallet address "${SIGNER[@]}")

passed=0
failed=0
ok() { echo "  ✓ $*"; passed=$((passed + 1)); }
bad() { echo "  ✗ $*"; failed=$((failed + 1)); }
step() { printf '\n== %s\n' "$*"; }
py() { python3 -c "print($*)"; }
lower() { tr '[:upper:]' '[:lower:]'; }

# A public RPC like sepolia.base.org balances requests over nodes that can be a block or two
# apart. So the script counts its own nonce, and every read is pinned to the block of its last
# transaction (BLOCK), retried until the node serving it has that block.
retry() {
  local out i
  for i in $(seq 15); do
    if out=$("$@" 2>&1); then
      printf '%s\n' "$out"
      return 0
    fi
    # A revert is an answer; only a node that is behind is worth asking again.
    grep -qiE "header not found|unknown block|block not found|not available|missing trie|rate limit|429" <<<"$out" ||
      break
    sleep 1
  done
  printf '%s\n' "$out" >&2
  return 1
}
cast_call() { retry cast call "$@" --rpc-url "$RPC" --block "$BLOCK"; }
# Read one value ("123 [1.23e2]" -> "123").
call() { cast_call "$@" | awk 'NR == 1 {print $1}'; }
# Read line $1 of a multi-value return.
call_n() { local n=$1; shift; cast_call "$@" | awk -v n="$n" 'NR == n {print $1}'; }
# A uint256[] as a cast argument: "[1,2,3]".
call_array() { cast_call "$@" --json | jq -r '.[0]' | tr -d ' '; }
block_time() { retry cast block "$BLOCK" -f timestamp --rpc-url "$RPC"; }

send() {
  local receipt
  receipt=$(cast send "$@" --rpc-url "$RPC" "${SIGNER[@]}" --nonce "$NONCE" --json)
  [[ $(jq -r .status <<<"$receipt") == 0x1 ]] || { echo "transaction failed: $*" >&2; exit 1; }
  NONCE=$((NONCE + 1))
  BLOCK=$(cast to-dec "$(jq -r .blockNumber <<<"$receipt")")
}

# check <description> <python condition>
check() {
  local desc=$1 cond=$2
  [[ $(py "$cond") == True ]] && { ok "$desc"; return; }
  bad "$desc ($cond)"
}

# expect_revert <description> <error signature> <cast call args...>
expect_revert() {
  local desc=$1 sig=$2 out
  shift 2
  local sel
  sel=$(cast sig "$sig")
  if out=$(cast_call "$@" --from "$ME" 2>&1); then
    bad "$desc: did not revert"
  elif grep -qi -e "${sel#0x}" -e "${sig%%(*}" <<<"$out"; then
    ok "$desc (${sig%%(*})"
  else
    bad "$desc: reverted with something else: $(tail -1 <<<"$out")"
  fi
}

echo "Chain $CHAIN_ID via $RPC, signer $ME ($(cast balance "$ME" --rpc-url "$RPC" --ether) ETH)"

# ---------------------------------------------------------------- deploy

if [[ -z ${REUSE:-} ]]; then
  step "Deploy mocks, fund, vault and rebalancer"
  log=$(mktemp)
  if ! (cd contracts && SKEW_INDEX_BPS=2000 COOLDOWN=300 forge script script/DeployMocks.s.sol \
    --rpc-url "$RPC" "${SIGNER[@]}" --sender "$ME" --broadcast --slow) >"$log" 2>&1; then
    tail -20 "$log"
    exit 1
  fi
  ok "deployed (log: $log)"
  # Carry on from forge's own record, not from a node that may not have seen it all yet.
  run=contracts/broadcast/DeployMocks.s.sol/$CHAIN_ID/run-latest.json
  NONCE=$(python3 -c "import json; print(max(int(t['transaction']['nonce'], 16) for t in json.load(open('$run'))['transactions']) + 1)")
  BLOCK=$(python3 -c "import json; print(max(int(r['blockNumber'], 16) for r in json.load(open('$run'))['receipts']))")
else
  NONCE=$(cast nonce "$ME" --block pending --rpc-url "$RPC")
  BLOCK=$(cast block-number --rpc-url "$RPC")
fi
[[ -f $DEPLOYMENT ]] || { echo "No $DEPLOYMENT. Run without REUSE first." >&2; exit 1; }

FUND=$(jq -r .fund "$DEPLOYMENT")
VAULT=$(jq -r .vault "$DEPLOYMENT")
CHIP=$(jq -r .chip "$DEPLOYMENT")
REB=$(jq -r .rebalancer "$DEPLOYMENT")
FAUCET=$(jq -r .faucet "$DEPLOYMENT")
mapfile -t TOKENS < <(jq -r '.tokens[]' "$DEPLOYMENT")
mapfile -t FEEDS < <(jq -r '.feeds[]' "$DEPLOYMENT")
mapfile -t SYMBOLS < <(jq -r '.symbols[]' "$DEPLOYMENT")
N=${#TOKENS[@]}

step "Wiring"
check "fund's rebalancer is the deployed one" "'$(call "$FUND" "rebalancer()(address)" | lower)' == '${REB,,}'"
check "rebalancer points at the fund" "'$(call "$REB" "fund()(address)" | lower)' == '${FUND,,}'"
check "fund is seeded" "'$(call "$FUND" "seeded()(bool)")' == 'true'"
check "rebalancer's updater is the signer" "'$(call "$REB" "updater()(address)" | lower)' == '${ME,,}'"

# ---------------------------------------------------------------- mint / redeem

step "Mint 1 BLUE"
ONE=1000000000000000000
send "$FAUCET" "drip(address,uint256)" "$ME" "$ONE"
for t in "${TOKENS[@]}"; do
  send "$t" "approve(address,uint256)" "$FUND" "$(cast max-uint)"
done
to_minter=$(call_n 1 "$FUND" "previewMintFee(uint256)(uint256,uint256)" "$ONE")
fee=$(call_n 2 "$FUND" "previewMintFee(uint256)(uint256,uint256)" "$ONE")
blue0=$(call "$FUND" "balanceOf(address)(uint256)" "$ME")
vault0=$(call "$FUND" "balanceOf(address)(uint256)" "$VAULT")
send "$FUND" "mint(uint256,address)" "$ONE" "$ME"
check "minter gets 1 BLUE minus the fee" "$(call "$FUND" "balanceOf(address)(uint256)" "$ME") == $blue0 + $to_minter"
check "CHIP vault gets the 0.30% fee" "$(call "$FUND" "balanceOf(address)(uint256)" "$VAULT") == $vault0 + $fee and $fee == $ONE * 30 // 10000"

step "Redeem 0.5 BLUE"
HALF=500000000000000000
mapfile -t OUT < <(cast_call "$FUND" "previewRedeem(uint256)(address[],uint256[])" "$HALF" --json |
  jq -r '.[1]' | tr -d '[] ' | tr ',' '\n')
before=()
for t in "${TOKENS[@]}"; do before+=("$(call "$t" "balanceOf(address)(uint256)" "$ME")"); done
send "$FUND" "redeem(uint256,address)" "$HALF" "$ME"
for i in "${!TOKENS[@]}"; do
  check "${SYMBOLS[$i]} paid out pro rata" \
    "$(call "${TOKENS[$i]}" "balanceOf(address)(uint256)" "$ME") == ${before[$i]} + ${OUT[$i]} and ${OUT[$i]} > 0"
done

# ---------------------------------------------------------------- CHIP

step "Burn CHIP for vault BLUE"
send "$CHIP" "faucet()"
AMOUNT=1000000000000000000000000000 # 1B CHIP, 1% of supply
expected=$(call "$VAULT" "previewClaim(uint256)(uint256)" "$AMOUNT")
supply0=$(call "$CHIP" "totalSupply()(uint256)")
blue0=$(call "$FUND" "balanceOf(address)(uint256)" "$ME")
send "$CHIP" "approve(address,uint256)" "$VAULT" "$AMOUNT"
send "$VAULT" "claim(uint256,uint256,address)" "$AMOUNT" "$expected" "$ME"
check "claim pays vault BLUE x 1%" "$(call "$FUND" "balanceOf(address)(uint256)" "$ME") == $blue0 + $expected and $expected > 0"
check "claimed CHIP is burned" "$(call "$CHIP" "totalSupply()(uint256)") == $supply0 - $AMOUNT"

# ---------------------------------------------------------------- index timelock

step "Index updates wait 7 days"
FLOATS=$(call_array "$REB" "floatShares()(uint256[])")
MULTS=$(call_array "$REB" "multipliers()(uint256[])")
send "$REB" "proposeIndex(uint256[],uint256[])" "$FLOATS" "$MULTS"
now=$(block_time)
eta=$(call "$REB" "pendingIndexEta()(uint256)")
check "activates 7 days out" "abs($eta - $now - 7 * 86400) < 120"
expect_revert "activating early" "TooEarly(uint256)" "$REB" "activateIndex()"
send "$REB" "cancelIndex()"
check "cancel clears it" "$(call "$REB" "pendingIndexEta()(uint256)") == 0"

# ---------------------------------------------------------------- rebalance

step "Rebalance"
if [[ $(call "$REB" "marketOpen()(bool)") != true ]]; then
  echo "  - skipped: outside the US session (Mon-Fri 14:30-20:00 UTC). Rerun then with REUSE=1."
else
  # Mock feeds only update when poked: mark every price fresh.
  for f in "${FEEDS[@]}"; do
    send "$f" "setPrice(int256)" "$(call "$f" "answer()(int256)")"
  done
  echo "  keeper says:"
  CHAIN_ID=$CHAIN_ID RPC_URL=$RPC node scripts/keeper.mjs --dry-run | sed 's/^/    /'

  plan=$(cast_call "$REB" "plan()(bool,uint256,uint256,uint256)" | awk '{print $1}')
  mapfile -t P <<<"$plan"
  can=${P[0]} sell=${P[1]} buy=${P[2]} value=${P[3]}
  if [[ $can != true ]]; then
    cooling=$(py "$(block_time) < $(call "$REB" "lastTradeAt()(uint256)") + $(call "$REB" "cooldown()(uint256)")")
    if [[ $cooling == True ]]; then
      echo "  - skipped: cooling down from the last trade. Rerun in a few minutes with REUSE=1."
    else
      bad "plan finds nothing to do (on target already? best trade $value)"
    fi
  else
    echo "  trading \$$(py "round($value / 1e18, 2)") of ${SYMBOLS[$sell]} for ${SYMBOLS[$buy]}"
    [[ ${SYMBOLS[$buy]} == "${SYMBOLS[$((N - 1))]}" ]] && ok "buys the stock whose float was raised" ||
      bad "expected to buy ${SYMBOLS[$((N - 1))]}, plan buys ${SYMBOLS[$buy]}"
    nav0=$(call_n 4 "$REB" "valuation()(uint256[],uint256[],uint256[],uint256)")
    hs0=$(call "$FUND" "holdings(address)(uint256)" "${TOKENS[$sell]}")
    hb0=$(call "$FUND" "holdings(address)(uint256)" "${TOKENS[$buy]}")
    max_slip=$(call "$REB" "maxSlippageBps()(uint256)")
    send "$REB" "rebalance(uint256,uint256)" "$sell" "$buy"
    nav1=$(call_n 4 "$REB" "valuation()(uint256[],uint256[],uint256[],uint256)")
    check "sold ${SYMBOLS[$sell]}" "$(call "$FUND" "holdings(address)(uint256)" "${TOKENS[$sell]}") < $hs0"
    check "bought ${SYMBOLS[$buy]}" "$(call "$FUND" "holdings(address)(uint256)" "${TOKENS[$buy]}") > $hb0"
    check "trade is at most 1% of NAV" "$value <= $nav0 // 100 + 1"
    check "NAV cost within the slippage bound" "$nav0 - $nav1 <= $value * $max_slip // 10000 + 10**12"
    expect_revert "a second trade inside the cooldown" "CoolingDown(uint256)" "$REB" "rebalance(uint256,uint256)" "$sell" "$buy"
  fi
fi

# ---------------------------------------------------------------- emergency brake

if [[ -n ${BRAKE:-} ]]; then
  step "Emergency brake"
  send "$FUND" "disableRebalancer()"
  check "rebalancer switched off" "'$(call "$FUND" "rebalancer()(address)")' == '0x0000000000000000000000000000000000000000'"
  blue0=$(call "$FUND" "balanceOf(address)(uint256)" "$ME")
  send "$FUND" "redeem(uint256,address)" 1000 "$ME"
  check "redeem still works" "$(call "$FUND" "balanceOf(address)(uint256)" "$ME") == $blue0 - 1000"
fi

# ---------------------------------------------------------------- summary

step "Result: $passed passed, $failed failed"
if [[ $CHAIN_ID == 84532 ]]; then
  echo "fund        https://sepolia.basescan.org/address/$FUND"
  echo "rebalancer  https://sepolia.basescan.org/address/$REB"
fi
[[ $failed == 0 ]]
