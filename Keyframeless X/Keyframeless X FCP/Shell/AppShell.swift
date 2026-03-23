/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct AppShell: View {
	@ObservedObject var audioModel: AudioModel
	@StateObject private var whisperManager = WhisperModelManager()
	@StateObject private var processingCoordinator = AudioProcessingCoordinator()
	@State private var selectedTab: AppTab = .audio
	@State private var updateVersion: String?
	@State private var updateURL: URL?
	@State private var updateDismissed = false

	var body: some View {
		VStack(spacing: KKSpacingMD) {
			if let version = updateVersion, !updateDismissed {
				UpdateBanner(
					version: version,
					url: updateURL,
					onDismiss: { withAnimation { updateDismissed = true } }
				)
				.transition(.move(edge: .top).combined(with: .opacity))
			}
			topBar
			Group {
				switch selectedTab {
				case .audio:
					switch audioModel.stage {
					case .setup:
						AudioSetupView(
							model: audioModel,
							whisperManager: whisperManager,
							onProcess: { replaceAll in
								if replaceAll {
									audioModel.editSelectedClips = nil
								}
								withAnimation(.easeInOut(duration: 0.3)) {
									processingCoordinator.isProcessing = true
								}
								processingCoordinator.process(
									model: audioModel,
									whisperManager: whisperManager,
									replaceAll: replaceAll
								)
							}
						)
					case .edit:
						AudioEditView(model: audioModel)
					}
				}
			}
		}
		.padding([.horizontal, .bottom], KKPadding2XL)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.blur(
			radius: audioModel.isDraggingToFCP || audioModel.paramsModalTemplate != nil
				|| audioModel.publishModalTemplate != nil ? 3 : 0
		)
		.animation(.easeInOut(duration: 0.2), value: audioModel.isDraggingToFCP)
		.allowsHitTesting(
			audioModel.paramsModalTemplate == nil && audioModel.publishModalTemplate == nil
		)
		.background(Color(nsColor: .windowBackground()))
		.onAppear {
			FontCache.warmup()
			KKUpdateChecker.shared().check { available in
				guard available else { return }
				withAnimation {
					updateVersion = KKUpdateChecker.shared().latestVersion
					updateURL = KKUpdateChecker.shared().downloadURL
				}
			}
		}
		.overlay {
			if processingCoordinator.isProcessing {
				ProcessingOverlay(
					statusLabel: processingCoordinator.statusLabel,
					progress: processingCoordinator.progress,
					onCancel: { processingCoordinator.cancel() }
				)
				.transition(.opacity)
			}
			if let template = audioModel.paramsModalTemplate {
				PublishedParamsModal(
					templateName: template.name,
					params: audioModel.paramsModalParams,
					hasPerWordAnimation: audioModel.paramsModalHasPerWord,
					initialEnabled: TemplatePublishedParamsStore.shared.params(for: template.id)?
						.enabledIDs ?? [],
					onSave: { enabledIDs in
						TemplatePublishedParamsStore.shared.setParams(
							audioModel.paramsModalParams, enabledIDs: enabledIDs,
							hasPerWordAnimation: audioModel.paramsModalHasPerWord,
							for: template.id)
						audioModel.paramsModalTemplate = nil
					},
					onDismiss: { audioModel.paramsModalTemplate = nil }
				)
				.transition(.opacity)
			}
			if let template = audioModel.publishModalTemplate {
				TemplatePublishModal(
					template: template,
					params: TemplatePublishedParamsStore.shared.params(for: template.id)?
						.allParams ?? [],
					hasPerWordAnimation: template.supportsPerWordAnimation,
					enabledIDs: TemplatePublishedParamsStore.shared.params(for: template.id)?
						.enabledIDs ?? [],
					onDismiss: { audioModel.publishModalTemplate = nil }
				)
				.transition(.opacity)
			}
		}
		.animation(.easeInOut(duration: 0.2), value: audioModel.paramsModalTemplate != nil)
		.animation(.easeInOut(duration: 0.2), value: audioModel.publishModalTemplate != nil)
	}

	private var topBar: some View {
		HStack {
			PillTabBar(selected: $selectedTab)
			Spacer()
			toolNav
		}
		.overlay {
			Image("keyframeless-logo")
				.resizable()
				.scaledToFit()
				.frame(width: 36)
				.opacity(0.15)
		}
	}

	@ViewBuilder
	private var toolNav: some View {
		switch selectedTab {
		case .audio:
			PillIconToggle<AudioModel.Stage>(
				selection: $audioModel.stage,
				options: [
					(
						label: "Setup", systemImage: "sparkles.rectangle.stack.fill",
						value: .setup
					),
					(label: "Edit", systemImage: "bubble.and.pencil", value: .edit),
				],
				disabledValues: audioModel.audioClips.isEmpty ? [.edit] : []
			)
		}
	}
}
