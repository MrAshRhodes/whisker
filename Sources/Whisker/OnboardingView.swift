import AppKit
import SwiftUI
import WhiskerCore

final class OnboardingChoices: ObservableObject {
    @Published var openAtLogin = true
}

/// First-run window: explains the Accessibility permission and offers to open Whisker at login.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    let onFinish: () -> Void

    var body: some View {
        OnboardingContent(permission: model.permission, loginItem: model.loginItem, onFinish: onFinish)
    }
}

private struct OnboardingContent: View {
    @ObservedObject var permission: AccessibilityPermission
    let loginItem: LoginItemController
    let onFinish: () -> Void
    @StateObject private var choices = OnboardingChoices()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to \(WhiskerInfo.name)").font(.title2.bold())
                    Text("Give every mouse button a job, fix scrolling, and set pointer speed per mouse.")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Image(systemName: permission.isTrusted ? "checkmark.circle.fill" : "hand.raised.circle.fill")
                            .font(.title2)
                            .foregroundStyle(permission.isTrusted ? .green : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(permission.isTrusted ? "Accessibility access granted" : "Allow Accessibility access")
                                .font(.headline)
                            Text("Whisker needs Accessibility access to see mouse buttons and the wheel and to change what they do. It never reads what you type.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !permission.isTrusted {
                        HStack {
                            Button("Open Accessibility Settings") { permission.openSystemSettings() }
                            Text("Turn on Whisker in the list. This window updates when you do.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Open Whisker at login", isOn: $choices.openAtLogin)

            HStack {
                Spacer()
                Button(permission.isTrusted ? "Done" : "Continue Without Access") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { permission.refresh() }
    }

    private func finish() {
        if choices.openAtLogin, !loginItem.isEnabled { loginItem.setEnabled(true) }
        onFinish()
    }
}
