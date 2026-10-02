// Index data shared by scripts/basket.mjs and scripts/index-update.mjs.
//
// The index is float-adjusted market cap, the S&P 500 method. Each company's float shares are
//   sharesOutstanding (SEC EDGAR, latest filing) x listedFraction x iwf
// listedFraction drops unlisted share classes (Alphabet and Meta Class B); EDGAR only reports their
// total. iwf is the investable weight factor: the part not held by insiders and strategic holders.
// Both live in the fund's contracts/basket/<basket>.config.json and change rarely.
//
// A constituent can instead name its listed classes in `coverClasses` (e.g. ["CommonClassA"]). Its
// shares then come from the cover page of its latest 10-Q or 10-K, counting only those classes, and
// listedFraction is 1. That is for companies whose filings tag the cover figure only per class
// (SpaceX), which EDGAR's companyfacts API leaves out.
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
    if (c.coverClasses && c.listedFraction !== 1) {
      throw new Error(`${c.symbol}: coverClasses already counts only the listed classes, so listedFraction must be 1`);
    }
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

/**
 * Shares outstanding in the given classes, from the cover page of the company's latest 10-Q or 10-K.
 * The cover tags one dei:EntityCommonStockSharesOutstanding per class in inline XBRL, each in a
 * context whose explicit member names the class (us-gaap:CommonClassAMember).
 */
export async function coverShares(cik, classes) {
  const headers = { "user-agent": SEC_USER_AGENT };
  const subsUrl = `https://data.sec.gov/submissions/CIK${String(cik).padStart(10, "0")}.json`;
  const res = await fetch(subsUrl, { headers });
  if (!res.ok) throw new Error(`SEC EDGAR ${res.status} for CIK ${cik} (set SEC_USER_AGENT="Name email")`);
  const recent = (await res.json()).filings.recent;
  const i = recent.form.findIndex((f) => f === "10-Q" || f === "10-K");
  if (i < 0) throw new Error(`CIK ${cik}: no 10-Q or 10-K in EDGAR`);
  const accession = recent.accessionNumber[i].replaceAll("-", "");
  const docUrl = `https://www.sec.gov/Archives/edgar/data/${cik}/${accession}/${recent.primaryDocument[i]}`;
  const doc = await fetch(docUrl, { headers }).then((r) => {
    if (!r.ok) throw new Error(`SEC EDGAR ${r.status} for ${docUrl}`);
    return r.text();
  });

  const contexts = new Map();
  for (const [, id, body] of doc.matchAll(/<xbrli:context id="([^"]+)">([\s\S]*?)<\/xbrli:context>/g)) {
    const members = [...body.matchAll(/<xbrldi:explicitMember[^>]*>([^<]+)</g)].map((m) => m[1].trim());
    contexts.set(id, { members, instant: body.match(/<xbrli:instant>([^<]+)</)?.[1] });
  }
  let shares = 0;
  let asOf;
  const found = new Set();
  for (const [tag] of doc.matchAll(/<ix:nonFraction[^>]*name="dei:EntityCommonStockSharesOutstanding"[^>]*>[^<]*/g)) {
    const ctx = contexts.get(tag.match(/contextRef="([^"]+)"/)[1]);
    const cls = classes.find((c) => ctx?.members.some((m) => m.endsWith(`:${c}Member`)));
    if (!cls) continue;
    const scale = Number(tag.match(/scale="(-?\d+)"/)?.[1] ?? 0);
    shares += Number(tag.slice(tag.lastIndexOf(">") + 1).replaceAll(",", "")) * 10 ** scale;
    asOf = ctx.instant;
    found.add(cls);
  }
  const missing = classes.filter((c) => !found.has(c));
  if (missing.length) throw new Error(`CIK ${cik}: no cover-page share count for ${missing.join(", ")} in ${docUrl}`);
  return {
    shares,
    source: `${classes.join(" + ")} on the cover as of ${asOf} (${recent.form[i]} filed ${recent.filingDate[i]})`,
  };
}

/** Float shares for each constituent, fetched live. */
export async function floatShares(cfg) {
  const out = [];
  for (const c of cfg.constituents) {
    const { shares, source } = c.coverClasses
      ? await coverShares(c.cik, c.coverClasses)
      : await sharesOutstanding(c.cik);
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
