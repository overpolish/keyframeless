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
	@MainActor
	@objc public static func registerSharedTimelineDocs() {
		AIKnowledgeRegistry.shared.register(
			BundleMarkdownKnowledgeProvider(
				name: "Keyframeless Timeline",
				bundle: .module,
				subdirectory: "TimelineKnowledge"
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
}
