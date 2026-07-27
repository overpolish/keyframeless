/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

@objc(KKAIPluginResultKind)
public enum AIPluginResultKind: Int {
	case answer = 0
	case mutation = 1
	/// The user asked to ADD a new shape/layer. `createSVG` holds an SVG
	/// document the host parses into new layers; `createAnimatePrompt`, when
	/// non-empty, is a follow-up animation request the host runs once the new
	/// layers exist. Only produced when the caller passed
	/// `supportsLayerCreation: true` (Canvas); other plugins never see it.
	case createLayers = 2
	/// The user asked to WRITE or EDIT the shader's GLSL source. `shaderSource`
	/// holds the complete shader the host writes into its code lane (which
	/// re-transpiles and re-derives its controls). Only produced when the caller
	/// used the code-authoring entry point (Mirage); other plugins never see it.
	case authorCode = 3
	/// The user asked to drive one or more properties from a FORMULA. `expressionOps`
	/// is JSON `{ "operations": [{ "lane": "...", "expression": "..." }] }`; the host
	/// sets each named lane's `linkExpression` and writes the timeline back (which
	/// re-derives the driven values). Cross-clip `${Clip.Param}` refs come back in the
	/// friendly display form the host translates to stored ids. Only produced when the
	/// caller enabled expression authoring.
	case authorExpression = 4
}

/// Returned by `AIPluginAgent.run(...)`. Either `.answer(String)` (Q&A reply),
/// `.mutation(String)` where the mutation is JSON of shape
/// `{ "operations": [{ "lane": "...", "keyposes": [{ "time": ..., "values": [...], "outgoing": {...} }] }] }`,
/// or `.createLayers` (an SVG + optional follow-up animation prompt).
/// The host plugin merges a mutation into its current timeline JSON and writes
/// it back through the existing param-mutation path.
@objc(KKAIPluginResult)
public final class AIPluginResult: NSObject {
	@objc public let kind: AIPluginResultKind
	@objc public let answer: String?
	@objc public let mutationJSON: String?
	@objc public let createSVG: String?
	@objc public let createAnimatePrompt: String?
	@objc public let shaderSource: String?
	@objc public let expressionOps: String?

	init(answer: String) {
		self.kind = .answer
		self.answer = answer
		self.mutationJSON = nil
		self.createSVG = nil
		self.createAnimatePrompt = nil
		self.shaderSource = nil
		self.expressionOps = nil
		super.init()
	}

	init(mutationJSON: String) {
		self.kind = .mutation
		self.answer = nil
		self.mutationJSON = mutationJSON
		self.createSVG = nil
		self.createAnimatePrompt = nil
		self.shaderSource = nil
		self.expressionOps = nil
		super.init()
	}

	init(createSVG: String, animatePrompt: String?) {
		self.kind = .createLayers
		self.answer = nil
		self.mutationJSON = nil
		self.createSVG = createSVG
		self.createAnimatePrompt = animatePrompt
		self.shaderSource = nil
		self.expressionOps = nil
		super.init()
	}

	init(shaderSource: String) {
		self.kind = .authorCode
		self.answer = nil
		self.mutationJSON = nil
		self.createSVG = nil
		self.createAnimatePrompt = nil
		self.shaderSource = shaderSource
		self.expressionOps = nil
		super.init()
	}

	init(expressionOps: String) {
		self.kind = .authorExpression
		self.answer = nil
		self.mutationJSON = nil
		self.createSVG = nil
		self.createAnimatePrompt = nil
		self.shaderSource = nil
		self.expressionOps = expressionOps
		super.init()
	}
}

/// Multi-pass orchestrator for natural-language → KKTiming mutations.
///
/// Pass 0a (classify)    - router: answer / mutation / vague + complexity flag
///                         + template fast-path resolution.
/// Pass 0b (answer)      - only fires on Q&A prompts; loads docs and replies.
/// Template (Swift)      - skips remaining passes when classifier resolved a
///                         known shape (e.g. modulate + lane).
/// Pass 1  (timing)      - keypose times, interval kinds, phase plan.
/// Pass 2  (values)      - numeric values per new keypose, per lane.
/// Pass 3  (styles)      - curve + modulation per interval, per lane.
/// Compile (Swift)       - assemble JSON, preserve values/styles deterministically.
///
/// Every LLM call uses provider-native structured outputs (Anthropic forced
/// `tool_choice`, OpenAI `response_format: json_schema`) so the model can't
/// emit malformed shapes - it either conforms or fails.
@objc(KKAIPluginAgent)
public final class AIPluginAgent: NSObject {
	@MainActor
	@objc public static func run(
		prompt: String,
		productContext: String,
		laneSchemaText: String,
		currentTimelineJSON: String,
		clipDurationSeconds: Double,
		currentInspectorMode: String,
		supportsLayerCreation: Bool,
		completion: @escaping (AIPluginResult?, Error?) -> Void
	) {
		Task { @MainActor in
			do {
				let result = try await runAsync(
					prompt: prompt,
					productContext: productContext,
					laneSchemaText: laneSchemaText,
					currentTimelineJSON: currentTimelineJSON,
					clipDurationSeconds: clipDurationSeconds,
					currentInspectorMode: currentInspectorMode,
					supportsCreate: supportsLayerCreation
				)
				completion(result, nil)
			} catch {
				completion(nil, error)
			}
		}
	}

	/// Generator variant of `run`: the host also passes its Type catalog (an
	/// "index = name (blurb)" list) and palette cap, which enables the styling
	/// fast-path for "make a look" prompts (one call sets Type + the whole
	/// palette). Q&A, animation, and vague prompts route exactly as `run` does.
	@MainActor
	@objc public static func runGenerator(
		prompt: String,
		productContext: String,
		laneSchemaText: String,
		currentTimelineJSON: String,
		clipDurationSeconds: Double,
		currentInspectorMode: String,
		typeCatalog: String,
		maxColors: Int,
		completion: @escaping (AIPluginResult?, Error?) -> Void
	) {
		Task { @MainActor in
			do {
				let result = try await runAsync(
					prompt: prompt,
					productContext: productContext,
					laneSchemaText: laneSchemaText,
					currentTimelineJSON: currentTimelineJSON,
					clipDurationSeconds: clipDurationSeconds,
					currentInspectorMode: currentInspectorMode,
					supportsCreate: false,
					generatorTypeCatalog: typeCatalog,
					generatorMaxColors: maxColors)
				completion(result, nil)
			} catch {
				completion(nil, error)
			}
		}
	}

	/// Code-authoring variant of `run` (Mirage): the host also passes the shader's
	/// current GLSL source, which enables the `code` route - "write a shader for a
	/// wavy look", "add a glow to this". The agent returns a `.authorCode` result
	/// whose `shaderSource` the host writes into its code lane. Q&A, animation
	/// (mutation), and vague prompts route exactly as `run` does; only prompts that
	/// ask to change the shader's actual look/effect become code.
	@MainActor
	@objc public static func runCodeAuthoring(
		prompt: String,
		productContext: String,
		laneSchemaText: String,
		currentTimelineJSON: String,
		clipDurationSeconds: Double,
		currentInspectorMode: String,
		currentShaderSource: String,
		availableSources: String,
		completion: @escaping (AIPluginResult?, Error?) -> Void
	) {
		Task { @MainActor in
			do {
				let result = try await runAsync(
					prompt: prompt,
					productContext: productContext,
					laneSchemaText: laneSchemaText,
					currentTimelineJSON: currentTimelineJSON,
					clipDurationSeconds: clipDurationSeconds,
					currentInspectorMode: currentInspectorMode,
					supportsCode: true,
					currentShaderSource: currentShaderSource,
					supportsExpressions: true,
					availableSources: availableSources)
				completion(result, nil)
			} catch {
				completion(nil, error)
			}
		}
	}

	/// Canvas targeted routing (see `runCanvasTargetedAsync`). Declared in the
	/// main class body - not an extension - so the `@objc` entry point reliably
	/// lands in the generated ObjC header the plugin imports.
	@MainActor
	@objc public static func runCanvasTargeted(
		prompt: String,
		productContext: String,
		laneLabels: [String],
		propertyCatalog: String,
		layerCatalog: String,
		clipDurationSeconds: Double,
		supportsLayerCreation: Bool,
		completion: @escaping (AIPluginResult?, Error?) -> Void
	) {
		Task { @MainActor in
			do {
				let result = try await runCanvasTargetedAsync(
					prompt: prompt, productContext: productContext,
					laneLabels: laneLabels, propertyCatalog: propertyCatalog,
					layerCatalog: layerCatalog, clipDurationSeconds: clipDurationSeconds,
					supportsCreate: supportsLayerCreation)
				completion(result, nil)
			} catch {
				completion(nil, error)
			}
		}
	}

	@MainActor
	static func runAsync(
		prompt: String,
		productContext: String,
		laneSchemaText: String,
		currentTimelineJSON: String,
		clipDurationSeconds: Double,
		currentInspectorMode: String,
		supportsCreate: Bool = false,
		supportsCode: Bool = false,
		currentShaderSource: String = "",
		supportsExpressions: Bool = false,
		availableSources: String = "",
		generatorTypeCatalog: String? = nil,
		generatorMaxColors: Int = 0
	) async throws -> AIPluginResult {
		AIDraftState.shared.routingStatus = AILoc("Reading prompt")
		// Pass 0a: classify. No docs in this prompt - classifier is just a
		// router. If the answer path wins, Pass 0b loads docs and writes the
		// reply. This keeps the mutation path (the hot path) cheap. We
		// expose the lane labels so the classifier can resolve template
		// fast-paths in natural language ("wobble the radius" → modulate
		// + Radius) without us maintaining a synonym list in Swift.
		let labels = laneLabels(
			fromTimelineJSON: currentTimelineJSON,
			fallbackSchemaText: laneSchemaText)
		let classification = try await classify(
			prompt: prompt, productContext: productContext, laneLabels: labels,
			supportsCreate: supportsCreate, supportsCode: supportsCode,
			supportsExpressions: supportsExpressions)
		// The user wants to write or edit the shader's GLSL. Generate the source
		// (editing the current shader when there is one and the ask implies it);
		// the host writes it into its code lane, which re-transpiles and rebuilds
		// the controls.
		if classification.kind == "code" {
			AIDraftState.shared.routingStatus = AILoc("Writing shader")
			let source = try await generateShaderCode(
				prompt: prompt, productContext: productContext,
				currentShaderSource: currentShaderSource)
			return AIPluginResult(shaderSource: source)
		}
		// The user wants a property driven by a formula (procedural motion, a
		// math relationship, or a link to another clip). Generate one expression
		// per target lane; the host sets each lane's linkExpression.
		if classification.kind == "expression" {
			AIDraftState.shared.routingStatus = AILoc("Writing expression")
			let ops = try await generateExpressionOps(
				prompt: prompt, productContext: productContext,
				currentTimelineJSON: currentTimelineJSON,
				availableSources: availableSources, laneLabels: labels)
			return AIPluginResult(expressionOps: ops)
		}
		// The user wants a new shape drawn. Hand back an SVG (+ optional follow-up
		// animation request); the host parses it into layers and, if asked, runs
		// the animation once they exist.
		if classification.kind == "create" {
			AIDraftState.shared.routingStatus = AILoc("Drawing")
			let draft = try await generateLayers(
				prompt: prompt, productContext: productContext)
			return AIPluginResult(
				createSVG: draft.svg, animatePrompt: draft.animatePrompt)
		}
		if classification.kind == "answer" {
			let docs = await renderDocs(for: prompt)
			AIDraftState.shared.routingStatus = AILoc("Answering")
			let reply = try await answerQuestion(
				prompt: prompt, productContext: productContext, docs: docs)
			return AIPluginResult(answer: reply)
		}
		if classification.kind == "vague" {
			// Surface the classifier's clarification as an answer result so
			// the popover renders it like any reply. Avoids burning thinking
			// budget on prompts that can't succeed.
			let clarification =
				classification.clarification?.trimmingCharacters(
					in: .whitespacesAndNewlines) ?? ""
			let reply =
				clarification.isEmpty
				? "Could you be a bit more specific about what you'd like to change?"
				: clarification
			return AIPluginResult(answer: reply)
		}

		// Generator styling fast-path: a "make a look" request (a Type + a
		// palette) resolves in ONE focused call instead of the per-lane timing
		// pipeline - fast on local, and it sets the Type reliably. Only when the
		// host is a generator (it passed its Type catalog + palette cap).
		if classification.template == "style",
			let catalog = generatorTypeCatalog, generatorMaxColors > 0
		{
			AIDraftState.shared.routingStatus = AILoc("Choosing a look")
			if let mutation = try await resolveGeneratorStyle(
				prompt: prompt, productContext: productContext,
				typeCatalog: catalog, maxColors: generatorMaxColors,
				enableThinking: classification.complexity == "complex")
			{
				return AIPluginResult(mutationJSON: mutation)
			}
			// Resolver returned nothing usable - fall through to the full pipeline.
		}

		// Template fast-path: classifier resolved a known shape, Swift builds
		// the mutation directly and skips Pass 1/2/3.
		if classification.template == "modulate",
			!classification.templateLane.isEmpty,
			let templated = buildModulateTemplate(
				lane: classification.templateLane,
				modulation: classification.templateModulation,
				currentTimelineJSON: currentTimelineJSON)
		{
			return AIPluginResult(mutationJSON: templated)
		}

		AIDraftState.shared.routingStatus = AILoc("Planning timing")
		// Pass 1: timing. Thinking only when the classifier flagged the prompt
		// as "complex" - simple template-matchable prompts don't need 4k
		// reasoning tokens.
		let timing = try await planTiming(
			prompt: prompt,
			productContext: productContext,
			laneSchemaText: laneSchemaText,
			// Compact timeline (labels + keyposes only) - the passes read only
			// those, so dropping lane metadata keeps this, the one prompt that
			// embeds the whole timeline, lean: fewer tokens, faster local prefill.
			currentTimelineJSON: compactTimelineForAI(currentTimelineJSON),
			clipDurationSeconds: clipDurationSeconds,
			currentInspectorMode: currentInspectorMode,
			enableThinking: classification.complexity == "complex"
		)
		// Phases are the authoritative orchestration when present (multi-lane
		// / temporal prompts). Derive per-lane operations from them and
		// discard whatever the LLM dropped in `operations`. For single-lane
		// prompts Pass 1 leaves phases empty and we use `operations` as-is.
		let effectiveOperations: [TimingOperation]
		if !timing.phases.isEmpty {
			effectiveOperations = deriveOperationsFromPhases(timing.phases)
		} else {
			effectiveOperations = timing.operations
		}
		guard !effectiveOperations.isEmpty else {
			return AIPluginResult(answer: AILoc("Couldn't figure out which lanes to change."))
		}

		// Pass 2 + Pass 3 per operation, in parallel (independent given Pass 1).
		let currentLanes = extractLanes(fromTimelineJSON: currentTimelineJSON)
		let currentIntervals =
			extractIntervals(fromTimelineJSON: currentTimelineJSON)
		var compiledOps: [[String: Any]] = []
		let totalOps = effectiveOperations.count
		let complex = classification.complexity == "complex"
		for (opIdx, op) in effectiveOperations.enumerated() {
			let suffix = totalOps > 1 ? " (\(opIdx + 1)/\(totalOps))" : ""
			// A multi-layer host tags labels "<property>\u{1F}<layerID>"; show only
			// the property name in the status, never the opaque layer id.
			let displayLane = op.lane.components(separatedBy: "\u{1F}").first ?? op.lane
			let laneLabel = "\(displayLane)\(suffix)"
			AIDraftState.shared.routingStatus = AILoc("Resolving \(laneLabel)")
			let oldKeyposes = currentLanes[op.lane] ?? []
			let oldIntervals = currentIntervals[op.lane] ?? []
			async let valuesAsync = resolveValues(
				prompt: prompt,
				productContext: productContext,
				laneSchemaText: laneSchemaText,
				operation: op,
				clipDurationSeconds: clipDurationSeconds,
				existingKeyposes: oldKeyposes,
				enableThinking: complex
			)
			// Pass 3 always runs (cheap Haiku, no thinking) so we don't have
			// to guess at colloquial style intent in Swift. Existing-interval
			// preservation is still handled deterministically in compile.
			async let stylesAsync = planCurves(
				prompt: prompt,
				productContext: productContext,
				operation: op,
				existingIntervals: oldIntervals
			)
			let values = try await valuesAsync
			let styles = try await stylesAsync
			compiledOps.append(
				buildOperationJSON(
					timingOp: op,
					values: values,
					styles: styles,
					existingKeyposes: oldKeyposes,
					existingIntervals: oldIntervals))
		}

		let mutation: [String: Any] = ["operations": compiledOps]
		let data = try JSONSerialization.data(withJSONObject: mutation)
		let json = String(data: data, encoding: .utf8) ?? "{\"operations\":[]}"
		return AIPluginResult(mutationJSON: json)
	}
}
