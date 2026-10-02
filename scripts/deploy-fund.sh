#!/usr/bin/env bash
# Deploys and seeds another fund (FUND=<id>, e.g. bluex) on Base mainnet, signed by a Foundry keystore.
# Rerun it after any stop: it picks up where it left off.
#
#   1. basket   regenerates contracts/basket/<fund>.json at live prices (skipped once deployed)
#   2. deploy   Deploy.s.sol: fund, swapper, rebalancer, CHIP burner (the fee recipient) and zap,
#               with the same CHIP pool, keeper and updater as BLUE (all read from chain)
#   3. seed     the first mint, from stocks the signer already holds; if any are short it lists
#               what to buy and stops, so buy them and run it again
#   4. checks   the contracts point at each other and the zap quotes a mint
#
# Every step that sends transactions shows what it will do and waits for you to type "yes".
#
#   FUND=bluex scripts/deploy-fund.sh                # BLUEX, keystore account mhaas, 1 share seed
#   FUND=bluex SHARES=2 scripts/deploy-fund.sh       # seed with 2 shares (about $100 each)
#   FUND=bluex ACCOUNT=other scripts/deploy-fund.sh
#   FUND=bluex OWNER=0x... scripts/deploy-fund.sh    # owner other than the signer (then that wallet seeds)
#   FUND=bluex SKIP_BASKET=1 scripts/deploy-fund.sh  # deploy the basket file as it is
#
# Env: BASE_RPC_URL (or contracts/.env; default the public RPC), ETHERSCAN_API_KEY (verifies the
# contracts if set), SEC_USER_AGENT (for the basket step), SUPPLY_CAP / MINT_FEE_BPS (Deploy.s.sol
# defaults: 1,000 shares, 0.30%).
set -euo pipefail
cd "$(dirname "$0")/.."

FUND=${FUND:?set FUND to the fund id, e.g. FUND=bluex}
ACCOUNT=${ACCOUNT:-mhaas}
SHARES=${SHARES:-1}
CHAIN_ID=8453
[[ $FUND != blue ]] || { echo "BLUE is already deployed; this script is for the other funds." >&2; exit 1; }
DEPLOYMENT=contracts/deployments/$CHAIN_ID-$FUND.json
BASKET=contracts/basket/$FUND.json
BLUE=contracts/deployments/$CHAIN_ID.json

if [[ -z ${BASE_RPC_URL:-} && -f contracts/.env ]]; then
  BASE_RPC_URL=$(sed -n 's/^BASE_RPC_URL=//p' contracts/.env | tr -d '"' | tail -1)
fi
RPC=${BASE_RPC_URL:-https://mainnet.base.org}
export BASE_RPC_URL=$RPC # foundry.toml's `base` endpoint reads it

step() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
confirm() {
  local answer
  read -rp "$1 Type yes to go ahead: " answer
  [[ $answer == yes ]] || die "stopped, nothing sent"
}
call() { cast call "$@" --rpc-url "$RPC"; }
lower() { tr '[:upper:]' '[:lower:]'; }

[[ $(cast chain-id --rpc-url "$RPC") == "$CHAIN_ID" ]] || die "$RPC is not Base mainnet"
[[ -f $BLUE ]] || die "no $BLUE: BLUE's deployment supplies the CHIP pool, keeper and updater"
[[ -f contracts/basket/$FUND.config.json ]] || die "no contracts/basket/$FUND.config.json"

# The keystore password is asked once and handed only to the commands that sign, as a file.
read -rsp "Password for keystore '$ACCOUNT': " password
echo
PASSWORD_FILE=$(mktemp) # readable by you only
trap 'rm -f "$PASSWORD_FILE"' EXIT
printf '%s' "$password" >"$PASSWORD_FILE"
unset password ETH_PASSWORD
SIGNER=(--account "$ACCOUNT" --password-file "$PASSWORD_FILE")
ME=$(cast wallet address "${SIGNER[@]}")
OWNER=${OWNER:-$ME}
echo "Signer $ACCOUNT $ME, $(cast balance "$ME" --rpc-url "$RPC" --ether) ETH on Base"

# ---------------------------------------------------------------- 1. basket

if [[ -f $DEPLOYMENT ]]; then
  step "1. Basket: skipped, $DEPLOYMENT already exists"
elif [[ -n ${SKIP_BASKET:-} ]]; then
  step "1. Basket: skipped (SKIP_BASKET), using $BASKET from $(jq -r .generatedAt "$BASKET")"
else
  step "1. Basket: SEC share counts and live Chainlink prices -> $BASKET"
  BASE_RPC_URL=$RPC node scripts/basket.mjs --fund "$FUND" --rpc "$RPC"
fi

# ---------------------------------------------------------------- 2. deploy

if [[ -f $DEPLOYMENT ]]; then
  step "2. Deploy: skipped, $DEPLOYMENT already exists"
else
  step "2. Deploy"
  # Same CHIP, CHIP pool and automation wallets as BLUE, read from its live contracts.
  CHIP=$(jq -r .chip "$BLUE")
  CHIP_SWAPPER=$(call "$(jq -r .burner "$BLUE")" "chipSwapper()(address)")
  CHIP_POOL_FEE=$(call "$CHIP_SWAPPER" "fee()(uint24)" | awk '{print $1}')
  CHIP_POOL_TICK_SPACING=$(call "$CHIP_SWAPPER" "tickSpacing()(int24)" | awk '{print $1}')
  CHIP_POOL_HOOKS=$(call "$CHIP_SWAPPER" "hooks()(address)")
  KEEPER=$(call "$(jq -r .burner "$BLUE")" "keeper()(address)")
  UPDATER=$(call "$(jq -r .rebalancer "$BLUE")" "updater()(address)")

  cat <<EOF
  fund        $(jq -r '.tokenName + " (" + .tokenSymbol + ")"' "$BASKET"), basket generated $(jq -r .generatedAt "$BASKET")
  stocks      $(jq -r '[.tokens[] | "\(.symbol) \((.weight * 10000 | round) / 100)%"] | join(", ")' "$BASKET")
  owner       $OWNER
  keeper      $KEEPER (BLUE's)
  updater     $UPDATER (BLUE's)
  CHIP        $CHIP, pool fee $CHIP_POOL_FEE, tick spacing $CHIP_POOL_TICK_SPACING, hooks $CHIP_POOL_HOOKS
  mint fee    ${MINT_FEE_BPS:-30} bps to the new CHIP burner; supply cap ${SUPPLY_CAP:-1000e18 (default)}
  verify      $([[ -n ${ETHERSCAN_API_KEY:-} ]] && echo "yes, on Basescan" || echo "no (set ETHERSCAN_API_KEY)")
EOF
  confirm "This deploys 6 contracts on Base mainnet from $ME."

  VERIFY=()
  [[ -n ${ETHERSCAN_API_KEY:-} ]] && VERIFY=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
  (
    cd contracts
    FUND=$FUND OWNER=$OWNER KEEPER=$KEEPER UPDATER=$UPDATER CHIP_ADDRESS=$CHIP \
      CHIP_POOL_FEE=$CHIP_POOL_FEE CHIP_POOL_TICK_SPACING=$CHIP_POOL_TICK_SPACING CHIP_POOL_HOOKS=$CHIP_POOL_HOOKS \
      forge script script/Deploy.s.sol --rpc-url "$RPC" "${SIGNER[@]}" --sender "$ME" --broadcast --slow "${VERIFY[@]}"
  )
  [[ -f $DEPLOYMENT ]] || die "forge finished but wrote no $DEPLOYMENT"
  echo "Wrote $DEPLOYMENT. Commit it: the site and the automation read it."
fi

FUND_ADDR=$(jq -r .fund "$DEPLOYMENT")
SYMBOL=$(jq -r .symbol "$DEPLOYMENT")

# ---------------------------------------------------------------- 3. seed

if [[ $(call "$FUND_ADDR" "seeded()(bool)") == true ]]; then
  step "3. Seed: skipped, $SYMBOL is already seeded"
else
  step "3. Seed $SHARES $SYMBOL"
  [[ $(call "$FUND_ADDR" "owner()(address)" | lower) == "${ME,,}" ]] ||
    die "only the fund owner can seed, and that isn't $ME: run scripts/seed.sh from the owner wallet"

  # What the seed deposits, and what the signer still has to buy.
  shares_wei=$(cast to-wei "$SHARES")
  preview=$(call "$FUND_ADDR" "previewMint(uint256)(address[],uint256[])" "$shares_wei" --json)
  mapfile -t TOKENS < <(jq -r '.[0] | ltrimstr("[") | rtrimstr("]") | split(", ")[]' <<<"$preview")
  mapfile -t AMOUNTS < <(jq -r '.[1] | ltrimstr("[") | rtrimstr("]") | split(", ")[]' <<<"$preview")
  mapfile -t SYMBOLS < <(jq -r '.symbols[]' "$DEPLOYMENT")
  short=0
  for i in "${!TOKENS[@]}"; do
    have=$(call "${TOKENS[$i]}" "balanceOf(address)(uint256)" "$ME" | awk '{print $1}')
    need=${AMOUNTS[$i]}
    if python3 -c "import sys; sys.exit(0 if $have >= $need else 1)"; then
      printf "  %-7s need %s, have %s\n" "${SYMBOLS[$i]}" "$(cast format-units "$need" 8)" "$(cast format-units "$have" 8)"
    else
      short=1
      printf "  %-7s need %s, have %s  -> buy %s: https://bankr.bot/terminal/trade?out=%s&chain=base\n" \
        "${SYMBOLS[$i]}" "$(cast format-units "$need" 8)" "$(cast format-units "$have" 8)" \
        "$(cast format-units "$((need - have))" 8)" "${TOKENS[$i]}"
    fi
  done
  if ((short)); then
    echo
    echo "$ME is short of the stocks above. Buy them (a little extra covers rounding), then rerun this script."
    exit 1
  fi
  confirm "This approves exactly these amounts and seeds $SHARES $SYMBOL (0.001 of it is locked at 0xdead forever)."
  FUND=$FUND CHAIN_ID=$CHAIN_ID RPC_URL=$RPC SHARES=$SHARES scripts/seed.sh "${SIGNER[@]}"
fi

# ---------------------------------------------------------------- 4. checks

step "4. Checks"
# A load-balanced RPC can answer from a node a block or two behind the seed: wait until it has it.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ $(call "$FUND_ADDR" "seeded()(bool)") == true ]] && break
  sleep 2
done
failed=0
check() {
  if [[ $2 == "$3" ]]; then echo "  ✓ $1"; else echo "  ✗ $1 (got $2, expected $3)"; failed=1; fi
}
REB=$(jq -r .rebalancer "$DEPLOYMENT")
BURNER=$(jq -r .burner "$DEPLOYMENT")
ZAP=$(jq -r .zap "$DEPLOYMENT")
check "fund is seeded" "$(call "$FUND_ADDR" "seeded()(bool)")" true
check "fund's rebalancer is the deployed one" "$(call "$FUND_ADDR" "rebalancer()(address)" | lower)" "${REB,,}"
check "rebalancer points at the fund" "$(call "$REB" "fund()(address)" | lower)" "${FUND_ADDR,,}"
check "mint fees go to the CHIP burner" "$(call "$FUND_ADDR" "feeRecipient()(address)" | lower)" "${BURNER,,}"
check "burner points at the fund" "$(call "$BURNER" "fund()(address)" | lower)" "${FUND_ADDR,,}"
check "zap mints this fund" "$(call "$ZAP" "fund()(address)" | lower)" "${FUND_ADDR,,}"
quote=$(cast call "$ZAP" "quoteMint(uint256)(uint256,uint256)" 10000000000000000 --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}' || true)
if [[ -n $quote ]]; then
  echo "  ✓ the zap quotes 0.01 $SYMBOL at $(cast format-units "$quote" 6) USDC"
else
  echo "  ✗ the zap can't quote a mint (pools thin or prices stale?)"
  failed=1
fi

# Every fund with a mainnet deployment file, for the automation's FUNDS variable.
FUNDS=$(for f in contracts/deployments/$CHAIN_ID.json contracts/deployments/$CHAIN_ID-*.json; do
  [[ $f == */$CHAIN_ID.json ]] && echo blue || basename "$f" .json | sed "s/^$CHAIN_ID-//"
done | paste -sd' ')

cat <<EOF

$SYMBOL is live: $FUND_ADDR
Next:
  git add $DEPLOYMENT $BASKET && git commit    # the site and the automation read these
  npm run deploy:site                          # the fund picker appears with $SYMBOL
  gh variable set FUNDS --body "$FUNDS"    # keeper and index updates for $SYMBOL too
EOF
exit $failed
