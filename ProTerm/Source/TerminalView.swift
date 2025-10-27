import SwiftUI
import Foundation

/// Ultra-minimal TerminalView with ZERO complexity
struct TerminalView: View {
    @ObservedObject var session: TerminalSession
    @State private var commandInput: String = ""
    @State private var passwordInput: String = ""
    @State private var showPasswordInput: Bool = false
    @EnvironmentObject private var lineNumbersManager: LineNumbersManager
    
    var body: some View {
        VStack(spacing: 0) {
            // Terminal output area
            terminalOutputView
            
            // Input area
            inputView
        }
        .onReceive(NotificationCenter.default.publisher(for: .copySelectedText)) { _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.output, forType: .string)
        }
        .onChange(of: session.output) {
            checkForPasswordPrompt()
        }
    }
    
    private var terminalOutputView: some View {
        ZStack {
            Color.black.opacity(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            HStack(alignment: .top, spacing: 0) {
                if lineNumbersManager.showLineNumbers {
                    LineNumbersView(text: session.output)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.leading, 10)
                        .padding(.trailing, 5)
                }
                
                TextEditor(text: .constant(session.output))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.clear)
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .disabled(true)
                    .accentColor(.green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture {
            // BULLETPROOF: This captures ALL clicks in the terminal area
        }
    }
    
    private var inputView: some View {
        Group {
            if showPasswordInput {
                passwordInputView
            } else {
                commandInputView
            }
        }
    }
    
    private var passwordInputView: some View {
        HStack {
            Text("Password: ")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.yellow)
            
            SecureField("Enter password", text: $passwordInput, onCommit: {
                if !passwordInput.isEmpty {
                    session.sendInput(passwordInput)
                    passwordInput = ""
                    showPasswordInput = false
                }
            })
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.white)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black as Color)
    }
    
    private var commandInputView: some View {
        HStack {
            Text(session.prompt)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.green)
            
            TextField("Enter command", text: $commandInput, onCommit: {
                if !commandInput.isEmpty {
                    session.runCommand(commandInput)
                    commandInput = ""
                }
            })
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.white)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black as Color)
    }
    
    private func checkForPasswordPrompt() {
        let output = session.output
        let lowercasedOutput = output.lowercased()
        
        // Check for various password prompt patterns
        if lowercasedOutput.contains("password:") || 
           lowercasedOutput.contains("enter password") || 
           lowercasedOutput.contains("sudo password") ||
           lowercasedOutput.contains("password for") ||
           output.contains("Password:") ||
           output.contains("password for") {
            showPasswordInput = true
        } else if output.contains(session.prompt) && showPasswordInput {
            showPasswordInput = false
        }
    }
}

// MARK: - Line Numbers View
struct LineNumbersView: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            let lines = text.components(separatedBy: .newlines)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, _ in
                Text("\(index + 1)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(height: 20, alignment: .trailing)
            }
        }
    }
}