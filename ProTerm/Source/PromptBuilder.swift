import Foundation

/// Builds the terminal prompt string from basic context. This is deliberately
/// minimal and independent; owners can extend with git or other integrations.
struct PromptBuilder {
    struct Context {
        var user: String?
        var host: String?
        var cwd: String?
        var promptSymbol: String = "$"
    }

    func build(_ ctx: Context) -> String {
        let user = ctx.user ?? NSUserName()
        let host = ctx.host ?? Host.current().localizedName ?? "localhost"
        let dir = ctx.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "~"
        return "\(user)@\(host) \(dir) \(ctx.promptSymbol) "
    }
}
