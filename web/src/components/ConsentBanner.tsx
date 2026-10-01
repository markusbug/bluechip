import { setConsent, type Consent } from "../lib/analytics";
import { Button } from "./ui";

/** Asks EU visitors before Google Analytics loads. Accept and decline look the same, so neither is the easy way out. */
export function ConsentBanner({ onClose }: { onClose: () => void }) {
  const choose = (c: Consent) => {
    setConsent(c);
    onClose();
  };
  return (
    <div role="region" aria-label="Cookie consent" className="fixed inset-x-4 bottom-4 z-50 mx-auto max-w-xl">
      <div className="rounded-[20px] border border-line bg-surface p-5 shadow-lg">
        <p className="text-sm text-muted">
          May we use Google Analytics? It sets cookies to count visits and show us where minting gets stuck. We never send it
          your wallet address. You can change your mind any time under Cookie settings at the bottom of the page.
        </p>
        <div className="mt-4 flex gap-3">
          <Button variant="outline" className="flex-1" onClick={() => choose("granted")}>
            Accept
          </Button>
          <Button variant="outline" className="flex-1" onClick={() => choose("denied")}>
            Decline
          </Button>
        </div>
      </div>
    </div>
  );
}
