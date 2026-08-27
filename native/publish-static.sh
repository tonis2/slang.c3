#!/usr/bin/env bash
#
# Publish the archive built by build-slang.sh as a GitHub release asset.
#
#   ./native/publish-static.sh                # this host's target
#   ./native/publish-static.sh --dry-run      # show what would be uploaded
#   ./native/publish-static.sh --repo o/n     # a repository other than the default
#
# ## Why a release asset and not a branch
#
# The merged archive is ~43 MB per target and is rebuilt on every Slang bump.
# Committing it to main would make git keep every version of every target for
# ever. That much was always true — what an orphan `static` branch got wrong is
# subtler: it kept the archives out of a *checkout* but not out of the *object
# database*, and `git clone` fetches every `refs/heads/*` whether or not anyone
# asked for it. So every clone of this repository, and of every project using it
# as a submodule, paid for all of them. There is no way to mark a branch
# "do not clone me".
#
# Release assets are not reachable from any ref. A clone pays nothing, and
# fetch-static.sh pulls exactly the one archive the fetching machine can link.
#
# ## Why it starts from the existing SHA256SUMS
#
# Each target is built on its own machine — a Mac cannot produce the Linux
# archive, because Slang's build runs generators it compiled for the host. So a
# publish must ADD this target to whatever is already published rather than
# replace it. The merge below is what makes that true; without it, publishing
# from a Mac would drop the linux-x64 line somebody else uploaded.
#
# That merge is read-modify-write against one file, so two machines publishing
# at the same moment can lose one of the two lines. Publishes are rare and
# manual; if it happens, re-run the losing one.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

REPO="${SLANG_C3_REPO:-tonis2/slang.c3}"
TAG="${SLANG_STATIC_TAG:-static}"
dry=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry=1; shift ;;
        --repo)    REPO="${2:?--repo needs owner/name}"; shift 2 ;;
        --tag)     TAG="${2:?--tag needs a name}"; shift 2 ;;
        *) echo "publish-static: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

command -v gh >/dev/null 2>&1 || {
    echo "publish-static: needs the GitHub CLI — https://cli.github.com" >&2
    exit 1; }

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
# the last point at which a bad archive is cheap: past it, it is an asset other
# machines fetch, and the failure it causes is an unresolved symbol in a
# consumer's link naming a file the consumer does not own.
# `|| true` so that `set -e` plus `set -o pipefail` cannot kill the script at the
# assignment when nm fails -- the refusal below is the message worth printing,
# and a silent non-zero exit here would look like a different bug entirely.
found=$({ nm -g "$archive" 2>/dev/null || true; } | awk '/ T _?spCreateSession$/ { f = 1 } END { if (f) print "yes" }')
[[ "$found" == yes ]] || {
    echo "publish-static: $archive does not define spCreateSession — refusing to publish it." >&2
    echo "  (If nm on this host cannot read the archive at all, that is the same" >&2
    echo "   message; check it by hand before overriding.)" >&2
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

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}
hash="$(sha256_of "$archive")"

# Assets are a flat namespace, so the target goes in the filename rather than in
# a directory the way it did on the branch. fetch-static.sh derives the same
# name from `uname` — keep the two in step.
asset="${name%.*}-${target}.${name##*.}"

echo "publish-static: $asset — slang $version, ${size} bytes, glslang $glslang"
echo "  sha256 $hash"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$archive" "$tmp/$asset"

cat > "$tmp/VERSION-$target" <<EOF
slang $version
target $target
archive $name
bytes $size
sha256 $hash
glslang $glslang
built-by build-slang.sh
EOF

# Merge rather than overwrite: drop any previous line for THIS asset, keep every
# other target's, add the new one, sort so the file is stable to diff.
sums="$tmp/SHA256SUMS"
: > "$sums"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    if gh release download "$TAG" -R "$REPO" -p SHA256SUMS -O "$tmp/existing" 2>/dev/null; then
        grep -v "  $asset\$" "$tmp/existing" > "$sums" || true
    fi
    release_exists=1
else
    release_exists=0
fi
printf '%s  %s\n' "$hash" "$asset" >> "$sums"
sort -k2 -o "$sums" "$sums"

echo "  SHA256SUMS after merge:"
sed 's/^/    /' "$sums"

if [[ $dry -eq 1 ]]; then
    echo "publish-static: --dry-run, not uploading. It would run:"
    [[ $release_exists -eq 1 ]] || \
        echo "  gh release create $TAG -R $REPO --title $TAG --notes 'Prebuilt static Slang archives.'"
    echo "  gh release upload $TAG -R $REPO --clobber $asset VERSION-$target SHA256SUMS"
    exit 0
fi

if [[ $release_exists -eq 0 ]]; then
    echo "  '$TAG' does not exist yet — creating it"
    gh release create "$TAG" -R "$REPO" --title "$TAG" \
        --notes "Prebuilt static Slang archives, one per target. Fetched by native/fetch-static.sh; not in git, so a clone does not pay for them."
fi

gh release upload "$TAG" -R "$REPO" --clobber \
    "$tmp/$asset" "$tmp/VERSION-$target" "$sums"

echo "publish-static: uploaded to $REPO release '$TAG'"
