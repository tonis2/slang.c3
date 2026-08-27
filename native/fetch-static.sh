#!/usr/bin/env bash
#
# Fetch this host's prebuilt static archive from the `static` orphan branch into
# lib/<target>/, and take the staged dylibs out of the way.
#
#   ./native/fetch-static.sh              # this host's target
#   ./native/fetch-static.sh --keep       # do not delete the staged dylibs
#
# This is the counterpart to stage-slang.sh, one level further along: that
# script gets you Slang as shared libraries beside the binary, this one gets you
# Slang *inside* the binary. Use it when the thing being produced is a single
# file somebody downloads and runs; use stage-slang.sh otherwise, because it
# needs no C++ toolchain and takes thirty seconds.
#
# The archives are built by native/build-slang.sh on a machine of each target's
# own architecture and pushed by native/publish-static.sh. They are not on main
# and not in a plain checkout: ~43 MB per target, rebuilt on every Slang bump,
# so main would keep every version of every target for ever. Same reasoning, and
# the same fetch, as vulkan.c3l's `driver` branch.
#
# **A consumer of these archives must pass `-O0` to Slang.** They are built
# without slang-glslang, which is where spirv-opt lives, and Slang runs
# spirv-opt at its default -O1 — so a compile that never mentions optimisation
# fails with "failed to load downstream compiler 'spirv-opt'". lib/<target>/
# VERSION records which build you got. See build-slang.sh's header for why the
# module cannot simply be linked in, and what -O0 costs.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

BRANCH="${SLANG_STATIC_BRANCH:-static}"
remote="origin"
keep=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) keep=1; shift ;;
        --remote) remote="${2:?--remote needs a name}"; shift 2 ;;
        --branch) BRANCH="${2:?--branch needs a name}"; shift 2 ;;
        *) echo "fetch-static: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)   target="macos-aarch64"; name="libslang.a" ;;
    Darwin/x86_64)  target="macos-x64";     name="libslang.a" ;;
    Linux/x86_64)   target="linux-x64";     name="libslang.a" ;;
    Linux/aarch64)  target="linux-aarch64"; name="libslang.a" ;;
    MINGW*/*|MSYS*/*|CYGWIN*/*) target="windows-x64"; name="slang.lib" ;;
    *) echo "fetch-static: no target mapping for $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

out="lib/$target"
mkdir -p "$out"

echo "fetch-static: $target from $remote/$BRANCH"
git fetch --depth 1 "$remote" "$BRANCH" || {
    echo "::fetch-static: $remote has no '$BRANCH' branch." >&2
    echo "  Build it on a $target machine and publish it:" >&2
    echo "    ./native/build-slang.sh && ./native/publish-static.sh" >&2
    exit 1; }

git cat-file -e "FETCH_HEAD:$target/$name" 2>/dev/null || {
    echo "fetch-static: $BRANCH carries no archive for $target." >&2
    echo "  It has:" >&2
    git ls-tree --name-only -d FETCH_HEAD | sed 's/^/    /' >&2
    echo "  Slang cannot be cross-built — its generators run on the host — so" >&2
    echo "  $target has to be built on a $target machine." >&2
    exit 1; }

# Straight out of the object store, the way setup.sh reads the driver blob. No
# checkout, so a dirty working tree here is not a problem.
git cat-file blob "FETCH_HEAD:$target/$name" > "$out/$name"

# 1 MB rather than -s: a fetch that went wrong can still leave a file, and a
# short one saved under this name would be reported as a working archive. The
# real thing has never been under 30 MB.
size="$(wc -c < "$out/$name" | tr -d ' ')"
if [[ "$size" -lt 1000000 ]]; then
    rm -f "$out/$name"
    echo "fetch-static: what came back is $size bytes — not an archive. Removed." >&2
    exit 1
fi

found=$(nm -g "$out/$name" 2>/dev/null | awk '/ T _?spCreateSession$/ { f = 1 } END { if (f) print "yes" }')
[[ "$found" == yes ]] || echo "fetch-static: WARNING — the archive does not define spCreateSession." >&2

# `-lslang` prefers a dylib to an archive when both are in the search path, so
# leaving the staged symlinks here means this script appears to have done
# nothing. stage-slang.sh puts them back and removes the archive; whichever ran
# last is what the next build links.
if [[ $keep -eq 0 ]]; then
    for stale in "$out"/*.dylib "$out"/*.so "$out"/*.so.* "$out"/*.dll; do
        if [[ -e "$stale" || -L "$stale" ]]; then rm -f "$stale"; fi
    done
fi

git cat-file blob "FETCH_HEAD:$target/VERSION" 2>/dev/null | sed 's/^/  /' || true
echo "fetch-static: wrote $out/$name ($size bytes)"
