/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	struct TimingOperation {
		let lane: String
		let keyposes: [TimingKeypose]
	}

	struct TimingKeypose {
		let time: Double
		/// What the interval to the NEXT keypose IS, structurally. Curves and
		/// modulation are picked in Pass 3.
		///   "hold"       - endpoints share a value, no motion
		///   "transition" - value moves from this keypose to the next
		///   "none"       - required on the LAST keypose (no following interval)
		let intervalKind: String
		/// True when this keypose was COPIED from the current lane (its time
		/// matches an existing keypose). Compile uses the existing value for
		/// these directly, bypassing Pass 2 - preservation becomes deterministic
		/// instead of relying on the values pass to obey instructions.
		let isPreserved: Bool
	}

	struct TimingPlan {
		let operations: [TimingOperation]
		/// When non-empty, this is the source of truth for orchestrating
		/// multi-lane / temporal prompts. Operations get derived from phases
		/// in Swift, replacing whatever the LLM emitted in `operations`. When
		/// empty, `operations` is used directly (single-lane prompts).
		let phases: [Phase]
	}

	struct Phase {
		let start: Double
		let end: Double
		/// One entry per lane active during this phase.
		let lanes: [PhaseLane]
	}

	struct PhaseLane {
		let lane: String
		/// "transition" - lane value moves from start of phase to end.
		/// "hold"       - lane value is held; the style pass may apply a
		///                modulation if the prompt asked for one.
		let kind: String
	}

	@MainActor
	static func planTiming(
		prompt: String,
		productContext: String,
		laneSchemaText: String,
		currentTimelineJSON: String,
		clipDurationSeconds: Double,
		currentInspectorMode: String,
		enableThinking: Bool
	) async throws -> TimingPlan {
		let dur = String(format: "%.3f", clipDurationSeconds)
		// Static instructions + pattern table + lane availability go in the
		// cacheable prefix (stable across runs). Dynamic per-call bits (clip
		// duration, mode, current timeline state) stay in `system`.
		let cachedPrefix = """
			Plan the keypose STRUCTURE for animation requests in \(productContext). \
			Your sole job: where do keyposes go, and is each interval a hold or a \
			transition? Easing curves and modulation are picked by a SEPARATE pass - \
			leave those alone here.

			Per keypose:
			- time: 0..1 fraction of clip ("N seconds" maps to N/duration).
			- interval_kind: kind of the interval to the NEXT keypose.
			    "hold"       - two surrounding keyposes share a value, no motion.
			    "transition" - value changes between this keypose and the next.
			    "none"       - REQUIRED on the LAST keypose (no interval after).
			- is_preserved: TRUE only when this keypose is a verbatim copy of an \
			  existing keypose that you are re-emitting unchanged from the current \
			  lane (same time, same role). FALSE for any keypose you are creating \
			  or modifying. When true, the existing value is used directly - the \
			  values pass never sees this keypose. Get this right: false-positives \
			  block the user's edits; false-negatives drop preserved values.

			Mode rules:
			- Basic: 2 keyposes at (0, 1), OR 3 keyposes at (0, boundary, 1) with \
			  exactly one hold + one transition.
			- Advanced: anywhere. Lanes extrapolate the first/last keypose's value \
			  outward, so no filler keyposes for unchanged edge regions.

			Pattern table. Substitute the formulas yourself.

			A) "from A to B" / "animate A to B" (whole clip): 2 keyposes.
			    [ (0, transition), (1, none) ]

			B) "in over N seconds" / "first N seconds" / "appear": 2 keyposes.
			    [ (0, transition), (N/dur, none) ]

			C) "out over N seconds" / "last N seconds" / "at the end": 2 keyposes.
			    [ (1 - N/dur, transition), (1, none) ]

			D) "in over Ni and out over No" / "X in, then back out": 4 keyposes.
			    [ (0, transition), (Ni/dur, hold), (1 - No/dur, transition), (1, none) ]

			E) "for N seconds in the middle" / "middle bump": 6 keyposes.
			    midStart = (1 - N/dur)/2; midEnd = midStart + N/dur.
			    [ (0, hold), (midStart - 0.05, transition), (midStart, hold), \
			      (midEnd, transition), (midEnd + 0.05, hold), (1, none) ]

			F) constant value / set X: 1 keypose.
			    [ (0, none) ]

			G) "wiggle radius" / "modulate X" / "shake": 2 keyposes.
			    [ (0, hold), (1, none) ]
			    (The hold interval will get a modulation chosen in the style pass.)

			I) "moves to X" / "change to Y" / "ends at Z" / "crop to X" / "to X" \
			   (end-state only, no start value given): the start keypose uses the \
			   lane's DEFAULT value (documented in the schema, e.g. Crop default \
			   = [1, 1, 0, 0], Radius default = 20).
			    [ (0, transition), (1, none) ]
			   Both keyposes NEW (is_preserved=false). The values pass picks the \
			   lane default for t=0 and the user's named destination for t=1.

			DEFAULT VALUES: the lane schema documents each lane's default. When a \
			pattern says "start = lane DEFAULT", emit a NEW (is_preserved=false) \
			keypose at that time and let the values pass fill in the default from \
			the schema. Never use is_preserved=true to mean "use the default" - \
			preservation always means "the value already at this exact time in \
			the current lane state."

			MULTI-LANE / TEMPORAL PROMPTS - use `phases` instead of operations.

			When the prompt mentions TWO OR MORE lanes, OR uses any temporal \
			connective ("and then", "then", "after", "first ... then", "once", \
			"whilst", "while", "at the same time", "simultaneously", "in \
			parallel", "during"), emit a `phases` array and leave `operations` \
			EMPTY. Swift derives the per-lane keyposes from the phases.

			A phase is a time range [start, end] (0..1 fractions of the clip) \
			with one entry per lane active during that range. Each lane entry \
			has a `kind`:
			  "transition" - the lane's value moves during this phase.
			  "hold"       - the lane's value is held; the style pass may add \
			                 a modulation if the prompt asked for one (wobble, \
			                 wiggle, oscillate, handheld).

			Examples:
			  "X and then Y" (sequential, two lanes):
			    phases = [
			      { start: 0.0, end: 0.5, lanes: [{ X, transition }] },
			      { start: 0.5, end: 1.0, lanes: [{ Y, transition }] }
			    ]

			  "X whilst Y" (parallel, two lanes):
			    phases = [
			      { start: 0.0, end: 1.0, lanes: [
			          { X, transition }, { Y, transition }
			        ] }
			    ]

			  "X and Y in parallel, then Z" (mixed, three lanes):
			    phases = [
			      { start: 0.0, end: 0.66, lanes: [
			          { X, transition }, { Y, transition }
			        ] },
			      { start: 0.66, end: 1.0, lanes: [{ Z, transition }] }
			    ]

			  "wobble X whilst Y moves to Q" (parallel, one hold + one transition):
			    phases = [
			      { start: 0.0, end: 1.0, lanes: [
			          { X, hold }, { Y, transition }
			        ] }
			    ]

			Boundaries: equal-share split unless the prompt specifies otherwise. \
			Two sequential lanes split at 0.5; three at 0.33 and 0.66; etc. \
			Explicit durations override the equal-share rule (e.g. "X for 1s \
			then Y" with a 4s clip → split at 0.25).

			Single-lane / partial-edit prompts: emit `operations` as before and \
			leave `phases` empty. Phases are ONLY for multi-lane orchestration.

			PARTIAL EDIT (critical): if the user names a REGION ("left", "right", \
			"middle", "first/last N", "around 3s", "the existing animation", "the \
			current timeline"), keyposes OUTSIDE that region must be re-emitted \
			verbatim. Walk the current lane's keyposes, copy each one outside the \
			edit region with the same time and interval_kind, then splice in the \
			new region.

			Available lanes:
			\(laneSchemaText.components(separatedBy: "\n").prefix(8).joined(separator: "\n"))
			"""
		let system = """
			Clip duration: \(dur)s. Mode: \(currentInspectorMode).

			Current timeline state (for partial-edit context):
			\(currentTimelineJSON)
			"""
		let raw = try await AIStructuredCall.call(
			system: system,
			cachedSystemPrefix: cachedPrefix,
			userMessage: prompt,
			schemaName: "plan_timing",
			schemaDescription:
				"Lay out lane keypose times and whether each interval is a hold or a transition.",
			jsonSchema: timingPlanSchema(),
			enableThinking: enableThinking
		)
		return parseTimingPlan(raw)
	}

	/// Schema for Pass 1's output: optional `operations` (single-lane shape)
	/// + optional `phases` (multi-lane orchestration). Exactly one is
	/// populated per prompt - the other comes back as an empty array.
	private static func timingPlanSchema() -> [String: Any] {
		let kinds = ["hold", "transition", "none"]
		let keyposeSchema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["time", "interval_kind", "is_preserved"],
			"properties": [
				"time": ["type": "number"],
				"interval_kind": ["type": "string", "enum": kinds],
				"is_preserved": ["type": "boolean"],
			],
		]
		let operationSchema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["lane", "keyposes"],
			"properties": [
				"lane": ["type": "string"],
				"keyposes": ["type": "array", "items": keyposeSchema],
			],
		]
		let phaseLaneSchema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["lane", "kind"],
			"properties": [
				"lane": ["type": "string"],
				"kind": ["type": "string", "enum": ["transition", "hold"]],
			],
		]
		let phaseSchema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["start", "end", "lanes"],
			"properties": [
				"start": ["type": "number"],
				"end": ["type": "number"],
				"lanes": ["type": "array", "items": phaseLaneSchema],
			],
		]
		return [
			"type": "object",
			"additionalProperties": false,
			"required": ["operations", "phases"],
			"properties": [
				"operations": ["type": "array", "items": operationSchema],
				"phases": ["type": "array", "items": phaseSchema],
			],
		]
	}

	private static func parseTimingPlan(_ raw: String) -> TimingPlan {
		let data = raw.data(using: .utf8) ?? Data()
		let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		let root = obj ?? [:]

		let opsRaw = root["operations"] as? [[String: Any]] ?? []
		let operations: [TimingOperation] = opsRaw.compactMap { d in
			guard let lane = d["lane"] as? String,
				let kpsRaw = d["keyposes"] as? [[String: Any]]
			else { return nil }
			let kps: [TimingKeypose] = kpsRaw.compactMap { k in
				guard let t = (k["time"] as? NSNumber)?.doubleValue,
					let kind = k["interval_kind"] as? String
				else { return nil }
				let preserved = (k["is_preserved"] as? Bool) ?? false
				return TimingKeypose(
					time: t, intervalKind: kind, isPreserved: preserved)
			}
			return TimingOperation(lane: lane, keyposes: kps)
		}

		let phasesRaw = root["phases"] as? [[String: Any]] ?? []
		let phases: [Phase] = phasesRaw.compactMap { d in
			guard let s = (d["start"] as? NSNumber)?.doubleValue,
				let e = (d["end"] as? NSNumber)?.doubleValue,
				let lanesRaw = d["lanes"] as? [[String: Any]]
			else { return nil }
			let lanes: [PhaseLane] = lanesRaw.compactMap { l in
				guard let lane = l["lane"] as? String,
					let kind = l["kind"] as? String
				else { return nil }
				return PhaseLane(lane: lane, kind: kind)
			}
			return Phase(start: s, end: e, lanes: lanes)
		}

		return TimingPlan(operations: operations, phases: phases)
	}

	/// Project a phase plan into per-lane TimingOperations. Each lane gets
	/// keyposes at the boundaries of every phase it appears in:
	/// - First keypose of a phase: interval_kind = the phase's kind for the
	///   lane (transition or hold).
	/// - Last keypose of a phase, when another phase for the same lane
	///   follows: interval_kind = "hold" (lane holds its value across the gap).
	/// - Last keypose of the lane's final phase: interval_kind = "none".
	/// `is_preserved` is always false in this path - phase-derived starts
	/// use lane defaults (per pattern I), not the current state.
	static func deriveOperationsFromPhases(_ phases: [Phase])
		-> [TimingOperation]
	{
		var byLane: [String: [(start: Double, end: Double, kind: String)]] = [:]
		for phase in phases {
			for ln in phase.lanes {
				byLane[ln.lane, default: []].append(
					(start: phase.start, end: phase.end, kind: ln.kind))
			}
		}
		var operations: [TimingOperation] = []
		for (lane, rawRanges) in byLane {
			let ranges = rawRanges.sorted { $0.start < $1.start }
			var kps: [TimingKeypose] = []
			for (i, range) in ranges.enumerated() {
				kps.append(
					TimingKeypose(
						time: range.start, intervalKind: range.kind,
						isPreserved: false))
				let isLastRange = i == ranges.count - 1
				let endKind = isLastRange ? "none" : "hold"
				kps.append(
					TimingKeypose(
						time: range.end, intervalKind: endKind, isPreserved: false))
			}
			operations.append(TimingOperation(lane: lane, keyposes: kps))
		}
		return operations.sorted { $0.lane < $1.lane }
	}
}
