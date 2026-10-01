import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";

const known: Record<string, string> = {
  CapExceeded: "That would take the fund over its supply cap. Try a smaller amount.",
  NotSeeded: "The fund hasn't been seeded yet.",
  ZeroAmount: "Enter an amount above zero.",
  TransferMismatch: "A token moved a different amount than expected.",
  Slippage: "Prices moved past your slippage limit since the quote. Try again, or allow more slippage.",
  Expired: "The transaction waited too long to be included. Try again.",
  PartialFill: "A stock pool doesn't have enough liquidity for this size. Try a smaller amount.",
  RefundFailed: "The unspent ETH couldn't be sent back to your wallet.",
  ERC20InsufficientBalance: "Not enough balance.",
  ERC20InsufficientAllowance: "An allowance is missing. Try again to re-sign.",
};

/** One sentence the user can act on. */
export function explainError(e: unknown): string {
  if (e instanceof BaseError) {
    if (e.walk((x) => x instanceof UserRejectedRequestError)) return "You rejected the request in your wallet.";
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName;
    if (name && known[name]) return known[name];
    if (name) return `The contract refused: ${name}.`;
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}

/** A short, address-free label for analytics: "rejected", the contract error's name, or "other". */
export function errorKind(e: unknown): string {
  if (!(e instanceof BaseError)) return "other";
  if (e.walk((x) => x instanceof UserRejectedRequestError)) return "rejected";
  const revert = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
  return revert?.data?.errorName ?? "other";
}
