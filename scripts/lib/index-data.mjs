// Index data shared by scripts/basket.mjs and scripts/index-update.mjs.
//
// The index is float-adjusted market cap, the S&P 500 method. Each company's float shares are
//   sharesOutstanding (SEC EDGAR, latest filing) x listedFraction x iwf
// listedFraction drops unlisted share classes (Alphabet and Meta Class B); EDGAR only reports their
// total. iwf is the investable weight factor: the part not held by insiders and strategic holders.
// Both live in the fund's contracts/basket/<basket>.config.json and change rarely.
import { readFileSync } from "node:fs";
import { basketOf, fundId } from "./fund.mjs";

const root = new URL("../..", import.meta.url).pathname;
export const configPath = `${root}contracts/basket/${basketOf(fundId())}.config.json`;

// SEC asks automated clients to identify themselves: set SEC_USER_AGENT="Your Name you@example.com".
const SEC_USER_AGENT = process.env.SEC_USER_AGENT || "bluechip-index";

// In order of preference. Multi-class companies (Alphabet, Meta) often lack the cover-page figure.
const SOURCES = [
  ["dei", "EntityCommonStockSharesOutstanding"],
  ["us-gaap", "CommonStockSharesOutstanding"],
  ["us-gaap", "WeightedAverageNumberOfSharesOutstandingBasic"],
];

export function loadConfig() {
  const cfg = JSON.parse(readFileSync(configPath, "utf8"));
  for (const c of cfg.constituents) {
    if (!(c.iwf > 0 && c.iwf <= 1)) throw new Error(`${c.symbol}: iwf must be in (0, 1], got ${c.iwf}`);
    if (!(c.listedFraction > 0 && c.listedFraction <= 1)) {
      throw new Error(`${c.symbol}: listedFraction must be in (0, 1], got ${c.listedFraction}`);
    }
  }
  return cfg;
}

/** Latest shares outstanding for a company, from its most recent SEC filing. */
export async function sharesOutstanding(cik) {
  const url = `https://data.sec.gov/api/xbrl/companyfacts/CIK${String(cik).padStart(10, "0")}.json`;
  const res = await fetch(url, { headers: { "user-agent": SEC_USER_AGENT } });
  if (!res.ok) throw new Error(`SEC EDGAR ${res.status} for CIK ${cik} (set SEC_USER_AGENT="Name email")`);
  const facts = await res.json();

  for (const [ns, concept] of SOURCES) {
    const rows = facts.facts?.[ns]?.[concept]?.units?.shares;
    if (!rows?.length) continue;
    const end = rows.reduce((m, r) => (r.end > m ? r.end : m), "");
    const atEnd = rows.filter((r) => r.end === end);
    const filed = atEnd.reduce((m, r) => (r.filed > m ? r.filed : m), "");
    let latest = atEnd.filter((r) => r.filed === filed);
    // Weighted averages come as quarter and year-to-date: take the shortest period.
    if (latest[0].start) {
      const start = latest.reduce((m, r) => (r.start > m ? r.start : m), "");
      latest = latest.filter((r) => r.start === start);
    }
    // The cover page lists one row per share class when a company reports them separately.
    const vals = [...new Set(latest.map((r) => r.val))];
    const shares = ns === "dei" ? vals.reduce((s, v) => s + v, 0) : vals[0];
    return { shares, source: `${concept} as of ${end} (${latest[0].form} filed ${filed})` };
  }
  throw new Error(`CIK ${cik}: no shares-outstanding figure in EDGAR`);
}

/** Float shares for each constituent, fetched live. */
export async function floatShares(cfg) {
  const out = [];
  for (const c of cfg.constituents) {
    const { shares, source } = await sharesOutstanding(c.cik);
    out.push({
      symbol: c.symbol,
      sharesOutstanding: shares,
      sharesSource: source,
      listedFraction: c.listedFraction,
      iwf: c.iwf,
      floatShares: Math.round(shares * c.listedFraction * c.iwf),
    });
    await new Promise((r) => setTimeout(r, 200)); // SEC allows 10 requests per second
  }
  return out;
}
