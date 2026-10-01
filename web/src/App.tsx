import { useState } from "react";
import { ChipSection } from "./components/ChipSection";
import { ConsentBanner } from "./components/ConsentBanner";
import { Footer } from "./components/Footer";
import { FundPicker } from "./components/FundPicker";
import { Header } from "./components/Header";
import { Hero } from "./components/Hero";
import { Holdings } from "./components/Holdings";
import { HowItWorks } from "./components/HowItWorks";
import { Trade } from "./components/Trade";
import { funds } from "./config";
import { useFund } from "./hooks/useFund";
import { useSelectedFund } from "./hooks/useSelectedFund";
import { useWallet } from "./hooks/useWallet";
import { consentRequired, storedConsent } from "./lib/analytics";

export default function App() {
  // `funds` is fixed for the build, so this calls the same hooks in the same order on every render.
  const states = funds.map((f) => useFund(f));
  const [selected, select] = useSelectedFund();
  const fund = states[funds.indexOf(selected)];
  const wallet = useWallet(selected);
  const [askConsent, setAskConsent] = useState(() => consentRequired() && storedConsent() === undefined);
  const refresh = () => {
    fund.refetch();
    wallet.refetch();
  };

  return (
    <>
      <Header multiFund={funds.length > 1} />
      <main>
        <div className="mx-auto max-w-6xl px-4 sm:px-6">
          <Hero fund={fund} multiFund={funds.length > 1} />
          {funds.length > 1 && <FundPicker funds={states} selected={selected.id} onSelect={select} />}
          <Holdings fund={fund} />
          {/* Keyed by fund, so switching funds starts every form afresh. */}
          <Trade key={selected.id} fund={fund} wallet={wallet} onDone={refresh} />
        </div>
        <ChipSection funds={states} wallet={wallet} onDone={refresh} />
        <div className="mx-auto max-w-6xl px-4 sm:px-6">
          <HowItWorks />
          <Footer onCookieSettings={consentRequired() ? () => setAskConsent(true) : undefined} />
        </div>
      </main>
      {askConsent && <ConsentBanner onClose={() => setAskConsent(false)} />}
    </>
  );
}
