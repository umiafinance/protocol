#!/usr/bin/env bash
#
# Publish the Umia ABIs to npm.
#
# Naming: internally this package is @umia/abi — that's the workspace name the
# rest of the monorepo (shared/chain et al.) imports. It can't be published under
# that scope because the @umia org is unavailable on npm, so it ships UNSCOPED as
# `umia-abi`. We swap the name only for the duration of `bun publish` and revert
# it afterwards (via a trap, so it reverts even if publish fails). The committed
# package.json therefore always reads @umia/abi.
#
# Usage: bump `version` in package.json and commit first, then `just publish-abi`.
# Extra args are forwarded to `bun publish` (e.g. `just publish-abi --dry-run`).
set -euo pipefail

cd "$(dirname "$0")" # smart-contracts/abi

# Clean-tree check via porcelain (catches staged + unstaged + untracked; plain
# `git diff --quiet` misses staged changes and new files).
require_clean() {
	[ -z "$(git status --porcelain -- .)" ] || {
		echo "$1"
		exit 1
	}
}

require_clean "✖ uncommitted changes in smart-contracts/abi/ — commit first"

bun run codegen
require_clean "✖ ABIs were stale — run 'just abi', commit, then retry"

bun run typecheck

# Swap @umia/abi -> umia-abi, publish, then always restore the committed name.
trap 'git checkout -- package.json' EXIT
npm pkg set name=umia-abi
echo "→ publishing umia-abi@$(npm pkg get version | tr -d '"') (internal name @umia/abi restored after)"
bun publish "$@"
