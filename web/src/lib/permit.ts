import type { Address, Hex, TypedDataDomain } from "viem";
import { hashDomain, parseAbi, parseSignature } from "viem";
import { readContract, readContracts, signTypedData } from "wagmi/actions";
import { wagmiConfig } from "../wagmi";
import { siteConfig } from "../config";

const permitAbi = parseAbi([
  "function nonces(address) view returns (uint256)",
  "function name() view returns (string)",
  "function version() view returns (string)",
  "function DOMAIN_SEPARATOR() view returns (bytes32)",
  "function eip712Domain() view returns (bytes1 fields, string name, string version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] extensions)",
]);

/**
 * The EIP-712 domain a token's permit uses. B20 stocks and OpenZeppelin tokens expose it (EIP-5267);
 * Bankr/Doppler tokens and USDC don't, so fall back to `name()` + `version()` (USDC's is "2"; "1"
 * when there is none) and check it against DOMAIN_SEPARATOR. Null means "no usable permit", and the caller approves instead.
 */
export async function permitDomain(token: Address): Promise<TypedDataDomain | null> {
  const chainId = siteConfig.chain.id;
  try {
    const d = await readContract(wagmiConfig, { address: token, abi: permitAbi, functionName: "eip712Domain" });
    return { name: d[1], version: d[2], chainId: Number(d[3]), verifyingContract: d[4] };
  } catch {
    /* not EIP-5267 */
  }
  try {
    const [name, separator, version] = await readContracts(wagmiConfig, {
      contracts: [
        { address: token, abi: permitAbi, functionName: "name" },
        { address: token, abi: permitAbi, functionName: "DOMAIN_SEPARATOR" },
        { address: token, abi: permitAbi, functionName: "version" },
      ],
    });
    if (name.status !== "success" || separator.status !== "success") return null;
    const domain = { name: name.result, version: version.status === "success" ? version.result : "1", chainId, verifyingContract: token };
    const hash = hashDomain({
      domain: { ...domain, chainId: BigInt(chainId) },
      types: {
        EIP712Domain: [
          { name: "name", type: "string" },
          { name: "version", type: "string" },
          { name: "chainId", type: "uint256" },
          { name: "verifyingContract", type: "address" },
        ],
      },
    });
    return hash === separator.result ? domain : null;
  } catch {
    return null;
  }
}

export type SignedPermit = { value: bigint; deadline: bigint; v: number; r: Hex; s: Hex };

/** Ask the wallet for an EIP-2612 permit signature (gasless). */
export async function signPermit(p: {
  token: Address;
  domain: TypedDataDomain;
  owner: Address;
  spender: Address;
  value: bigint;
  deadline: bigint;
}): Promise<SignedPermit> {
  const nonce = await readContract(wagmiConfig, { address: p.token, abi: permitAbi, functionName: "nonces", args: [p.owner] });
  const signature = await signTypedData(wagmiConfig, {
    account: p.owner,
    domain: p.domain,
    types: {
      Permit: [
        { name: "owner", type: "address" },
        { name: "spender", type: "address" },
        { name: "value", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Permit",
    message: { owner: p.owner, spender: p.spender, value: p.value, nonce, deadline: p.deadline },
  });
  const { r, s, v, yParity } = parseSignature(signature);
  return { value: p.value, deadline: p.deadline, v: Number(v ?? BigInt(yParity + 27)), r, s };
}

/** A permit slot that tells the contract "no permit for this token". */
export const NO_PERMIT: SignedPermit = { value: 0n, deadline: 0n, v: 0, r: `0x${"0".repeat(64)}`, s: `0x${"0".repeat(64)}` };

export const permitDeadline = () => BigInt(Math.floor(Date.now() / 1000) + 30 * 60);
