import Foundation

enum AppAutomation {
    static let uiTestingArgument = "-callmate-ui-testing"
    static let forceMainStateArgument = "-callmate-ui-force-main"
    static let skipExternalBootstrapArgument = "-callmate-ui-skip-bootstrap"
    static let languageArgument = "-callmate-ui-language"
    static let seedCallsArgument = "-callmate-ui-seed-calls"

    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestingArgument)
    }

    static var forceMainState: Bool {
        isUITesting && ProcessInfo.processInfo.arguments.contains(forceMainStateArgument)
    }

    static var shouldSkipExternalBootstrap: Bool {
        isUITesting && (
            ProcessInfo.processInfo.arguments.contains(skipExternalBootstrapArgument) ||
            forceMainState
        )
    }

    static var preferredLanguage: Language? {
        guard let rawValue = argumentValue(after: languageArgument) else { return nil }
        return Language(rawValue: rawValue)
    }

    static var seededCallCount: Int? {
        guard let rawValue = argumentValue(after: seedCallsArgument) else { return nil }
        guard let count = Int(rawValue), count > 0 else { return nil }
        return count
    }

    static var shouldUseEphemeralPersistence: Bool {
        isUITesting
    }

    private static func argumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
