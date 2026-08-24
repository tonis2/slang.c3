<*
 Slang, bound through the flat C API it exports alongside its COM one.

 **Nothing here touches a vtable and nothing here refcounts.** Slang's headline
 interface is COM — `IGlobalSession`, `ICompileRequest`, `ISlangBlob` — and
 binding that from C3 would mean laying out vtables by hand and getting
 `AddRef`/`Release` right on every path. The `sp*` family is the same
 functionality as plain exported symbols taking plain pointers, returning plain
 integers, and it is what this file declares.

 Two of those functions are the reason the choice is free rather than merely
 convenient:

 - `spGetCompileRequestCode` hands back a `void const*` and a size. The blob
   variant hands back an `ISlangBlob**` and drags COM in for nothing.
 - `spGetDiagnosticOutput` hands back a `char const*`. That string is the whole
   error-reporting story, and getting it without a blob means it can be copied
   with `zstr.str_view()` and forgotten about.

 **The `sp*` family is formally deprecated.** `slang-deprecated.h` says so at the
 top: kept for source and binary compatibility, and expected to be dropped
 eventually. Every symbol below was checked present in the SDK this was built
 against (2026.12.2, 258 exported `sp*` symbols). The exposure is bounded — if a
 future SDK drops them, this one file is what gets rewritten against the COM
 surface, and everything above it is unaffected.

 **Casing is not consistent across the family and there is no rule to it.**
 `spReflection_GetParameterCount` is capitalised; `spReflection_getEntryPointCount`
 is not. Both are in the same header, five lines apart. A wrong guess is a link
 error rather than anything subtle, but it is a link error naming a symbol that
 looks exactly right.

 ## Lifetimes

 A `Session` is process-scoped and expensive — roughly 55 ms to create here — and
 is meant to be made once and reused. A `Request` is per compile and cheap.

 **Everything a `Request` hands back dies with the request.** The SPIR-V bytes,
 the diagnostic string and every reflection pointer are all interior to it, and
 the address is reused by the next request — verified, not assumed: two
 successive requests returned code at the identical address. Copy anything worth
 keeping out before `Request.free`.
*>
module slang;

import std::collections::list;

// Opaque handles. Every one of these is a pointer Slang owns; this side only
// ever passes them back.
alias Session = void*;
alias Request = void*;
alias Reflection = void*;
alias TypeLayout = void*;
alias VarLayout = void*;
alias Variable = void*;
alias Type = void*;
alias EntryPoint = void*;

// `SlangResult` is an HRESULT-shaped int32: negative is a failure, and zero or
// positive is not. It is *not* a fault code to be compared against a list.
alias Result = int;

macro bool failed(Result result) => result < 0;
macro bool succeeded(Result result) => result >= 0;

// SlangCompileTarget. Only the one this project emits is named.
const int TARGET_SPIRV = 6;

// SlangSourceLanguage.
const int LANG_SLANG = 1;

// SlangStage. The graphics stages plus compute; the ray-tracing and mesh
// stages exist in the enum and have no business in a binding that does not use
// them.
const uint STAGE_NONE = 0;
const uint STAGE_VERTEX = 1;
const uint STAGE_HULL = 2;
const uint STAGE_DOMAIN = 3;
const uint STAGE_GEOMETRY = 4;
const uint STAGE_FRAGMENT = 5;
const uint STAGE_COMPUTE = 6;

<*
 SlangBindingType — what a descriptor range actually is.

 This is the enum that makes a derived descriptor set layout possible, because it
 is the only place Slang distinguishes a `Texture2D` from a `Sampler2D`. The type
 *kind* calls both of them a resource and the parameter *category* calls both of
 them a descriptor-table slot; only the binding type says one is a sampled image
 and the other a combined image sampler.
*>
const uint BINDING_UNKNOWN = 0;
const uint BINDING_SAMPLER = 1;
const uint BINDING_TEXTURE = 2;
const uint BINDING_CONSTANT_BUFFER = 3;
const uint BINDING_PARAMETER_BLOCK = 4;
const uint BINDING_TYPED_BUFFER = 5;
const uint BINDING_RAW_BUFFER = 6;
const uint BINDING_COMBINED_TEXTURE_SAMPLER = 7;
const uint BINDING_INPUT_RENDER_TARGET = 8;
const uint BINDING_INLINE_UNIFORM_DATA = 9;
const uint BINDING_ACCELERATION_STRUCTURE = 10;
const uint BINDING_VARYING_INPUT = 11;
const uint BINDING_VARYING_OUTPUT = 12;
const uint BINDING_EXISTENTIAL_VALUE = 13;
const uint BINDING_PUSH_CONSTANT = 14;
// Set on a range whose resource is writable — RWTexture2D rather than Texture2D.
// The base type is what is left after masking it off.
const uint BINDING_MUTABLE_FLAG = 0x100;
const uint BINDING_BASE_MASK = 0x00FF;

<*
 SlangParameterCategory — which kind of "slot" a parameter consumes.

 Only two of the nineteen matter here, and they matter for opposite reasons:
 `UNIFORM` is the category offsets and sizes inside a constant block are measured
 in, and `PUSH_CONSTANT_BUFFER` is how a push block is told apart from a
 descriptor so it does not end up in the set layout.
*>
const int CATEGORY_NONE = 0;
const int CATEGORY_MIXED = 1;
const int CATEGORY_CONSTANT_BUFFER = 2;
const int CATEGORY_UNIFORM = 8;
const int CATEGORY_DESCRIPTOR_TABLE_SLOT = 9;
const int CATEGORY_PUSH_CONSTANT_BUFFER = 11;
const int CATEGORY_REGISTER_SPACE = 12;

// SlangTypeKind.
const int KIND_NONE = 0;
const int KIND_STRUCT = 1;
const int KIND_ARRAY = 2;
const int KIND_MATRIX = 3;
const int KIND_VECTOR = 4;
const int KIND_SCALAR = 5;
const int KIND_CONSTANT_BUFFER = 6;
const int KIND_RESOURCE = 7;
const int KIND_SAMPLER_STATE = 8;
const int KIND_PARAMETER_BLOCK = 11;
const int KIND_POINTER = 18;

// SlangDebugInfoLevel / SlangOptimizationLevel.
const uint DEBUG_NONE = 0;
const uint DEBUG_MINIMAL = 1;
const uint DEBUG_STANDARD = 2;
const uint DEBUG_MAXIMAL = 3;

const uint OPTIMIZE_NONE = 0;
const uint OPTIMIZE_DEFAULT = 1;
const uint OPTIMIZE_HIGH = 2;
const uint OPTIMIZE_MAXIMAL = 3;

// ============================================================================
// The C surface, declared exactly as it is exported
// ============================================================================

// The compiler's own identity. No arguments and no session — it is a string
// baked into the binary at its build, which is what makes it usable as a cache
// key before anything has been compiled.
extern fn ZString spGetBuildTagString();

// Session and request lifetime.
extern fn Session spCreateSession(ZString unused);
extern fn void spDestroySession(Session session);
extern fn Request spCreateCompileRequest(Session session);
extern fn void spDestroyCompileRequest(Request request);

// Setting a request up.
extern fn Result spProcessCommandLineArguments(Request request, ZString* argv, int argc);
extern fn void spSetCodeGenTarget(Request request, int target);
extern fn void spSetTargetProfile(Request request, int target_index, uint profile);
extern fn uint spFindProfile(Session session, ZString name);
extern fn void spSetDebugInfoLevel(Request request, uint level);
extern fn void spSetOptimizationLevel(Request request, uint level);
extern fn int spAddTranslationUnit(Request request, int language, ZString name);
extern fn void spAddTranslationUnitSourceString(Request request, int unit, ZString path, ZString source);
extern fn int spAddEntryPoint(Request request, int unit, ZString name, uint stage);

// Compiling, and reading the two things a compile produces.
extern fn Result spCompile(Request request);
extern fn ZString spGetDiagnosticOutput(Request request);
extern fn void* spGetCompileRequestCode(Request request, usz* out_size);

// Reflection: the program, its entry points, and its global parameters.
extern fn Reflection spGetReflection(Request request);
extern fn int spReflection_getEntryPointCount(Reflection reflection);
extern fn EntryPoint spReflection_getEntryPointByIndex(Reflection reflection, int index);
extern fn ZString spReflectionEntryPoint_getName(EntryPoint entry);
extern fn uint spReflectionEntryPoint_getStage(EntryPoint entry);
extern fn TypeLayout spReflection_getGlobalParamsTypeLayout(Reflection reflection);
extern fn uint spReflection_GetParameterCount(Reflection reflection);
extern fn VarLayout spReflection_GetParameterByIndex(Reflection reflection, uint index);

// Reflection: descriptor ranges, which is how a set layout gets derived.
extern fn long spReflectionTypeLayout_getBindingRangeCount(TypeLayout layout);
extern fn uint spReflectionTypeLayout_getBindingRangeType(TypeLayout layout, long index);
extern fn long spReflectionTypeLayout_getBindingRangeBindingCount(TypeLayout layout, long index);
extern fn long spReflectionTypeLayout_getBindingRangeDescriptorSetIndex(TypeLayout layout, long index);
extern fn long spReflectionTypeLayout_getBindingRangeFirstDescriptorRangeIndex(TypeLayout layout, long index);
extern fn Variable spReflectionTypeLayout_getBindingRangeLeafVariable(TypeLayout layout, long index);
extern fn long spReflectionTypeLayout_getDescriptorSetCount(TypeLayout layout);
extern fn long spReflectionTypeLayout_getDescriptorSetSpaceOffset(TypeLayout layout, long set);
extern fn long spReflectionTypeLayout_getDescriptorSetDescriptorRangeCount(TypeLayout layout, long set);
extern fn long spReflectionTypeLayout_getDescriptorSetDescriptorRangeIndexOffset(TypeLayout layout, long set, long range);
extern fn long spReflectionTypeLayout_getDescriptorSetDescriptorRangeDescriptorCount(TypeLayout layout, long set, long range);
extern fn uint spReflectionTypeLayout_getDescriptorSetDescriptorRangeType(TypeLayout layout, long set, long range);
extern fn int spReflectionTypeLayout_getDescriptorSetDescriptorRangeCategory(TypeLayout layout, long set, long range);

// Reflection: walking a type's fields, which is how a push block gets derived.
extern fn int spReflectionTypeLayout_getKind(TypeLayout layout);
extern fn usz spReflectionTypeLayout_GetSize(TypeLayout layout, int category);
extern fn uint spReflectionTypeLayout_GetFieldCount(TypeLayout layout);
extern fn VarLayout spReflectionTypeLayout_GetFieldByIndex(TypeLayout layout, uint index);
extern fn TypeLayout spReflectionTypeLayout_GetElementTypeLayout(TypeLayout layout);
extern fn Type spReflectionTypeLayout_GetType(TypeLayout layout);
extern fn ZString spReflectionType_GetName(Type type);
extern fn Variable spReflectionVariableLayout_GetVariable(VarLayout layout);
extern fn TypeLayout spReflectionVariableLayout_GetTypeLayout(VarLayout layout);
extern fn usz spReflectionVariableLayout_GetOffset(VarLayout layout, int category);
extern fn ZString spReflectionVariable_GetName(Variable variable);

// ============================================================================
// The C3 surface
// ============================================================================

faultdef SESSION_FAILED, REQUEST_FAILED, NO_CODE;

<*
 Which Slang built this — the release tag, as the compiler reports it.

 A build of Slang stamps its own tag in, so this is `v2026.12.2` on a release
 and something like `unknown` or a commit description on a build made from a
 checkout with no tag. Either way it is *stable for a given binary and different
 across an upgrade*, which is the only property a cache key needs from it.

 Free to ask: no session, no request, no allocation, and the pointer is static
 storage inside libslang. That is the difference between this and hashing the
 dylib, which costs 35 MB of reading to learn the same thing.

 @return `A view of libslang's own static storage. Valid for the life of the process; never freed.`
*>
fn String build_tag()
{
	ZString tag = spGetBuildTagString();
	return tag == null ? "" : tag.str_view();
}

<*
 Start a Slang session. One per process is the intended shape.

 @return? SESSION_FAILED : `Slang declined to start. There is no diagnostic for this — there is no request to ask yet — so the usual cause is that libslang could not find the downstream compiler it needs.`
*>
fn Session? session()
{
	Session handle = spCreateSession(null);
	if (handle == null) return SESSION_FAILED~;
	return handle;
}

<*
 A description of one compile: the source, what to call it, and its entry points.

 `name` is what appears in diagnostics. It is not a path and is never opened —
 `spAddTranslationUnitSourceString` takes the source itself — so it can be
 whatever will read best in an error message.
*>
struct Job
{
	String name;
	String source;
	Entry[] entries;
	// Passed to `spProcessCommandLineArguments` verbatim. Empty is legal and
	// means Slang's defaults, which for SPIR-V is not what this project wants.
	String[] arguments;
}

struct Entry
{
	String name;
	uint stage;
}

<*
 What one compile produced. Every field points into the request and dies with it.

 A compile that failed still has a diagnostic, and a compile that succeeded may
 have one too — that is where warnings arrive.
*>
struct Compiled
{
	bool ok;
	char[] spirv;
	String diagnostic;
	Reflection reflection;
	Request request;
}

<*
 Compile one job.

 The request is left open and returned inside `Compiled`, because the bytes and
 every reflection pointer are interior to it. **The caller must call
 `Compiled.free` exactly once**, after copying out whatever it means to keep.

 Failure to compile is not a fault here: a shader that does not compile is the
 ordinary case this whole binding exists to report on, and the diagnostic is the
 answer. A fault would throw away the one thing worth returning.

 @return? REQUEST_FAILED : `Slang would not create a compile request. Not a shader error.`
*>
fn Compiled? Session.compile(self, Job job)
{
	Request request = spCreateCompileRequest(self);
	if (request == null) return REQUEST_FAILED~;

	// tmem, because everything here is consumed inside the call: Slang copies
	// the source and the names into the request.
	@pool()
	{
		if (job.arguments.len > 0)
		{
			ZString[] argv = alloc::new_array(tmem, ZString, job.arguments.len);
			foreach (i, argument : job.arguments) argv[i] = argument.zstr_tcopy();
			spProcessCommandLineArguments(request, argv.ptr, (int)argv.len);
		}

		int unit = spAddTranslationUnit(request, LANG_SLANG, job.name.zstr_tcopy());
		spAddTranslationUnitSourceString(request, unit, job.name.zstr_tcopy(), job.source.zstr_tcopy());

		// **Named rather than discovered.** A `[shader("vertex")]` attribute
		// would let Slang find the entry points on its own, and then a shader
		// that spells `vertexMain` differently compiles happily and produces a
		// module the pipeline cannot use. Naming them means that is an error
		// with a sentence attached.
		foreach (entry : job.entries)
		{
			spAddEntryPoint(request, unit, entry.name.zstr_tcopy(), entry.stage);
		}
	};

	Result result = spCompile(request);

	Compiled out = { .request = request, .ok = succeeded(result) };

	ZString diagnostic = spGetDiagnosticOutput(request);
	out.diagnostic = diagnostic == null ? "" : diagnostic.str_view();

	if (out.ok)
	{
		usz size = 0;
		void* code = spGetCompileRequestCode(request, &size);
		// **The whole program, not one entry point.** `spGetEntryPointCode`
		// answers with zero bytes under `-emit-spirv-directly`, because the
		// emitted module holds every entry point together and there is no
		// per-entry-point artifact to hand back. It returns no error either —
		// just a null pointer and a length of nothing.
		if (code != null && size > 0) out.spirv = ((char*)code)[:size];
		out.reflection = spGetReflection(request);
	}

	return out;
}

<*
 Release the request, and with it the bytes, the diagnostic and the reflection.
*>
fn void Compiled.free(&self)
{
	if (self.request != null) spDestroyCompileRequest(self.request);
	*self = {};
}

fn void Session.free(self)
{
	if (self != null) spDestroySession(self);
}

// ============================================================================
// Reflection, in the shapes a caller actually wants
// ============================================================================

<*
 One descriptor range: what it is, where it binds, and how many of it there are.

 `name` points into the reflection and dies with the request.
*>
struct Descriptor
{
	String name;
	uint set;
	uint binding;
	uint count;
	uint type; // BINDING_*
}

<*
 One field of a uniform or push-constant block.
*>
struct Field
{
	String name;
	uint offset;
	uint size;
}

<*
 Every descriptor the program declares, in binding-range order.

 **Push-constant ranges are skipped**, because a push block is not a descriptor
 and putting it in a set layout is a validation error. It is told apart by its
 parameter category rather than by its name or its type: a push block reflects as
 a constant buffer whose category is `PUSH_CONSTANT_BUFFER`, which is the only
 signal that survives being given a different name in a different shader.

 @param [&inout] out : `Appended to, not cleared.`
*>
fn void Reflection.descriptors(self, List{Descriptor}* out)
{
	TypeLayout global = spReflection_getGlobalParamsTypeLayout(self);
	if (global == null) return;

	long ranges = spReflectionTypeLayout_getBindingRangeCount(global);
	for (long i = 0; i < ranges; i++)
	{
		uint kind = spReflectionTypeLayout_getBindingRangeType(global, i);
		if ((kind & BINDING_BASE_MASK) == BINDING_PUSH_CONSTANT) continue;

		long set = spReflectionTypeLayout_getBindingRangeDescriptorSetIndex(global, i);
		long first = spReflectionTypeLayout_getBindingRangeFirstDescriptorRangeIndex(global, i);
		if (set < 0 || first < 0) continue;

		// The binding *index* is not the range index: it comes from the
		// descriptor-set view, which is the one that knows about `[vk::binding]`.
		long binding = spReflectionTypeLayout_getDescriptorSetDescriptorRangeIndexOffset(global, set, first);
		long count = spReflectionTypeLayout_getDescriptorSetDescriptorRangeDescriptorCount(global, set, first);
		long space = spReflectionTypeLayout_getDescriptorSetSpaceOffset(global, set);

		Variable leaf = spReflectionTypeLayout_getBindingRangeLeafVariable(global, i);
		ZString name = leaf == null ? null : spReflectionVariable_GetName(leaf);

		out.push({
			.name = name == null ? "" : name.str_view(),
			.set = (uint)space,
			.binding = (uint)binding,
			.count = count < 1 ? 1 : (uint)count,
			.type = kind,
		});
	}
}

<*
 The program's push-constant block, if it has one: its size and its fields.

 @param [&inout] fields : `Appended to, not cleared. Empty if there is no push block.`
 @return `The block's size in bytes, or zero if there is none.`
*>
fn uint Reflection.push_block(self, List{Field}* fields)
{
	uint count = spReflection_GetParameterCount(self);
	for (uint i = 0; i < count; i++)
	{
		VarLayout parameter = spReflection_GetParameterByIndex(self, i);
		TypeLayout layout = spReflectionVariableLayout_GetTypeLayout(parameter);
		if (layout == null) continue;

		// A push block reflects as a constant buffer *around* the struct, so the
		// fields are one level down. Asking the outer layout for its size in the
		// uniform category answers zero — it consumes a push-constant slot, not
		// uniform bytes — which is why the element layout is what gets measured.
		if (spReflectionTypeLayout_getKind(layout) != KIND_CONSTANT_BUFFER) continue;

		TypeLayout element = spReflectionTypeLayout_GetElementTypeLayout(layout);
		if (element == null) continue;

		usz size = spReflectionTypeLayout_GetSize(element, CATEGORY_UNIFORM);
		if (size == 0) continue;

		// Distinguishes the push block from an ordinary ConstantBuffer<T>, which
		// is a descriptor and has no business here.
		bool is_push = false;
		TypeLayout global = spReflection_getGlobalParamsTypeLayout(self);
		if (global != null)
		{
			long ranges = spReflectionTypeLayout_getBindingRangeCount(global);
			for (long r = 0; r < ranges; r++)
			{
				if ((spReflectionTypeLayout_getBindingRangeType(global, r) & BINDING_BASE_MASK) != BINDING_PUSH_CONSTANT) continue;
				Variable leaf = spReflectionTypeLayout_getBindingRangeLeafVariable(global, r);
				Variable mine = spReflectionVariableLayout_GetVariable(parameter);
				if (leaf != null && leaf == mine) is_push = true;
			}
		}
		if (!is_push) continue;

		uint field_count = spReflectionTypeLayout_GetFieldCount(element);
		for (uint f = 0; f < field_count; f++)
		{
			VarLayout field = spReflectionTypeLayout_GetFieldByIndex(element, f);
			Variable variable = spReflectionVariableLayout_GetVariable(field);
			ZString name = variable == null ? null : spReflectionVariable_GetName(variable);
			TypeLayout field_layout = spReflectionVariableLayout_GetTypeLayout(field);
			fields.push({
				.name = name == null ? "" : name.str_view(),
				.offset = (uint)spReflectionVariableLayout_GetOffset(field, CATEGORY_UNIFORM),
				.size = (uint)spReflectionTypeLayout_GetSize(field_layout, CATEGORY_UNIFORM),
			});
		}
		return (uint)size;
	}
	return 0;
}

<*
 The entry points the compiled program actually contains, with their stages.

 @param [&inout] out : `Appended to, not cleared.`
*>
fn void Reflection.entry_points(self, List{Entry}* out)
{
	int count = spReflection_getEntryPointCount(self);
	for (int i = 0; i < count; i++)
	{
		EntryPoint entry = spReflection_getEntryPointByIndex(self, i);
		if (entry == null) continue;
		ZString name = spReflectionEntryPoint_getName(entry);
		out.push({
			.name = name == null ? "" : name.str_view(),
			.stage = spReflectionEntryPoint_getStage(entry),
		});
	}
}
