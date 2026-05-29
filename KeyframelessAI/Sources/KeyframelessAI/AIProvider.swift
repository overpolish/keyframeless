import Foundation

public enum AIProvider: String, CaseIterable, Identifiable, Sendable {
	case anthropic
	case openai

	public var id: String { rawValue }

	public var displayName: String {
		switch self {
		case .anthropic: return "Claude"
		case .openai: return "ChatGPT"
		}
	}

	public var keyConsoleURL: URL {
		switch self {
		case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
		case .openai: return URL(string: "https://platform.openai.com/api-keys")!
		}
	}

	public var keyPrefixHint: String {
		switch self {
		case .anthropic: return "sk-ant-"
		case .openai: return "sk-"
		}
	}
}
