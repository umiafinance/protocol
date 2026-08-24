import * as generated from "./generated";

export {
  ALL_ARTIFACTS,
  CONTRACTS,
  type ContractName,
  FOUNDRY_ARTIFACT_PATHS,
  INTERFACES,
  type InterfaceName,
  LIBRARIES,
  type LibraryName,
} from "./contracts";
export * from "./generated";

export type AbiErrorItem = {
  readonly type: "error";
  readonly name: string;
  readonly inputs: ReadonlyArray<{
    readonly name?: string;
    readonly type: string;
    readonly internalType?: string;
  }>;
};

// Composite ABI of every custom error declared across the published
// surface — contracts, spec-only interfaces, and libraries. Pass this to
// `viem.decodeErrorResult({ abi: allErrorsAbi, data })` to decode any
// revert the Umia protocol can emit, regardless of which artifact
// originally declared it.
export const allErrorsAbi: readonly AbiErrorItem[] = (
  Object.values(generated) as readonly unknown[]
)
  .filter((value): value is readonly unknown[] => Array.isArray(value))
  .flatMap((abi) => abi as readonly unknown[])
  .filter(
    (item): item is AbiErrorItem =>
      typeof item === "object" && item !== null && (item as { type?: unknown }).type === "error",
  );
