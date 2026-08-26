# umia-abi

Typed ABIs and raw JSON exports for the Umia smart contracts. Generated from `forge build` output via `wagmi-cli`.

> Published to npm as **`umia-abi`** (unscoped). Inside the monorepo it's the `@umia/abi` workspace package — the name is swapped at publish time (see `publish.sh`).

## Layout

| Path                | What                                                      |
| ------------------- | --------------------------------------------------------- |
| `src/contracts.ts`  | Source-of-truth list of contracts whose ABIs we publish   |
| `src/generated.ts`  | `wagmi generate` output: typed `as const` ABIs            |
| `src/index.ts`      | Public TS entrypoint                                      |
| `json/*.json`       | Raw ABI JSON, one file per contract                       |
| `wagmi.config.ts`   | `wagmi-cli` config                                        |
| `src/dump-json.ts`  | Extracts `out/*.sol/*.json` → `json/*.json`               |

## Use

From inside the monorepo:

```ts
import { umiaHubAbi } from "@umia/abi";
```

From outside (`bun add umia-abi`), grab the raw JSON:

```ts
import umiaHub from "umia-abi/json/UmiaHub.json";
// or via fetch / fs in non-TS clients
```

## Regenerate

After changing any of the contracts listed in `src/contracts.ts`:

```bash
just abi
```

This runs `wagmi generate` (which calls `forge build` internally) and then dumps the raw JSON. Commit the regenerated `src/generated.ts` and `json/*.json` alongside the contract change.

## Adding a contract

Add the name to the appropriate list in `src/contracts.ts` — `CONTRACTS` (in-scope deployables), `INTERFACES` (spec-only / integrator-facing), or `LIBRARIES` (with custom errors) — then run `just abi`.

## Decoding errors

Custom errors are declared across contracts, interfaces, and libraries. `allErrorsAbi` is a composite that unions every error declaration in the published surface, so SDK consumers can decode any revert without manually composing ABIs:

```ts
import { allErrorsAbi } from "@umia/abi";
import { decodeErrorResult } from "viem";

try {
  await client.simulateContract(...);
} catch (err) {
  const decoded = decodeErrorResult({ abi: allErrorsAbi, data: err.data });
  console.log(decoded.errorName, decoded.args);
}
```

The three lists exist because solc doesn't always bubble errors from libraries and uninherited interfaces into the calling contract's ABI. Shipping the source-of-truth ABIs alongside the contract ABIs closes that gap.

## Publishing to npm

1. Bump `version` in `smart-contracts/abi/package.json`.
2. Commit the bump.
3. From the repo root:
   ```bash
   just publish-abi
   ```

The recipe refuses to publish if `smart-contracts/abi/` has uncommitted changes or if `just abi` would produce a diff (i.e. the committed ABIs are stale). It publishes the package as **`umia-abi`** with public access (the `@umia/abi` workspace name is swapped to the unscoped `umia-abi` only during publish, then reverted — see `publish.sh`).

Consumers install with `bun add umia-abi` (or `pnpm` / `npm`) and import either the typed TS barrel or the raw JSON files:

```ts
// typed (viem / wagmi-friendly, `as const` ABIs)
import { umiaHubAbi, allErrorsAbi } from "umia-abi";

// raw JSON (any TS / JS / Node setup)
import umiaHub from "umia-abi/json/UmiaHub.json";
```
