/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import SwiftUI

/// ObjC-callable factory that builds an `NSHostingView` wrapping the SwiftUI
/// `AIButton`. FxPlug plugin banners use this to
/// reuse the workflow-ext button design without pulling SwiftUI into
/// KeyframelessKit.
@objc(KKAIBannerHost)
public final class AIBannerHost: NSObject {
	@MainActor
	@objc public static func makeButton(
		productContext: String,
		examplePairs: [[String]],
		placeholder: String,
		onRun: @escaping (String) -> Void
	) -> NSView {
		makeButtonInternal(
			productContext: productContext,
			examplePairs: examplePairs,
			placeholder: placeholder,
			isPluginMode: false,
			onRun: onRun
		)
	}

	/// Plugin variant: bypasses the built-in Steno router. The popover's Run
	/// button calls `onRun` directly with the raw prompt; the plugin is
	/// responsible for invoking `AIPluginAgent` and driving `KKAIDraft` to
	/// show the spinner/answer/error in the popover. The popover does NOT
	/// auto-dismiss after Run.
	@MainActor
	@objc public static func makePluginButton(
		productContext: String,
		examplePairs: [[String]],
		placeholder: String,
		onRun: @escaping (String) -> Void
	) -> NSView {
		makeButtonInternal(
			productContext: productContext,
			examplePairs: examplePairs,
			placeholder: placeholder,
			isPluginMode: true,
			onRun: onRun
		)
	}

	/// The standard `aiAccessoryView` spine: the plugin variant above PLUS the
	/// "Keyframeless AI update available" banner wiring. `checkForAIUpdate`
	/// runs the host's update check (the plugin owns `KKUpdateChecker`; this
	/// package can't import KeyframelessKit) and reports the available version
	/// + notes URL through its completion, which lands in the popover via
	/// `KKAIUpdate`. Plugins supply only their product context, examples,
	/// placeholder and run handler.
	@MainActor
	@objc public static func makeStandardPluginButton(
		productContext: String,
		examplePairs: [[String]],
		placeholder: String,
		checkForAIUpdate: @escaping (@escaping (String?, String?) -> Void) -> Void,
		onRun: @escaping (String) -> Void
	) -> NSView {
		AIUpdateBridge.setCheckHandler {
			checkForAIUpdate { version, notesURL in
				AIUpdateBridge.setAvailableVersion(version, notesURL: notesURL)
			}
		}
		return makePluginButton(
			productContext: productContext,
			examplePairs: examplePairs,
			placeholder: placeholder,
			onRun: onRun
		)
	}

	@MainActor
	private static func makeButtonInternal(
		productContext: String,
		examplePairs: [[String]],
		placeholder: String,
		isPluginMode: Bool,
		onRun: @escaping (String) -> Void
	) -> NSView {
		let examples = examplePairs.compactMap { pair -> AIPromptExample? in
			guard pair.count == 2 else { return nil }
			return AIPromptExample(label: pair[0], value: pair[1])
		}
		let button = AIButton(
			selectedCount: 0,
			productContext: productContext,
			examples: examples,
			placeholder: placeholder,
			isPluginMode: isPluginMode,
			onRun: onRun
		)
		let host = NSHostingView(rootView: button)
		host.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			host.widthAnchor.constraint(equalToConstant: 22),
			host.heightAnchor.constraint(equalToConstant: 22),
		])
		return host
	}
}
