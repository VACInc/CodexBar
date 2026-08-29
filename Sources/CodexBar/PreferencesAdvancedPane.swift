import CodexBarCore
import SwiftUI

@MainActor
struct AdvancedPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var isInstallingCLI = false
    @State private var cliStatus: String?
    @State private var remoteCodexBarServerURLDraft: String
    @State private var remoteCodexBarBearerTokenDraft: String

    init(settings: SettingsStore, store: UsageStore) {
        self.settings = settings
        self.store = store
        self._remoteCodexBarServerURLDraft = State(initialValue: settings.remoteCodexBarServerURL)
        self._remoteCodexBarBearerTokenDraft = State(initialValue: settings.remoteCodexBarBearerToken)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button {
                        Task { await self.installCLI() }
                    } label: {
                        if self.isInstallingCLI {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L("install_cli"))
                        }
                    }
                    .disabled(self.isInstallingCLI)
                } label: {
                    SettingsRowLabel(L("install_cli"), subtitle: L("install_cli_subtitle"))
                }
            } header: {
                Text(L("section_command_line"))
            } footer: {
                if let status = self.cliStatus {
                    SettingsSectionFooter(status)
                }
            }

            Section {
                TextField("https://codexbar.example", text: self.$remoteCodexBarServerURLDraft)
                    .textFieldStyle(.roundedBorder)
                SecureField("Bearer token", text: self.$remoteCodexBarBearerTokenDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect") {
                        self.settings.applyRemoteCodexBarConfiguration(
                            serverURL: self.remoteCodexBarServerURLDraft,
                            bearerToken: self.remoteCodexBarBearerTokenDraft)
                    }
                    .disabled(self.remoteCodexBarDraftConfiguration == nil || !self.remoteCodexBarDraftHasChanges)

                    Button("Disconnect", role: .destructive) {
                        self.settings.applyRemoteCodexBarConfiguration(serverURL: "", bearerToken: "")
                        self.remoteCodexBarServerURLDraft = ""
                        self.remoteCodexBarBearerTokenDraft = ""
                    }
                    .disabled(self.settings.remoteCodexBarConfiguration == nil)
                }
            } header: {
                Text("Remote CodexBar")
            } footer: {
                if let message = self.settings.remoteCodexBarURLValidationMessage(
                    for: self.remoteCodexBarServerURLDraft) ??
                    self.settings.remoteCodexBarSecretError ??
                    self.store.remoteCodexBarError
                {
                    SettingsSectionFooter(message)
                } else {
                    SettingsSectionFooter(
                        "Connects to a separately running codexbar serve and shows its provider snapshots in menus.")
                }
            }

            Section {
                Toggle(isOn: self.$settings.hidePersonalInfo) {
                    SettingsRowLabel(
                        L("hide_personal_info_title"),
                        subtitle: L("hide_personal_info_subtitle") + " " + L("hide_cost_history_identity_subtitle"))
                }

                Toggle(isOn: self.$settings.debugDisableKeychainAccess) {
                    SettingsRowLabel(
                        L("disable_keychain_access_title"),
                        subtitle: L("disable_keychain_access_subtitle"))
                }
            } header: {
                Text(L("section_privacy"))
            } footer: {
                SettingsSectionFooter(L("keychain_access_caption"))
            }

            Section {
                Toggle(isOn: self.$settings.providerStorageFootprintsEnabled) {
                    SettingsRowLabel(
                        L("show_provider_storage_usage_title"),
                        subtitle: L("show_provider_storage_usage_subtitle"))
                }

                Toggle(isOn: self.$settings.debugMenuEnabled) {
                    SettingsRowLabel(L("show_debug_settings_title"), subtitle: L("show_debug_settings_subtitle"))
                }
            } header: {
                Text(L("section_diagnostics"))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
    }
}

extension AdvancedPane {
    private var remoteCodexBarDraftConfiguration: RemoteCodexBarConfiguration? {
        RemoteCodexBarConfiguration.resolve(
            serverURL: self.remoteCodexBarServerURLDraft,
            bearerToken: self.remoteCodexBarBearerTokenDraft)
    }

    private var remoteCodexBarDraftHasChanges: Bool {
        self.remoteCodexBarServerURLDraft != self.settings.remoteCodexBarServerURL ||
            self.remoteCodexBarBearerTokenDraft != self.settings.remoteCodexBarBearerToken
    }

    private func installCLI() async {
        if self.isInstallingCLI {
            return
        }
        self.isInstallingCLI = true
        defer { self.isInstallingCLI = false }

        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexBarCLI")
        let fm = FileManager.default
        guard fm.fileExists(atPath: helperURL.path) else {
            self.cliStatus = L("cli_not_found")
            return
        }

        let destinations = [
            "/usr/local/bin/codexbar",
            "/opt/homebrew/bin/codexbar",
        ]

        var installed: [String] = []
        var conflicts: [String] = []
        var failures: [String] = []
        for dest in destinations {
            let dir = (dest as NSString).deletingLastPathComponent
            guard fm.fileExists(atPath: dir) else { continue }

            if fm.fileExists(atPath: dest) {
                if Self.isLink(atPath: dest, pointingTo: helperURL.path) {
                    installed.append("Installed: \(dir)")
                } else {
                    conflicts.append("Exists: \(dir)")
                }
                continue
            }

            guard fm.isWritableFile(atPath: dir) else {
                failures.append("No write access: \(dir)")
                continue
            }

            do {
                try fm.createSymbolicLink(atPath: dest, withDestinationPath: helperURL.path)
                installed.append("Installed: \(dir)")
            } catch {
                failures.append("Failed: \(dir)")
            }
        }

        self.cliStatus = Self.cliInstallStatus(
            installed: installed,
            conflicts: conflicts,
            failures: failures)
    }

    private static func isLink(atPath path: String, pointingTo destination: String) -> Bool {
        guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        let resolved = URL(fileURLWithPath: link, relativeTo: URL(fileURLWithPath: dir))
            .standardizedFileURL
            .path
        return resolved == destination
    }

    static func cliInstallStatus(installed: [String], conflicts: [String], failures: [String]) -> String {
        if installed.isEmpty == false {
            return (installed + conflicts).joined(separator: " · ")
        }
        if conflicts.isEmpty == false {
            return (conflicts + failures).joined(separator: " · ")
        }
        if failures.isEmpty == false {
            return failures.joined(separator: " · ")
        }
        return L("no_writable_bin_dirs")
    }
}
