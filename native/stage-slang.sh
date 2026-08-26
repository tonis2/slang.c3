#!/usr/bin/env bash
#
# Symlink the Slang libraries this binding links against into lib/<target>/.
#
# Run once per checkout:
#
#     ./native/stage-slang.sh              # use an installed SDK, or fetch one
#     ./native/stage-slang.sh --fetch      # always fetch the pinned release
#     ./native/stage-slang.sh --no-fetch   # fail instead of reaching the network
#
# An SDK is looked for in this order: $SLANG_SDK, a previously fetched one in the
# shared cache, then slangc on PATH, then a short list of usual places. If none
# of those turns one up, the release named by $SLANG_VERSION is downloaded,
# pruned to the two libraries this needs, and used.
#
# The download is cached **per machine, not per checkout** — ~/.cache/slang.c3 by
# default — so a second checkout costs nothing. $SLANG_C3_CACHE moves it.
#
# Nothing about the path is recorded anywhere — the symlinks and the cache are
# both outside git and the manifest names only `slang` — so a different machine
# re-runs this and gets a working build without editing anything.
#
# **Two libraries on Unix, three on Windows, and not five.** libslang-compiler
# is the compiler itself. libslang-glslang is spirv-opt, which Slang loads as a
# downstream tool on the SPIR-V path — without it every compile fails with
# "failed to load downstream compiler 'spirv-opt'", which reads like a missing
# binary rather than a missing dylib. libslang-llvm is 102 MB and is only needed
# for CPU and host codegen targets, so it is deliberately not kept; that was a
# guess once and is now measured.
#

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# **The version is the whole configuration.** It names a release tag —
#
#     https://github.com/shader-slang/slang/releases/tag/v2026.12.2
#
# — and everything else is derived from it. Bumping is this one line, or
# `SLANG_VERSION=2026.14.1 ./native/stage-slang.sh --fetch` to try one without
# editing anything.
#
# Pinned rather than "latest" so that two machines running this a month apart get
# the same compiler; a shader that compiles here and not there is the failure
# this exists to prevent.
SLANG_VERSION="${SLANG_VERSION:-2026.12.2}"

# **Optional.** A version listed here is verified against its recorded SHA-256; a
# version that is not still works, and the script prints the hash it got so it
# can be added. That keeps a bump to one line while leaving the door open to
# locking it down, and it is an honest description of what is being trusted:
# with a hash, GitHub cannot swap the asset under an existing tag without this
# noticing; without one, it can.
#
# Slang publishes no checksum file, so these are this repository's own, taken
# from the archives as downloaded. The macos-aarch64 one was additionally
# cross-checked against an independently installed SDK, whose two libraries hash
# identically to the ones inside the archive.
sha_for() {
    case "$1/$2" in
        2026.12.2/macos-aarch64) echo "de919ef0d616a8dba86fa8443bb25975492936872cb261094c1a152522b3b495" ;;
        2026.12.2/macos-x64)     echo "e0bdbd8cc39c8d0b9f7a0308d93f4f5d004af27d71aa131d7b173768fe3f70eb" ;;
        2026.12.2/linux-x64)     echo "44be91947132d46222e6565cbdaa0f32a898a8328f04de1091e89222d2a3fdfd" ;;
        2026.12.2/linux-aarch64) echo "42e2c649e5b7d1e05e466210ee3314232538604053323d1e3e2f32af81faef08" ;;
        # Not the pinned version — recorded because the suite was run against it
        # to see whether the deprecated sp* family survives a couple of releases.
        # It does: 11/11 on 2026.14.1, reflection numbers and the row-major
        # default included. Bumping to it is a one-word change with the
        # verification already here.
        2026.14.1/macos-aarch64) echo "92da7ab6226dd951037cd85397f830ae78fe40fbbb8928882e0b2654e468fdd4" ;;
    esac
}

# Release assets are named by the platform's own spelling, which is not c3c's.
#
# **linux-x64 takes the glibc-2.28 build deliberately.** It is 22 MB against the
# plain build's 73 MB, carries the same two libraries this needs, and omits only
# libslang-llvm — which gets deleted below anyway. Being built against an older
# glibc makes it run on *more* systems, not fewer. The aarch64 story is the
# reverse: its plain build is already 20 MB with no llvm, and its glibc-2.28
# variant is bigger, so each platform takes whichever is smaller.
asset_for_target() {
    case "$1" in
        macos-aarch64)  echo "slang-$SLANG_VERSION-macos-aarch64.tar.gz" ;;
        macos-x64)      echo "slang-$SLANG_VERSION-macos-x86_64.tar.gz" ;;
        linux-x64)      echo "slang-$SLANG_VERSION-linux-x86_64-glibc-2.28.tar.gz" ;;
        linux-aarch64)  echo "slang-$SLANG_VERSION-linux-aarch64.tar.gz" ;;
        # No glibc variants and no small build to choose between: the x86_64
        # archive is the only one, and it is 69 MB because it carries
        # slang-llvm. The prune below takes it back to about 50 MB staged.
        windows-x64)    echo "slang-$SLANG_VERSION-windows-x86_64.tar.gz" ;;
    esac
}

mode="auto"
case "${1:-}" in
    --fetch)    mode="fetch" ;;
    --no-fetch) mode="no-fetch" ;;
    "")         ;;
    *) echo "stage-slang: unknown argument '$1' (--fetch, --no-fetch)" >&2; exit 1 ;;
esac

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)   target="macos-aarch64"; ext="dylib" ;;
    Darwin/x86_64)  target="macos-x64";     ext="dylib" ;;
    Linux/x86_64)   target="linux-x64";     ext="so"    ;;
    Linux/aarch64)  target="linux-aarch64"; ext="so"    ;;
    # git-bash, MSYS2 and Cygwin each spell it differently and all three are how
    # a Windows checkout runs a shell script.
    MINGW*/*|MSYS*/*|CYGWIN*/*) target="windows-x64"; ext="dll" ;;
    *) echo "stage-slang: no target mapping for $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

# One flag rather than a string compare at four call sites.
windows=0
[[ "$ext" == "dll" ]] && windows=1

# Where a fetched SDK is kept. **Shared between checkouts on purpose:** the
# archive is 20-54 MB depending on platform, and three checkouts on one machine
# should not mean downloading the same bytes three times.
#
# $SLANG_C3_CACHE overrides it; otherwise $XDG_CACHE_HOME, then ~/.cache. If none
# of those is usable — no HOME, or an unwritable one, which build containers do —
# it falls back to .slang-sdk/ inside the checkout, which is gitignored. Keyed by
# version *and* target so that two projects pinning different versions, or a
# cross-compile, do not fight over one directory.
cache_root() {
    if [[ -n "${SLANG_C3_CACHE:-}" ]]; then
        echo "$SLANG_C3_CACHE"
    elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
        echo "$XDG_CACHE_HOME/slang.c3"
    elif [[ -n "${HOME:-}" ]]; then
        echo "$HOME/.cache/slang.c3"
    fi
}

shared_root="$(cache_root)"
shared_sdk=""
[[ -n "$shared_root" ]] && shared_sdk="$shared_root/$SLANG_VERSION/$target"
local_sdk="$here/.slang-sdk/$SLANG_VERSION/$target"

# Set by fetch_sdk to wherever it actually put things.
fetched_sdk=""

find_sdk() {
    if [[ -n "${SLANG_SDK:-}" ]]; then
        echo "$SLANG_SDK"
        return
    fi
    # Before PATH, so that a machine which fetched once keeps using what it
    # fetched rather than silently switching to whatever gets installed later.
    if [[ -n "$shared_sdk" && -d "$shared_sdk/lib" ]]; then
        echo "$shared_sdk"
        return
    fi
    if [[ -d "$local_sdk/lib" ]]; then
        echo "$local_sdk"
        return
    fi
    if command -v slangc >/dev/null 2>&1; then
        local bin
        bin="$(command -v slangc)"
        echo "$(cd "$(dirname "$bin")/.." && pwd)"
        return
    fi
    for candidate in "$HOME/binaries/slang" "$HOME/slang" /usr/local/slang /opt/slang; do
        if [[ -d "$candidate/lib" ]]; then
            echo "$candidate"
            return
        fi
    done
    return 1
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        echo "stage-slang: no shasum or sha256sum — cannot verify the download" >&2
        exit 1
    fi
}

download_to() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --show-progress -O "$out" "$url"
    else
        echo "stage-slang: neither curl nor wget is available" >&2
        exit 1
    fi
}

fetch_sdk() {
    local asset expected url dest hold tmp archive got
    asset="$(asset_for_target "$target")"
    if [[ -z "$asset" ]]; then
        cat >&2 <<EOF
stage-slang: no release asset known for $target.

Install a Slang SDK and set SLANG_SDK, or add this target to asset_for_target in
this script. Releases: https://github.com/shader-slang/slang/releases
EOF
        exit 1
    fi
    expected="$(sha_for "$SLANG_VERSION" "$target")"

    url="https://github.com/shader-slang/slang/releases/download/v$SLANG_VERSION/$asset"

    # The shared cache when it can be written, the checkout when it cannot.
    # Probed rather than assumed, and only at the point of actually needing it,
    # so that a run which finds an installed SDK creates nothing in ~/.cache.
    dest="$local_sdk"
    if [[ -n "$shared_root" ]] && mkdir -p "$shared_root" 2>/dev/null && [[ -w "$shared_root" ]]; then
        dest="$shared_sdk"
    elif [[ -n "$shared_root" ]]; then
        echo "stage-slang: $shared_root is not writable — keeping the SDK in the checkout" >&2
    fi
    hold="$(dirname "$dest")"
    tmp="$hold/.tmp.$$"
    archive="$hold/$asset"

    mkdir -p "$hold"
    # The whole temp tree, not just the archive: an interrupted run must not
    # leave a half-unpacked directory that the next one mistakes for an SDK.
    trap 'rm -rf "$tmp" "$archive"' EXIT

    echo "stage-slang: fetching Slang $SLANG_VERSION for $target" >&2
    echo "  $url" >&2
    if ! download_to "$url" "$archive"; then
        cat >&2 <<EOF

stage-slang: the download failed.

If this is not a network problem, the release may no longer carry that asset —
check https://github.com/shader-slang/slang/releases/tag/v$SLANG_VERSION. An
installed SDK pointed at by SLANG_SDK is used in preference to any download.
EOF
        exit 1
    fi

    got="$(sha256_of "$archive")"
    if [[ -z "$expected" ]]; then
        cat >&2 <<EOF
stage-slang: $SLANG_VERSION is not a recorded version, so nothing was verified.

To pin it, add this line to sha_for in this script:

        $SLANG_VERSION/$target) echo "$got" ;;
EOF
    elif [[ "$got" != "$expected" ]]; then
        cat >&2 <<EOF
stage-slang: checksum mismatch — refusing to use this download.

  expected  $expected
  got       $got

Either the release assets were replaced upstream, or the download is not what
it claims to be. Nothing has been installed.
EOF
        exit 1
    else
        echo "stage-slang: sha256 ok" >&2
    fi

    rm -rf "$tmp"
    mkdir -p "$tmp"
    tar xzf "$archive" -C "$tmp"

    # Up to 169 MB unpacked, depending on the platform — 102 MB of that is
    # libslang-llvm where it ships at all, and 22 MB is documentation.
    # Everything but the compiler, spirv-opt and the slangc driver goes, which
    # leaves about 36 MB. Pruned here rather than extracted selectively because
    # tar's wildcard flags differ between BSD and GNU, and a flag that is
    # silently ignored is worse than a delete that is not.
    if (( windows )); then
        # bin/ is where the CODE is on Windows, so the Unix rule — keep only
        # slangc in bin/ — would delete the compiler. lib/ here holds import
        # libraries, which are small and are what the linker reads.
        find "$tmp/bin" -mindepth 1 -maxdepth 1 \
            ! -name "slang.dll" \
            ! -name "slang-compiler.dll" \
            ! -name "slang-glslang.dll" \
            ! -name "slangc.exe" \
            -exec rm -rf {} + 2>/dev/null || true
        find "$tmp/lib" -mindepth 1 -maxdepth 1 \
            ! -name "slang.lib" \
            ! -name "slang-compiler.lib" \
            -exec rm -rf {} + 2>/dev/null || true
    else
        find "$tmp/lib" -mindepth 1 -maxdepth 1 \
            ! -name "libslang.$ext" \
            ! -name "libslang-compiler*" \
            ! -name "libslang-glslang*" \
            -exec rm -rf {} + 2>/dev/null || true
        find "$tmp/bin" -mindepth 1 -maxdepth 1 ! -name slangc -exec rm -rf {} + 2>/dev/null || true
    fi
    rm -rf "$tmp/share" "$tmp/include"

    rm -rf "$dest"
    mv "$tmp" "$dest"
    trap - EXIT
    rm -f "$archive"

    fetched_sdk="$dest"
    echo "stage-slang: unpacked to $dest ($(du -sh "$dest" | cut -f1))" >&2
}

if [[ "$mode" == "fetch" ]]; then
    # Reuses a cached copy of the same pinned version rather than downloading
    # again — it is the same bytes, already checksummed when it was written.
    # Delete the directory this prints to force a fresh download.
    if [[ -n "$shared_sdk" && -d "$shared_sdk/lib" ]]; then
        sdk="$shared_sdk"
    elif [[ -d "$local_sdk/lib" ]]; then
        sdk="$local_sdk"
    else
        fetch_sdk
        sdk="$fetched_sdk"
    fi
else
    sdk="$(find_sdk || true)"
    if [[ -z "$sdk" || ! -d "$sdk/lib" ]]; then
        if [[ "$mode" == "no-fetch" ]]; then
            cat >&2 <<'EOF'
stage-slang: could not find a Slang SDK, and --no-fetch was given.

Set SLANG_SDK to the directory holding bin/ include/ lib/, or put slangc on
PATH. Releases: https://github.com/shader-slang/slang/releases
EOF
            exit 1
        fi
        echo "stage-slang: no installed SDK found" >&2
        fetch_sdk
        sdk="$fetched_sdk"
    fi
fi

echo "stage-slang: SDK at $sdk"
mkdir -p "$here/lib/$target"

# **No `.$ext` on the prefixed patterns**, because the two platforms put the
# version on opposite sides of the extension:
#
#     macOS   libslang-compiler.0.2026.12.2.dylib
#     Linux   libslang-compiler.so.0.2026.12.2
#
# and the file that has to be there at runtime is the versioned one — it is the
# macOS install name and it is the Linux SONAME, both verified with objdump.
# `libslang-compiler*.so` matches only the unversioned symlink, so a Linux build
# linked and then failed to load. Not caught for a milestone because nothing had
# been built on Linux.
# What to take, and from which directory of the SDK. On Unix everything the
# build needs is in lib/; on Windows the linker's half is in lib/ and the
# loader's half is in bin/, and both land in one staged directory because that
# is what the manifest's linklib-dir points at and what a bundle ships.
if (( windows )); then
    sources=( "lib/slang.lib" "bin/slang.dll" "bin/slang-compiler.dll" "bin/slang-glslang.dll" )
else
    sources=( "lib/libslang-compiler*" "lib/libslang-glslang*" "lib/libslang.$ext" )
fi

# A staged entry is a symlink where the platform has them and a copy where it
# does not. Windows symlinks need SeCreateSymbolicLinkPrivilege, which an
# ordinary checkout does not have, and a silently-failed link is a build that
# cannot find the compiler.
stage_one() {
    local found="$1" name
    name="$(basename "$found")"
    if (( windows )); then
        cp -f "$found" "$here/lib/$target/$name"
    else
        ln -sfn "$found" "$here/lib/$target/$name"
    fi
    echo "  $name"
}

staged=0
for pattern in "${sources[@]}"; do
    # Nullglob rather than a bare glob: an SDK laid out differently should say
    # which library is missing, not link a file literally named "libslang-*".
    shopt -s nullglob
    for found in "$sdk/"$pattern; do
        stage_one "$found"
        staged=$((staged + 1))
    done
    shopt -u nullglob
done

if [[ $staged -eq 0 ]]; then
    echo "stage-slang: $sdk/lib holds no libslang — is that really an SDK?" >&2
    exit 1
fi

# The linker resolves -lslang through this name. Some SDK layouts ship it as a
# symlink already, in which case the loop above copied the link and this is a
# no-op; others name only the versioned file.
#
# Windows needs none of it: -lslang reaches `slang.lib`, which the SDK ships
# under exactly that name and the loop above already staged. There is no
# versioned filename to alias and no `lib` prefix to add.
if (( ! windows )) && [[ ! -e "$here/lib/$target/libslang.$ext" ]]; then
    shopt -s nullglob
    for found in "$here/lib/$target/"libslang-compiler*."$ext"; do
        ln -sfn "$(basename "$found")" "$here/lib/$target/libslang.$ext"
        echo "  libslang.$ext -> $(basename "$found")"
    done
    shopt -u nullglob
fi

echo "stage-slang: $staged libraries in lib/$target"
