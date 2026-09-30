# Launch runbook

Order matters. The Bankr launch wants a website and an image URL, so **the site goes up first**, in its pre-launch state. The CHIP burner needs CHIP's pool, so it deploys after the launch. The fund can go either side of it: deployed before CHIP, its fees go to your wallet until `DeployBurner.s.sol` and `setFeeRecipient` (step 3b).

```
1 site (pre-launch)  ->  2 bankr launch CHIP  ->  3 deploy  ->  4 seed  ->  5 site (live)  ->  6 automation
```

Every step below is outward-facing or spends money. Run them yourself, one at a time.

## 0. Prerequisites

- A deployer wallet in a Foundry keystore. It will own the fund.
  - Create it with `cast wallet import deployer --interactive`.
  - It needs a little ETH on Base for gas.
  - Later, move ownership to a Safe (see step 6).
- `bankr login`, with a wallet at least 24h old. That's Bankr's launch rule.
- Firebase CLI logged in (`firebase login`).
- An Etherscan v2 API key for verification (it covers Base).
- Two more wallets for the automation (step 6): a **keeper** (only needs gas money) and an **updater** (can only propose index changes, which wait 7 days). Keep neither the owner key nor any funds in them.

## 1. Refresh the basket and put the site up

1. Check `listedFraction` and `iwf` in `contracts/basket/mag7.config.json` against the latest proxy statements. They're estimates; share counts themselves come from SEC EDGAR.
2. Regenerate the basket:

   ```bash
   SEC_USER_AGENT="Your Name you@example.com" npm run basket
   ```

   This reads share counts from EDGAR and live Chainlink prices, and writes `contracts/basket/mag7.json` plus `web/src/data/stocks.json`. It targets 1 BLUE ≈ $100, and the same float shares become the rebalancer's first index, so the fund starts on target.
3. Configure the site. In `web/.env` set `VITE_CHAIN=base`, `VITE_SITE_URL=https://bluechip.markushaas.com` and `VITE_GITHUB_URL`.
4. Deploy it:

   ```bash
   cp .firebaserc.example .firebaserc   # set your Firebase project id
   npm run preview:site                 # temporary URL, check it
   npm run deploy:site
   ```

   Firebase console → Hosting → *Add custom domain* → `bluechip.markushaas.com`. Add the TXT and A records it shows, then wait for the certificate.

The site shows the planned basket at live prices, with "Not live yet" in place of fund stats. It serves `/chip.png` for the launch image.

## 2. Launch $CHIP on Bankr

Simulate first:

```bash
bankr launch --name "Chip" --symbol CHIP \
  --image https://bluechip.markushaas.com/chip.png \
  --website https://bluechip.markushaas.com \
  --fee <your wallet or ENS> --fee-type wallet \
  --simulate
```

If it looks right, run the same command without `--simulate`.

What you get:
- A 100B-supply ERC-20 (Doppler, Uniswap v4) paired with WETH.
- By default, 15% vests to the fee recipient over a year. Add `--no-vesting` to put 100% in the pool.
- `--quote-only-fees` takes those fees all in WETH.

Record the CHIP address.

Optional: set `VITE_CHIP_ADDRESS=<address>` and redeploy the site. The "Buy $CHIP" terminal then goes live before the fund does.

## 3. Deploy the fund, the rebalancer and the CHIP burner

```bash
cd contracts
eval "$(node ../scripts/chip-pool.mjs <CHIP address> | sed 's/^/export /')"  # CHIP_ADDRESS and its v4 pool key
UPDATER=<updater wallet> KEEPER=<keeper wallet> SUPPLY_CAP=1000000000000000000000 \
forge script script/Deploy.s.sol --rpc-url base --account deployer --broadcast \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

- The script deploys the `AerodromeSwapper` over the pools in the basket, the `ChipSwapper` (USDC → WETH → CHIP), `BlueFund` (0.30% fee, recipient = the burner's precomputed address, rebalancer = the rebalancer's), the `Rebalancer` with the basket's float shares as its index, the `ChipBurner`, and the `MintZap` (mint with USDC, ETH or WETH through the same pools). It writes `deployments/8453.json`, which the site and the scripts import.
- `KEEPER=<keeper wallet>` makes the automation keeper the burner's keeper (default: the owner).
- **Fund before CHIP:** leave out the `CHIP_*` variables. Mint fees then go to `FEE_RECIPIENT` (default: the owner). Once CHIP is live, run step 3b.

### 3b. Add the CHIP burner to a fund deployed before CHIP

```bash
cd contracts
eval "$(node ../scripts/chip-pool.mjs <CHIP address> | sed 's/^/export /')"
KEEPER=<keeper wallet> \
forge script script/DeployBurner.s.sol --rpc-url base --account deployer --broadcast --verify
cast send <fund> "setFeeRecipient(address)" <burner> --account deployer --rpc-url base
```

Fees minted before this sat in `FEE_RECIPIENT`; send that BLUE to the burner to have it burned too.

### 3c. Add the zap to a fund deployed before it

`MintZap` lets people mint with USDC, ETH or WETH: it buys exactly the stocks a mint deposits, with exact-output swaps in the basket's Aerodrome pools (ETH and WETH go through the USDC/WETH pool first), and mints in the same transaction. It has no owner and needs nothing from the fund, so anyone can deploy it. Running the script again deploys a new zap and points the site at it; the old one keeps working for anyone who calls it directly.

```bash
cd contracts
forge script script/DeployZap.s.sol --rpc-url base --account deployer --broadcast --verify
```

This writes `zap`, `usdc` and `weth` to `deployments/8453.json`, and the site shows "Pay with USDC / ETH / WETH" once it's redeployed. Forge can't simulate the stock tokens, so the first zap mint is also the first time they move through exact-output swaps. Check the quote, then make a small mint with the real node:

```bash
cast call <zap> "quoteMint(uint256)(uint256,uint256)" 10000000000000000 --rpc-url base   # 0.01 BLUE: USDC in, ETH in
cast send <zap> "mintWithEth(uint256,address,uint256)" 10000000000000000 <you> <unix deadline> \
  --value <ETH quote + 2%> --account deployer --rpc-url base
```
- Rebalancer settings default to 0.5% max slippage against the oracle, trades of 0.05–1% of NAV, 30 minutes apart, on prices at most 6 hours old. Override with `MAX_SLIPPAGE_BPS`, `MAX_TRADE_BPS`, `MIN_TRADE_BPS`, `COOLDOWN`, `MAX_FEED_AGE`; the owner can change them later within hard caps.
- `SUPPLY_CAP` is in wei. Here 1,000 BLUE, about $100k. Keep it low at first; stock liquidity on Base is thin.
- The script never touches the stock tokens. They're chain-native B20 precompiles, and forge's simulator can't execute them. (The swapper's constructor reads the pools, which are ordinary contracts.)

Commit `contracts/deployments/8453.json`.

## 4. Seed

The owner makes the first mint at the fixed seed ratio, and 0.001 BLUE of it is locked at `0xdead` forever.

1. Buy the basket for `SHARES` BLUE with the deployer wallet. Each stock has a Bankr link: `https://bankr.bot/terminal/trade?out=<stock>&chain=base`.
2. Print the exact amounts without sending anything:

   ```bash
   DRY_RUN=1 SHARES=1 scripts/seed.sh
   ```

3. Seed. This runs 7 approvals, then `seed`, all through `cast send`:

   ```bash
   SHARES=1 scripts/seed.sh --account deployer
   ```

Check the result:

```bash
cast call <fund> "previewRedeem(uint256)(address[],uint256[])" 1000000000000000000 --rpc-url base
```

## 5. Site goes live

The site picks up `deployments/8453.json` automatically.

```bash
npm run deploy:site
```

Smoke test with a second wallet: mint 0.01 BLUE (browser wallet → permits + one tx), redeem it, then open the CHIP section.

## 6. Turn on the automation

The fund is on target at launch, so nothing trades until the index changes. Two jobs keep it that way (`.github/workflows/automation.yml`):

- **keeper**, every 10 minutes on weekdays 14:00–20:00 UTC: activates a due index update, makes at most one trade, and once the fees in the CHIP burner are worth $25 it burns them (quoting the burn first and accepting at most 2% less).
- **index-update**, Mondays 15:00 UTC: re-reads SEC filings and proposes a new index when any company's float moved 0.5% or more. A move over 25% stops it for you to check.

Set up in GitHub → Settings → Secrets and variables → Actions (or with `gh secret set` / `gh variable set`):
- Secrets: `KEEPER_KEY`, `UPDATER_KEY`, and optionally `BASE_RPC_URL` (the public RPC rate-limits).
- Variables: `SEC_USER_AGENT` = `Your Name you@example.com`, then add `8453` to `KEEPER_CHAINS` and `INDEX_CHAINS` (space-separated; `84532` is Base Sepolia).
- Commit `contracts/deployments/8453.json` first: the workflow reads it.

Before enabling, run both once by hand without keys to see what they would do:

```bash
npm run keeper -- --dry-run
SEC_USER_AGENT="Your Name you@example.com" npm run index:update -- --dry-run
```

The first index change is also the first time trades touch the real stock tokens (forge can't simulate them; the keeper's simulation runs on the real node). Watch that first rebalance and keep the supply cap low until it has worked.

## 7. After launch

- **Ownership:** `transferOwnership(<safe>)` on the fund and on the rebalancer, then `acceptOwnership()` from the Safe (Ownable2Step). The fund owner can change the fee (≤ 1%), the supply cap and the fee recipient, propose a new rebalancer (takes effect after 7 days, so holders can redeem first), and switch rebalancing off at once. It can never move holdings out itself.
- **Emergency brake:** if prices or trades look wrong, `cast send <fund> "disableRebalancer()" --account deployer --rpc-url base`. Mint and redeem keep working.
- **Yearly:** after proxy season, check `listedFraction` and `iwf` in the config and let the next index update pick them up.
- **Supply cap:** raise it as liquidity grows: `cast send <fund> "setSupplyCap(uint256)" <wei> --account deployer --rpc-url base`.

## Testnet (Base Sepolia)

The real stock tokens don't exist on Sepolia, so it runs on mocks. The quickest check is the live test, which deploys a fresh set and runs mint, redeem, a CHIP buy-and-burn, the index timelock and a rebalancing trade (the trade needs Mon–Fri 14:30–20:00 UTC):

```bash
npm run test:testnet                     # keystore account mhaas; ACCOUNT=<name> for another
REUSE=1 npm run test:testnet             # rerun the checks on the last deployment
```

To deploy by hand instead:

```bash
cd contracts && forge script script/DeployMocks.s.sol --rpc-url base_sepolia --account deployer --broadcast
```

Then set `VITE_CHAIN=baseSepolia`. The site shows a faucet for test stocks and test CHIP.
