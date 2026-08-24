# UmiaValidationHook

Source: `src/periphery/UmiaValidationHook.sol`

## Purpose

CCA validation hook that restricts bidding to verified users during auction steps. Supports three verification flows:

1. **Pre-verification (zkTLS)**: User submits a Reclaim proof via `submitProof()`, then bids later.
2. **Inline zkTLS**: User passes proof in `hookData` during bid submission.
3. **Server permit (EIP-712)**: Server signs a single-use permit for `(wallet, step, nonce, deadline, amount)`, submitted inline in `hookData`; the signature covers the bid amount, so a permit only authorizes the exact amount the server approved.

Registration is monotonic: a user verified at step N is eligible for steps N, N+1, N+2, etc.

## Lifecycle

One hook per gated auction. The CCA takes its `validationHook` as an immutable constructor parameter, so the order is:

1. Deploy the hook (`owner`, Reclaim verifier, permit signer). It is unpaired and inert.
2. Create the venture/CCA with the hook address as `validationHook` (ungated auctions pass `address(0)`).
3. `setCCA(cca)` as owner: one-shot pairing that caches the CCA's step schedule.
4. Enable steps, providers, permits as usual.

`internal-cli create-venture --whitelist-steps N` does all four; `deploy-validation-hook` + `pair-validation-hook` expose steps 1 and 3 for manual flows.

## Key state

- `_cca` (paired CCA contract, set once via `setCCA`)
- `_steps` (cached block ranges parsed from CCA's SSTORE2 data)
- `_stepEnabledBitmap` (which steps enforce verification)
- `_stepPermitEnabledBitmap` (which steps accept server permits)
- `_verifiedFromStep[user]` (per-user verification status, 1-indexed)
- `_stepProviderHashes[stepIndex]` (required Reclaim provider hashes per step)
- `_signer` (authorized EIP-712 permit signer)
- `_maxBidPrice` (optional bid price cap in Q96 format)
- `_identityToUser[providerHash][identityHash]` (OPRF sybil gate)

## Access control

- `validate(...)` called by the paired CCA on every bid submission.
- `setCCA(address)` owner-only; idempotent after first set.
- `enableStep(...)` / `disableStep(...)` owner-only step toggle with provider configuration.
- `setSigner(address)` / `setMaxBidPrice(uint256)` owner-only configuration.
- `submitProof(...)` / `submitProofBatch(...)` permissionless (the proof is the authorization). Server permits are never submitted on their own; they are consumed inline by `validate()`.
- `unregister(...)` / `clearIdentity(...)` owner-only user management.

## ERC165 introspection

Per [CIP-1](https://github.com/Uniswap/continuous-clearing-auction/blob/main/CIPs/cip-1.md), the hook inherits the CCA's `ValidationHookIntrospection` and advertises its own interface, `IUmiaValidationHook` (`src/interfaces/IUmiaValidationHook.sol`), so integrators can discover it through `supportsInterface` instead of trusting an address list.

| Interface                    | ID           |
| ---------------------------- | ------------ |
| `IERC165`                    | `0x01ffc9a7` |
| `IValidationHook`            | `0x22c44b5f` |
| `IUmiaValidationHook`        | `0xbff343b3` |
| `IMaxBidPriceValidationHook` | `0x2268a4c3` |

`IUmiaValidationHook` covers the permissionless surface: the gating config reads (`cca`, `getSteps`, `isStepEnabled`, `isStepPermitEnabled`, `getStepProviders`, `isVerified`, `signer`, `stepMaxBidAmount`, `zkBidTotal`, `isPermitNonceUsed`, `identityOwner`) plus the proof relays (`submitProof`, `submitProofBatch`). Owner-only administration is deliberately excluded, so ops changes cannot shift the ID integrators key off.

`IMaxBidPriceValidationHook` is Uniswap's own interface for a price-capped hook ([#365](https://github.com/Uniswap/continuous-clearing-auction/pull/365), still open, so `src/interfaces/IMaxBidPriceValidationHook.sol` mirrors it until we can import it). Our `maxBidPrice()` is signature-identical and, since Uniswap standardised `0` as "no effective cap", semantically identical too, so the claim is unconditional. The one thing that still differs is mutability: theirs is `immutable`, ours moves via `setMaxBidPrice`, so a consumer must not cache the value.

The cap's revert is `MaxBidPriceExceeded()`, deliberately bare so the selector (`0x77c99cf5`) matches theirs and generic CCA tooling can decode it without our ABI. `test_maxBidPriceExceeded_selectorMatchesUniswap` pins it.

`test_supportsInterface_idsAreStable` pins both IDs, so changing either interface fails the suite until the constants and this table are updated together.

## Notes

- If `_cca` is unset, `validate()` returns without enforcing. Bids sent between CCA creation and `setCCA` are therefore ungated; pair before the auction's first gated step.
- If the current block is outside all steps or the step is not enabled, validation passes.
- `sender != owner` on bids is rejected (`SenderNotBidOwner`).
- OPRF sybil gate binds one real-world identity to one wallet per provider. If `extractedParameters` is absent in the proof context, the gate is skipped rather than blocking the auction.
