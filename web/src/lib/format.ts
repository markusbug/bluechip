import { formatUnits } from "viem";

export const shortAddress = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

/** Human number with a sensible number of significant decimals. */
export function fmt(value: bigint | undefined, decimals: number, maxFrac = 4): string {
  if (value === undefined) return "–";
  const n = Number(formatUnits(value, decimals));
  if (n === 0) return "0";
  if (Math.abs(n) < 10 ** -maxFrac) return `<${(10 ** -maxFrac).toFixed(maxFrac)}`;
  return n.toLocaleString("en-US", { maximumFractionDigits: maxFrac });
}

export function usd(n: number | undefined, frac = 2): string {
  if (n === undefined || !Number.isFinite(n)) return "–";
  return n.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: frac, minimumFractionDigits: frac });
}

export function compactUsd(n: number | undefined): string {
  if (n === undefined || !Number.isFinite(n)) return "–";
  return n.toLocaleString("en-US", { style: "currency", currency: "USD", notation: "compact", maximumFractionDigits: 2 });
}

export const pct = (x: number, frac = 1) => `${(x * 100).toFixed(frac)}%`;

/** Parse a user-typed amount; undefined when empty or malformed. */
export function parseAmount(s: string, decimals: number): bigint | undefined {
  const t = s.trim();
  if (!/^\d*\.?\d*$/.test(t) || t === "" || t === ".") return undefined;
  const [int, frac = ""] = t.split(".");
  if (frac.length > decimals) return undefined;
  return BigInt(int || "0") * 10n ** BigInt(decimals) + BigInt((frac + "0".repeat(decimals)).slice(0, decimals) || "0");
}
