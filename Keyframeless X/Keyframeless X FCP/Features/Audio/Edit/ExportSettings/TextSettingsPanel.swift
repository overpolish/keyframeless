/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct TextSettingsPanel: View {
	@ObservedObject var model: AudioModel

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			FontPickerRow(
				selectedFont: $model.textFont,
				textColorR: $model.textColorR,
				textColorG: $model.textColorG,
				textColorB: $model.textColorB,
				textColorA: $model.textColorA,
			)
			LabeledSlider(
				label: String(localized: "Font Size"), value: $model.textSize, range: 10...200,
				suffix: "pt")
			LabeledSlider(
				label: String(localized: "Text Width"), value: $model.textWidthPercent,
				range: 10...100,
				suffix: "%")
			LabeledSlider(
				label: String(localized: "Y Position"), value: $model.textYPosition, range: 0...100,
				suffix: "%")
		}
	}
}
