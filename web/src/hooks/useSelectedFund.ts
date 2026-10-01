import { useEffect, useState } from "react";
import { funds, type FundConfig } from "../config";

const fromUrl = () => new URLSearchParams(window.location.search).get("fund");

/**
 * Which fund the page shows and trades, kept in ?fund= so a link opens on the same fund.
 * The first fund (BLUE) is the default and leaves the URL clean.
 */
export function useSelectedFund(): [FundConfig, (id: string) => void] {
  const [id, setId] = useState(() => (funds.some((f) => f.id === fromUrl()) ? fromUrl()! : funds[0].id));

  useEffect(() => {
    const onPop = () => setId(funds.some((f) => f.id === fromUrl()) ? fromUrl()! : funds[0].id);
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);

  const select = (next: string) => {
    if (next === id) return;
    const url = new URL(window.location.href);
    if (next === funds[0].id) url.searchParams.delete("fund");
    else url.searchParams.set("fund", next);
    window.history.pushState(null, "", url);
    setId(next);
  };

  return [funds.find((f) => f.id === id) ?? funds[0], select];
}
