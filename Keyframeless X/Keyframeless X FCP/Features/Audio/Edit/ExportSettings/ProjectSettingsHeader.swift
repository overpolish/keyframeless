/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct ProjectSettingsHeader: View {
	@ObservedObject var model: AudioModel

	private var projectFormat: FCPXMLParser.ProjectFormat {
		model.projectFormat ?? .default
	}

	private var hasChanges: Bool {
		model.exportWidth != "\(projectFormat.width)"
			|| model.exportHeight != "\(projectFormat.height)"
			|| model.exportFramerate != Framerate.from(frameDuration: projectFormat.frameDuration)
	}

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text("Project Settings")
				.font(.caption)
				.foregroundStyle(.secondary)
			Spacer()
			if hasChanges {
				Button {
					model.exportWidth = "\(projectFormat.width)"
					model.exportHeight = "\(projectFormat.height)"
					model.exportFramerate = Framerate.from(
						frameDuration: projectFormat.frameDuration)
				} label: {
					Image(systemName: "arrow.uturn.backward")
						.font(.system(size: 10))
						.padding(.horizontal, KKPaddingSM)
						.padding(.vertical, KKSpacingSM)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.foregroundStyle(.secondary)
			}
			IntegerField(placeholder: "Width", text: $model.exportWidth, min: 60, max: 7680)
				.frame(width: 60)
			Text("\u{00d7}")
				.foregroundStyle(.secondary)
			IntegerField(placeholder: "Height", text: $model.exportHeight, min: 60, max: 4320)
				.frame(width: 60)
			FrameratePickerButton(selection: $model.exportFramerate)
		}
	}
}
