# Bluechip 🔵

**An onchain index fund of tokenized US stocks, on Base.**

Base is blue. The stocks are blue chips. Two tokens:

| Token | Ticker | What it is |
|---|---|---|
| Bluechip Index | `$BLUE` | The fund share. An ERC-20 backed in kind by the seven largest US tech stocks (NVDA, AAPL, GOOGL, MSFT, AMZN, META, TSLA), cap-weighted. Mint by depositing the basket, redeem to get it back. |
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
```

- **No oracle anywhere in the contracts.** Mint and redeem are pure ratios of `holdings / totalSupply`. Deposits round up and payouts round down, so the ratio only ever grows.
- **The stocks** are Coinbase's tokenized equities: native B20 tokens on Base (`AAPLc`, … at `0xb200…`), 8 decimals, EIP-2612 permit. Dividends and splits move a `multiplier()`, not balances, so the basket needs no rebalancing for them.
- **`$CHIP`** is a standard Bankr/Doppler token (100B supply, `burn`, `permit`). Its "fees flow into the token" logic lives in `ChipVault`, which has no owner. `claim` burns CHIP and pays `vaultBLUE × amount / CHIP.totalSupply()`, so the backing per CHIP never decreases.
- **Admin** is `Ownable2Step` and can only set the mint fee (hard-capped at 1%), the supply cap (0 pauses minting) and the fee recipient. It can never move holdings.
- **Frozen stock?** `redeemExcept` lets you leave a paused constituent behind and still exit with the rest.
- **Browser wallets** (MetaMask, Rabby) mint with one gasless permit per stock plus a single `mintWithPermits` transaction. Smart wallets (Base Account, Ambire) batch approvals and the mint atomically (EIP-5792). After the first mint it's one click.

## Repository layout

```
contracts/                Foundry
  src/BlueFund.sol        $BLUE: in-kind seed/mint/mintWithPermits/redeem/redeemExcept, capped fee
  src/ChipVault.sol       holds the BLUE fees; claim / claimWithPermit burn CHIP
  src/mocks/              MockStock, MockChip (mimics the Bankr token), MockBasketFaucet
  test/                   unit, fuzz and invariant tests (49 tests; 100% line coverage on src)
  script/Deploy.s.sol     mainnet: fund + vault over real stocks and the launched CHIP
  script/DeployMocks.s.sol  local / Base Sepolia with mocks, seeded
  basket/mag7.config.json   tickers, addresses, feeds, shares outstanding  (edit this)
  basket/mag7.json          generated seed vector                          (npm run basket)
  deployments/<chainId>.json  written by the deploy scripts, imported by the site
scripts/basket.mjs        live Chainlink prices -> cap-weighted seed units; snapshots names/icons
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
npm run deploy:local           # mock stocks + mock CHIP + fund + vault, seeded
cp web/.env.example web/.env   # set VITE_CHAIN=anvil
npm run web                    # http://localhost:5173
```

On the local chain the wallet menu offers an **Anvil dev account**, and the site has faucets for test stocks and test CHIP. Everything works end to end: mint (permits + one tx), redeem, burn CHIP.

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

## Why some things are the way they are

- **The stock tokens can't run in a fork.** Their code is the single byte `0xef` (a chain-native precompile), so anvil forks and `forge script` simulations hit `OpcodeNotFound`. Tests use mocks. The constituent tokens are only touched by `cast send`, which the real node simulates.
- **The fund owns what it accounts for.** Holdings are tracked internally, so tokens sent to the fund directly never change mint or redeem amounts. The owner can `sweep` only the excess over `holdings`.
- **The site is static.** It has no keys, no backend and no analytics. Stock icons are served from the site itself, and Base Account telemetry is off. The only third parties are Google Fonts, the Base RPC and, inside the CHIP section, the Bankr trade iframe.

## Status and risks

Unaudited weekend-project code. Keep the supply cap low. Coinbase's tokenized stocks are not offered to US persons, and their issuer can pause or restrict transfers. An index product and a fee-accruing token can raise securities questions. Check them before a public launch.

## License

MIT
