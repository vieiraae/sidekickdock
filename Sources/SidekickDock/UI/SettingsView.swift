import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var loginItem = LoginItem.shared

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            access
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 340)
    }

    private var general: some View {
        Form {
            Picker("Screen edge", selection: $prefs.edge) {
                ForEach(Preferences.Edge.allCases) { edge in
                    Text(edge.label).tag(edge)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Preview size") {
                Slider(value: $prefs.cardWidth, in: 110...260, step: 2) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "rectangle").imageScale(.small)
                } maximumValueLabel: {
                    Image(systemName: "rectangle").imageScale(.large)
                }
            }

            LabeledContent("Reveal delay") {
                Slider(value: $prefs.revealDelay, in: 0...0.6, step: 0.02) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Instant").font(.caption)
                } maximumValueLabel: {
                    Text("Relaxed").font(.caption)
                }
            }

            Toggle("Show window titles", isOn: $prefs.showTitles)
            Toggle("Include minimised windows", isOn: $prefs.includeMinimized)
            Toggle("Replace ⌘Tab with the window switcher", isOn: $prefs.replaceCommandTab)

            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))

            if loginItem.needsApproval {
                LabeledContent("") {
                    HStack(spacing: 8) {
                        Text("macOS needs you to approve SidekickDock in Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open…") { loginItem.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
            }

            if let error = loginItem.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("Move the pointer to the \(prefs.edge.label.lowercased()) edge of any display to reveal the dock. Clicking a preview brings that window forward — nothing else is minimised or hidden.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }

    private var access: some View {
        Form {
            Section {
                permissionRow(
                    title: "Screen Recording",
                    detail: "Required to render live previews of your windows.",
                    granted: permissions.hasScreenRecording,
                    action: permissions.requestScreenRecording
                )
                permissionRow(
                    title: "Accessibility",
                    detail: "Required to bring a window forward when you click its preview.",
                    granted: permissions.hasAccessibility,
                    action: permissions.requestAccessibility
                )
            } footer: {
                Text("After granting Screen Recording for the first time, quit and reopen SidekickDock so macOS hands over the new capture privileges.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
