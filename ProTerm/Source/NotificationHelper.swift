// NotificationHelper.swift
import UserNotifications
import Foundation
import SwiftUI
import AppKit
import Combine

final class NotificationHelper: @unchecked Sendable {
    static let shared = NotificationHelper()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                print("User denied notification permission.")
            }
        }
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

// MARK: - Toast Notification Manager
@MainActor
class ToastManager: ObservableObject {
    static let shared = ToastManager()
    
    @Published var toasts: [Toast] = []
    
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let icon: String
        let type: ToastType
        
        enum ToastType {
            case success
            case error
            case info
            case warning
        }
    }
    
    func show(_ message: String, type: Toast.ToastType = .info, icon: String? = nil) {
        let toast = Toast(
            message: message,
            icon: icon ?? iconForType(type),
            type: type
        )
        toasts.append(toast)
        
        // Auto-dismiss after 3 seconds
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                if let index = toasts.firstIndex(where: { $0.id == toast.id }) {
                    _ = withAnimation(.easeOut(duration: 0.2)) {
                        toasts.remove(at: index)
                    }
                }
            }
        }
    }
    
    private func iconForType(_ type: Toast.ToastType) -> String {
        switch type {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Toast View
struct ToastView: View {
    let toast: ToastManager.Toast
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.icon)
                .foregroundColor(colorForType(toast.type))
            Text(toast.message)
                .font(.caption)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
    
    private func colorForType(_ type: ToastManager.Toast.ToastType) -> Color {
        switch type {
        case .success: return .green
        case .error: return .red
        case .info: return .blue
        case .warning: return .orange
        }
    }
}

// MARK: - Toast Container
struct ToastContainer: View {
    @ObservedObject var toastManager = ToastManager.shared
    
    var body: some View {
        VStack {
            ForEach(toastManager.toasts) { toast in
                ToastView(toast: toast)
            }
            Spacer()
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }
}

// MARK: - Global Notification Names
extension Notification.Name {
    // Session & Terminal
    static let directoryChanged = Notification.Name("ProTermDirectoryChanged")
    static let terminalTitleDidChange = Notification.Name("ProTermTerminalTitleDidChange")
    static let sshPTYOutput = Notification.Name("ProTermSSHPTYOutput")
    static let sshPTYExit = Notification.Name("ProTermSSHPTYExit")
    static let proTermTerminalColumnsDidChange = Notification.Name("ProTermTerminalColumnsDidChange")
    static let focusCommandInput = Notification.Name("ProTermFocusCommandInput")
    static let terminalBell = Notification.Name("ProTermTerminalBell")
    static let selectAllTerminal = Notification.Name("ProTermSelectAllTerminal")
    static let showCommandPalette = Notification.Name("ProTermShowCommandPalette")
    static let resumeProcess = Notification.Name("ProTermResumeProcess")
    static let paginationKeySent = Notification.Name("ProTermPaginationKeySent")
    static let sshSessionClosed = Notification.Name("ProTermSSHSessionClosed")
    
    // Preferences & UI
    static let proTermIOSettingsDidChange = Notification.Name("ProTermIOSettingsDidChange")
    static let closePreferences = Notification.Name("ProTermClosePreferences")
    static let showPreferences = Notification.Name("ProTermShowPreferences")
    
    // Search & Edit
    static let searchInTerminal = Notification.Name("ProTermSearchInTerminal")
    static let findInTerminal = Notification.Name("ProTermFindInTerminal")
    static let setSearchRegexMode = Notification.Name("ProTermSetSearchRegexMode")
    static let replaceInTerminal = Notification.Name("ProTermReplaceInTerminal")
    static let quickSearch = Notification.Name("ProTermQuickSearch")
    
    // Commands & History
    static let copySelectedText = Notification.Name("ProTermCopySelectedText")
    static let pasteToInput = Notification.Name("ProTermPasteToInput")
    static let copyLastCommand = Notification.Name("ProTermCopyLastCommand")
    static let showHistory = Notification.Name("ProTermShowHistory")
    static let findInHistory = Notification.Name("ProTermFindInHistory")
    static let showSystemInfo = Notification.Name("ProTermShowSystemInfo")
}
