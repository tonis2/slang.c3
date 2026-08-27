#!/usr/bin/env bash
#
# Push the archive built by build-slang.sh to the `static` orphan branch.
#
#   ./native/publish-static.sh                # this host's target
#   ./native/publish-static.sh --dry-run      # build the commit, do not push
#   ./native/publish-static.sh --remote up    # a remote other than origin
#
# ## Why a branch and not main
#
# The merged archive is ~43 MB per target, and it is rebuilt on every Slang bump.
# On main, git would keep every version of every target for ever — the same
# argument that keeps the SDK dylibs out of this repository in the first place,
# and the same one vulkan.c3l's `driver` branch was created for. This mirrors
# that branch deliberately, down to the fetch: one orphan commit, force-pushed,
# so the branch has exactly one revision however many bumps it has seen.
#
# It is cheaper than it sounds. git stores blobs zlib-compressed and this
# archive is object code: 42.8 MB on disk is about 14.5 MB in the pack, so all
# three targets together cost roughly what one uncompressed copy would. Old
# objects linger after a force-push until GitHub garbage-collects, which is
# also true of the driver branch and has not been a problem there.
#
# ## Why plumbing rather than a checkout
#
# Nothing below touches the working tree or HEAD. A `git checkout --orphan`
# would refuse or clobber, since this repository normally has a dirty tree —
# lib/<target>/ is where the archive being published *lives*. So the commit is
# assembled in a temporary index with hash-object/update-index/commit-tree,
# and the branch is written by pushing a commit id at a ref. The checkout you
# ran this from is not modified in any way.
#
# ## Why it starts from the existing branch
#
# Each target is built on its own machine — a Mac cannot produce the Linux
# archive, because Slang's build runs generators it compiled for the host. So a
# publish must ADD this target to whatever is already on the branch rather than
# replace it. The fetch below is what makes that true; without it, publishing
# from a Mac would silently delete the linux-x64 archive somebody else pushed.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

BRANCH="${SLANG_STATIC_BRANCH:-static}"
remote="origin"
dry=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry=1; shift ;;
        --remote) remote="${2:?--remote needs a name}"; shift 2 ;;
        --branch) BRANCH="${2:?--branch needs a name}"; shift 2 ;;
        *) echo "publish-static: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)   target="macos-aarch64"; name="libslang.a" ;;
    Darwin/x86_64)  target="macos-x64";     name="libslang.a" ;;
    Linux/x86_64)   target="linux-x64";     name="libslang.a" ;;
    Linux/aarch64)  target="linux-aarch64"; name="libslang.a" ;;
    # c3c reads a static library as <name>.lib on Windows, the shape ktx.c3l
    # ships zstd.lib in.
    MINGW*/*|MSYS*/*|CYGWIN*/*) target="windows-x64"; name="slang.lib" ;;
    *) echo "publish-static: no target mapping for $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

archive="lib/$target/$name"
[[ -f "$archive" ]] || {
    echo "publish-static: $archive does not exist — run ./native/build-slang.sh first" >&2
    exit 1; }

# **The same check build-slang.sh ends with, repeated here on purpose.** This is
# the last point at which a bad archive is cheap: past it, it is on a branch
# that other machines fetch, and the failure it causes is an unresolved symbol
# in a consumer's link naming a file the consumer does not own.
found=$(nm -g "$archive" 2>/dev/null | awk '/ T _?spCreateSession$/ { f = 1 } END { if (f) print "yes" }')
[[ "$found" == yes ]] || {
    echo "publish-static: $archive does not define spCreateSession — refusing to publish it." >&2
    exit 1; }

version="$(sed -n 's/^SLANG_VERSION="${SLANG_VERSION:-\(.*\)}"$/\1/p' native/build-slang.sh)"
[[ -n "$version" ]] || version="unknown"

# Recorded rather than left to be rediscovered: a consumer of this archive has
# to pass -O0, because glslang — which is where spirv-opt lives — is a shared
# module Slang dlopens by name and so can never be inside an archive. It is
# always `absent`; the field stays so that a VERSION file from a future build
# that somehow had it would say so rather than being silently identical.
glslang=absent

size="$(wc -c < "$archive" | tr -d ' ')"
echo "publish-static: $target/$name — slang $version, ${size} bytes, glslang $glslang"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_INDEX_FILE="$tmp/index"

# The branch may not exist yet; the first publish creates it.
if git fetch --depth 1 "$remote" "$BRANCH" 2>/dev/null; then
    echo "  starting from the existing $BRANCH"
    git read-tree FETCH_HEAD
else
    echo "  $BRANCH does not exist yet — creating it"
    git read-tree --empty
fi

blob="$(git hash-object -w "$archive")"
git update-index --add --cacheinfo "100644,$blob,$target/$name"

# One manifest per target rather than one for the branch, so two machines
# publishing different targets never write the same path and never conflict.
note="$tmp/note"
cat > "$note" <<EOF
slang $version
target $target
archive $name
bytes $size
glslang $glslang
built-by build-slang.sh
EOF
noteblob="$(git hash-object -w "$note")"
git update-index --add --cacheinfo "100644,$noteblob,$target/VERSION"

tree="$(git write-tree)"
# No parent: every publish replaces the branch with a single commit, so the
# history never accumulates a second copy of a 43 MB archive.
commit="$(git commit-tree "$tree" -m "static archives: $target, slang $version")"

echo "  commit $commit"
git ls-tree -r --long "$tree" | awk '{ printf "    %10s  %s\n", $4, $5 }'

if [[ $dry -eq 1 ]]; then
    echo "publish-static: --dry-run, not pushing. To push it:"
    echo "  git push --force $remote $commit:refs/heads/$BRANCH"
    exit 0
fi

git push --force "$remote" "$commit:refs/heads/$BRANCH"
echo "publish-static: pushed to $remote/$BRANCH"
