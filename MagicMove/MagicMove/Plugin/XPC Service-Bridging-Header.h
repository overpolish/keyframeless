// Bridging header for the MagicMove XPC Service target.
// Empty: the local-LLM Swift runner imports KeyframelessAI / LocalLLMClient
// as modules and needs nothing from ObjC here. This file only exists so the
// (pre-existing) SWIFT_OBJC_BRIDGING_HEADER build setting resolves once Swift
// compilation is enabled by adding the first .swift file.
