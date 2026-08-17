<*
 That Slang starts, compiles, fails usefully, and describes what it compiled.

	c3c test

 These are about the *binding*, not about Slang — the compiler has its own test
 suite and nothing here is going to improve on it. What is worth checking is the
 boundary: that the flat `sp*` surface is declared with the right signatures,
 that a shader which does not compile arrives as a readable diagnostic rather
 than as a crash or an empty success, and that the reflection walk answers with
 the numbers a descriptor set layout is built from.

 **The reflection tests are the ones that earn their keep.** A wrong descriptor
 type is not a compile error and not a crash; it is a validation message in
 somebody else's application, or a black screen with nothing said at all. The
 rich fixture below has one binding of every kind this binding translates,
 including the two — `Sampler2D` and `Texture2D` — that are indistinguishable at
 two of Slang's three levels of reflection.

 No GPU is involved anywhere here.
*>
module slang_tests;

import slang;

import std::collections::list;
import std::core::test;

<*
 What this binding was built to emit. Passed verbatim to
 `spProcessCommandLineArguments`.

 `-matrix-layout-column-major` is not decoration: `slangc` defaults to it and
 the compile-request API does not. See `the_api_does_not_default_to_slangcs_matrix_layout`.
*>
const String[*] FLAGS = {
	"-target", "spirv",
	"-emit-spirv-directly",
	"-force-glsl-scalar-layout",
	"-matrix-layout-column-major",
};

// The same, with the matrix layout said the other way and not said at all, for
// the test that pins down which one the API defaults to.
const String[*] FLAGS_ROW_MAJOR = {
	"-target", "spirv",
	"-emit-spirv-directly",
	"-force-glsl-scalar-layout",
	"-matrix-layout-row-major",
};

const String[*] FLAGS_UNSAID = {
	"-target", "spirv",
	"-emit-spirv-directly",
	"-force-glsl-scalar-layout",
};

<*
 A shader with one binding of every kind this binding can describe, in two sets.

 Six parameters rather than one, because a reflection walk that only ever looked
 at binding range zero would pass every check against a simpler shader. The
 array, the separate sampler and the push block are each here to catch a
 different way of being quietly wrong.
*>
const String RICH_SOURCE = `
struct Params { float4 tint; float time; };
[vk::binding(0, 0)] ConstantBuffer<Params> params;
[vk::binding(1, 0)] Sampler2D albedo;
[vk::binding(2, 0)] Texture2D extras[4];
[vk::binding(3, 0)] SamplerState linearSampler;
[vk::binding(0, 1)] StructuredBuffer<float4> points;

struct PushBlock { float4x4 mvp; uint flags; };
[vk_push_constant] const PushBlock pc;

struct VOut { float2 uv : TEXCOORD0; float4 sv_position : SV_Position; };

[shader("vertex")]
VOut vertexMain(uint vid : SV_VertexID)
{
	VOut o;
	o.sv_position = mul(pc.mvp, points[vid]);
	o.uv = float2(0, 0);
	return o;
}

[shader("fragment")]
float4 fragmentMain(VOut i) : SV_Target
{
	float3 c = albedo.Sample(i.uv).rgb * params.tint.rgb;
	c += extras[1].Sample(linearSampler, i.uv).rgb * params.time;
	return float4(c, 1.0);
}
`;

// The smallest thing that is still a whole graphics program.
const String MINIMAL_SOURCE = `
struct VOut { float4 sv_position : SV_Position; };

[shader("vertex")]
VOut vertexMain(uint vid : SV_VertexID)
{
	VOut o;
	o.sv_position = float4(float(vid), 0, 0, 1);
	return o;
}

[shader("fragment")]
float4 fragmentMain(VOut i) : SV_Target { return float4(1, 1, 1, 1); }
`;

<*
 A session per test.

 Roughly 55 ms each, which is the cost of not having one test's session leak into
 the next one's answers. A real application makes one and keeps it.
*>
macro @with_session(; @body(slang::Session session))
{
	slang::Session? opened = slang::session();
	if (catch opened)
	{
		test::@check(false, "a session can be created — if this is the only failure, libslang-glslang is probably missing");
		return;
	}
	slang::Session session = opened;
	defer session.free();

	@body(session);
}

// Compile one of the fixtures above with both stages named.
macro slang::Compiled compile(slang::Session session, String source, String name, String[] flags = FLAGS[..])
{
	slang::Entry[2] entries = {
		{ "vertexMain", slang::STAGE_VERTEX },
		{ "fragmentMain", slang::STAGE_FRAGMENT },
	};
	return session.compile({
		.name = name,
		.source = source,
		.entries = entries[..],
		.arguments = flags,
	})!!;
}

// ============================================================================
// The session
// ============================================================================

fn void a_session_opens_and_closes() @test
{
	slang::Session? opened = slang::session();
	if (catch opened)
	{
		test::@check(false, "a session can be created");
		return;
	}
	slang::Session session = opened;
	test::@check(session != null, "and it is a handle");
	session.free();

	// Beside a `defer` that may run after a path which already freed, a second
	// free has to be a no-op rather than a double destroy.
	slang::Session none = null;
	none.free();
}

// ============================================================================
// Compiling
// ============================================================================

<*
 A known-good shader compiles to a SPIR-V module.

 The magic number is assembled byte by byte rather than read through a `uint*`,
 because the point is what the first four bytes *are*, not what they are on a
 machine that happens to be little-endian and 4-aligned.
*>
fn void a_shader_compiles_to_spirv() @test
{
	@with_session(; slang::Session session)
	{
		slang::Compiled result = compile(session, MINIMAL_SOURCE, "minimal.slang");
		defer result.free();

		test::@check(result.ok, "it compiled: %s", result.diagnostic);
		test::@check(result.spirv.len > 0, "and produced a module");
		test::@check(result.spirv.len % 4 == 0, "which is a whole number of words");

		char[] bytes = result.spirv;
		uint magic = (uint)bytes[0] | ((uint)bytes[1] << 8) | ((uint)bytes[2] << 16) | ((uint)bytes[3] << 24);
		test::@check(magic == 0x07230203, "and starts with the SPIR-V magic number, got %x", magic);

		test::@check(result.reflection != null, "with reflection attached");
	};
}

<*
 Two compiles of the same source produce the same bytes.

 Not a curiosity: a consumer that caches pipelines keys on the source, so a
 compiler answering differently for identical input would mean a cache hit and a
 cache miss are not the same program.
*>
fn void the_same_source_compiles_to_the_same_bytes() @test
{
	@with_session(; slang::Session session)
	{
		slang::Compiled first = compile(session, RICH_SOURCE, "rich.slang");
		defer first.free();
		slang::Compiled second = compile(session, RICH_SOURCE, "rich.slang");
		defer second.free();

		test::@check(first.spirv.len == second.spirv.len, "same length: %d and %d", first.spirv.len, second.spirv.len);
		test::@check(first.spirv == second.spirv, "and the same bytes");
	};
}

<*
 **`slangc` and this API do not default to the same matrix layout.**

 The CLI is column-major; `spProcessCommandLineArguments` is not, under the same
 flags. Passing a documented `slangc` command line verbatim therefore produces a
 different module, with every transform transposed and nothing reporting
 anything at any layer.

 This is the most expensive thing found while writing this binding, and it is a
 test rather than a paragraph because a future SDK could change it in either
 direction and say nothing.

 Compiled three ways and compared byte for byte, rather than asserted on a name
 in the module: how the layout shows up depends on where the matrix lives. In a
 buffer it becomes a named storage type with `ColMajor` in it; in a push block —
 where this fixture's is — it is a numeric `OpMemberDecorate` with no string
 anywhere. The bytes are the claim either way.
*>
fn void the_api_does_not_default_to_slangcs_matrix_layout() @test
{
	@with_session(; slang::Session session)
	{
		slang::Compiled column = compile(session, RICH_SOURCE, "rich.slang");
		defer column.free();
		slang::Compiled row = compile(session, RICH_SOURCE, "rich.slang", FLAGS_ROW_MAJOR[..]);
		defer row.free();
		slang::Compiled unsaid = compile(session, RICH_SOURCE, "rich.slang", FLAGS_UNSAID[..]);
		defer unsaid.free();

		test::@check(column.ok && row.ok && unsaid.ok, "all three compile");
		test::@check(column.spirv != row.spirv, "the two layouts are different modules");
		test::@check(
			unsaid.spirv == row.spirv,
			"and saying nothing means row-major — which is *not* what the same slangc command line does"
		);
		test::@check(
			unsaid.spirv != column.spirv,
			"so a slangc line passed verbatim is transposed — if this now fails, the SDK changed and the flag can go"
		);
	};
}

// ============================================================================
// Diagnostics
// ============================================================================

<*
 A shader that does not compile is `ok: false` with a diagnostic, not a fault.

 A fault would throw away the one thing worth returning. The line number is what
 is asserted rather than the wording: the wording is Slang's to change, and the
 line is what somebody uses to fix the shader. The error is on line 7 of a
 9-line source, so a diagnostic reporting line 1 would not accidentally pass.
*>
fn void a_broken_shader_is_a_diagnostic_not_a_fault() @test
{
	@with_session(; slang::Session session)
	{
		String source = `struct VOut { float4 sv_position : SV_Position; };

[shader("vertex")]
VOut vertexMain(uint vid : SV_VertexID)
{
	VOut o;
	o.sv_position = notAFunction(vid);
	return o;
}`;

		slang::Compiled result = compile(session, source, "bad.slang");
		defer result.free();

		test::@check(!result.ok, "it did not compile");
		test::@check(result.spirv.len == 0, "and produced no module");
		test::@check(result.diagnostic.len > 0, "and said something");
		test::@check(result.diagnostic.contains("bad.slang:7"), "naming line 7: %s", result.diagnostic);
		test::@check(result.diagnostic.contains("notAFunction"), "and the identifier that is wrong");
	};
}

<*
 An entry point the caller named and the shader does not have is an error.

 This binding names its entry points instead of letting `[shader(...)]`
 attributes discover them, precisely so that a shader spelling `vertexMain`
 differently is a sentence rather than a module the caller cannot use.
*>
fn void a_missing_entry_point_is_a_diagnostic() @test
{
	@with_session(; slang::Session session)
	{
		String source = `struct VOut { float4 sv_position : SV_Position; };
[shader("vertex")]
VOut vertexMain(uint vid : SV_VertexID) { VOut o; o.sv_position = float4(0,0,0,1); return o; }`;

		slang::Compiled result = compile(session, source, "half.slang");
		defer result.free();

		test::@check(!result.ok, "a program without fragmentMain does not compile");
		test::@check(result.diagnostic.contains("fragmentMain"), "and says which one is missing: %s", result.diagnostic);
	};
}

<*
 Freeing a `Compiled` twice is a no-op, not a double destroy.

 It is returned from a function that can fail on a later line, so it is
 routinely deferred beside a path that already released it.
*>
fn void a_compiled_can_be_freed_twice() @test
{
	@with_session(; slang::Session session)
	{
		slang::Compiled result = compile(session, MINIMAL_SOURCE, "minimal.slang");
		result.free();
		test::@check(result.request == null, "the request is gone");
		test::@check(result.spirv.len == 0, "and so are the bytes");
		result.free();
	};
}

// ============================================================================
// Reflection
// ============================================================================

<*
 The entry points come back named, with their stages.
*>
fn void the_entry_points_reflect_with_their_stages() @test
{
	@with_session(; slang::Session session)
	{
		slang::Compiled result = compile(session, RICH_SOURCE, "rich.slang");
		defer result.free();
		test::@check(result.ok, "the fixture compiles: %s", result.diagnostic);

		List{slang::Entry} entries;
		entries.init(mem, 4);
		defer entries.free();
		result.reflection.entry_points(&entries);

		test::@check(entries.len() == 2, "two entry points, got %d", entries.len());

		bool vertex = false;
		bool fragment = false;
		foreach (entry : entries)
		{
			if (entry.name == "vertexMain" && entry.stage == slang::STAGE_VERTEX) vertex = true;
			if (entry.name == "fragmentMain" && entry.stage == slang::STAGE_FRAGMENT) fragment = true;
		}
		test::@check(vertex, "vertexMain is a vertex shader");
		test::@check(fragment, "fragmentMain is a fragment shader");

		// `OpEntryPoint` carries the name as a literal, so the module itself can
		// be asked and not only the reflection describing it.
		String module_bytes = (String)result.spirv;
		test::@check(module_bytes.contains("vertexMain"), "and the module names vertexMain");
		test::@check(module_bytes.contains("fragmentMain"), "and fragmentMain");
	};
}

<*
 A shader with known bindings reflects them, with their sets, numbers and counts.

 Every field is asserted, because each comes from a different corner of Slang's
 reflection and each has its own way of being wrong: the type from the binding
 range, the number from the descriptor-set view — the only one that knows about
 `[vk::binding]` — the count from the range's descriptor count, and the set from
 the space offset.
*>
fn void a_shader_with_known_bindings_reflects_them() @test
{
	@with_session(; slang::Session session)
	{
		slang::Compiled result = compile(session, RICH_SOURCE, "rich.slang");
		defer result.free();
		test::@check(result.ok, "the fixture compiles: %s", result.diagnostic);

		List{slang::Descriptor} found;
		found.init(mem, 8);
		defer found.free();
		result.reflection.descriptors(&found);

		// Five, not six: the push block is not a descriptor. See below.
		test::@check(found.len() == 5, "five descriptors, got %d", found.len());

		slang::Descriptor* params = descriptor_named(&found, "params");
		test::@check(params != null, "params is there");
		if (params != null)
		{
			test::@check(params.type == slang::BINDING_CONSTANT_BUFFER, "a ConstantBuffer is a constant buffer");
			test::@check(params.set == 0 && params.binding == 0, "at 0,0 — got %d,%d", params.set, params.binding);
			test::@check(params.count == 1, "one of it");
		}

		// The distinction this whole walk exists for. A `Sampler2D` and a
		// `Texture2D` share a type kind and a parameter category; only the
		// binding range type tells them apart, and getting it wrong is a black
		// screen rather than an error.
		slang::Descriptor* albedo = descriptor_named(&found, "albedo");
		test::@check(albedo != null, "albedo is there");
		if (albedo != null)
		{
			test::@check(
				albedo.type == slang::BINDING_COMBINED_TEXTURE_SAMPLER,
				"a Sampler2D is a combined texture sampler, not a texture"
			);
			test::@check(albedo.binding == 1, "at binding 1, got %d", albedo.binding);
		}

		slang::Descriptor* extras = descriptor_named(&found, "extras");
		test::@check(extras != null, "extras is there");
		if (extras != null)
		{
			test::@check(extras.type == slang::BINDING_TEXTURE, "a Texture2D is a texture");
			// One binding of four, not four bindings — an array arriving as
			// count 1 sizes a descriptor set the shader then overruns.
			test::@check(extras.count == 4, "an array of four, got %d", extras.count);
		}

		slang::Descriptor* sampler = descriptor_named(&found, "linearSampler");
		test::@check(sampler != null, "linearSampler is there");
		if (sampler != null)
		{
			test::@check(sampler.type == slang::BINDING_SAMPLER, "a SamplerState is a sampler");
		}

		slang::Descriptor* points = descriptor_named(&found, "points");
		test::@check(points != null, "points is there");
		if (points != null)
		{
			test::@check(points.type == slang::BINDING_RAW_BUFFER, "a StructuredBuffer is a raw buffer");
			test::@check(points.set == 1, "in set 1, got %d", points.set);
		}

		// A push block reflects as a constant buffer, exactly like `params`
		// does. Told apart only by its parameter category — and a push block in
		// a descriptor set layout is a validation error naming a binding the
		// shader never declared.
		test::@check(descriptor_named(&found, "pc") == null, "the push block is not a descriptor");
	};
}

<*
 The push block comes back with its size and its fields' offsets.

 68 bytes: a `float4x4` at 0 and a `uint` at 64. That the offsets are read in the
 uniform category is what makes them bytes rather than slots — asking the outer
 layout instead answers zero, because a push block consumes a push-constant slot
 and no uniform bytes at all.
*>
fn void the_push_block_reflects_with_its_offsets() @test
{
	@with_session(; slang::Session session)
	{
		slang::Compiled result = compile(session, RICH_SOURCE, "rich.slang");
		defer result.free();

		List{slang::Field} fields;
		fields.init(mem, 8);
		defer fields.free();
		uint size = result.reflection.push_block(&fields);

		test::@check(size == 68, "the block is 68 bytes, got %d", size);
		test::@check(fields.len() == 2, "with two fields, got %d", fields.len());

		slang::Field* mvp = field_named(&fields, "mvp");
		test::@check(mvp != null, "mvp is there");
		if (mvp != null)
		{
			test::@check(mvp.offset == 0, "at offset 0, got %d", mvp.offset);
			test::@check(mvp.size == 64, "and 64 bytes long, got %d", mvp.size);
		}

		slang::Field* flags = field_named(&fields, "flags");
		test::@check(flags != null, "flags is there");
		if (flags != null)
		{
			test::@check(flags.offset == 64, "at offset 64, got %d", flags.offset);
			test::@check(flags.size == 4, "and 4 bytes long, got %d", flags.size);
		}
	};
}

<*
 A shader with no push block reports no push block.

 Zero rather than a guess: a caller that declared a push-constant range for a
 shader without one is a layout mismatch at pipeline creation.
*>
fn void a_shader_without_a_push_block_says_so() @test
{
	@with_session(; slang::Session session)
	{
		slang::Compiled result = compile(session, MINIMAL_SOURCE, "minimal.slang");
		defer result.free();

		List{slang::Field} fields;
		fields.init(mem, 4);
		defer fields.free();

		test::@check(result.reflection.push_block(&fields) == 0, "no push block");
		test::@check(fields.len() == 0, "and no fields");

		List{slang::Descriptor} found;
		found.init(mem, 4);
		defer found.free();
		result.reflection.descriptors(&found);
		test::@check(found.len() == 0, "and nothing to bind");
	};
}

// ============================================================================

fn slang::Descriptor* descriptor_named(List{slang::Descriptor}* list, String name) @local
{
	foreach (i, &descriptor : *list) if (descriptor.name == name) return descriptor;
	return null;
}

fn slang::Field* field_named(List{slang::Field}* list, String name) @local
{
	foreach (i, &field : *list) if (field.name == name) return field;
	return null;
}
