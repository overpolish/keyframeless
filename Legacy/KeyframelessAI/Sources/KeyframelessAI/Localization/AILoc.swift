/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Localizes against KeyframelessAI's own bundle.
///
/// Keyframeless X (an app target) localizes with a bare `String(localized:)`,
/// which resolves against `Bundle.main`. That works there because the app *is*
/// main. KeyframelessAI's SwiftUI views, however, also render inside FxPlug
/// plugins running in an XPC process where `Bundle.main` is the Final Cut Pro
/// host - not us - so the default lookup would miss our catalog entirely.
///
/// Pinning to `.module` mirrors KeyframelessKit's `KKLoc` / `bundleForClass`
/// pattern and keeps resolution deterministic in both contexts. Use this for
/// every user-facing string in this package; never a bare `String(localized:)`.
public func AILoc(_ key: String.LocalizationValue) -> String {
	String(localized: key, bundle: .module)
}
