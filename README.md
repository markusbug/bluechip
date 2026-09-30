# Bluechip 🔵

**An onchain index fund of tokenized US stocks, on Base.**

Base is blue. The stocks are blue chips. Two tokens:

| Token | Ticker | What it is |
|---|---|---|
| Bluechip Index | `$BLUE` | The fund share. An ERC-20 backed in kind by the seven largest US tech stocks (NVDA, AAPL, GOOGL, MSFT, AMZN, META, TSLA), weighted by float-adjusted market cap like the S&P 500 and kept on that index automatically. Mint by depositing the basket, redeem to get it back. |
| Chip | `$CHIP` | The project token, launched on [Bankr](https://bankr.bot). Every mint pays 0.30% in `$BLUE` into the CHIP vault; burn CHIP there for your pro-rata share. |

Put the two together and you get **BLUE + CHIP**.

## How it works

```
             deposit 7 stocks                          0.30% of each mint (as BLUE)
  minter  ───────────────────────►  BlueFund ($BLUE)  ────────────────────────────►  ChipVault
          ◄───────────────────────                                                       │
             BLUE (minus the fee)      redeem: burn BLUE, get the stocks back            │ burn CHIP,
                                       (free, never paused)                              │ get vault BLUE
                                                                                          ▼ pro rata
                                                                              $CHIP holders (Bankr token)

  SEC EDGAR ──► index-update ──► Rebalancer ──(7-day delay)──► new index
                                     │
  keeper (anyone) ──► rebalance ─────┴──► BlueFund.swapHoldings ──► AerodromeSwapper ──► stock/USDC pools
```

- **Mint and redeem never read an oracle.** They are pure ratios of `holdings / totalSupply`. Deposits round up and payouts round down, so between trades the ratio only ever grows.
- **The stocks** are Coinbase's tokenized equities: native B20 tokens on Base (`AAPLc`, … at `0xb200…`), 8 decimals, EIP-2612 permit. Dividends and splits move a `multiplier()`, not balances, so the basket needs no rebalancing for them.
- **`$CHIP`** is a standard Bankr/Doppler token (100B supply, `burn`, `permit`). Its "fees flow into the token" logic lives in `ChipVault`, which has no owner. `claim` burns CHIP and pays `vaultBLUE × amount / CHIP.totalSupply()`, so the backing per CHIP never decreases.
- **Admin** is `Ownable2Step`. On the fund it sets the mint fee (hard-capped at 1%), the supply cap (0 pauses minting) and the fee recipient. It can also replace the rebalancer, which takes 7 days so holders can redeem first, or switch rebalancing off at once. It can never move holdings out itself.
- **Frozen stock?** `redeemExcept` lets you leave a paused constituent behind and still exit with the rest.
- **Browser wallets** (MetaMask, Rabby) mint with one gasless permit per stock plus a single `mintWithPermits` transaction. Smart wallets (Base Account, Ambire) batch approvals and the mint atomically (EIP-5792). After the first mint it's one click.

## Staying on the index

The fund weights like the S&P 500 (which Vanguard's VOO tracks): float-adjusted market cap. Each company's float shares are its shares outstanding from its latest SEC filing, times the fraction in listed share classes, times an investable weight factor (IWF) that leaves out insider and strategic holdings.

- **Price moves need no trades.** Holding tokens in proportion to float shares stays cap-weighted as prices move, exactly as an index fund does between index updates.
- **Index updates** come from `scripts/index-update.mjs`: it reads EDGAR, and if any company's float moved by 0.5% or more it proposes the new index to the `Rebalancer`. The proposal applies after 7 days; anyone can activate it. The updater key can only propose, and the owner can cancel. Changes over 25% stop the script for a human to check (usually a split that EDGAR hasn't caught up with).
- **Splits** don't disturb anything: the index stores each float count with the token `multiplier()` it was counted at, and weighs a company as `floatShares × price / multiplier`.
- **Trades** are made by anyone calling `Rebalancer.rebalance(sell, buy)`; `scripts/keeper.mjs` does it. The contract checks `sell` is overweight and `buy` underweight at Chainlink prices, sizes the trade (at most 1% of NAV, at least 0.05%, 30 minutes apart), and asks the fund to swap with a minimum output of the oracle value minus 0.5%. The swap goes stock → USDC → stock through Aerodrome Slipstream pools, directly (no router).
- **Market hours only.** Trades run on weekdays 14:30–20:00 UTC (the US session under both EST and EDT) and only on prices updated in the last 6 hours, so weekend and holiday DEX prices are never traded against stale feeds.
- **Automation:** `.github/workflows/automation.yml` runs the keeper every 10 minutes in the session and the index update weekly, once `AUTOMATION_ENABLED` is set.
- **Trust:** the Chainlink feeds set each trade's minimum output, so a wrong price means trading at that wrong price, at most 1% of NAV per 30 minutes until someone calls `disableRebalancer()`. The updater is bounded by the 7-day delay and the owner's cancel, and the owner by the 7-day delay on a new rebalancer. A holder who disagrees with any change can redeem in kind before it applies.

## Repository layout

```
contracts/                Foundry
  src/BlueFund.sol        $BLUE: in-kind seed/mint/mintWithPermits/redeem/redeemExcept, capped fee
  src/ChipVault.sol       holds the BLUE fees; claim / claimWithPermit burn CHIP
  src/Rebalancer.sol      the index (float shares, 7-day updates) and permissionless rebalance
  src/AerodromeSwapper.sol  stock -> USDC -> stock through Aerodrome Slipstream pools
  src/mocks/              MockStock, MockChip (mimics the Bankr token), MockBasketFaucet,
                          MockPriceFeed, MockOracleSwapper (a DEX at feed prices)
  test/                   unit, fuzz and invariant tests (83 tests; 100% line coverage on src)
  script/Deploy.s.sol     mainnet: fund + vault + swapper + rebalancer over real stocks and CHIP
  script/DeployMocks.s.sol  local / Base Sepolia with mocks, seeded
  basket/mag7.config.json   tickers, addresses, feeds, pools, CIKs, IWFs  (edit this)
  basket/mag7.json          generated seed vector                          (npm run basket)
  deployments/<chainId>.json  written by the deploy scripts, imported by the site
scripts/basket.mjs        EDGAR shares + live Chainlink prices -> seed units and initial index
scripts/index-update.mjs  EDGAR -> proposes a new index when float shares move
scripts/keeper.mjs        activates due index updates and makes rebalancing trades
.github/workflows/        runs the keeper and the index update on a schedule
scripts/seed.sh           mainnet seeding with cast (forge can't execute B20 precompiles)
scripts/export-abi.mjs    contracts/out -> web/src/abi.ts
web/                      Vite + React 19 + Tailwind v4 + wagmi 3 + viem; static, no backend
docs/PLAN.md              the original design
docs/LAUNCH.md            mainnet runbook: site -> bankr launch -> deploy -> seed -> live
```

## Run it locally

```bash
git submodule update --init --recursive
npm install
npm test                       # forge test: unit + fuzz + invariants

npm run chain                  # anvil on :8545 (separate terminal)
npm run deploy:local           # mock stocks, feeds, DEX + mock CHIP + fund + vault + rebalancer, seeded
cp web/.env.example web/.env   # set VITE_CHAIN=anvil
npm run web                    # http://localhost:5173
```

On the local chain the wallet menu offers an **Anvil dev account**, and the site has faucets for test stocks and test CHIP. Everything works end to end: mint (permits + one tx), redeem, burn CHIP.

To watch a rebalance, start anvil inside the US session (`anvil --timestamp <a weekday 15:00 UTC>`), propose a changed index with `cast send <rebalancer> "proposeIndex(uint256[],uint256[])"`, skip the delay with `cast rpc evm_increaseTime 604800`, refresh the mock feeds (`setPrice`), and run `KEEPER_KEY=<anvil key> CHAIN_ID=31337 RPC_URL=http://127.0.0.1:8545 npm run keeper`.

## Launch

See [`docs/LAUNCH.md`](docs/LAUNCH.md). In short:

1. Put the site up (it shows the planned basket at live prices).
2. Launch CHIP with Bankr:

   ```bash
   bankr launch --name "Chip" --symbol CHIP --image https://bluechip.markushaas.com/chip.png \
     --website https://bluechip.markushaas.com --fee <wallet> --fee-type wallet --simulate
   ```

3. Run `forge script script/Deploy.s.sol` with `CHIP_ADDRESS`.
4. Seed with `scripts/seed.sh`.
5. Redeploy the site.
6. Turn on the automation (keys in GitHub secrets, then `AUTOMATION_ENABLED=true`).

## Why some things are the way they are

- **The stock tokens can't run in a fork.** Their code is the single byte `0xef` (a chain-native precompile), so anvil forks and `forge script` simulations hit `OpcodeNotFound`. Tests use mocks, including a mock Slipstream pool for the swapper. On mainnet the constituent tokens are only touched through the real node (`cast send`, the site, the keeper), which simulates them correctly. So the first real rebalance is also the first time the swap path meets the real tokens: dry-run it (`npm run keeper -- --dry-run`) and keep the supply cap low until it has worked.
- **The fund owns what it accounts for.** Holdings are tracked internally, so tokens sent to the fund directly never change mint or redeem amounts. The owner can `sweep` only the excess over `holdings`.
- **The site is static.** It has no keys, no backend and no analytics. Stock icons are served from the site itself, and Base Account telemetry is off. The only third parties are Google Fonts, the Base RPC and, inside the CHIP section, the Bankr trade iframe.

## Status and risks

Unaudited weekend-project code. Keep the supply cap low. The rebalancer adds oracle, DEX and keeper dependencies that mint and redeem don't have; the owner can switch it off at once with `disableRebalancer()`. Coinbase's tokenized stocks are not offered to US persons, and their issuer can pause or restrict transfers. An index product and a fee-accruing token can raise securities questions. Check them before a public launch.

## License

MIT
