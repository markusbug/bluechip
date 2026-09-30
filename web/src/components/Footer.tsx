import { deployment, siteConfig } from "../config";

export function Footer() {
  const links = deployment
    ? [
        { label: "BLUE fund", href: siteConfig.explorerAddress(deployment.fund) },
        { label: "CHIP vault", href: siteConfig.explorerAddress(deployment.vault) },
      ]
    : [];
  return (
    <footer className="border-t border-line py-10 text-sm text-muted">
      <div className="grid gap-8 md:grid-cols-[2fr_1fr]">
        <div className="max-w-2xl space-y-3">
          <p>
            Bluechip is experimental, unaudited software. It is not investment advice and not an offer of securities. The tokenized
            stocks are issued by Coinbase and are not available to US persons; their issuer can pause or freeze them. BLUE and
            CHIP can lose value. Check the rules where you live before using it.
          </p>
          <p>Stock prices come from Chainlink feeds and are shown for information only. The contracts never read them.</p>
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
        </ul>
      </div>
    </footer>
  );
}
