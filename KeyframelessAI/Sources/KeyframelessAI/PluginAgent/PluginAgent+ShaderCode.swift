/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	/// Pass for "code" prompts (Mirage only): turn a request about the shader's
	/// look/effect into a complete GLSL source. The host writes it into its code
	/// lane, which re-transpiles and rebuilds the controls.
	///
	/// `currentShaderSource` is the shader currently in the editor, or "" when it's
	/// the untouched default (the host passes "" so a fresh ask starts clean). When
	/// non-empty, the model EDITS it - preserving what works and its controls -
	/// rather than replacing it wholesale. A multi-pass shader arrives (and comes
	/// back) as one flat `// #tab` blob, which the host splits into sections.
	/// How many compile-and-repair rounds follow the first draft. Each round
	/// hands the model the host's exact compiler message and asks for the whole
	/// shader back; three is enough that a slip (a reserved identifier, a
	/// mistyped builtin) never reaches the editor, without turning a genuinely
	/// confused answer into a long wait.
	static let shaderRepairAttempts = 3

	/// `validate` is the host's compiler: it returns a human-readable error (with
	/// section and line where it has them) for source that won't compile or
	/// can't be saved, nil when the shader is good. When it is provided, the
	/// draft is validated before it is returned and repaired on failure, so the
	/// user only ever sees working code.
	@MainActor
	static func generateShaderCode(
		prompt: String, productContext: String, currentShaderSource: String,
		validate: ((String) -> String?)? = nil
	) async throws -> String {
		var source = try await draftShaderCode(
			prompt: prompt, productContext: productContext,
			currentShaderSource: currentShaderSource, repairing: nil)
		guard let validate else { return source }
		var attempt = 0
		while let problem = validate(source), attempt < shaderRepairAttempts {
			attempt += 1
			AIDraftState.shared.routingStatus = AILoc("Fixing compile error")
			source = try await draftShaderCode(
				prompt: prompt, productContext: productContext,
				currentShaderSource: source, repairing: problem)
		}
		return source
	}

	/// One model round: a fresh draft, an edit of the current shader, or (when
	/// `repairing` carries a compiler message) a fix of the shader that failed.
	@MainActor
	private static func draftShaderCode(
		prompt: String, productContext: String, currentShaderSource: String,
		repairing: String?
	) async throws -> String {
		let editing = !currentShaderSource.trimmingCharacters(
			in: .whitespacesAndNewlines
		).isEmpty
		let docs = await shaderAuthoringDocs(for: prompt)

		let rules = """
			You write GLSL shaders for \(productContext), a Shadertoy-style effect \
			that compiles your source and runs it live on the clip.

			Rules (follow exactly):
			- Output complete, compilable GLSL. The Image pass is the entry point and \
			  its function is `void mainImage(out vec4 fragColor, in vec2 fragCoord)`.
			- The Image source must declare exactly one `// #template ...` line (see \
			  the reference for the types and which one fits).
			- A single-pass shader is just the Image source, with no marker line \
			  around it. If the effect genuinely needs several passes, output every \
			  section in ONE block, each opened by its own `// #tab <name>` line: \
			  `image`, `common`, and `buffer-a` through `buffer-d`, and nothing else. \
			  Mark a section only when you are writing more than one, and give each \
			  pass its own `mainImage`. `// #tab` is an interchange marker, not a \
			  directive - it is stripped before the source is compiled.
			- The clip being processed is `iChannel0` (a sampler2D). Sample it with \
			  `texture(iChannel0, fragCoord/iResolution.xy)`. Process or composite \
			  over the footage unless the user clearly wants a look that ignores it.
			- These inputs are provided - use them, never redeclare them: iTime, \
			  iResolution, iChannel0, iChannel1, iMouse, iFrame, iTimeDelta, iDate.
			- Expose adjustable parameters as uniforms annotated with `// #` \
			  directives on the line BEFORE each uniform (see the directives \
			  reference), so the user gets inspector + on-screen controls. Prefer a \
			  couple of well-named controls (amount, speed, colour) over hard-coded \
			  magic numbers.
			- Self-contained only: no #include, no textures beyond iChannel0/iChannel1, \
			  no compute. Animate with iTime so the effect moves.
			- The source is compiled as GLSL 4.50 core, which is stricter than WebGL. \
			  Never use a reserved word as a variable or function name: sample, \
			  filter, input, output, common, partition, active, superp, asm, class, \
			  union, enum, typedef, template, this, goto, inline, noinline, volatile, \
			  public, static, extern, external, interface, long, short, half, fixed, \
			  unsigned, sizeof, cast, namespace, using, resource, patch, subroutine. \
			  Name a fetched texel `tap`, `col`, or `src`, never `sample`.
			- Every variable must be declared before use, every function before its \
			  first call (or forward-declared), and float literals need the decimal \
			  point (`1.0`, not `1`) where a float is expected.
			- Directive uniforms arrive in the value space the reference states, not \
			  the one the control displays: a `#percent` uniform is already divided \
			  by 100 (never divide again), and a `#point` uniform is already in \
			  PIXELS (fragCoord space, multiplied by `iResolution.xy`) - divide it \
			  by `iResolution.xy` before using it against 0..1 UVs, or every sample \
			  lands off-frame and the output goes black while compiling fine.
			- A fragment shader has NO memory: globals are re-created for every pixel \
			  of every frame, so never store state in global arrays, never "initialise \
			  on iFrame == 0", never expect a value to survive to the next frame. \
			  Derive everything from fragCoord/uv, iTime, the uniforms and hash \
			  functions of those (a buffer pass is the only persistent state).
			- Loops need an int counter against a compile-time constant bound; when a \
			  uniform sets the count, loop to the constant maximum and `break` past \
			  `int(uCount)`.
			- The result must be the clip VISIBLY transformed at the default control \
			  values: sample iChannel0 at displaced/warped coordinates and keep that \
			  footage in the output. Never end with the whole frame replaced by a flat \
			  colour, and never use a mix factor that is always 1.0.
			- Before writing, decide what one frame looks like at the DEFAULT values \
			  and check the numbers make it unmistakable on a 1920x1080 clip: a \
			  displacement reads only when it is a few percent of the frame (0.02 to \
			  0.2 in uv, not 0.001), an edge/feature mask must be 0 over most of the \
			  frame and 1 only on the feature (for an edge at `f` near 0 or 1 use \
			  `1.0 - smoothstep(0.0, w, f)` and `smoothstep(1.0 - w, 1.0, f)`, never \
			  `smoothstep(0.0, w, f)` which is 1 almost everywhere), and anything \
			  "flying apart" or "breaking" needs per-piece random offsets, rotation \
			  and visible gaps (background or black between pieces), not a uniform \
			  shift. Choose defaults that show the effect clearly, not subtly.
			- Output ONLY the shader source. No prose, no explanation.
			"""
		let cachedPrefix = docs.isEmpty ? rules : (docs + "\n\n" + rules)

		let editInstruction: String
		if let repairing {
			editInstruction = """
				The shader below was written for the user's request but FAILED TO \
				COMPILE. Fix the error while keeping the look, the structure and every \
				`// #` control the same. Check the whole source for the same class of \
				mistake, not only the reported line. Return the COMPLETE corrected \
				shader, not a diff. If it carries `// #tab` markers it is a multi-pass \
				shader: keep the markers and return every tab whole.

				COMPILER ERROR:
				\(repairing)

				SHADER THAT FAILED:
				\(currentShaderSource)
				"""
		} else if editing {
			editInstruction = """
				The user is editing the CURRENT shader below. Modify it to satisfy the \
				request while preserving everything that already works and its existing \
				`// #` controls. Return the COMPLETE updated shader, not a diff. If it \
				carries `// #tab` markers it is a multi-pass shader: keep the markers, \
				return every tab whole, and never flatten them into one pass.

				CURRENT SHADER:
				\(currentShaderSource)
				"""
		} else {
			editInstruction = "Write a new shader for the user's request."
		}

		// Local: emit the shader as PLAIN TEXT. Small models write GLSL fine but
		// routinely mis-escape it inside a JSON string, which then fails to parse -
		// so skip the envelope and pull the code out of the reply.
		if AIKeyState.shared.activeProvider == .local {
			guard let runner = LocalLLM.runner else {
				throw AITransformError.localUnavailable
			}
			let modelID = LocalModelStore.shared.selectedModelID ?? ""
			let sys =
				cachedPrefix + "\n\n" + editInstruction
				+ "\n\nOutput ONLY the GLSL source. No JSON, no code fences, no commentary."
			let text = LocalLLM.stripThink(
				try await runner.complete(
					modelID: modelID, system: sys, user: prompt,
					jsonSchemaJSON: nil, enableThinking: true))
			return extractShaderCode(text)
		}

		let schema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["source"],
			"properties": [
				"source": ["type": "string"]
			],
		]
		let raw = try await AIStructuredCall.call(
			system: editInstruction,
			cachedSystemPrefix: cachedPrefix,
			userMessage: prompt,
			schemaName: "author_shader",
			schemaDescription:
				"Emit the complete GLSL source for the requested shader look/effect - "
				+ "one blob, with `// #tab` markers only when it is multi-pass.",
			jsonSchema: schema,
			// The small models on purpose: Kai's cloud path is meant to stay cheap
			// for the user, and the compile-and-repair loop plus the rules above are
			// what make a small model's shader land, not a bigger model.
			modelOverride: AIKeyState.shared.activeProvider == .anthropic
				? "claude-haiku-4-5-20251001"
				: "gpt-4o-mini",
			// Writing a whole shader benefits from a moment of reasoning first.
			enableThinking: true
		)
		let data = raw.data(using: .utf8) ?? Data()
		let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
		return extractShaderCode(obj["source"] as? String ?? "")
	}

	/// Shader-authoring reference registered by the host. Local models retrieve the
	/// handful of heading-sized sections relevant to this request; sending the full
	/// directives manual alone costs ~20k prompt tokens before generation starts.
	/// Cloud models retain the complete reference.
	@MainActor
	private static func shaderAuthoringDocs(for prompt: String) async -> String {
		let wanted: Set<String> = ["custom-shader", "directives"]
		let entries =
			AIKeyState.shared.activeProvider == .local
			? await AIKnowledgeRegistry.shared.relevantEntries(
				to: prompt, limit: 4, topicIDs: wanted)
			: await AIKnowledgeRegistry.shared.allEntries()
				.filter { wanted.contains($0.topic.id) }
		guard !entries.isEmpty else { return "" }
		var out = "SHADER REFERENCE (follow these conventions exactly):\n"
		for e in entries.sorted(by: { $0.topic.id < $1.topic.id }) {
			out += "\n## \(e.topic.id) - \(e.topic.summary)\n" + e.topic.content + "\n"
		}
		return out
	}

	/// Pull the GLSL out of a reply that may be wrapped in ``` fences or padded
	/// with stray words. Falls back to the trimmed input.
	private static func extractShaderCode(_ s: String) -> String {
		var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
		// Strip a leading ```glsl / ``` fence and its closing ```.
		if text.hasPrefix("```") {
			if let firstNewline = text.firstIndex(of: "\n") {
				text = String(text[text.index(after: firstNewline)...])
			}
			if let close = text.range(of: "```", options: .backwards) {
				text = String(text[..<close.lowerBound])
			}
		}
		return text.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
