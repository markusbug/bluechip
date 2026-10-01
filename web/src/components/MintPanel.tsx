import { useMemo, useState } from "react";
import { useReadContract } from "wagmi";
import type { Address } from "viem";
import { erc20Abi } from "viem";
import { blueFundAbi, mockFaucetAbi } from "../abi";
import { siteConfig } from "../config";
import type { FundState } from "../hooks/useFund";
import type { WalletState } from "../hooks/useWallet";
import { track } from "../lib/analytics";
import { errorKind, explainError } from "../lib/errors";
import { fmt, parseAmount, usd } from "../lib/format";
import { NO_PERMIT, permitDeadline, permitDomain, signPermit, type SignedPermit } from "../lib/permit";
import { canBatch, runCalls, type Call } from "../lib/tx";
import { AmountInput, Button, LinkButton, TokenIcon, TxStatus } from "./ui";
import { ZapMint, type PayToken } from "./ZapMint";
import { useDebounced } from "../hooks/useDebounced";

/**
 * Approvals and permits cover exactly this mint, never more. Deposits round up by at most a few units if
 * someone mints first; 0.1% more covers that.
 */
const withHeadroom = (x: bigint) => x + x / 1000n + 1n;

export function MintPanel({ fund, wallet, onDone }: { fund: FundState; wallet: WalletState; onDone: () => void }) {
  const [amount, setAmount] = useState("1");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string>();
  const [error, setError] = useState<string>();
  const [hash, setHash] = useState<string>();

  const d = fund.config.deployment!;
  const { symbol } = fund.config;
  const hasZap = !!d.zap && !!d.usdc;
  const [pay, setPay] = useState<PayToken | "stocks">(hasZap ? "usdc" : "stocks");
  const shares = parseAmount(amount, 18);
  // What the RPC is asked about: the amount once typing pauses.
  const settledShares = useDebounced(shares);
  const preview = useReadContract({
    address: d.fund,
    abi: blueFundAbi,
    functionName: "previewMint",
    args: [settledShares ?? 0n],
    query: { enabled: pay === "stocks" && !!settledShares && settledShares > 0n, refetchInterval: 15_000 },
  });
  const need = preview.data && settledShares === shares ? preview.data[1] : [];

  const rows = fund.constituents.map((c, i) => {
    const req = need[i] ?? 0n;
    const have = wallet.balances[i] ?? 0n;
    return { c, req, have, short: req > have ? req - have : 0n, approved: (wallet.allowances[i] ?? 0n) >= withHeadroom(req) };
  });
  const missing = rows.filter((r) => r.short > 0n);
  const toApprove = rows.map((r, i) => ({ ...r, i })).filter((r) => r.req > 0n && !r.approved);
  const fee = shares ? (shares * BigInt(fund.mintFeeBps)) / 10_000n : 0n;
  const overCap = !!shares && fund.supplyCap !== undefined && fund.totalSupply + shares > fund.supplyCap;
  const value = shares && fund.navPerBlue ? (Number(shares) / 1e18) * fund.navPerBlue : undefined;

  const plan = useMemo(() => {
    if (toApprove.length === 0) return "Mint";
    return `Approve ${toApprove.length} ${toApprove.length === 1 ? "stock" : "stocks"} and mint`;
  }, [toApprove.length]);

  async function mint() {
    const account = wallet.address!;
    setBusy(true);
    setError(undefined);
    setHash(undefined);
    track("mint_start", { fund: symbol, pay_with: "stocks" });
    try {
      const mintCall: Call = { address: d.fund, abi: blueFundAbi, functionName: "mint", args: [shares!, account], label: "Mint" };
      let tx: string;

      if (toApprove.length === 0 || (await canBatch(account))) {
        // Nothing to approve, or a smart wallet that runs approvals and the mint as one batch.
        const approvals: Call[] = toApprove.map((r) => ({
          address: r.c.address,
          abi: erc20Abi,
          functionName: "approve",
          args: [d.fund, withHeadroom(r.req)],
          label: `Approve ${r.c.ticker}`,
        }));
        tx = await runCalls(account, [...approvals, mintCall], (p) => setMessage(progressText(p.label, p.step, p.total, p.stage)));
      } else {
        // Plain EOA (MetaMask, Rabby): gasless permit signatures, then a single transaction.
        const permits: SignedPermit[] = fund.constituents.map(() => NO_PERMIT);
        const fallback: Call[] = [];
        for (const [k, r] of toApprove.entries()) {
          setMessage(`Sign ${k + 1} of ${toApprove.length}: allow the fund to take ${r.c.ticker} (no gas)`);
          const domain = await permitDomain(r.c.address);
          if (!domain) {
            fallback.push({ address: r.c.address, abi: erc20Abi, functionName: "approve", args: [d.fund, withHeadroom(r.req)], label: `Approve ${r.c.ticker}` });
            continue;
          }
          permits[r.i] = await signPermit({ token: r.c.address, domain, owner: account, spender: d.fund, value: withHeadroom(r.req), deadline: permitDeadline() });
        }
        const mintWithPermits: Call = {
          address: d.fund,
          abi: blueFundAbi,
          functionName: "mintWithPermits",
          args: [shares!, account, permits],
          label: "Mint",
        };
        tx = await runCalls(account, [...fallback, mintWithPermits], (p) => setMessage(progressText(p.label, p.step, p.total, p.stage)));
      }
      setHash(tx);
      setMessage(`Minted ${fmt(shares! - fee, 18)} ${symbol}.`);
      track("mint", { fund: symbol, pay_with: "stocks", value: value === undefined ? undefined : Math.round(value), currency: "USD" });
      onDone();
    } catch (e) {
      setMessage(undefined);
      setError(explainError(e));
      track("mint_failed", { fund: symbol, pay_with: "stocks", reason: errorKind(e) });
    } finally {
      setBusy(false);
    }
  }

  async function faucet() {
    const account = wallet.address!;
    setBusy(true);
    setError(undefined);
    try {
      const tx = await runCalls(
        account,
        [{ address: d.faucet as Address, abi: mockFaucetAbi, functionName: "drip", args: [account, withHeadroom(shares!)], label: "Get test stocks" }],
        (p) => setMessage(progressText(p.label, p.step, p.total, p.stage)),
      );
      setHash(tx);
      setMessage("Test stocks received.");
      onDone();
    } catch (e) {
      setMessage(undefined);
      setError(explainError(e));
    } finally {
      setBusy(false);
    }
  }

  const connected = !!wallet.address && wallet.onChain;
  const disabled = !connected || busy || !shares || shares === 0n || !fund.seeded || overCap || missing.length > 0 || need.length === 0;

  return (
    <div>
      <AmountInput label={`${symbol} to mint`} value={amount} onChange={setAmount} unit={symbol} />
      <p className="mt-2 text-sm text-muted">
        {value !== undefined && `Worth about ${usd(value)}. `}
        You receive {shares ? fmt(shares - fee, 18) : "0"} {symbol}; {fmt(fee, 18)} {symbol} ({(fund.mintFeeBps / 100).toFixed(2)}%) goes to
        buying and burning $CHIP.
      </p>

      {hasZap && (
        <div className="mt-6 flex flex-wrap items-center gap-3">
          <span className="text-sm font-semibold">Pay with</span>
          <div role="radiogroup" className="inline-flex rounded-full border border-line p-1">
            {(
              [
                ["usdc", "USDC"],
                ["eth", "ETH"],
                ...(d.weth ? ([["weth", "WETH"]] as const) : []),
                ["stocks", `The ${fund.constituents.length} stocks`],
              ] as const
            ).map(([k, label]) => (
              <button
                key={k}
                type="button"
                role="radio"
                aria-checked={pay === k}
                onClick={() => setPay(k)}
                className={`h-8 rounded-full px-4 text-sm font-semibold transition ${pay === k ? "bg-blue text-white" : "text-muted hover:text-ink"}`}
              >
                {label}
              </button>
            ))}
          </div>
        </div>
      )}

      {pay !== "stocks" ? (
        <ZapMint deployment={d} symbol={symbol} pay={pay} shares={shares} settledShares={settledShares} received={shares ? shares - fee : 0n} value={value} overCap={overCap} wallet={wallet} onDone={onDone} />
      ) : (
        <>
          <h3 className="mt-6 text-sm font-semibold">You deposit</h3>
          <ul className="mt-2 divide-y divide-line">
            {rows.map(({ c, req, have, short }) => (
              <li key={c.symbol} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2.5 text-sm">
                <TokenIcon icon={c.icon} ticker={c.ticker} size={24} />
                <span className="w-14 font-semibold">{c.ticker}</span>
                <span className="grow">{fmt(req, c.decimals, 6)}</span>
                {connected &&
                  (short > 0n ? (
                    siteConfig.isMainnet ? (
                      <LinkButton href={siteConfig.bankrTrade(c.address)}>Buy {fmt(short, c.decimals, 6)} on Bankr</LinkButton>
                    ) : (
                      <span className="text-warn">Need {fmt(short, c.decimals, 6)} more</span>
                    )
                  ) : (
                    <span className="text-muted">You have {fmt(have, c.decimals, 4)}</span>
                  ))}
              </li>
            ))}
          </ul>

          {connected && missing.length > 0 && d.faucet && (
            <Button variant="outline" className="mt-4" onClick={faucet} disabled={busy || !shares}>
              Get test stocks for this mint
            </Button>
          )}

          <Button size="lg" className="mt-6 w-full" disabled={disabled} onClick={mint}>
            {!connected ? "Connect a wallet to mint" : overCap ? "Above the supply cap" : missing.length > 0 ? `Missing ${missing.length} of ${rows.length} stocks` : plan}
          </Button>
          {connected && toApprove.length > 0 && missing.length === 0 && (
            <p className="mt-2 text-xs text-muted">
              Browser wallets sign {toApprove.length} gasless {toApprove.length === 1 ? "permit" : "permits"}, then send one transaction. Smart
              wallets do it all in one batch.
            </p>
          )}
          <TxStatus busy={busy} message={message} error={error} hash={hash} explorerTx={siteConfig.explorerTx} />
        </>
      )}
    </div>
  );
}

export function progressText(label: string, step: number, total: number, stage: "sign" | "wallet" | "pending") {
  const n = total > 1 ? ` (${step} of ${total})` : "";
  return stage === "pending" ? `${label}${n}: waiting for the transaction` : `${label}${n}: confirm in your wallet`;
}
