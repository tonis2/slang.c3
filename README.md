# slang.c3

[Slang](https://github.com/shader-slang/slang) as a C3 library — compile shaders
at runtime from a string, get a diagnostic back when they do not compile, and
walk the reflection into a descriptor set layout.

## Setup — once per checkout

```sh
./native/fetch-static.sh
c3c build
```

That is the whole requirement. It downloads one file — `lib/<target>/libslang.a`
— and you are building. No Slang SDK on the machine, no C++ toolchain, no
network beyond that fetch.

**Slang is linked into your binary, and that is the only mode this binding
has.** There are no shared libraries beside the executable, no rpath to get
wrong, and nothing to copy when you move the binary. Two things follow from
that and neither is optional:

- **Every compile must pass `-O0`.** See [The compile flag](#the-compile-flag).
- **Your link line needs the C++ runtime.** `manifest.json` already passes it
  for the five known targets; see [The link flag](#the-link-flag).

**Forgetting the fetch fails at the linker**, with `library not found for
-lslang`. That is worth stating because it did not always used to be true: an
earlier version of this binding staged the SDK's dylibs, and on a machine with
another Slang installed somewhere the linker searches by default — `/usr/local/lib`,
from an installer — `-lslang` would find *that* one, link happily, and the build
would die at startup in dyld naming a version nobody asked for. Static linking
removes that failure mode outright: an archive in `linklib-dir` is either there
or it is not.

If you are upgrading from that version, `fetch-static.sh` deletes the leftover
dylibs and says so. It has to, for the reason above in reverse — `-lslang`
prefers a shared library to an archive.

### Where the archives come from

They are not on `main` and not in a plain checkout. They are **GitHub release
assets**, on the rolling `static` tag: ~43 MB per target, rebuilt on every Slang
bump, so `main` would keep every version of every target for ever.

They used to live on a `static` orphan *branch*, and that was the wrong shape for
a reason worth recording. A branch keeps a binary out of a checkout but not out
of the object database — `git clone` fetches every `refs/heads/*`
unconditionally, and there is no way to mark a branch "do not clone me". So every
clone of this repository, and of every project using it as a submodule, paid for
all of them regardless. A release asset is not reachable from any ref: a clone
costs nothing and `fetch-static.sh` pulls only the one archive the fetching
machine can actually link.

| asset | |
|---|---|
| `libslang-macos-aarch64.a` | 42.8 MB |
| `VERSION-macos-aarch64` | slang version, size, sha256, and how it was built |
| `SHA256SUMS` | one line per published asset — what `fetch-static.sh` verifies against |

The tag is rolling, so it alone promises nothing; `SHA256SUMS` is the pin, and a
mismatch fails the fetch by name rather than surfacing as an unresolved symbol in
a consumer's link.

> **Only `macos-aarch64` is published, and only it has been built and run.** The
> Linux path should work as written but nobody has published an archive yet.
> The Windows path in `build-slang.sh` — MSVC, `lib.exe` through a response
> file — is written from the tools' documented behaviour and has never been
> executed.

Building one yourself, if your platform is not there yet:

```sh
./native/build-slang.sh          # 15-40 min; the CMake tree is kept for re-runs
./native/publish-static.sh       # upload it to the `static` release
```

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

### Why a source build, and why the merge

**Slang's releases ship no static library.** Every asset under
<https://github.com/shader-slang/slang/releases> carries `.dylib`/`.so`/`.dll`
and an import `.lib`, and nothing else. So `build-slang.sh` configures Slang
with `SLANG_LIB_TYPE=STATIC` and builds it — 15-40 minutes — rather than
unpacking somebody's release.

Then it merges every archive the build produced into one, and *that* is the
point of the script rather than an optimisation. A static build emits the
compiler plus every internal target it links privately — `core`,
`compiler-core`, `slang-capability-*`, `slang-lookup-tables`, and vendored
miniz, lz4 and SPIRV-Tools. Slang's own CMakeLists says a link line naming only
`-lslang-compiler` "omits every transitive internal archive ... causing
unresolved-symbol errors at link time", and c3c cannot express the alternative:
`linked-libraries` is a list of `-l` names in no guaranteed order with no
`--start-group`. One archive means one `-l`, and the manifest entry stays the
single word it already is.

`publish-static.sh` merges into whatever `SHA256SUMS` is already published, so
uploading one target never drops another's line. That merge is a
read-modify-write on one file, so two machines publishing at the same instant can
lose one of them; publishes are rare and manual, and the fix is to re-run the
losing one.

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

**Why glslang cannot simply be linked in too:** Slang does not link
slang-glslang, it `dlopen`s it by name at runtime. `otool -L
libslang-compiler.dylib` lists only libc++ and libSystem. So there is no build
of this that both keeps spirv-opt and stays one file — which is why there is no
flag for it.

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

**Your link line needs the C++ runtime.** Slang is C++. A shared library records
libc++ as its own dependency and you never see it; an archive does not.
`manifest.json` handles this for every target it knows: `-lc++` on macOS,
`-lstdc++` on Linux. On Linux consider `-static-libstdc++` instead, or the
binary picks up a version dependency on the build machine's libstdc++.

**Windows names it `slang.lib`, not `libslang.a`** — c3c reads a static library
as `<name>.lib` there, with no `lib` prefix. That is also what Slang's own SDK
calls its *import* library, so on Windows the file name does not tell you which
of the two you are holding. `build-slang.sh` checks for `spCreateSession` at the
end, which does.

**macOS wants `"macos-min-version": "26.0"`** in your `project.json`. The archive
is built with `CMAKE_OSX_DEPLOYMENT_TARGET=26.0`, and an object built for a
newer target than the binary linking it makes `ld` warn on every build — which
is how a real warning gets missed. It cannot be set in `manifest.json`: c3c
rejects `macos-min-version` there by name.

## Using it

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

One archive, and nothing beside your binary.

| | size | |
|---|---|---|
| `libslang.a` | 42.8 MB | the compiler, every internal archive it needs, merged |

Roughly 31 MB of that survives into a stripped release binary, measured on
three.c3: 30.8 MB total, of which the engine is a couple of MB.

Not built, and not wanted: `slang-llvm` is 102 MB and is for CPU and
host-callable codegen, not SPIR-V; `slang-rt`, `gfx`, `slangd`, `slangi`, the
replayer and DXIL are all off. `libslang-glslang` is the interesting omission —
see [The compile flag](#the-compile-flag) for what it costs and why keeping it
is not on offer.

**This is editor weight, not shipping weight.** ~31 MB of compiler inside a
binary is the right trade for an application whose whole point is compiling
shaders at runtime, and the wrong one for a game that ships fixed shaders. For
the latter, compile ahead of time and link nothing from here.

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

How fast that clock is running is measured rather than feared: the suite was
run against **2026.14.1**, two releases past the pin, and passes 11/11 — the
symbols are all still there, the reflection numbers are unchanged, and the
row-major default still holds.

Checking again on a bump is no longer a thirty-second download, and that is the
one real cost of being static-only: it is
`SLANG_VERSION=<new> ./native/build-slang.sh && c3c test`, so 15-40 minutes of
compiling before the eleven tests run.

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
./native/fetch-static.sh
c3c test        # 11 tests, no GPU, about 0.7 s
```

Every compile in the suite passes `-O0`, for the reason under
[The compile flag](#the-compile-flag).

`project.json` is the standalone build; `manifest.json` is what consumers read.
They must be kept in step, and they differ in one structural way: a
`project.json` cannot key settings by platform, so it names the host this is
developed on while the manifest covers five targets. Both are commented where
they are.

## Licence

The binding is MIT (`LICENSE`). Slang itself is Apache-2.0 WITH LLVM-exception.

**Note that a static link redistributes it.** No Slang code is in this
repository's `main`, but the archive published on the `static` release is Slang
compiled,
and a binary linking it contains Slang — so the Apache-2.0 attribution
requirements apply to whatever you ship. That was not true of the SDK-staging
arrangement this replaced, where the libraries came from an SDK the user
installed.
