#!/usr/bin/env bash
#
# Fetch this host's prebuilt static archive from the GitHub release into
# lib/<target>/.
#
#   ./native/fetch-static.sh
#   ./native/fetch-static.sh --no-fetch    # fail instead of reaching the network
#   ./native/fetch-static.sh --force       # re-download even if the file verifies
#
# **This is the setup step — the only one.** slang.c3l links Slang statically
# and has no other mode: there is no SDK to install, no dylibs to stage, no
# rpath, and nothing beside the finished binary. It needs no C++ toolchain,
# takes a few seconds, and a checkout that has not run it fails at the linker
# with "library not found for -lslang".
#
# The archives are built by native/build-slang.sh on a machine of each target's
# own architecture and published by native/publish-static.sh.
#
# ## Why a release asset and not a branch
#
# These used to live on a `static` orphan branch. That kept them out of a
# checkout but NOT out of the object database: `git clone` fetches every
# `refs/heads/*` unconditionally, so every clone of this repository — and every
# clone of anything using it as a submodule — paid for ~43 MB per target whether
# or not it ever linked against one. There is no per-branch opt-out; a branch is
# simply the wrong place to put a binary.
#
# A release asset is not reachable from any ref, so it costs a clone nothing and
# is fetched on demand by exactly the machines that need it.
#
# **The pin is native/SHA256SUMS, published beside the archives.** The tag is
# rolling, so it alone promises nothing; the hashes say which bytes a given
# publish produced, and a mismatch fails here by name rather than surfacing as
# an unresolved symbol in a consumer's link.
#
# **A consumer of these archives must pass `-O0` to Slang.** They are built
# without slang-glslang, which is where spirv-opt lives, and Slang runs
# spirv-opt at its default -O1 — so a compile that never mentions optimisation
# fails with "failed to load downstream compiler 'spirv-opt'". lib/<target>/
# VERSION records which build you got. See build-slang.sh's header for why that
# module cannot be linked in whatever anybody does, and what -O0 costs.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

REPO="${SLANG_C3_REPO:-tonis2/slang.c3}"
TAG="${SLANG_STATIC_TAG:-static}"
CACHE="${SLANG_C3_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/slang.c3}"

force=0
allow_fetch=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)     REPO="${2:?--repo needs owner/name}"; shift 2 ;;
        --tag)      TAG="${2:?--tag needs a name}"; shift 2 ;;
        --force)    force=1; shift ;;
        --no-fetch) allow_fetch=0; shift ;;
        -h|--help)  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Release assets are a flat namespace, so the target goes in the filename rather
# than in a directory the way it did on the branch.
#   libslang.a + macos-aarch64 -> libslang-macos-aarch64.a
#   slang.lib  + windows-x64   -> slang-windows-x64.lib
asset="${name%.*}-${target}.${name##*.}"
base="https://github.com/$REPO/releases/download/$TAG"

out="lib/$target"
mkdir -p "$out" "$CACHE"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Download to a temporary and only rename once it verifies. A half-written file
# left under the final name would be trusted by the next run, and a 404 body is
# a perfectly valid small file.
download() {
    local url="$1" dest="$2"
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest.part" "$url" || { rm -f "$dest.part"; return 1; }
    mv "$dest.part" "$dest"
}

echo "fetch-static: $target from $REPO release '$TAG'"

# The pin lives with the release rather than in this repository — an archive is
# published from whichever machine can build it, and a hash committed here would
# mean a commit per target per bump. So it is fetched, and kept: the last copy
# that came down is cached, which is what lets --no-fetch still VERIFY rather
# than shrug and accept whatever is on disk.
sums="$CACHE/SHA256SUMS-$TAG"
if [[ $allow_fetch -eq 1 ]]; then
    download "$base/SHA256SUMS" "$sums" || {
        echo "fetch-static: the '$TAG' release has no SHA256SUMS." >&2
        echo "  Build this target and publish it:" >&2
        echo "    ./native/build-slang.sh && ./native/publish-static.sh" >&2
        exit 1; }
elif [[ -f "$sums" ]]; then
    echo "  --no-fetch: verifying against the SHA256SUMS cached from the last fetch"
else
    echo "fetch-static: --no-fetch was given and no SHA256SUMS has been fetched" >&2
    echo "  on this machine, so there is nothing to verify against." >&2
    exit 1
fi

want="$(awk -v a="$asset" '$2 == a { print $1 }' "$sums")"
if [[ -z "$want" ]]; then
    echo "fetch-static: the '$TAG' release carries no archive for $target." >&2
    echo "  It has:" >&2
    awk '{ print "    " $2 }' "$sums" >&2
    echo "  Slang cannot be cross-built — its generators run on the host — so" >&2
    echo "  $target has to be built on a $target machine." >&2
    exit 1
fi

if [[ $force -eq 0 && -f "$out/$name" ]] \
   && [[ "$(sha256_of "$out/$name")" == "$want" ]]; then
    echo "  $name: present"
else
    cached="$CACHE/$want"
    if [[ ! -f "$cached" || "$(sha256_of "$cached")" != "$want" ]]; then
        if [[ $allow_fetch -eq 0 ]]; then
            echo "fetch-static: $asset is not cached and --no-fetch was given." >&2
            exit 1
        fi
        echo "  $asset: downloading"
        download "$base/$asset" "$cached" || {
            echo "fetch-static: could not download $asset from the '$TAG' release." >&2
            echo "  SHA256SUMS lists it, so the asset itself is missing or the" >&2
            echo "  release was edited between the two requests. Check with:" >&2
            echo "    gh release view $TAG -R $REPO" >&2
            exit 1; }

        got="$(sha256_of "$cached")"
        if [[ "$got" != "$want" ]]; then
            rm -f "$cached"
            echo "fetch-static: $asset does not match SHA256SUMS." >&2
            echo "  expected $want" >&2
            echo "  got      $got" >&2
            exit 1
        fi
    else
        echo "  $asset: from cache"
    fi
    cp "$cached" "$out/$name"
fi

# 1 MB rather than -s: a fetch that went wrong can still leave a file, and a
# short one saved under this name would be reported as a working archive. The
# real thing has never been under 30 MB.
size="$(wc -c < "$out/$name" | tr -d ' ')"
if [[ "$size" -lt 1000000 ]]; then
    rm -f "$out/$name"
    echo "fetch-static: what came back is $size bytes — not an archive. Removed." >&2
    exit 1
fi

# `|| true` inside the substitution, and it is load-bearing: `set -o pipefail`
# makes the pipeline return nm's status, and a failing command substitution under
# `set -e` exits the script. So on any host whose nm cannot read this archive --
# no nm at all, or a format it does not know -- an advisory check would abort the
# fetch instead of warning about it.
found=$({ nm -g "$out/$name" 2>/dev/null || true; } | awk '/ T _?spCreateSession$/ { f = 1 } END { if (f) print "yes" }')
[[ "$found" == yes ]] || echo "fetch-static: WARNING — could not confirm the archive defines spCreateSession." >&2

# Nothing writes shared libraries here any more — the SDK-staging script that
# used to is gone. This sweeps what an older checkout of this library left
# behind, and it is not cosmetic: `-lslang` prefers a dylib to an archive when
# both are in the search path, so one surviving symlink from a previous version
# silently produces the old, dynamically linked build and this script appears to
# have done nothing.
for stale in "$out"/*.dylib "$out"/*.so "$out"/*.so.* "$out"/*.dll "$out"/*.lib; do
    if [[ -e "$stale" || -L "$stale" ]]; then
        case "$stale" in
            "$out/$name") continue ;;   # slang.lib on Windows IS the archive
        esac
        echo "fetch-static: removing $(basename "$stale") — left by an older checkout"
        rm -f "$stale"
    fi
done

if [[ $allow_fetch -eq 1 ]] && download "$base/VERSION-$target" "$out/VERSION"; then
    sed 's/^/  /' "$out/VERSION"
fi
echo "fetch-static: wrote $out/$name ($size bytes)"
