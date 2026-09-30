import { ChipSection } from "./components/ChipSection";
import { Footer } from "./components/Footer";
import { Header } from "./components/Header";
import { Hero } from "./components/Hero";
import { Holdings } from "./components/Holdings";
import { HowItWorks } from "./components/HowItWorks";
import { Trade } from "./components/Trade";
import { useFund } from "./hooks/useFund";
import { useWallet } from "./hooks/useWallet";

export default function App() {
  const fund = useFund();
  const wallet = useWallet();
  const refresh = () => {
    fund.refetch();
    wallet.refetch();
  };

  return (
    <>
      <Header />
      <main>
        <div className="mx-auto max-w-6xl px-4 sm:px-6">
          <Hero fund={fund} />
          <Holdings fund={fund} />
          <Trade fund={fund} wallet={wallet} onDone={refresh} />
        </div>
        <ChipSection fund={fund} wallet={wallet} onDone={refresh} />
        <div className="mx-auto max-w-6xl px-4 sm:px-6">
          <HowItWorks />
          <Footer />
        </div>
      </main>
    </>
  );
}
