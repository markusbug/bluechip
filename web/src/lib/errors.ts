import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";

const known: Record<string, string> = {
  CapExceeded: "That would take the fund over its supply cap. Try a smaller amount.",
  NotSeeded: "The fund hasn't been seeded yet.",
  ZeroAmount: "Enter an amount above zero.",
  TransferMismatch: "A token moved a different amount than expected.",
  Slippage: "Your CHIP is worth nothing at this size. Claim a larger amount.",
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
