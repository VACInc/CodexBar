import CodexBarCore
import SwiftUI

@MainActor
struct ICloudSyncPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @Bindable var state: CloudSyncState
    @State private var remoteCodexBarServerURLDraft: String
    @State private var remoteCodexBarBearerTokenDraft: String
    @State private var remoteCodexBarPlainHTTPConsentEndpoint: String?
    private static let securityFootnote =
        "Secrets use iCloud end-to-end encryption via encryptedValues. " +
        "Hooks and machine-local paths never sync."

    init(settings: SettingsStore, store: UsageStore, state: CloudSyncState) {
        self.settings = settings
        self.store = store
        self.state = state
        self._remoteCodexBarServerURLDraft = State(initialValue: settings.remoteCodexBarServerURL)
        self._remoteCodexBarBearerTokenDraft = State(initialValue: settings.remoteCodexBarBearerToken)
        self._remoteCodexBarPlainHTTPConsentEndpoint = State(initialValue: settings.remoteCodexBarAllowsPlainHTTP
            ? settings.remoteCodexBarServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil)
    }

    var body: some View {
        Form {
            if self.state.status.needsAppUpdate {
                Section {
                    Label(
                        L("Sync is paused: another Mac uses a newer version of CodexBar. Update to resume."),
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Section {
                Toggle(
                    L("Sync settings and providers across your Macs via iCloud"),
                    isOn: self.primarySyncBinding)
                    .toggleStyle(.checkbox)
                    .disabled(!self.syncCanBeEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L("Include API keys, cookies, and tokens"), isOn: self.includeSecretsBinding)
                    Toggle(L("Sync usage snapshots"), isOn: self.snapshotsBinding)
                    Toggle(L("Show accounts from other Macs"), isOn: self.showFleetAccountsBinding)
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 20)
                .disabled(!self.syncCanRun)
            } header: {
                Text(L("iCloud Sync"))
            } footer: {
                if let availabilityMessage = self.availabilityMessage {
                    SettingsSectionFooter(availabilityMessage)
                }
            }

            Section {
                TextField("https://codexbar.example", text: self.remoteCodexBarServerURLDraftBinding)
                    .textFieldStyle(.roundedBorder)
                SecureField("Bearer token", text: self.$remoteCodexBarBearerTokenDraft)
                    .textFieldStyle(.roundedBorder)
                if self.remoteCodexBarDraftRequiresPlainHTTPConsent {
                    Toggle(
                        "Allow this bearer token over unencrypted private-network HTTP",
                        isOn: self.remoteCodexBarPlainHTTPConsentBinding)
                        .toggleStyle(.checkbox)
                }
                HStack {
                    Button("Connect") {
                        self.settings.applyRemoteCodexBarConfiguration(
                            serverURL: self.remoteCodexBarServerURLDraft,
                            bearerToken: self.remoteCodexBarBearerTokenDraft,
                            allowsPlainHTTP: self.remoteCodexBarDraftAllowsPlainHTTP)
                    }
                    .disabled(self.remoteCodexBarDraftConfiguration == nil || !self.remoteCodexBarDraftHasChanges)

                    Button("Disconnect", role: .destructive) {
                        if self.settings.applyRemoteCodexBarConfiguration(serverURL: "", bearerToken: "") {
                            self.remoteCodexBarServerURLDraft = ""
                            self.remoteCodexBarBearerTokenDraft = ""
                            self.remoteCodexBarPlainHTTPConsentEndpoint = nil
                        }
                    }
                    .disabled(self.settings.remoteCodexBarConfiguration == nil)
                }

                Toggle(
                    "Use every provider from this server only",
                    isOn: self.remoteOnlyBinding)
                    .toggleStyle(.checkbox)
                    .disabled(self.settings.remoteCodexBarConfiguration == nil)
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
                        self.settings.usesRemoteCodexBarProvidersOnly
                            ? "Local provider probes are disabled. Provider menus and usage come only from this server."
                            :
                            "Connects to a separately running codexbar serve and shows its provider snapshots in menus.")
                }
            }

            Section {
                LabeledContent(
                    L("Last successful fetch"),
                    value: self.relativeTime(self.state.status.lastSuccessfulFetchAt))
                LabeledContent(
                    L("Last successful push"),
                    value: self.relativeTime(self.state.status.lastSuccessfulPushAt))
            } header: {
                Text(L("Status"))
            }

            Section {
                if self.devices.isEmpty {
                    Text(L("No synced Macs yet."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.devices, id: \.deviceID) { device in
                        ICloudSyncDeviceRow(
                            device: device,
                            isCurrentDevice: device.deviceID == self.settings.iCloudSyncDeviceID)
                    }
                }
            } header: {
                Text(L("Macs"))
            } footer: {
                SettingsSectionFooter(L(Self.securityFootnote))
            }
        }
        .formStyle(.grouped)
    }

    private var syncCanBeEnabled: Bool {
        self.state.availability == .available
    }

    private var remoteCodexBarServerURLDraftBinding: Binding<String> {
        Binding(
            get: { self.remoteCodexBarServerURLDraft },
            set: { newValue in
                let committedEndpoint = self.settings.remoteCodexBarServerURL
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let newEndpoint = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if newEndpoint != committedEndpoint {
                    self.remoteCodexBarBearerTokenDraft = ""
                    self.remoteCodexBarPlainHTTPConsentEndpoint = nil
                }
                self.remoteCodexBarServerURLDraft = newValue
            })
    }

    private var remoteCodexBarDraftConfiguration: RemoteCodexBarConfiguration? {
        RemoteCodexBarConfiguration.resolve(
            serverURL: self.remoteCodexBarServerURLDraft,
            bearerToken: self.remoteCodexBarBearerTokenDraft,
            allowsPlainHTTP: self.remoteCodexBarDraftAllowsPlainHTTP)
    }

    private var remoteCodexBarDraftHasChanges: Bool {
        self.remoteCodexBarServerURLDraft != self.settings.remoteCodexBarServerURL ||
            self.remoteCodexBarBearerTokenDraft != self.settings.remoteCodexBarBearerToken ||
            self.remoteCodexBarDraftAllowsPlainHTTP != self.settings.remoteCodexBarAllowsPlainHTTP
    }

    private var remoteCodexBarDraftRequiresPlainHTTPConsent: Bool {
        RemoteCodexBarConfiguration.requiresPlainHTTPConsent(serverURL: self.remoteCodexBarServerURLDraft)
    }

    private var remoteCodexBarDraftAllowsPlainHTTP: Bool {
        self.remoteCodexBarDraftRequiresPlainHTTPConsent &&
            self.remoteCodexBarPlainHTTPConsentEndpoint ==
            self.remoteCodexBarServerURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var remoteCodexBarPlainHTTPConsentBinding: Binding<Bool> {
        Binding(
            get: { self.remoteCodexBarDraftAllowsPlainHTTP },
            set: { isAllowed in
                self.remoteCodexBarPlainHTTPConsentEndpoint = isAllowed
                    ? self.remoteCodexBarServerURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
            })
    }

    private var syncCanRun: Bool {
        self.syncCanBeEnabled && !self.state.status.needsAppUpdate
    }

    private var availabilityMessage: String? {
        switch self.state.availability {
        case .available:
            nil
        case .missingEntitlement:
            L("Requires a signed release build of CodexBar.")
        case .noICloudAccount:
            L("Sign in to iCloud in System Settings to enable sync.")
        case .restricted:
            L("iCloud access is restricted on this Mac.")
        }
    }

    private var devices: [DeviceSyncPayload] {
        self.state.fleetDevices.values.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.deviceID == self.settings.iCloudSyncDeviceID
            let rhsIsCurrent = rhs.deviceID == self.settings.iCloudSyncDeviceID
            if lhsIsCurrent != rhsIsCurrent {
                return lhsIsCurrent
            }
            if lhs.lastSeen != rhs.lastSeen {
                return lhs.lastSeen > rhs.lastSeen
            }
            return lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName) == .orderedAscending
        }
    }

    private var primarySyncBinding: Binding<Bool> {
        Binding(
            get: { self.settings.iCloudSyncEnabled },
            set: { self.settings.iCloudSyncEnabled = $0 })
    }

    private var includeSecretsBinding: Binding<Bool> {
        Binding(
            get: { self.settings.iCloudSyncIncludeSecrets },
            set: { self.settings.iCloudSyncIncludeSecrets = $0 })
    }

    private var snapshotsBinding: Binding<Bool> {
        Binding(
            get: { self.settings.iCloudSyncSnapshotsEnabled },
            set: { self.settings.iCloudSyncSnapshotsEnabled = $0 })
    }

    private var showFleetAccountsBinding: Binding<Bool> {
        Binding(
            get: { self.settings.iCloudSyncShowFleetAccounts },
            set: { self.settings.iCloudSyncShowFleetAccounts = $0 })
    }

    private var remoteOnlyBinding: Binding<Bool> {
        Binding(
            get: { self.settings.remoteCodexBarRemoteOnlyEnabled },
            set: { self.settings.remoteCodexBarRemoteOnlyEnabled = $0 })
    }

    private func relativeTime(_ date: Date?) -> String {
        date?.relativeDescription() ?? L("Never")
    }
}

private struct ICloudSyncDeviceRow: View {
    let device: DeviceSyncPayload
    let isCurrentDevice: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.device.hostName)
                Text(String(format: L("Last seen %@"), self.device.lastSeen.relativeDescription()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if self.isCurrentDevice {
                Text(L("This Mac"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}
