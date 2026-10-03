import Foundation
import os.log

/// PTY / submit diagnostics. Filter Console.app with `ProTermPTY`.
/// Toggle: `defaults write com.proterm.app ProTermPTYDebug -bool false` (bundle id may vary in dev).
enum ProTermPTYDebug {
    private static let logger = Logger(subsystem: "com.proterm.app", category: "PTY")
    private static let userDefaultsKey = "ProTermPTYDebug"

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: userDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        logger.log("\(message, privacy: .public)")
    }

    static func repr(_ text: String, maxLength: Int = 120) -> String {
        var s = ""
        for scalar in text.unicodeScalars.prefix(maxLength) {
            switch scalar.value {
            case 0x0A: s += "\\n"
            case 0x0D: s += "\\r"
            case 0x09: s += "\\t"
            case 0x07: s += "\\a"
            case 0x1B: s += "\\e"
            default:
                if scalar.value < 0x20 {
                    s += String(format: "\\u{%04X}", scalar.value)
                } else {
                    s.append(Character(scalar))
                }
            }
        }
        if text.unicodeScalars.count > maxLength {
            s += "…(\(text.count) chars)"
        }
        return "\"\(s)\""
    }

    struct PTYFlags: CustomStringConvertible {
        var isProcessRunning: Bool
        var isLoginShellActive: Bool
        var isSSHSession: Bool
        var isShuttingDown: Bool
        var masterFD: Int32
        var childPID: pid_t
        var pidAlive: Bool
        var fdValid: Bool
        var hasPTYHandler: Bool
        var outputLength: Int
        var shellPromptLine: String

        var description: String {
            "running=\(isProcessRunning) loginShell=\(isLoginShellActive) ssh=\(isSSHSession) "
                + "shuttingDown=\(isShuttingDown) masterFD=\(masterFD) childPID=\(childPID) "
                + "pidAlive=\(pidAlive) fdValid=\(fdValid) ptyHandler=\(hasPTYHandler) "
                + "outputLen=\(outputLength) shellPrompt=\(repr(shellPromptLine, maxLength: 60))"
        }
    }
}
