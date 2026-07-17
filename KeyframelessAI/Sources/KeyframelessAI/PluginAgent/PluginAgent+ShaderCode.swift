/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	/// Pass for "code" prompts (Shader only): turn a request about the shader's
	/// look/effect into a complete GLSL source. The host writes it into its code
	/// lane, which re-transpiles and rebuilds the controls.
	///
	/// `currentShaderSource` is the shader currently in the editor, or "" when it's
	/// the untouched default (the host passes "" so a fresh ask starts clean). When
	/// non-empty, the model EDITS it - preserving what works and its controls -
	/// rather than replacing it wholesale.
	@MainActor
	static func generateShaderCode(
		prompt: String, productContext: String, currentShaderSource: String
	) async throws -> String {
		let editing = !currentShaderSource.trimmingCharacters(
			in: .whitespacesAndNewlines
		).isEmpty
		let docs = await shaderAuthoringDocs()

		let rules = """
			You write GLSL shaders for \(productContext), a Shadertoy-style effect \
			that compiles your source and runs it live on the clip.

			Rules (follow exactly):
			- Output ONE complete, compilable GLSL Image shader whose entry point is \
			  `void mainImage(out vec4 fragColor, in vec2 fragCoord)`.
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
			- Output ONLY the shader source. No prose, no explanation.
			"""
		let cachedPrefix = docs.isEmpty ? rules : (docs + "\n\n" + rules)

		let editInstruction =
			editing
			? """
			The user is editing the CURRENT shader below. Modify it to satisfy the \
			request while preserving everything that already works and its existing \
			`// #` controls. Return the COMPLETE updated shader, not a diff.

			CURRENT SHADER:
			\(currentShaderSource)
			"""
			: "Write a new shader for the user's request."

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
				"Emit the complete GLSL source for the requested shader look/effect.",
			jsonSchema: schema,
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

	/// The full text of the shader-authoring reference topics (the custom-shader
	/// language guide + the `// #` directives guide) the host registered, so the
	/// model writes correct conventions. Empty if the host registered no docs.
	@MainActor
	private static func shaderAuthoringDocs() async -> String {
		let wanted: Set<String> = ["custom-shader", "directives"]
		let entries = await AIKnowledgeRegistry.shared.allEntries()
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
