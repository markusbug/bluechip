import { useState } from "react";
import { useReadContract } from "wagmi";
import { erc20Abi, formatUnits } from "viem";
import { chipVaultAbi, mockChipAbi } from "../abi";
import { deployment, siteConfig } from "../config";
import type { FundState } from "../hooks/useFund";
import type { WalletState } from "../hooks/useWallet";
import { explainError } from "../lib/errors";
import { fmt, parseAmount, usd } from "../lib/format";
import { permitDeadline, permitDomain, signPermit } from "../lib/permit";
import { canBatch, runCalls, type Call } from "../lib/tx";
import { progressText } from "./MintPanel";
import { AmountInput, Button, CopyButton, LinkButton, TxStatus } from "./ui";

const BILLION = 1_000_000_000n * 10n ** 18n;

export function ChipSection({ fund, wallet, onDone }: { fund: FundState; wallet: WalletState; onDone: () => void }) {
  const chip = siteConfig.chipAddress;
  const d = deployment;
  const backingPerBillion = fund.chipSupply > 0n ? (fund.vaultBacking * BILLION) / fund.chipSupply : 0n;
  const usdPerBillion = fund.navPerBlue !== undefined ? (Number(backingPerBillion) / 1e18) * fund.navPerBlue : undefined;

  return (
    <section id="chip" className="scroll-mt-16 bg-blue-deep text-white">
      <div className="mx-auto max-w-6xl px-4 py-16 sm:px-6">
        <div className="grid gap-10 lg:grid-cols-[1fr_1.15fr]">
          <div className="min-w-0">
            <h2 className="font-display text-3xl font-bold tracking-tight sm:text-4xl">$CHIP is backed by every mint.</h2>
            <p className="mt-4 max-w-lg text-white/75">
              Every BLUE minted sends {(fund.mintFeeBps / 100).toFixed(2)}% to the CHIP vault, a contract with no owner. Burn CHIP there
              and it pays out your share of the vault in BLUE, which you can redeem for the stocks. Mints only add to the vault and
              burns take out exactly their share, so the BLUE behind each CHIP never goes down.
            </p>
            <dl className="mt-8 grid grid-cols-2 gap-6 border-t border-white/15 pt-6">
              <div>
                <dt className="text-sm text-white/65">BLUE in the vault</dt>
                <dd className="mt-1 font-display text-2xl">{fmt(fund.vaultBacking, 18)}</dd>
                <dd className="text-xs text-white/65">{fund.navPerBlue !== undefined ? usd((Number(fund.vaultBacking) / 1e18) * fund.navPerBlue) : ""}</dd>
              </div>
              <div>
                <dt className="text-sm text-white/65">Backing per 1B CHIP</dt>
                <dd className="mt-1 font-display text-2xl">{fmt(backingPerBillion, 18, 8)} BLUE</dd>
                <dd className="text-xs text-white/65">{usd(usdPerBillion, 4)}</dd>
              </div>
            </dl>
            {chip && (
              <div className="mt-8 flex flex-wrap items-center gap-2 text-sm">
                <span className="text-white/65">CHIP</span>
                <code className="min-w-0 break-all rounded-2xl bg-white/10 px-3 py-1.5 font-medium">{chip}</code>
                <span className="[&_button]:border-white/25 [&_button]:text-white">
                  <CopyButton text={chip} />
                </span>
              </div>
            )}
          </div>

          <div className="min-w-0 rounded-[20px] bg-white p-5 text-ink sm:p-7 dark:bg-surface">
            {d && chip ? <Claim fund={fund} wallet={wallet} onDone={onDone} /> : <p className="text-muted">The CHIP vault goes live with the fund.</p>}
          </div>
        </div>

        <Buy />
      </div>
    </section>
  );
}

function Claim({ fund, wallet, onDone }: { fund: FundState; wallet: WalletState; onDone: () => void }) {
  const d = deployment!;
  const chip = siteConfig.chipAddress!;
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string>();
  const [error, setError] = useState<string>();
  const [hash, setHash] = useState<string>();

  const chipAmount = parseAmount(amount, 18);
  const preview = useReadContract({
    address: d.vault,
    abi: chipVaultAbi,
    functionName: "previewClaim",
    args: [chipAmount ?? 0n],
    query: { enabled: !!chipAmount && chipAmount > 0n, refetchInterval: 15_000 },
  });
  const allowance = useReadContract({
    address: chip,
    abi: erc20Abi,
    functionName: "allowance",
    args: [wallet.address ?? "0x0000000000000000000000000000000000000000", d.vault],
    query: { enabled: !!wallet.address },
  });
  const out = preview.data ?? 0n;
  const connected = !!wallet.address && wallet.onChain;
  const tooMuch = !!chipAmount && chipAmount > wallet.chip;

  async function claim() {
    const account = wallet.address!;
    setBusy(true);
    setError(undefined);
    setHash(undefined);
    try {
      // Backing per CHIP never falls, so the preview is a floor for what the claim pays.
      const minOut = out;
      const claimCall: Call = { address: d.vault, abi: chipVaultAbi, functionName: "claim", args: [chipAmount!, minOut, account], label: "Burn CHIP" };
      let calls: Call[];
      if ((allowance.data ?? 0n) >= chipAmount!) {
        calls = [claimCall];
      } else if (await canBatch(account)) {
        calls = [{ address: chip, abi: erc20Abi, functionName: "approve", args: [d.vault, chipAmount!], label: "Approve CHIP" }, claimCall];
      } else {
        const domain = await permitDomain(chip);
        if (domain) {
          setMessage("Sign a permit for the vault to take your CHIP (no gas)");
          const p = await signPermit({ token: chip, domain, owner: account, spender: d.vault, value: chipAmount!, deadline: permitDeadline() });
          calls = [{
            address: d.vault,
            abi: chipVaultAbi,
            functionName: "claimWithPermit",
            args: [chipAmount!, minOut, account, p.deadline, p.v, p.r, p.s],
            label: "Burn CHIP",
          }];
        } else {
          calls = [{ address: chip, abi: erc20Abi, functionName: "approve", args: [d.vault, chipAmount!], label: "Approve CHIP" }, claimCall];
        }
      }
      const tx = await runCalls(account, calls, (p) => setMessage(progressText(p.label, p.step, p.total, p.stage)));
      setHash(tx);
      setMessage(`Burned ${fmt(chipAmount!, 18)} CHIP for ${fmt(out, 18, 6)} BLUE.`);
      setAmount("");
      onDone();
      void allowance.refetch();
    } catch (e) {
      setMessage(undefined);
      setError(explainError(e));
    } finally {
      setBusy(false);
    }
  }

  async function faucet() {
    setBusy(true);
    setError(undefined);
    try {
      await runCalls(wallet.address!, [{ address: chip, abi: mockChipAbi, functionName: "faucet", args: [], label: "Get test CHIP" }], (p) =>
        setMessage(progressText(p.label, p.step, p.total, p.stage)),
      );
      setMessage("1B test CHIP received.");
      onDone();
    } catch (e) {
      setMessage(undefined);
      setError(explainError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      <h3 className="font-display text-lg font-bold">Burn CHIP for BLUE</h3>
      <div className="mt-5">
        <AmountInput
          label="CHIP to burn"
          value={amount}
          onChange={setAmount}
          unit="CHIP"
          onMax={connected ? () => setAmount(formatUnits(wallet.chip, 18)) : undefined}
        />
      </div>
      <p className="mt-2 text-sm text-muted">
        {connected && `You hold ${fmt(wallet.chip, 18, 0)} CHIP. `}
        You receive {fmt(out, 18, 6)} BLUE
        {fund.navPerBlue !== undefined && out > 0n ? `, about ${usd((Number(out) / 1e18) * fund.navPerBlue, 4)}` : ""}. Burning is final.
      </p>
      <Button size="lg" className="mt-6 w-full" disabled={!connected || busy || !chipAmount || tooMuch || out === 0n} onClick={claim}>
        {!connected ? "Connect a wallet to burn CHIP" : tooMuch ? "More than you hold" : chipAmount && out === 0n ? "Too small to pay out" : "Burn CHIP"}
      </Button>
      {connected && siteConfig.isMock && (
        <Button variant="outline" className="mt-3 w-full" disabled={busy} onClick={faucet}>
          Get test CHIP
        </Button>
      )}
      <TxStatus busy={busy} message={message} error={error} hash={hash} explorerTx={siteConfig.explorerTx} />
    </div>
  );
}

/** Buying CHIP happens on Bankr, where it was launched. Embedded, with a new-tab fallback. */
function Buy() {
  const chip = siteConfig.chipAddress;
  if (!siteConfig.isMainnet) return null;
  return (
    <div className="mt-16 border-t border-white/15 pt-10">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h3 className="font-display text-2xl font-bold">Buy $CHIP</h3>
          <p className="mt-2 max-w-lg text-white/75">
            {chip ? "CHIP trades on Base through Bankr. Swap from ETH or USDC right here." : "CHIP launches on Bankr soon. The trade widget appears here once it's live."}
          </p>
        </div>
        {chip && (
          <div className="flex gap-2 [&_a]:border-white/25 [&_a]:text-white">
            <LinkButton href={siteConfig.bankrTrade(chip)}>Open on Bankr</LinkButton>
            <LinkButton href={siteConfig.explorerToken(chip)}>Basescan</LinkButton>
          </div>
        )}
      </div>
      {chip && (
        <>
          <div className="mt-6 overflow-hidden rounded-[20px] bg-white">
            <iframe
              src={siteConfig.bankrTrade(chip)}
              title="Buy $CHIP on Bankr"
              loading="lazy"
              allow="clipboard-write; web-share"
              referrerPolicy="strict-origin-when-cross-origin"
              className="block h-[900px] w-full"
            />
          </div>
          <p className="mt-3 text-sm text-white/65">
            Wallet not connecting inside the frame?{" "}
            <a className="underline" href={siteConfig.bankrTrade(chip)} target="_blank" rel="noreferrer">
              Open the trade page in a new tab
            </a>
            .
          </p>
        </>
      )}
    </div>
  );
}
