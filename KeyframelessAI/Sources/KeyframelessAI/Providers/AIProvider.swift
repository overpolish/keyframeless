import Foundation

public enum AIProvider: String, CaseIterable, Identifiable, Sendable {
	// Order drives the picker; Local is listed first (Apple Silicon only).
	case local
	case anthropic
	case openai

	public var id: String { rawValue }

	/// Cases offered to the user. Local is hidden unless the machine supports it
	/// (Apple Silicon with >=16 GB RAM); otherwise only the cloud providers show.
	public static var availableCases: [AIProvider] {
		AIPlatform.supportsLocal ? allCases : allCases.filter { $0 != .local }
	}

	public var displayName: String {
		switch self {
		case .anthropic: return "Claude"
		case .openai: return "ChatGPT"
		case .local: return AILoc("Local")
		}
	}

	/// Cloud providers authenticate with a BYOK API key. The local provider
	/// authenticates with nothing - it's gated on a downloaded model instead -
	/// so the key-entry plumbing (Keychain, validator, console link) is skipped
	/// for it and the config tab shows a model-manager view instead.
	public var requiresAPIKey: Bool {
		switch self {
		case .anthropic, .openai: return true
		case .local: return false
		}
	}

	public var keyConsoleURL: URL? {
		switch self {
		case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
		case .openai: return URL(string: "https://platform.openai.com/api-keys")
		case .local: return nil
		}
	}

	public var keyPrefixHint: String? {
		switch self {
		case .anthropic: return "sk-ant-"
		case .openai: return "sk-"
		case .local: return nil
		}
	}
}
