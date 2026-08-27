# slang.c3

[Slang](https://github.com/shader-slang/slang) as a C3 library — compile shaders
at runtime from a string, get a diagnostic back when they do not compile, and
walk the reflection into a descriptor set layout.

## Setup — once per checkout

```sh
./native/stage-slang.sh
```

That is the one to run. There is a second mode — **Slang linked into your binary
as one static archive**, for shipping a single file — described under
[Linking Slang in](#linking-slang-in). It needs no C++ toolchain either, as long
as somebody has published an archive for your platform.

That is the whole requirement, whether or not you have Slang installed. The
script looks for an SDK — `$SLANG_SDK`, then one it fetched earlier, then
`slangc` on `PATH`, then the usual places — and **if it finds none, it downloads
the pinned release**, verifies its SHA-256, prunes it to the two libraries this
binding needs, and uses that. Either way it ends with symlinks in
`lib/<target>/` and a build that works.

```sh
./native/stage-slang.sh --fetch      # ignore what is installed; use the pinned release
./native/stage-slang.sh --no-fetch   # fail rather than reach the network
```

The libraries are **not vendored and not in git**: libslang alone is 27 MB, and
committing it would put that in this repository's history permanently — every
SDK bump adding another copy that no later commit can take out. The script
symlinks them into `lib/<target>/` instead.

To use a Slang of your own rather than the pinned one, unpack a release archive
anywhere and point `SLANG_SDK` at it — no build, nothing installed system wide.
Releases: <https://github.com/shader-slang/slang/releases>

**Forgetting the script does not always fail at the linker**, which is the part
worth knowing. On a clean machine it does, with `library not found for -lslang`.
On a machine that has a Slang installed somewhere the linker searches by default
— `/usr/local/lib`, say, from an installer package — `-lslang` finds *that* one
instead, links happily, and the build dies at startup in dyld:

    Library not loaded: @rpath/libslang-compiler.0.2026.8.dylib

naming a version you never asked for. That is measured, on the machine this was
written on. If you see a Slang version you do not recognise in a load error, this
is why: run the script, and the staged SDK takes precedence over the system one.

### About the fetch

**The version is the whole configuration.** `SLANG_VERSION` in the script names a
release tag — `2026.12.2` is
<https://github.com/shader-slang/slang/releases/tag/v2026.12.2> — and the asset,
the URL and the cache key all come from it. Bumping is that one line. Trying one
without editing anything:

```sh
SLANG_VERSION=2026.14.1 ./native/stage-slang.sh --fetch
```

It is **pinned rather than "latest"** so that two machines running this a month
apart get the same compiler; a shader that compiles here and not there is the
failure this exists to prevent.

#### Checksums are optional, and that is a real trade

A version listed in `sha_for` is verified and a mismatch **refuses and installs
nothing**, printing both hashes. A version that is not listed still works — it
prints the hash it got and the line to paste in if you want to lock it down.

So a bump stays one line, and what you are trusting is stated rather than
implied: with a recorded hash, a release asset swapped under an existing tag is
caught; without one, it is not. GitHub permits that swap, which is why the option
exists at all. Slang publishes no checksum file, so the hashes here are this
repository's own, taken from the archives as downloaded.

The `macos-aarch64` archive was additionally cross-checked against a separately
installed SDK: the two libraries inside it hash identically to the installed
ones, so the fetched path and the installed path produce the same build rather
than merely similar ones.

#### Where it goes, and how big it is

The download is cached **per machine, not per checkout** —
`~/.cache/slang.c3/<version>/<target>/`, or `$SLANG_C3_CACHE`, or
`$XDG_CACHE_HOME`. A second checkout finds it and stages in a third of a second
with no network at all. Where none of those is writable, which happens in build
containers, it falls back to `.slang-sdk/` inside the checkout.

| download, per machine | |
|---|---|
| macOS arm64 | 54 MB |
| macOS x64 | 20 MB |
| Linux x64 | 22 MB |
| Linux arm64 | 20 MB |

Linux x64 takes the `glibc-2.28` asset deliberately: 22 MB against the plain
build's 73 MB, the same two libraries, and built against an older glibc so it
runs on *more* systems rather than fewer. The difference is `libslang-llvm`,
which gets deleted either way. On arm64 the plain build is already the smaller
one, so each platform takes whichever wins.

Unpacked it is as much as 169 MB, most of that `libslang-llvm` and
documentation; what is kept is about 36 MB — the compiler, `spirv-opt` and the
`slangc` driver, which still runs afterwards. Deleting the cache directory costs
one re-download and nothing else.

```json
"dependencies": ["slang"]
```

```c3
import slang;

slang::Session session = slang::session()!;     // ~55 ms; make one, keep it
defer session.free();

slang::Entry[2] entries = {
    { "vertexMain", slang::STAGE_VERTEX },
    { "fragmentMain", slang::STAGE_FRAGMENT },
};
String[*] flags = {
    "-target", "spirv",
    "-emit-spirv-directly",
    "-force-glsl-scalar-layout",
    "-matrix-layout-column-major",
};

slang::Compiled result = session.compile({
    .name = "mesh.slang",       // what diagnostics call it; never opened
    .source = source,
    .entries = entries[..],
    .arguments = flags[..],
})!;
defer result.free();

if (!result.ok) io::printn(result.diagnostic);  // with line and column
```

A failed compile is **not** an error return. It is `ok: false` with the
diagnostic attached, because a shader that does not compile is the ordinary
answer this binding exists to give — a fault would throw away the one thing
worth returning.

**Everything a compile hands back dies with it.** The SPIR-V bytes, the
diagnostic and every reflection pointer are interior to the request, and the
next request reuses the address. Copy out what you mean to keep before
`Compiled.free`.

## Reflection

Three calls, which between them are enough to build a pipeline layout without
declaring one:

```c3
List{slang::Descriptor} bindings;   // set, binding, count, type
List{slang::Field} fields;          // name, offset, size
List{slang::Entry} entries;         // name, stage

result.reflection.descriptors(&bindings);
uint push_size = result.reflection.push_block(&fields);
result.reflection.entry_points(&entries);
```

`Descriptor.type` is a `BINDING_*` value, and that is the point of it: a
`Sampler2D` and a `Texture2D` are indistinguishable at Slang's other two levels
of reflection — same type kind, same parameter category — and only the binding
range type says one is a combined image sampler and the other a sampled image.
Getting that wrong is a black screen, not an error.

`descriptors` skips push-constant ranges, because a push block is not a
descriptor and putting one in a set layout is a validation error naming a
binding the shader never declared. It is told apart by its parameter category
rather than its name, so it works whatever the shader calls it.

## What is linked, and what is not

This is the default — `stage-slang.sh`, shared libraries beside the binary. The
static alternative is the [next section](#linking-slang-in).

Two libraries, 35 MB

| library | size | why |
|---|---|---|
| `libslang-compiler` | 27 MB | the compiler |
| `libslang-glslang` | 8 MB | `spirv-opt`, which Slang loads as a downstream tool on the SPIR-V path |

`libslang-llvm` is 102 MB and is **not** needed — it is for CPU and host codegen
targets. `libslang-rt`, `libgfx` and the GLSL module are not needed either.

Omitting `libslang-glslang` is the one that surprises: every compile then fails
with `failed to load downstream compiler 'spirv-opt'`, which reads like a
missing binary rather than a missing dylib.

Nothing records the SDK's path. The symlinks are gitignored, the manifest names
only `slang`, and the two rpaths in it are *relative* — one for a binary in
`build/` inside a checkout, one for the dylibs copied beside a shipped binary. A
different machine re-runs the script and gets a working build without editing
anything.

**This is editor weight, not shipping weight.** 35 MB of compiler beside a
binary is the right trade for an application whose whole point is compiling
shaders at runtime, and the wrong one for a game that ships fixed shaders. For
the latter, compile ahead of time and link nothing from here.

If you want the compiler at runtime *and* a single file to hand somebody, that
is what the next section is for.

## Linking Slang in

Everything above puts Slang beside your binary. This puts it inside:

```sh
./native/fetch-static.sh     # download a prebuilt archive for this platform
c3c build
```

You get one executable with no Slang libraries next to it and no rpath to get
wrong. Two things do have to change on your side — a compile flag and a link
flag — and they are the two subsections below.

> **Only `macos-aarch64` has been built and run this way.** The Linux path
> should work as written but nobody has published an archive yet. The Windows
> path in `build-slang.sh` — MSVC, `lib.exe` through a response file — is
> written from the tools' documented behaviour and has never been executed.

`fetch-static.sh` and `stage-slang.sh` are alternatives, not a sequence. Both
write to `lib/<target>/`, `-lslang` prefers a shared library to an archive when
both are present, and each script deletes what the other left. Whichever ran
last is what the next build links.

### The compile flag

**Pass `-O0` to every compile.** The archives are built without
`libslang-glslang`, and that is where `spirv-opt` lives. Slang runs spirv-opt at
its *default* optimization level — `-O1`, per `slangc -h optimization-level`:
"This is the default if no -O options are used" — so a compile that never
mentions optimization still needs it, and fails without it:

```
error[E00100]: failed to load downstream compiler 'spirv-opt'
note[E99996]: failed to load dynamic library 'slang-glslang-2026.12.2'
```

`-emit-spirv-directly` does not change this. It selects the codegen path; the
optimizer runs after codegen either way.

**Why it cannot simply be linked in too:** Slang does not link slang-glslang, it
`dlopen`s it by name at runtime. `otool -L libslang-compiler.dylib` lists only
libc++ and libSystem. So a build that keeps glslang has two files to ship
however slang itself is linked, and the single-file goal is gone.

**What `-O0` costs**, measured on a real project's shaders with Slang 2026.12.2:

| shader | `-O0` | `-O1` |
|---|---|---|
| vertex + fragment, ~800 lines | 28700 B | 28728 B |
| vertex only, depth pass | 11776 B | 10320 B |

spirv-opt makes the larger module 28 bytes *bigger* and the smaller one 12%
smaller. Module size is not runtime speed — but every Vulkan driver runs its own
optimizer over SPIR-V before it reaches the GPU, and Slang's direct emitter is
plainly not leaning on spirv-opt for much.

### The link flag

**Your link line needs the C++ runtime.** A shared library records libc++ as its
own dependency and you never see it; an archive does not. `manifest.json` passes
`-lc++` on macOS. On Linux add `-lstdc++` (and consider `-static-libstdc++`, or
the binary picks up a dependency on the build machine's libstdc++ version).

**Windows names it `slang.lib`, not `libslang.a`** — c3c reads a static library
as `<name>.lib` there, with no `lib` prefix. That is also the name
`stage-slang.sh` gives Slang's *import* library, so the two collide by design and
whichever script ran last wins.

### Where the archives come from

They are not on `main` and not in a plain checkout. They live on a **`static`
orphan branch**, one force-pushed commit however many Slang bumps it has seen:
~43 MB per target, rebuilt on every bump, so `main` would keep every version of
every target for ever. It is cheaper than it sounds — git stores blobs
compressed and this is object code, so 43 MB on disk is about 15 MB in the pack.

| | |
|---|---|
| `macos-aarch64/libslang.a` | 42.8 MB |
| `macos-aarch64/VERSION` | what it was built from |

Building one yourself, if your platform is not there yet:

```sh
./native/build-slang.sh          # 15-40 min; the CMake tree is kept for re-runs
./native/publish-static.sh       # push it to the `static` branch
```

`build-slang.sh` configures Slang with `SLANG_LIB_TYPE=STATIC` and merges every
archive the build produces into one. That merge is the point of the script, not
an optimisation: a static build emits the compiler plus every internal target it
links privately — `core`, `compiler-core`, `slang-capability-*`,
`slang-lookup-tables`, and vendored miniz, lz4 and SPIRV-Tools. Slang's own
CMakeLists says a link line naming only `-lslang-compiler` "omits every
transitive internal archive ... causing unresolved-symbol errors at link time",
and c3c cannot express the alternative — `linked-libraries` is a list of `-l`
names in no guaranteed order with no `--start-group`. One archive means one
`-l`.

`publish-static.sh` starts from whatever is already on the branch, so publishing
one target never deletes another, and it assembles its commit in a temporary
index rather than checking out — this repository's tree is normally dirty, since
`lib/<target>/` is where the archive being published lives.

### Host target only

**A `windows-x64` archive is built on Windows, `linux-x64` on Linux,
`macos-aarch64` on Apple silicon.** Not a limitation of these scripts — three
things stack:

- CMake compiles tools during Slang's build and then *runs* them. Cross-building
  means building those for the host first and pointing a second configure at
  them through `SLANG_GENERATORS_PATH`. Supported, but a two-stage build.
- Slang's CMakeLists knows `WIN32` and `MSVC` and has **no `MINGW` branch**, so
  the usual cross-to-Windows compiler is not a configuration it supports.
- Off Windows there is no MSVC-ABI C++ compiler without a separate SDK
  extraction step.

Which is exactly why the branch is keyed by target and each machine publishes
its own.

## Why the deprecated C API

Slang's headline interface is COM — `IGlobalSession`, `ICompileRequest`,
`ISlangBlob` — and binding that from C3 would mean laying out vtables by hand
and getting `AddRef`/`Release` right on every path. The `sp*` family is the same
functionality as plain exported symbols taking plain pointers and returning
plain integers, and **nothing in it passes a struct by value**, so `extern fn`
declarations reach it directly. There is no shim here at all.

It is formally deprecated: `slang-deprecated.h` says it is kept for source and
binary compatibility and will be dropped over time. All 258 symbols are exported
by the SDK this was built against, and the seventeen used here were each checked
present. The exposure is bounded to one file — if a future SDK drops them,
`src/slang.c3` is what gets rewritten against the COM surface.

How fast that clock is running is now measured rather than feared: the suite was
run against **2026.14.1**, two releases past the pin, and passes 11/11 — the
symbols are all still there, the reflection numbers are unchanged, and the
row-major default still holds. Checking again on a bump costs
`SLANG_VERSION=<new> ./native/stage-slang.sh --fetch && c3c test`.

## Two things that cost a day between them

**`spGetEntryPointCode` does not work under `-emit-spirv-directly`.** It returns
a null pointer and a length of zero, with no error, because the emitted module
holds every entry point together and there is no per-entry-point artifact to
hand back. `spGetCompileRequestCode` — the whole program — is what there is, and
is what this binding calls.

**`slangc` and this API have different defaults under the same flags.** The CLI
is column-major; the compile-request API is row-major. Passing a documented
`slangc` command line verbatim produces a different module with every transform
transposed, and nothing reports anything at any layer — the picture renders, and
it renders wrong. Pass `-matrix-layout-column-major` explicitly.
`the_api_does_not_default_to_slangcs_matrix_layout` in `test/` pins this down by
compiling three ways and comparing bytes, so an SDK that changes it says so.

## Developing the binding

```sh
./native/stage-slang.sh
c3c test        # 11 tests, no GPU, about 0.7 s
```

The suite passes against a static archive too — `./native/fetch-static.sh`
instead of the first line — but every compile in it then needs `-O0`, for the
reason under [Linking Slang in](#linking-slang-in).

`project.json` is the standalone build; `manifest.json` is what consumers read.
They must be kept in step, and they differ in two structural ways — a
`project.json` cannot key settings by platform, and the rpath differs because a
test binary here sits in `./build` while a consumer's sits beside its own
`lib/`. Both are commented where they are.

## Licence

The binding is MIT (`LICENSE`). No Slang code is redistributed here — the
libraries come from an SDK you install — and Slang itself is Apache-2.0 WITH
LLVM-exception.
