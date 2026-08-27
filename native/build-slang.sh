#!/usr/bin/env bash
#
# Build Slang from source and freeze it into ONE static archive:
# lib/<target>/libslang.a, the way quickjs.c3l's build-quickjs.sh freezes
# quickjs-ng.
#
#   ./native/build-slang.sh                 # host target, no glslang
#   ./native/build-slang.sh --with-glslang   # keep spirv-opt (see below)
#   ./native/build-slang.sh --jobs 8
#   ./native/build-slang.sh --clean          # throw the CMake tree away first
#
# **This is an alternative to stage-slang.sh, not a replacement.** That script
# is still the right default: it takes 30 seconds, needs no C++ toolchain, and
# is what a checkout should run to get building. This one exists for the one
# thing symlinked dylibs cannot do — ship `three` as a single file that a person
# downloads and runs, with no libraries beside it and no rpath to get wrong.
#
# The two are mutually exclusive inside lib/<target>/, because `-lslang` prefers
# a dylib to an archive when both are there. This script deletes the staged
# dylibs before writing the archive; re-running stage-slang.sh puts them back and
# deletes the archive. Whichever ran last is what the next build links.
#
# ## Why a source build at all
#
# **Slang's releases ship no static library.** Every asset under
# https://github.com/shader-slang/slang/releases carries .dylib/.so/.dll and an
# import .lib, and nothing else — there is no .a to link even if you want one.
# So unlike quickjs, where the archive is built from a vendored submodule in
# four `cc` invocations, this has to configure and build a real CMake project.
# Budget 15-40 minutes on a first run; the CMake tree is kept, so a second run
# is incremental unless --clean is passed.
#
# ## Why the archives get merged
#
# A STATIC Slang build does not produce one library. It produces the compiler
# plus every internal target it links privately — core, compiler-core, prelude,
# slang-capability-*, slang-lookup-tables — plus the third-party archives
# vendored into the build: SPIRV-Tools, SPIRV-Headers, miniz, lz4,
# unordered_dense. Slang's own CMakeLists says so, in the comment explaining why
# it refuses to install a pkg-config file for a static build: a link line naming
# only -lslang-compiler "omits every transitive internal archive ... causing
# unresolved-symbol errors at link time".
#
# c3c has no way to express that. A manifest's `linked-libraries` is a list of
# names it turns into -l flags, in no guaranteed order, with no repetition and no
# --start-group. Handing it twenty interdependent archives would be a link that
# works or does not depending on how the C3 compiler happens to sort them.
#
# So the merge is the point of this script, not an optimisation: one archive
# means one -l, and the manifest entry stays the single word it already is.
#
# ## Why glslang is off by default, and what it costs
#
# `libslang-glslang` is not glslang. It is glslang **and SPIRV-Tools**, and the
# part of it Slang actually wants on the SPIR-V path is `spirv-opt`. Slang runs
# spirv-opt at its default optimization level — `-O1`, per
# `slangc -h optimization-level`: "This is the default if no -O options are
# used" — so a compile that never mentions optimization still needs it, and
# -emit-spirv-directly does not change that. It selects the codegen path; the
# optimizer runs after codegen either way.
#
# **Static linking cannot absorb it.** Slang does not link slang-glslang; it
# dlopens it by name at runtime. `otool -L libslang-compiler.dylib` lists only
# libc++ and libSystem, and deleting the file produces
#
#     error[E00100]: failed to load downstream compiler 'spirv-opt'
#     note[E99996]: failed to load dynamic library 'slang-glslang-2026.12.2'
#
# So a build that keeps glslang has two files to ship no matter how slang itself
# is linked, and the single-file goal is gone. Hence OFF, and hence the coupling
# below.
#
# **A consumer of a no-glslang build must pass `-O0`.** three.c3 sets it in
# `SLANG_ARGUMENTS` (src/shader/compile.c3). Without it every compile fails with
# the error above. What -O0 costs, measured on this project's own shaders with
# slangc 2026.12.2:
#
#     mesh.slang   (vertex+fragment)   -O0 28700 B    -O1 28728 B
#     shadow.slang (vertex only)       -O0 11776 B    -O1 10320 B
#
# spirv-opt makes the larger module 28 bytes *bigger* and the smaller one 12%
# smaller. Module size is not runtime speed, and every Vulkan driver runs its own
# optimizer over SPIR-V before it reaches the GPU — but Slang's direct emitter is
# clearly not leaning on spirv-opt for much here.
#
# `--with-glslang` builds it anyway, for measuring that claim rather than
# trusting it. The archive is still one file; slang-glslang lands beside it as a
# shared module and has to be shipped.
#
# ## What is deliberately not built
#
#   slang-llvm    102 MB, and only for CPU and host-callable codegen. This
#                 binding targets SPIR-V. FETCH_BINARY would also reach the
#                 network mid-build, which a build script should not do.
#   gfx, slangd, slangi, slang-rt, tests, examples, replayer, DXIL
#                 Consumers of the library, not parts of it.
#   the proxy     SLANG_ENABLE_SLANG_PROXY exists to emit a legacy libslang
#                 shared object aliasing slang-compiler. There is no shared
#                 object here to alias.
#
# The core module IS embedded (SLANG_EMBED_CORE_MODULE, on by default), which is
# what keeps this a single file rather than a file plus a data directory.
#
# ## The C++ runtime
#
# libslang is C++ and a static link does not carry libc++ with it, so the
# consumer's link line needs it. manifest.json passes -lc++ (macOS, Linux with
# libc++) or -lstdc++ under link-args; it is harmless on a dylib build, which
# already has the dependency recorded.
#
# ## Not committed, unlike quickjs
#
# lib/*/ is gitignored here. The merged archive is 100-200 MB — quickjs's is
# 1.5 MB — and this repository's whole reason for symlinking rather than
# vendoring is that 27 MB in git history is permanent. Nothing changes about
# that: what is in git is this script.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Kept identical to stage-slang.sh on purpose. The tag decides the source, the
# checksum table there decides the binaries, and a bump has to move both
# together or a fetched SDK and a built archive are different compilers.
SLANG_VERSION="${SLANG_VERSION:-2026.12.2}"
SLANG_REPO="${SLANG_REPO:-https://github.com/shader-slang/slang.git}"

glslang=OFF
jobs=""
clean=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-glslang) glslang=ON; shift ;;
        --jobs) jobs="${2:?--jobs needs a number}"; shift 2 ;;
        --jobs=*) jobs="${1#*=}"; shift ;;
        --clean) clean=1; shift ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-slang: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

# **Host target only, and that is not laziness.** build-quickjs.sh cross-builds
# happily, so the natural expectation is that this does too. It does not, for
# reasons that stack:
#
#   the generators   CMake compiles tools during the build and then RUNS them.
#                    Cross-compiling means building those for the host first and
#                    pointing a second configure at them through
#                    SLANG_GENERATORS_PATH. Supported, but a two-stage build.
#   no mingw         Slang's CMakeLists knows WIN32 and MSVC and has no MINGW
#                    branch at all, so the compiler build-quickjs.sh crosses to
#                    Windows with is not a configuration this project supports.
#   no MSVC ABI off  Windows the CRT c3c downloads is import libraries only, with
#                    no headers, so nothing on a Mac or a Linux box can compile
#                    C++ for that ABI without a separate SDK-extraction step.
#
# The practical rule: **a windows-x64 archive is built on Windows, a linux-x64
# archive on Linux, and a macos-aarch64 archive on Apple silicon.** That is what
# the per-target `static` branch is for — each machine publishes its own.
windows=0
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)   target="macos-aarch64"; archive_name="libslang.a" ;;
    Darwin/x86_64)  target="macos-x64";     archive_name="libslang.a" ;;
    Linux/x86_64)   target="linux-x64";     archive_name="libslang.a" ;;
    Linux/aarch64)  target="linux-aarch64"; archive_name="libslang.a" ;;
    # git-bash, MSYS2 and Cygwin each spell it differently and all three are how
    # a Windows checkout runs a shell script. c3c reads a static library as
    # <name>.lib there — no `lib` prefix — which is the shape ktx.c3l ships
    # zstd.lib in, and is also the name stage-slang.sh gives Slang's IMPORT
    # library. The two are mutually exclusive in this directory, and the install
    # step below deletes whichever one it is replacing.
    MINGW*/*|MSYS*/*|CYGWIN*/*) target="windows-x64"; archive_name="slang.lib"; windows=1 ;;
    *) echo "build-slang: no target mapping for $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

for tool in cmake git; do
    command -v "$tool" >/dev/null || {
        echo "build-slang: $tool is required and not on PATH" >&2; exit 1; }
done

if [[ -z "$jobs" ]]; then
    if command -v sysctl >/dev/null 2>&1; then jobs="$(sysctl -n hw.ncpu)"
    elif command -v nproc >/dev/null 2>&1; then jobs="$(nproc)"
    else jobs=4; fi
fi

# **Windows needs MSVC, and needs it to be the compiler CMake picks.** Slang's
# CMakeLists knows WIN32 and MSVC and has no MINGW branch anywhere, so mingw is
# not a configuration upstream supports — and a git-bash shell usually has
# mingw's gcc on PATH, which CMake would otherwise choose on its own and fail
# somewhere deep in a header.
#
# Two ways to reach MSVC, and which is available depends on how the shell was
# started:
#
#   cl on PATH       a Developer Command Prompt or VS dev shell is active, so
#                    Ninja can be used and the build is much faster
#   cl not on PATH   fall back to the "Visual Studio 17 2022" generator, which
#                    locates the toolchain itself and needs no dev shell
#
# The merge below needs lib.exe, which comes with the same toolchain — so the
# Ninja path wants the dev shell for that reason too, and the check for it is
# at the merge rather than here.
generator="Unix Makefiles"
if [[ $windows -eq 1 ]]; then
    if command -v cl >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1; then
        generator="Ninja"
    else
        generator="Visual Studio 17 2022"
    fi
elif command -v ninja >/dev/null; then
    generator="Ninja"
fi

# The source and the CMake tree live beside the fetched SDKs, keyed by version,
# for stage-slang.sh's reason: they are large, they are reusable across
# checkouts, and none of it belongs in git. $SLANG_C3_CACHE moves it.
cache_root() {
    if [[ -n "${SLANG_C3_CACHE:-}" ]]; then echo "$SLANG_C3_CACHE"
    elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then echo "$XDG_CACHE_HOME/slang.c3"
    elif [[ -n "${HOME:-}" ]]; then echo "$HOME/.cache/slang.c3"
    else echo "$here/.slang-sdk"; fi
}

root="$(cache_root)/src"
src="$root/slang-$SLANG_VERSION"
build="$root/build-$SLANG_VERSION-$target-glslang$glslang"

echo "build-slang: $target, slang v$SLANG_VERSION, glslang=$glslang, -j$jobs"

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------
#
# --depth 1 at the tag. The gitlink history is not wanted and the submodules are
# large; what matters is that the tree is the pinned release and not whatever
# main happens to be, which is the same argument stage-slang.sh makes for
# pinning the asset.
if [[ ! -d "$src/.git" ]]; then
    echo "build-slang: cloning v$SLANG_VERSION"
    mkdir -p "$root"
    rm -rf "$src"
    git clone --depth 1 --branch "v$SLANG_VERSION" --recurse-submodules --shallow-submodules \
        "$SLANG_REPO" "$src"
else
    echo "build-slang: reusing $src"
fi

# ---------------------------------------------------------------------------
# Configure and build
# ---------------------------------------------------------------------------
if [[ $clean -eq 1 ]]; then rm -rf "$build"; fi

cmake_args=(
    -S "$src" -B "$build" -G "$generator"
    -DCMAKE_BUILD_TYPE=Release
    # Every archive that ends up merged has to be linkable into whatever the
    # consumer produces, and cc links a PIE by default on Linux — the same
    # relocation problem build-quickjs.sh passes -fPIC for, one level up.
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DSLANG_LIB_TYPE=STATIC
    -DSLANG_SLANG_LLVM_FLAVOR=DISABLE
    -DSLANG_ENABLE_SLANG_GLSLANG="$glslang"
    -DSLANG_ENABLE_GFX=OFF
    -DSLANG_ENABLE_SLANGD=OFF
    -DSLANG_ENABLE_SLANGI=OFF
    -DSLANG_ENABLE_SLANGRT=OFF
    -DSLANG_ENABLE_TESTS=OFF
    -DSLANG_ENABLE_EXAMPLES=OFF
    -DSLANG_ENABLE_REPLAYER=OFF
    -DSLANG_ENABLE_DXIL=OFF
    -DSLANG_ENABLE_SLANG_PROXY=OFF
    -DSLANG_EMBED_CORE_MODULE=ON
    # ON by default, and the single biggest thing between a usable archive and
    # an unusable one: with it, libslang-compiler.a alone is 1.1 GB. A static
    # library carries every object's DWARF in the archive rather than in a
    # separate .dSYM, so what is a manageable dylib plus a debug bundle becomes
    # one enormous file. Measured, not guessed.
    -DSLANG_ENABLE_RELEASE_DEBUG_INFO=OFF
    # A GPU abstraction layer for Slang's own examples and tests. TESTS=OFF does
    # not remove it — the first build made slang-rhi-tests anyway.
    -DSLANG_ENABLE_SLANG_RHI=OFF
)

# Matches three.c3's macos-min-version, which is 26.0 because that is what the
# bundled KosmicKrisp driver needs. The archive itself would build for far less
# — nothing in Slang asks for a recent SDK — but an object built for a *newer*
# target than the binary linking it is what draws ld's "built for newer macOS"
# warning, and a warning on every build is how a real one gets missed.
if [[ "$target" == macos-* ]]; then
    cmake_args+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0)
fi

if [[ $windows -eq 1 ]]; then
    # The Visual Studio generator is multi-config and takes the architecture as
    # a generator option rather than a variable; Ninja is single-config and
    # inherits it from the dev shell that put cl on PATH.
    if [[ "$generator" == Visual* ]]; then
        cmake_args+=(-A x64)
    fi
    # **Has to match what c3c links against.** c3c pulls an MSVC CRT into
    # ~/.cache/c3/msvc_sdk and links its import libraries — the DYNAMIC runtime.
    # An archive built /MT would drag a second, static copy of the CRT into the
    # same binary, and the linker reports that as several hundred duplicate
    # symbols naming msvcrt objects nobody in this project owns.
    cmake_args+=(-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL)
fi

# slangc is left at its default (built) deliberately: it is the cheapest possible
# proof that the static library it just linked against actually works, and the
# check at the bottom runs it.
cmake "${cmake_args[@]}"
cmake --build "$build" --config Release --parallel "$jobs"

# ---------------------------------------------------------------------------
# Merge
# ---------------------------------------------------------------------------
#
# Every .a the build produced, not a hand-written list. A list would go stale on
# the next release — Slang splits and renames internal targets between versions,
# and a missing one is an unresolved symbol in the *consumer's* link, naming a
# file the consumer does not own. A superset costs nothing: a static linker pulls
# only the members it needs.
#
# CMake's own object libraries (CMakeFiles/**) are excluded — they are inputs to
# the archives, not archives.
out="$here/lib/$target"
mkdir -p "$out"

# A while-read loop rather than mapfile: macOS still ships bash 3.2, and
# `mapfile` is bash 4. Nothing else here needs a newer shell.
# **No grep, and find with one plain predicate.** Both tools get wrapped on
# developer machines — this was written on one where /Users/.../bin/rtk-proxy
# shadows both, and its grep turns a stdin filter into a file-search summariser.
# That is a wrong-output failure rather than an error: the pipeline stayed green
# and the merge silently ran on three lines of a summary. Filtering in the shell
# cannot be intercepted, so the paths are matched with `case` instead.
#
# **generators/ is excluded, and that one is not cosmetic.** CMake builds a
# second, host-side compiler there — libslang-without-embedded-core-module.a,
# the whole compiler again — whose only job is to compile the core module that
# then gets embedded into the real one. Merging it doubles the archive and puts
# two definitions of every symbol in it.
#
# MSVC writes .lib rather than .a, and writes it for both the static libraries
# and the import libraries of anything shared — but nothing here is shared, so
# every .lib in the tree is a real archive.
lib_glob='*.a'
if [[ $windows -eq 1 ]]; then lib_glob='*.lib'; fi

archives=()
while IFS= read -r a; do
    case "$a" in
        */CMakeFiles/*) continue ;;
        */generators/*) continue ;;
    esac
    archives+=("$a")
done < <(find "$build" -name "$lib_glob" | sort)
if [[ ${#archives[@]} -eq 0 ]]; then
    echo "build-slang: the build produced no $lib_glob files" >&2
    exit 1
fi

echo "build-slang: merging ${#archives[@]} archives"
# **Not inside $build.** The merged archive is a .a like any other, so writing it
# there means the next run globs its own previous output back in as an input —
# the archive eats itself, one round per run.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
merged="$work/$archive_name"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        # **lib.exe, through a response file.** It is the MSVC archiver and it
        # merges archives the way libtool does — pass it .lib inputs and it
        # copies their members out rather than nesting them.
        #
        # The response file is not a nicety: Slang's build produces enough
        # archives, with long paths under the version-keyed cache directory,
        # to go past the ~32 KB Windows command line limit, and what that
        # produces is a truncated argument list rather than an error.
        #
        # llvm-lib is accepted as a stand-in because it takes the same flags
        # and ships with clang, which some Windows setups have without a full
        # VS install.
        archiver=""
        for candidate in lib.exe lib llvm-lib.exe llvm-lib; do
            if command -v "$candidate" >/dev/null 2>&1; then archiver="$candidate"; break; fi
        done
        [[ -n "$archiver" ]] || {
            echo "build-slang: no lib.exe on PATH." >&2
            echo "  It comes with MSVC. Start a Developer Command Prompt, or run" >&2
            echo "  vcvars64.bat, and try again." >&2
            exit 1; }

        rsp="$work/inputs.rsp"
        : > "$rsp"
        for a in "${archives[@]}"; do
            # cygpath so lib.exe gets a Windows path; it does not understand
            # the /c/... form a git-bash `find` hands back.
            if command -v cygpath >/dev/null 2>&1; then
                printf '"%s"\n' "$(cygpath -w "$a")" >> "$rsp"
            else
                printf '"%s"\n' "$a" >> "$rsp"
            fi
        done
        out_win="$merged"
        if command -v cygpath >/dev/null 2>&1; then out_win="$(cygpath -w "$merged")"; fi
        "$archiver" /NOLOGO "/OUT:$out_win" "@$(command -v cygpath >/dev/null 2>&1 && cygpath -w "$rsp" || echo "$rsp")"
        ;;
    Darwin)
        # libtool rather than ar: two archives in this set contain a member with
        # the same basename, and ar would keep one of them. libtool renames.
        # -no_warning_for_no_symbols because several of the small internal
        # targets are header-only and archive to nothing.
        libtool -static -no_warning_for_no_symbols -o "$merged" "${archives[@]}"
        ;;
    *)
        # GNU ar's MRI script. `addlib` copies members out of each archive rather
        # than nesting them, which is what a consumer's linker can read; `ar rcs
        # out.a in.a` would archive the archives themselves and link to nothing.
        {
            echo "create $merged"
            for a in "${archives[@]}"; do echo "addlib $a"; done
            echo "save"
            echo "end"
        } | ar -M
        ranlib "$merged" 2>/dev/null || true
        ;;
esac

# ---------------------------------------------------------------------------
# Install, and take the dylibs out of the way
# ---------------------------------------------------------------------------
#
# `-lslang` prefers libslang.dylib to libslang.a when both are in the search
# path, so leaving a stale symlink here means this script appears to do nothing.
for stale in "$out"/*.dylib "$out"/*.so "$out"/*.so.* "$out"/*.dll "$out"/slang.lib; do
    if [[ -e "$stale" || -L "$stale" ]]; then rm -f "$stale"; fi
done
rm -f "$out/$archive_name"
cp "$merged" "$out/$archive_name"

# The one library that cannot be merged in, when it was asked for: Slang dlopens
# it by name, so it has to stay a shared module and be shipped beside the binary.
if [[ "$glslang" == ON ]]; then
    while IFS= read -r f; do
        case "$f" in
            *.dylib|*.so|*.so.*|*.dll) cp "$f" "$out/" ;;
        esac
    done < <(find "$build" -name '*slang-glslang*')
fi

# ---------------------------------------------------------------------------
# Check it
# ---------------------------------------------------------------------------
#
# A merged archive that is missing a symbol fails in the consumer's link with a
# message about three.c3, which is the worst place to find out. `spCreateSession`
# is the entry point src/slang.c3 opens with; if it is not here, nothing is.
# awk rather than grep, for the reason above. It reads to EOF rather than
# exiting on the first hit: `exit` closes the pipe, nm takes SIGPIPE, and
# pipefail turns that into a 141 that kills the script — intermittently,
# depending on whether nm had finished writing.
#
# **dumpbin /LINKERMEMBER on Windows, not nm.** That switch prints the archive's
# own symbol table — the index a linker reads — so it answers in a moment. The
# obvious alternative, `dumpbin /SYMBOLS`, walks every object in a 40 MB library
# and takes minutes to say the same thing.
found=""
if [[ $windows -eq 1 ]]; then
    if command -v dumpbin >/dev/null 2>&1; then
        found=$(dumpbin /NOLOGO /LINKERMEMBER:1 "$out/$archive_name" 2>/dev/null \
            | awk '/spCreateSession/ { f = 1 } END { if (f) print "yes" }')
    elif command -v llvm-nm >/dev/null 2>&1; then
        found=$(llvm-nm "$out/$archive_name" 2>/dev/null \
            | awk '/ T _?spCreateSession$/ { f = 1 } END { if (f) print "yes" }')
    else
        found=skipped
    fi
else
    found=$(nm -g "$out/$archive_name" 2>/dev/null | awk '/ T _?spCreateSession$/ { f = 1 } END { if (f) print "yes" }')
fi

if [[ "$found" == skipped ]]; then
    echo "build-slang: no dumpbin or llvm-nm — the archive was not checked for spCreateSession." >&2
elif [[ "$found" != yes ]]; then
    echo "build-slang: WARNING — spCreateSession is not defined in the merged archive." >&2
    echo "  The build may have produced a shared library instead. Check SLANG_LIB_TYPE." >&2
fi

size=$(du -h "$out/$archive_name" | cut -f1)
echo "build-slang: wrote $out/$archive_name ($size)"
if [[ "$glslang" == OFF ]]; then
    cat <<'EOF'

  This archive has no spirv-opt. A consumer MUST pass -O0 to Slang, or every
  compile fails with "failed to load downstream compiler 'spirv-opt'".
  In three.c3 that is SLANG_ARGUMENTS in src/shader/compile.c3.
EOF
fi

echo "build-slang: the CMake tree is kept at $build — a re-run is incremental."
