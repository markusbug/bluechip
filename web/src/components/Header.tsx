import { siteConfig } from "../config";
import { ChipMark } from "./PokerChip";
import { WalletButton } from "./WalletButton";

export function Header() {
  return (
    <header className="sticky top-0 z-20 border-b border-line bg-paper/85 backdrop-blur">
      <div className="mx-auto flex max-w-6xl items-center justify-between gap-3 px-4 py-3 sm:px-6">
        <a href="#top" className="flex items-center gap-2.5">
          <ChipMark size={30} />
          <span className="font-display text-base font-bold tracking-tight">Bluechip</span>
        </a>
        <nav className="hidden items-center gap-6 text-sm font-medium text-muted md:flex">
          <a href="#fund" className="hover:text-ink">The fund</a>
          <a href="#trade" className="hover:text-ink">Mint and redeem</a>
          <a href="#chip" className="hover:text-ink">$CHIP</a>
          <a href={siteConfig.githubUrl} target="_blank" rel="noreferrer" className="hover:text-ink">Code</a>
        </nav>
        <WalletButton />
      </div>
      {!siteConfig.isMainnet && (
        <div className="bg-blue-deep px-4 py-1.5 text-center text-xs font-medium text-white">
          {siteConfig.chainName} with mock stocks. Nothing here has real value.
        </div>
      )}
    </header>
  );
}
