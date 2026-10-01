import { funds } from "../config";

/** "BLUE" while it's the only fund, "BLUE or BLUEAI" once there are more. */
const token = new Intl.ListFormat("en", { type: "disjunction" }).format(funds.map((f) => f.symbol));

const steps = [
  {
    title: `Deposit the stocks, get ${token}`,
    body: "Minting pulls each stock in the fund's current proportion. Deposits round in the fund's favour, so no one can mint cheaper than the holders before them.",
  },
  {
    title: "0.30% of each mint buys and burns CHIP",
    body: "The fee is paid in freshly minted fund tokens to the fund's CHIP burner. The owner can lower it or raise it up to a hard cap of 1%. Changing who may trade the stocks takes 7 days' notice, so you can redeem first.",
  },
  {
    title: "The burner turns fees into burned CHIP",
    body: "It redeems the fees for the stocks, sells them for USDC, buys CHIP in its trading pool and burns it. Burned CHIP is gone for good, so every mint shrinks the supply.",
  },
  {
    title: `Redeem ${token} for the stocks, any time`,
    body: "No fee, no queue, no pause switch. If an issuer freezes one stock, you can leave it behind and still take the rest.",
  },
];

export function HowItWorks() {
  return (
    <section id="how" className="scroll-mt-24 py-16">
      <h2 className="font-display text-2xl font-bold tracking-tight sm:text-3xl">How the money moves</h2>
      <ol className="mt-8 grid gap-8 sm:grid-cols-2 lg:grid-cols-4">
        {steps.map((s, i) => (
          <li key={s.title} className="border-t-2 border-blue pt-4">
            <span className="font-display text-sm font-bold text-blue">{i + 1}</span>
            <h3 className="mt-2 font-semibold leading-snug">{s.title}</h3>
            <p className="mt-2 text-sm leading-relaxed text-muted">{s.body}</p>
          </li>
        ))}
      </ol>
    </section>
  );
}
