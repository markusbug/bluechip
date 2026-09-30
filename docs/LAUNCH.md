# Launch runbook

Order matters. The CHIP vault is immutable and needs the CHIP address, so **CHIP launches before the fund deploys**. The Bankr launch wants a website and an image URL, so **the site goes up first**, in its pre-launch state.

```
1 site (pre-launch)  ->  2 bankr launch CHIP  ->  3 deploy fund + vault  ->  4 seed  ->  5 site (live)
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

## 1. Refresh the basket and put the site up

1. Check `sharesOutstanding` in `contracts/basket/mag7.config.json` against the latest filings. The numbers in the repo are approximate.
2. Regenerate the basket:

   ```bash
   npm run basket
   ```

   This reads live Chainlink prices and writes `contracts/basket/mag7.json` plus `web/src/data/stocks.json`. It targets 1 BLUE ≈ $100.
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
- The fee recipient earns 0.665% of trading volume. Claim it with `bankr fees claim <CHIP address>`.
- `--quote-only-fees` takes those fees all in WETH.

Record the CHIP address.

Optional: set `VITE_CHIP_ADDRESS=<address>` and redeploy the site. The "Buy $CHIP" terminal then goes live before the fund does.

## 3. Deploy the fund and the vault

```bash
cd contracts
CHIP_ADDRESS=0x... SUPPLY_CAP=1000000000000000000000 \
forge script script/Deploy.s.sol --rpc-url base --account deployer --broadcast \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

- The script deploys `BlueFund` (0.30% fee, recipient = the vault's precomputed address) and then `ChipVault(fund, CHIP)`. It writes `deployments/8453.json`, which the site imports.
- `SUPPLY_CAP` is in wei. Here 1,000 BLUE, about $100k. Keep it low at first; stock liquidity on Base is thin.
- The script never touches the stock tokens. They're chain-native B20 precompiles, and forge's simulator can't execute them.

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

## 6. After launch

- **Ownership:** `transferOwnership(<safe>)` on the fund, then `acceptOwnership()` from the Safe (Ownable2Step). The owner can only change the fee (≤ 1%), the supply cap and the fee recipient. It can never move holdings.
- **Supply cap:** raise it as liquidity grows: `cast send <fund> "setSupplyCap(uint256)" <wei> --account deployer --rpc-url base`.
- **Creator fees:** CHIP's trading fees land in the fee wallet. Claim them with `bankr fees claim <CHIP>`. To route value into CHIP, buy the basket with them, mint BLUE and send it to the vault. Every CHIP holder's backing rises.

## Testnet (Base Sepolia)

The real stock tokens don't exist on Sepolia, so it runs on mocks:

```bash
cd contracts && forge script script/DeployMocks.s.sol --rpc-url base_sepolia --account deployer --broadcast
```

Then set `VITE_CHAIN=baseSepolia`. The site shows a faucet for test stocks and test CHIP.
