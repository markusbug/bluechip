// Which fund a script works on: --fund <id> or FUND=<id>, default "blue".
//
// One rule maps a fund id to its files (contracts/script/DeploymentIO.sol and web/src/config.ts
// follow the same one). BLUE predates the rule and keeps its original names:
//   blue    contracts/basket/mag7.config.json    contracts/deployments/<chainId>.json
//   <id>    contracts/basket/<id>.config.json    contracts/deployments/<chainId>-<id>.json
export const DEFAULT_FUND = "blue";

export function fundId() {
  const i = process.argv.indexOf("--fund");
  const id = i > 0 ? process.argv[i + 1] : process.env.FUND || DEFAULT_FUND;
  if (!/^[a-z0-9]+$/.test(id)) throw new Error(`fund id must be lowercase letters and digits, got "${id}"`);
  return id;
}

/** The basket file name: contracts/basket/<basket>.config.json and <basket>.json. */
export function basketOf(id) {
  return id === DEFAULT_FUND ? "mag7" : id;
}

/** The deployment file name in contracts/deployments/. */
export function deploymentFile(chainId, id) {
  return id === DEFAULT_FUND ? `${chainId}.json` : `${chainId}-${id}.json`;
}
