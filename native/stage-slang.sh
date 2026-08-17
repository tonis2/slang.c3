#!/usr/bin/env bash
#
# Symlink the Slang libraries this binding links against into lib/<target>/.
#
# Run once per checkout:
#
#     ./native/stage-slang.sh
#
# The SDK is found in this order: $SLANG_SDK, then the directory two levels up
# from slangc on PATH, then a short list of usual places. Nothing about the path
# is recorded anywhere — the symlinks are gitignored and the manifest names only
# `slang`, so a different machine re-runs this and gets a working build without
# editing anything.
#
# **Two libraries, not one, and not five.** libslang-compiler is the compiler
# itself. libslang-glslang is spirv-opt, which Slang loads as a downstream tool
# on the SPIR-V path — without it every compile fails with "failed to load
# downstream compiler 'spirv-opt'", which reads like a missing binary rather
# than a missing dylib. libslang-llvm is 102 MB and is only needed for CPU and
# host codegen targets, so it is deliberately not staged; that was a guess once
# and is now measured.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)  target="macos-aarch64"; ext="dylib" ;;
    Darwin/x86_64) target="macos-x64";     ext="dylib" ;;
    Linux/x86_64)  target="linux-x64";     ext="so"    ;;
    Linux/aarch64) target="linux-aarch64"; ext="so"    ;;
    *) echo "stage-slang: no target mapping for $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

find_sdk() {
    if [[ -n "${SLANG_SDK:-}" ]]; then
        echo "$SLANG_SDK"
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

sdk="$(find_sdk || true)"
if [[ -z "$sdk" || ! -d "$sdk/lib" ]]; then
    cat >&2 <<'EOF'
stage-slang: could not find a Slang SDK.

Set SLANG_SDK to the directory holding bin/ include/ lib/, or put slangc on
PATH. Releases: https://github.com/shader-slang/slang/releases

Only the release archive is needed — no build, and nothing to install system
wide. Unpack it anywhere and point SLANG_SDK at it.
EOF
    exit 1
fi

echo "stage-slang: SDK at $sdk"
mkdir -p "$here/lib/$target"

staged=0
for pattern in "libslang-compiler*.$ext" "libslang-glslang*.$ext" "libslang.$ext"; do
    # Nullglob rather than a bare glob: an SDK laid out differently should say
    # which library is missing, not link a file literally named "libslang-*".
    shopt -s nullglob
    for found in "$sdk/lib/"$pattern; do
        name="$(basename "$found")"
        ln -sfn "$found" "$here/lib/$target/$name"
        echo "  $name"
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
if [[ ! -e "$here/lib/$target/libslang.$ext" ]]; then
    shopt -s nullglob
    for found in "$here/lib/$target/"libslang-compiler*."$ext"; do
        ln -sfn "$(basename "$found")" "$here/lib/$target/libslang.$ext"
        echo "  libslang.$ext -> $(basename "$found")"
    done
    shopt -u nullglob
fi

echo "stage-slang: $staged libraries in lib/$target"
