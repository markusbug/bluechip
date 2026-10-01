import { funds, siteConfig } from "../config";

export function Footer({ onCookieSettings }: { onCookieSettings?: () => void }) {
  const links = funds.flatMap(({ symbol, deployment }) =>
    deployment
      ? [
          { label: `${symbol} fund`, href: siteConfig.explorerAddress(deployment.fund) },
          ...(deployment.rebalancer ? [{ label: `${symbol} rebalancer`, href: siteConfig.explorerAddress(deployment.rebalancer) }] : []),
          ...(deployment.burner && !/^0x0+$/.test(deployment.burner)
            ? [{ label: `${symbol} CHIP burner`, href: siteConfig.explorerAddress(deployment.burner) }]
            : []),
        ]
      : [],
  );
  const symbols = new Intl.ListFormat("en", { type: "conjunction" }).format(funds.map((f) => f.symbol));
  return (
    <footer className="border-t border-line py-10 text-sm text-muted">
      <div className="grid gap-8 md:grid-cols-[2fr_1fr]">
        <div className="max-w-2xl space-y-3">
          <p>
            Bluechip is experimental, unaudited software. It is not investment advice and not an offer of securities. The tokenized
            stocks are issued by Coinbase and are not available to US persons; their issuer can pause or freeze them. {symbols}{" "}
            and CHIP can lose value. Check the rules where you live before using it.
          </p>
          <p>
            Stock prices come from Chainlink feeds. Minting and redeeming never read them; the rebalancer uses them to size and
            check its trades.
          </p>
        </div>
        <ul className="space-y-2">
          {links.map((l) => (
            <li key={l.label}>
              <a className="hover:text-ink" href={l.href} target="_blank" rel="noreferrer">
                {l.label} contract
              </a>
            </li>
          ))}
          <li>
            <a className="hover:text-ink" href={siteConfig.githubUrl} target="_blank" rel="noreferrer">
              Source code
            </a>
          </li>
          <li>
            <a className="hover:text-ink" href="https://bankr.bot" target="_blank" rel="noreferrer">
              CHIP launched on Bankr
            </a>
          </li>
          {onCookieSettings && (
            <li>
              <button type="button" className="hover:text-ink" onClick={onCookieSettings}>
                Cookie settings
              </button>
            </li>
          )}
        </ul>
      </div>
    </footer>
  );
}
