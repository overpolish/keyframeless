/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import Foundation

/// ObjC-callable surface for registering plugin docs at process start.
/// FxPlug plugins (Rounded, Canvas, …) call these from their ObjC plugin
/// init to wire the shared timeline docs + their own per-plugin bundle.
@objc(KKAIKnowledge)
public final class AIKnowledgeBridge: NSObject {
	/// Canonical ids of the shared timeline knowledge docs. They now live in the
	/// KeyframelessKit framework bundle (flattened to its Resources root, like
	/// the OSC docs) so the kit's own help window can render the same source.
	/// The registering plugin passes that bundle and we filter to just these
	/// topics, keeping the OSC docs + README out of this group.
	private static let sharedTimelineTopicIDs: [String] = [
		"timeline-basics", "basic-vs-advanced", "easing", "modulation",
		"animated-properties", "multi-component-properties", "value-editing",
		"motion-blur", "snap-guides", "constants-panel", "inspector-controls",
		"mini-viewer", "clip-space-and-wrapping", "guides", "shortcuts",
		"presets", "lane-filter", "expressions",
	]

	@MainActor
	@objc public static func registerSharedTimelineDocs(bundle: Bundle) {
		AIKnowledgeRegistry.shared.register(
			BundleMarkdownKnowledgeProvider(
				name: "Keyframeless Timeline",
				bundle: bundle,
				subdirectory: nil,
				onlyTopicIDs: Set(sharedTimelineTopicIDs)
			)
		)
	}

	@MainActor
	@objc public static func registerBundleDocs(
		name: String,
		bundle: Bundle,
		subdirectory: String?
	) {
		AIKnowledgeRegistry.shared.register(
			BundleMarkdownKnowledgeProvider(
				name: name,
				bundle: bundle,
				subdirectory: subdirectory
			)
		)
	}

	/// Register a subset of markdown topics from a shared docs folder. Used
	/// for the KeyframelessKit OSCKnowledge folder so each plugin gets only
	/// the OSC docs it actually exposes (rotation, position, arc, etc).
	@MainActor
	@objc public static func registerBundleDocs(
		name: String,
		bundle: Bundle,
		subdirectory: String?,
		onlyTopicIDs: [String]
	) {
		AIKnowledgeRegistry.shared.register(
			BundleMarkdownKnowledgeProvider(
				name: name,
				bundle: bundle,
				subdirectory: subdirectory,
				onlyTopicIDs: Set(onlyTopicIDs)
			)
		)
	}

	/// Register a single in-memory topic whose `content` is markdown the host
	/// GENERATED (not a bundle file) - e.g. a function reference rendered from
	/// the editor's own vocabulary catalog, so the AI's list can never drift
	/// from the autocomplete. `name` namespaces it (dedup is by name).
	@MainActor
	@objc public static func registerInlineDoc(
		name: String,
		topicID: String,
		summary: String,
		content: String
	) {
		AIKnowledgeRegistry.shared.register(
			InlineKnowledgeProvider(
				name: name,
				topic: AIKnowledgeTopic(
					id: topicID, summary: summary, content: content
				)
			)
		)
	}
}

/// A knowledge provider wrapping a single host-supplied topic (markdown string),
/// for content generated at runtime rather than loaded from a bundle file.
private struct InlineKnowledgeProvider: AIKnowledgeProvider {
	let name: String
	let topic: AIKnowledgeTopic
	func topics() async -> [AIKnowledgeTopic] { [topic] }
}
