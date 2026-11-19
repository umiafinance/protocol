#!/usr/bin/env bash
# Runs forge with the experimental Solar compiler into out-solar/. Never deploy its output.
# Fetches a pinned Foundry nightly on first use: Solar in the v1.8.7 stable release miscompiles
# strings and memory arrays in this suite.
set -euo pipefail

tag=nightly-a577a1142515f5a96935a525935936a2281b4c75
case "$(uname -s)-$(uname -m)" in
Darwin-arm64) platform=darwin_arm64 sha=bc7f88a15772d20e8654fc53efabff29301a1c748ec11125ab235b8e030dc178 ;;
Darwin-x86_64) platform=darwin_amd64 sha=21169e13e8d82e41c1d1a9093c3182bf1c227eb9b1a73cbcf726b03fbac2c167 ;;
Linux-x86_64) platform=linux_amd64 sha=ae664bb91d82bc017b603ba82b9b081b4174b5f839bd9f35358df6483177d0a1 ;;
Linux-aarch64 | Linux-arm64) platform=linux_arm64 sha=acfd9a58148474879d5ba95ab598f468374eff839e709868734d126855992725 ;;
*)
    echo "forge-solar: unsupported platform $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

dir="${XDG_CACHE_HOME:-$HOME/.cache}/umia/foundry-$tag"
if [[ ! -x "$dir/bin/forge" ]]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "forge-solar: fetching Foundry $tag" >&2
    curl -fsSL -o "$tmp/foundry.tar.gz" \
        "https://github.com/foundry-rs/foundry/releases/download/$tag/foundry_nightly_$platform.tar.gz"
    if command -v sha256sum >/dev/null; then
        echo "$sha  $tmp/foundry.tar.gz" | sha256sum -c --quiet -
    else
        echo "$sha  $tmp/foundry.tar.gz" | shasum -a 256 -c --quiet -
    fi
    mkdir -p "$tmp/bin" "$(dirname "$dir")"
    tar -C "$tmp/bin" -xzf "$tmp/foundry.tar.gz"
    rm -rf "$dir"
    mkdir "$dir"
    mv "$tmp/bin" "$dir/bin"
fi

cd "$(dirname "$0")"
cmd="$1"
shift
# Forge >= 1.8 points v4-core's forge-std at its nested copy (two `Test`s), and Solar cannot yet
# resolve universal-router's context-scoped remapping, so its two importers are skipped.
PATH="$dir/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1 FOUNDRY_OUT=out-solar FOUNDRY_CACHE_PATH=cache-solar \
    exec forge "$cmd" --use solar --remappings 'lib/v4-core/:forge-std/=lib/forge-std/src/' \
    --skip UniversalRouterSingleHop --skip DeployV4Infra "$@"
