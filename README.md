# slang.c3

[Slang](https://github.com/shader-slang/slang) as a C3 library — compile shaders
at runtime from a string, get a diagnostic back when they do not compile, and
walk the reflection into a descriptor set layout.

## Setup — once per checkout

```sh
./native/stage-slang.sh          # finds $SLANG_SDK, or slangc on PATH
```

The libraries are **not vendored and not in git**: libslang alone is 27 MB, and
committing it would put that in this repository's history permanently — every
SDK bump adding another copy that no later commit can take out. The script
symlinks the two this binding needs into `lib/<target>/` instead.

**Forgetting it does not always fail at the linker.** On a clean machine it does,
with `library not found for -lslang`. On a machine that has a Slang installed
somewhere the linker searches by default — `/usr/local/lib`, say, from an
installer package — `-lslang` finds *that* one instead, links happily, and the
build dies at startup in dyld:

    Library not loaded: @rpath/libslang-compiler.0.2026.8.dylib

naming a version you never asked for. That is measured, on the machine this was
written on. If you see a Slang version you do not recognise in a load error, this
is why: run the script, and the staged SDK takes precedence over the system one.

Only the release archive is needed — no build and nothing installed system wide.
Unpack it anywhere and point `SLANG_SDK` at it:
<https://github.com/shader-slang/slang/releases>

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

Two libraries, 35 MB, measured rather than guessed:

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

`project.json` is the standalone build; `manifest.json` is what consumers read.
They must be kept in step, and they differ in two structural ways — a
`project.json` cannot key settings by platform, and the rpath differs because a
test binary here sits in `./build` while a consumer's sits beside its own
`lib/`. Both are commented where they are.

## Licence

The binding is MIT (`LICENSE`). No Slang code is redistributed here — the
libraries come from an SDK you install — and Slang itself is Apache-2.0 WITH
LLVM-exception.
