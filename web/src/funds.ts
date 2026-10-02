/**
 * The funds the site knows about, in display order, with their display copy. A fund shows on the
 * site once its basket file exists and (except BLUE) it is deployed on the chain (see config.ts).
 */
export type FundInfo = {
  /** The FUND id the scripts use; picks the deployment file. */
  id: string;
  /** contracts/basket/<basketName>.json */
  basketName: string;
  name: string;
  symbol: string;
  /** One line on what it holds. */
  tagline: string;
  /** The hero headline while this is the only fund on the site. */
  headline: string;
};

export const FUND_INFO: FundInfo[] = [
  {
    id: "blue",
    basketName: "mag7",
    name: "Bluechip Index",
    symbol: "BLUE",
    tagline: "The seven largest US tech companies.",
    headline: "Seven blue chips in one token.",
  },
  {
    id: "blueai",
    basketName: "blueai",
    name: "Bluechip AI",
    symbol: "BLUEAI",
    tagline: "The AI build-out: chips, cloud, models and memory.",
    headline: "The AI build-out in one token.",
  },
  {
    id: "bluex",
    basketName: "bluex",
    name: "Bluechip X",
    symbol: "BLUEX",
    tagline: "SpaceX and Tesla: rockets, satellites, cars and robots.",
    headline: "SpaceX and Tesla in one token.",
  },
];
