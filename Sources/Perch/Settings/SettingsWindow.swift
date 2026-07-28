import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Perch"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: SettingsView())
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @State private var approvalMode = Prefs.approvalMode
    @State private var autoAllowReadOnly = Prefs.autoAllowReadOnly
    @State private var sounds = Prefs.sounds
    @State private var alwaysShow = Prefs.alwaysShow
    @State private var scanProcesses = Prefs.scanProcesses
    @State private var trackCost = Prefs.trackCost
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var installed = ClaudeCodeInstaller.isInstalled
    @State private var trusted = HotkeyMonitor.isTrusted
    @State private var style = Prefs.notchStyle
    @State private var planReview = Prefs.planReview
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                section("Claude Code") {
                    HStack {
                        Circle()
                            .fill(installed ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(installed ? "Hooks installed" : "Hooks not installed")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button(installed ? "Reinstall" : "Install") { install() }
                        if installed { Button("Remove") { uninstall() } }
                    }
                    caption("Writes hook entries into ~/.claude/settings.json. Your previous file is copied to settings.json.perch-backup. Restart running Claude Code sessions to pick up changes.")
                }

                section("Approvals") {
                    Toggle("Review plans in the notch", isOn: $planReview)
                        .onChange(of: planReview) { _, v in Prefs.planReview = v }
                    caption("When the agent finishes planning, the plan is rendered in the notch. Approve it, or send feedback and it keeps planning. Independent of the setting below: this replaces a prompt the agent already shows rather than pre-empting your permission rules.")

                    Toggle("Approve tool calls from the notch", isOn: $approvalMode)
                        .onChange(of: approvalMode) { _, v in
                            AppDelegate.shared?.state.approvalMode = v
                            trusted = HotkeyMonitor.isTrusted
                            AppDelegate.shared?.hotkeys.start()
                        }
                    caption("Off by default. When on, Perch answers Claude Code's PreToolUse hook, which overrides your normal permission prompts and allowlists. Anything Perch does not decide falls through to Claude's own prompt.")
                    Toggle("Auto-allow read-only tools (Read, Grep, Glob…)", isOn: $autoAllowReadOnly)
                        .disabled(!approvalMode)
                        .onChange(of: autoAllowReadOnly) { _, v in Prefs.autoAllowReadOnly = v }

                    HStack {
                        Circle()
                            .fill(trusted ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(trusted ? "⌘Y / ⌘N work from any app" : "⌘Y / ⌘N need Accessibility")
                            .font(.system(size: 12))
                        Spacer()
                        if !trusted {
                            Button("Grant…") {
                                HotkeyMonitor.requestTrust()
                                message = "Approve Perch in System Settings › Privacy & Security › Accessibility, then reopen this window."
                            }
                        }
                    }
                }

                section("Notch") {
                    StylePicker(style: $style)
                        .onChange(of: style) { _, v in AppDelegate.shared?.state.style = v }
                    caption(style.blurb)

                    Toggle("Always show the island", isOn: $alwaysShow)
                        .onChange(of: alwaysShow) { _, v in Prefs.alwaysShow = v }
                    Toggle("Chiptune alerts", isOn: $sounds)
                        .onChange(of: sounds) { _, v in Prefs.sounds = v; if v { SoundEngine.shared.play(.done) } }
                    Toggle("Track tokens and cost", isOn: $trackCost)
                        .onChange(of: trackCost) { _, v in Prefs.trackCost = v }
                    caption("Cost uses approximate list prices. Override them in ~/.perch/pricing.json.")
                }

                section("Discovery") {
                    Toggle("Detect agents without hook support", isOn: $scanProcesses)
                        .onChange(of: scanProcesses) { _, v in Prefs.scanProcesses = v }
                    caption("Polls the process list for codex, gemini, aider, opencode, amp, droid, goose, qwen and crush, and lists them read-only.")
                }

                section("System") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, v in setLaunchAtLogin(v) }
                    caption("Everything stays on this Mac: no account, no network calls off loopback, no telemetry.")
                }

                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Quit Perch") { NSApp.terminate(nil) }
                }
            }
            .padding(24)
        }
        .frame(width: 460, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Perch").font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Your coding agents, in the notch.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func install() {
        do {
            try ClaudeCodeInstaller.install()
            installed = ClaudeCodeInstaller.isInstalled
            message = "Hooks installed. New Claude Code sessions will report to Perch."
            AppDelegate.shared?.refreshInstallState()
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
    }

    private func uninstall() {
        do {
            try ClaudeCodeInstaller.uninstall()
            installed = ClaudeCodeInstaller.isInstalled
            message = "Hooks removed from ~/.claude/settings.json."
            AppDelegate.shared?.refreshInstallState()
        } catch {
            message = "Removal failed: \(error.localizedDescription)"
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Login item change failed: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Style picker

/// A segmented control would describe these styles; a thumbnail shows them.
/// Each tile is a tiny screen with a menu bar and the island drawn in place.
private struct StylePicker: View {
    @Binding var style: NotchStyle

    var body: some View {
        HStack(spacing: 10) {
            ForEach(NotchStyle.allCases) { option in
                let selected = option == style
                VStack(spacing: 6) {
                    Thumbnail(style: option)
                    Text(option.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
                .onTapGesture { style = option }
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel(option.title)
            }
            Spacer()
        }
    }

    private struct Thumbnail: View {
        let style: NotchStyle

        var body: some View {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.14)],
                                         startPoint: .top, endPoint: .bottom))

                // The menu bar, so the island's vertical position reads.
                VStack(spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 6)
                    Spacer(minLength: 0)
                }

                island
            }
            .frame(width: 92, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }

        @ViewBuilder private var island: some View {
            switch style {
            case .notch:
                UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                    .fill(.black)
                    .frame(width: 46, height: 12)
            case .floating:
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.black)
                    .frame(width: 40, height: 11)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.5))
                    .padding(.top, 10)
            case .compact:
                UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                    .fill(.black)
                    .frame(width: 30, height: 10)
            }
        }
    }
}
