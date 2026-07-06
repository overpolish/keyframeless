/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct TemplateParamsPanel: View {
	let template: CaptionTemplate
	@ObservedObject var store: TemplatePublishedParamsStore

	private var enabledParams: [PublishedParameter] {
		guard let settings = store.params(for: template.id) else { return [] }
		return settings.allParams.filter { $0.isToggleable && !$0.isFont && !$0.isTextSize }
	}

	private var fontParams: [PublishedParameter] {
		guard let settings = store.params(for: template.id) else { return [] }
		return settings.allParams.filter(\.isFont)
	}

	private var hasParams: Bool {
		!enabledParams.isEmpty || !fontParams.isEmpty
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingMD) {
			if hasParams {
				ScrollShadowView(cornerRadius: KKRadiusSM) {
					VStack(alignment: .leading, spacing: KKSpacingLG) {
						ForEach(enabledParams) { param in
							ParamControlRow(
								param: param, templateID: template.id,
								store: store, compact: true)
						}
						ForEach(fontParams) { param in
							FontControlRow(
								param: param, templateID: template.id,
								store: store, compact: true)
						}
					}
					.padding(.vertical, KKPaddingXS)
				}
			} else {
				Spacer()
				Text("No options to customise")
					.font(.system(size: 9))
					.foregroundStyle(.secondary.opacity(0.6))
					.multilineTextAlignment(.center)
					.frame(maxWidth: .infinity)
				Spacer()
			}
		}
		.frame(maxHeight: .infinity)
	}
}
