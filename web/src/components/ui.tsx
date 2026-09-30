import type { ButtonHTMLAttributes, ReactNode } from "react";
import { useState } from "react";

export function Panel({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <div className={`rounded-[20px] border border-line bg-surface p-5 sm:p-7 ${className}`}>{children}</div>;
}

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "quiet" | "outline"; size?: "sm" | "md" | "lg" };

export function Button({ variant = "primary", size = "md", className = "", ...rest }: ButtonProps) {
  const v = {
    primary: "bg-blue text-white hover:brightness-110 disabled:hover:brightness-100",
    outline: "border border-line text-ink hover:border-blue hover:text-blue",
    quiet: "text-muted hover:text-ink",
  }[variant];
  const s = { sm: "h-8 px-3 text-sm", md: "h-10 px-4 text-sm", lg: "h-12 px-6 text-base" }[size];
  return (
    <button
      {...rest}
      className={`inline-flex items-center justify-center gap-2 rounded-full font-semibold transition disabled:cursor-not-allowed disabled:opacity-50 ${v} ${s} ${className}`}
    />
  );
}

export function LinkButton({ href, children, variant = "outline", size = "sm" }: { href: string; children: ReactNode; variant?: "primary" | "outline"; size?: "sm" | "md" }) {
  const v = variant === "primary" ? "bg-blue text-white hover:brightness-110" : "border border-line text-ink hover:border-blue hover:text-blue";
  const s = size === "sm" ? "h-8 px-3 text-sm" : "h-10 px-4 text-sm";
  return (
    <a href={href} target="_blank" rel="noreferrer" className={`inline-flex items-center justify-center rounded-full font-semibold transition ${v} ${s}`}>
      {children}
    </a>
  );
}

export function AmountInput({
  value,
  onChange,
  unit,
  onMax,
  label,
}: {
  value: string;
  onChange: (v: string) => void;
  unit: string;
  onMax?: () => void;
  label: string;
}) {
  return (
    <label className="block">
      <span className="mb-2 block text-sm text-muted">{label}</span>
      <span className="flex items-center gap-3 rounded-2xl border border-line bg-paper px-4 focus-within:border-blue focus-within:ring-2 focus-within:ring-blue/25">
        <input
          inputMode="decimal"
          autoComplete="off"
          value={value}
          onChange={(e) => onChange(e.target.value.replace(",", "."))}
          placeholder="0"
          className="h-16 w-full min-w-0 bg-transparent font-display text-2xl font-medium outline-none placeholder:text-muted/50 focus-visible:outline-none"
        />
        {onMax && (
          <button type="button" onClick={onMax} className="text-sm font-semibold text-blue hover:underline">
            Max
          </button>
        )}
        <span className="font-semibold text-muted">{unit}</span>
      </span>
    </label>
  );
}

export function CopyButton({ text, label = "Copy" }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <Button
      type="button"
      variant="outline"
      size="sm"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text);
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        } catch {
          /* clipboard blocked */
        }
      }}
    >
      {copied ? "Copied" : label}
    </Button>
  );
}

export function Spinner() {
  return <span className="inline-block h-4 w-4 animate-spin rounded-full border-2 border-current border-t-transparent" aria-hidden />;
}

export function TokenIcon({ icon, ticker, size = 28 }: { icon: string | null; ticker: string; size?: number }) {
  const [broken, setBroken] = useState(false);
  if (icon && !broken) {
    return <img src={icon} alt="" width={size} height={size} onError={() => setBroken(true)} className="shrink-0 rounded-full bg-white" style={{ width: size, height: size }} />;
  }
  return (
    <span className="grid shrink-0 place-items-center rounded-full bg-blue-soft text-[10px] font-bold text-blue" style={{ width: size, height: size }}>
      {ticker.slice(0, 2)}
    </span>
  );
}

export function Stat({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) {
  return (
    <div>
      <div className="text-sm text-muted">{label}</div>
      <div className="mt-1 font-display text-xl font-medium sm:text-2xl">{value}</div>
      {sub && <div className="mt-0.5 text-xs text-muted">{sub}</div>}
    </div>
  );
}

/** Status line under an action: progress, success with a link, or an actionable error. */
export function TxStatus({ busy, message, error, hash, explorerTx }: { busy: boolean; message?: string; error?: string; hash?: string; explorerTx: (h: string) => string }) {
  if (error) return <p className="mt-3 text-sm text-warn" role="alert">{error}</p>;
  if (busy && message) return <p className="mt-3 flex items-center gap-2 text-sm text-muted" aria-live="polite"><Spinner /> {message}</p>;
  if (message)
    return (
      <p className="mt-3 text-sm text-good" aria-live="polite">
        {message}{" "}
        {hash && hash !== "0x" && explorerTx(hash) && (
          <a className="underline" href={explorerTx(hash)} target="_blank" rel="noreferrer">
            View transaction
          </a>
        )}
      </p>
    );
  return null;
}
