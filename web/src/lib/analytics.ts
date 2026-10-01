/**
 * Google Analytics (GA4), loaded only when VITE_GA_MEASUREMENT_ID is set, so local and testnet
 * builds send nothing. Switching funds rewrites ?fund= with pushState, which GA4's enhanced
 * measurement already counts as a page view. On top of that, track() records the funnel:
 * wallet_connect, then mint_start / mint / mint_failed and the same for redeem.
 *
 * Visitors who look like they're in the EU, EEA, UK or Switzerland (judged by time zone, since the
 * site is static and sees no geo header) get GA only after they accept it in the consent banner.
 * Until then the tag isn't loaded at all, so no cookie is set and nothing is sent.
 */
declare global {
  interface Window {
    dataLayer: unknown[];
    gtag?: (...args: unknown[]) => void;
    [gaDisable: `ga-disable-${string}`]: boolean | undefined;
  }
}

export type Consent = "granted" | "denied";

const CONSENT_KEY = "bluechip:analytics-consent";

// Places outside the Europe/* zones where GDPR (or the UK and Swiss equivalents) applies:
// Cyprus, the Canaries, Madeira, the Azores, Iceland, the Faroes, Svalbard and France's overseas regions.
const GDPR_ZONES_OUTSIDE_EUROPE = new Set([
  "Asia/Nicosia",
  "Asia/Famagusta",
  "Atlantic/Canary",
  "Atlantic/Madeira",
  "Atlantic/Azores",
  "Atlantic/Reykjavik",
  "Atlantic/Faroe",
  "Arctic/Longyearbyen",
  "America/Guadeloupe",
  "America/Martinique",
  "America/Cayenne",
  "Indian/Reunion",
  "Indian/Mayotte",
  "CET",
  "EET",
  "MET",
  "WET",
]);

function measurementId(): string | undefined {
  const id = import.meta.env.VITE_GA_MEASUREMENT_ID as string | undefined;
  return id && /^G-[A-Z0-9]+$/.test(id) ? id : undefined;
}

/** True in the EU and nearby, and when the time zone can't be read: this errs toward asking. */
function inGdprRegion(): boolean {
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    return !zone || zone.startsWith("Europe/") || GDPR_ZONES_OUTSIDE_EUROPE.has(zone);
  } catch {
    return true;
  }
}

/** Whether this visitor has to opt in before GA loads. False when analytics is off for the build. */
export function consentRequired(): boolean {
  return measurementId() !== undefined && inGdprRegion();
}

export function storedConsent(): Consent | undefined {
  try {
    const v = localStorage.getItem(CONSENT_KEY);
    return v === "granted" || v === "denied" ? v : undefined;
  } catch {
    return undefined;
  }
}

/** Records the visitor's choice; granting loads GA now, denying stops it and clears its cookies. */
export function setConsent(consent: Consent): void {
  try {
    localStorage.setItem(CONSENT_KEY, consent);
  } catch {
    /* storage blocked: the choice holds for this visit only */
  }
  const id = measurementId();
  if (!id) return;
  window[`ga-disable-${id}`] = consent === "denied";
  if (consent === "granted") load(id);
  else clearGaCookies();
}

export function initAnalytics(): void {
  const id = measurementId();
  if (!id || (inGdprRegion() && storedConsent() !== "granted")) return;
  load(id);
}

let loaded = false;

function load(id: string): void {
  if (loaded) return;
  loaded = true;

  window.dataLayer = window.dataLayer || [];
  // gtag.js reads the `arguments` object itself, so this can't be a rest-parameter arrow function.
  window.gtag = function gtag() {
    window.dataLayer.push(arguments);
  };
  window.gtag("js", new Date());
  window.gtag("config", id);

  const script = document.createElement("script");
  script.async = true;
  script.src = `https://www.googletagmanager.com/gtag/js?id=${id}`;
  document.head.appendChild(script);
}

/** GA sets _ga and _ga_<id> on the widest domain it can, so expire them on every parent of this host. */
function clearGaCookies(): void {
  const names = document.cookie.split(";").map((c) => c.split("=")[0].trim()).filter((n) => n === "_ga" || n.startsWith("_ga_"));
  const parts = location.hostname.split(".");
  const domains = parts.map((_, i) => parts.slice(i).join(".")).filter((d) => d.includes("."));
  for (const name of names) {
    document.cookie = `${name}=; Max-Age=0; path=/`;
    for (const d of domains) document.cookie = `${name}=; Max-Age=0; path=/; domain=.${d}`;
  }
}

/** Sends a GA event; does nothing when analytics is off. Never pass a wallet address or raw error text (RPC errors can include one). */
export function track(name: string, params: Record<string, string | number | undefined> = {}): void {
  window.gtag?.("event", name, params);
}
