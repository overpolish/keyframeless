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
	@State private var updateMessage: String?
	@State private var updateURL: URL?
	@State private var updateDismissed = Self.dismissed
	private static var dismissed = false

	var body: some View {
		VStack(spacing: KKSpacingMD) {
			if let message = updateMessage, !updateDismissed {
				UpdateBanner(
					message: message,
					url: updateURL,
					onDismiss: {
						withAnimation { updateDismissed = true }
						Self.dismissed = true
					}
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
				&& !processingCoordinator.isProcessing
		)
		.background(Color(nsColor: .windowBackground()))
		.onAppear {
			FontCache.warmup()
			KKUpdateChecker.shared().check { available in
				guard available else { return }
				let checker = KKUpdateChecker.shared()
				withAnimation {
					updateMessage = Self.updateMessage(from: checker)
					updateURL = checker.downloadURL
				}
			}
		}
		.overlay {
			if processingCoordinator.isProcessing {
				ProcessingOverlay(
					statusLabel: processingCoordinator.statusLabel,
					progress: processingCoordinator.progress,
					estimatedTimeRemaining: processingCoordinator.estimatedTimeRemaining,
					onCancel: { processingCoordinator.cancel() }
				)
				.transition(.opacity)
			}
			if let template = audioModel.paramsModalTemplate {
				PublishedParamsModal(
					templateName: template.name,
					params: audioModel.paramsModalParams,
					hasPerWordAnimation: audioModel.paramsModalHasPerWord,
					initialKinds: TemplatePublishedParamsStore.shared.kindMap(
						for: template.id),
					initialPerWordStartsAtZero: TemplatePublishedParamsStore.shared
						.params(for: template.id)?.perWordStartsAtZero ?? false,
					onSave: { params, perWordStartsAtZero in
						TemplatePublishedParamsStore.shared.setParams(
							params,
							hasPerWordAnimation: audioModel.paramsModalHasPerWord,
							for: template.id)
						TemplatePublishedParamsStore.shared.setPerWordStartsAtZero(
							perWordStartsAtZero, for: template.id)
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

	private static func updateMessage(from checker: KKUpdateChecker) -> String {
		var parts: [String] = []
		if let version = checker.availableVersion {
			parts.append("Keyframeless X \(version) available")
		}
		for key in checker.availableComponentKeys {
			parts.append("\(key) now available")
		}
		return parts.joined(separator: " · ")
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
