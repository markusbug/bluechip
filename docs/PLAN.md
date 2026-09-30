# Bluechip: Project Plan

## 1. Core idea

`$BLUE` is an ERC-20 whose supply is backed by a basket of tokenized stocks held by the contract.
Each `$BLUE` represents a fixed number of **units** of each constituent, like an ETF creation unit.

- **mint** is in-kind: deposit the basket's tokens pro-rata and receive `$BLUE`.
- **redeem** is in-kind too: burn `$BLUE` and receive the pro-rata share of every holding.
- **fee**: a mint fee (e.g. 0.30%) is taken as freshly minted `$BLUE` and sent to the `$CHIP` contract.

### Why in-kind first

In-kind mint and redeem need **no oracles and no pricing**. The math is just ratios:

```
mint(shares):   deposit_i = ceil(holdings_i * shares / totalSupply)    // round against the user
redeem(shares): payout_i  = floor(holdings_i * shares / totalSupply)   // round against the user
```

A NAV oracle can't be manipulated when the core never reads one.
Buying with USDC is handled by a separate **Zap** router (see §4), which swaps USDC into the basket and then calls `mint`.
The core fund stays small and easy to audit.

### Cap-weighting comes almost for free

If the fund holds a fixed number of shares of each company, proportional to that company's shares outstanding, the basket **stays market-cap weighted as prices move** and never has to trade.
Trades are only needed when:
- a company enters or leaves the index,
- a company's share count changes materially (buybacks, issuance),
- corporate actions happen (splits, dividends; see Open Questions).

That's why v1 can skip rebalancing entirely.

## 2. The index

We can't do all 500 on day one because only a limited set of stocks is tokenized on Base.
Plan: **"Bluechip 10"** (or N), the top-N US large caps that are available as tokens on Base with decent liquidity, cap-weighted.
The index grows as more tickers are listed.

> Avoid the name "S&P 500" in the product. It's a trademark and the index is licensed.
> "Tracks the largest US companies" is fine.

## 3. Contracts

```
src/
  BlueFund.sol        // $BLUE: ERC20 + in-kind mint/redeem + mint fee
  Chip.sol            // $CHIP: ERC20, holds $BLUE fees, burn-to-claim
  periphery/
    Zap.sol           // USDC <-> basket via DEX, calls mint/redeem
  mocks/
    MockStock.sol     // ERC20 stand-ins for tokenized stocks (testnet)
```

### BlueFund (`$BLUE`)

```solidity
function mint(uint256 shares, address to) external returns (uint256[] memory deposited);
function redeem(uint256 shares, address to) external returns (uint256[] memory paidOut);
function previewMint(uint256 shares) external view returns (address[] memory tokens, uint256[] memory amounts);
function previewRedeem(uint256 shares) external view returns (address[] memory tokens, uint256[] memory amounts);
function constituents() external view returns (address[] memory);
function holdings(address token) external view returns (uint256);
```

Design notes:
- **Internal accounting**: track `holdings[token]` in storage instead of reading `balanceOf(this)`. Tokens donated to the contract can then no longer skew the ratios, which rules out donation/inflation games.
- **Seeding**: the deployer does the first mint with an explicit units-per-share vector. It also burns a small amount of "dead shares" so supply can never return to 0.
- **Fee**: `feeShares = shares * mintFeeBps / 10_000`. The user deposits the basket for `shares`, receives `shares - feeShares`, and `Chip` receives `feeShares`. Hard-cap the fee in code (e.g. ≤ 1%).
- **Redeem fee**: 0 in v1, so exiting is always free.
- **Emergency redeem**: tokenized stocks usually have issuer pause/freeze/blocklist powers. If one constituent's transfer reverts, a normal redeem would brick for everyone. Add `redeemExcept(shares, to, skip[])` so the user can forfeit the stuck token and still exit.
- **Deposit cap** for mainnet v1.
- **Admin**: `owner` can only change the fee (capped), the cap, and the fee recipient. **No ability to move holdings.** Put a timelock on these later.
- Reentrancy guard; SafeERC20; handle tokens with different decimals.

### Chip (`$CHIP`)

This is where "fees go into the token" happens:
- `Chip` receives `$BLUE` from every mint.
- `backingPerChip = BLUE.balanceOf(chip) / chip.totalSupply()`
- `burn(amount)` burns CHIP and sends out the pro-rata `$BLUE`. That gives CHIP a rising floor, backed by the index.

Alternative if we want CHIP supply to stay fixed: a staking contract where stakers earn streamed `$BLUE` ("stake CHIP, earn the index").
Burn-to-claim is simpler and has no reward accounting, so it's the v1 choice.

CHIP launch mechanics (supply, distribution, LP) are an open question, and deliberately so. Build the fund first.

## 4. Zap (periphery)

This is the UX layer, for buying `$BLUE` with USDC:
1. Off-chain, get quotes for USDC → each constituent (Uniswap on Base, or an aggregator like 0x/1inch).
2. `zapIn(usdcIn, shares, minShares, swapCalldata[])` executes the swaps, calls `fund.mint`, and refunds dust.
3. `zapOut` does the reverse: redeem, then swap everything to USDC with a `minUsdcOut`.

Slippage protection lives in the Zap, not in the fund.
This is where MEV and sandwich risk sits, so the user always sets the min-out.

## 5. Milestones

**M0: Research (~2h)** (done, 2026-09-30)
- [x] Issuers on Base: **Coinbase tokenized stocks** (live since 2026-08-24). These are native B20 precompile tokens at `0xb200…`, symbols like `AAPLc`, 8 decimals, EIP-2612 permit. The list is at `api.coinbase.com/v1/tokenized-stocks`.
- [x] **Transfer restrictions:** secondary holding and transfer is permissionless, apart from a blocklist-style policy. A simulated transfer to arbitrary contracts succeeds. The issuer can pause, which `redeemExcept` covers.
- [x] Liquidity: only the Mag 7 have meaningful supply, e.g. ~19k NVDA and ~8.6k AAPL onchain; AVGO, LLY and ORCL each have under 130. **N = 7 (Mag 7).**
- [x] Dividends and splits change a WAD `multiplier()`, not balances. So no rebase and no airdrop, and the in-kind math is unaffected.
- [x] Chainlink "Coinbase <TICKER>" total-return feeds on Base (8 decimals, multiplier included). Used for display only.
- Gotcha: the tokens' bytecode is `0xef`, so anvil/forge forks can't execute them. Tests use mocks, and mainnet token calls go through `cast`.

**Decisions:**
- **Fee:** 0.30%.
- **CHIP launch:** launched with Bankr (Doppler), with burn-to-claim in a separate ownerless `ChipVault`, because Bankr deploys its own token contract.
- **Site:** mints in kind, with per-stock "Buy on Bankr" links. The USDC Zap is deferred.

**M1: Core contracts (Sat)** (done: BlueFund, ChipVault, 49 tests incl. invariants)
- [ ] `forge init`, OpenZeppelin, `MockStock`
- [ ] `BlueFund` mint/redeem/fee + `Chip` burn-to-claim
- [ ] Unit tests + fuzz/invariant tests:
  - redeeming everything returns ≤ what was deposited (rounding never leaks value)
  - `holdings_i / totalSupply` ratios are unchanged by mint/redeem
  - donations can't change mint/redeem amounts
  - Chip backing never decreases on mint

**M2: Zap + testnet (Sun)**
- [ ] `Zap` against a Base mainnet fork (real stock tokens + Uniswap)
- [ ] Deploy to Base Sepolia with mocks; deploy scripts in `script/`

**M3: Frontend** (done: web/, see docs/LAUNCH.md)
- [ ] Single page: NAV, holdings pie, mint with USDC, redeem, CHIP backing

**M4: v2 ideas (later)**
- [ ] Index updates via a timelocked `rebalance` with bounded trades (or an auction-based rebalance)
- [ ] Cash redeem with oracle-checked NAV
- [ ] Management fee (streaming) in addition to the mint fee
- [ ] Automatic dividend handling

## 6. Open questions

1. Is the mint fee 0.30%, or lower to compete with ~0.03% ETFs? Maybe start at 0.10%.
2. How do we launch CHIP: fair launch, airdrop to early minters, or LP on Aerodrome?
3. Do we pick N up front, or set it by a liquidity threshold?
4. Are corporate actions handled per issuer?

## 7. Legal note

Tokenized equities, an index product, and a token that accrues fees can each bring securities, licensing, and KYC questions.
They're fine for a testnet weekend project; check them before any public mainnet launch.
