import SwiftUI

struct LayoutSettingsView: View {
    @ObservedObject private var prefs = LayoutPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showMetarResetConfirm   = false
    @State private var showAdvisoryResetConfirm = false
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("Starting Tab", systemImage: "house")
                            .font(.subheadline)
                        Spacer()
                        Picker("", selection: $prefs.startingTab) {
                            ForEach(StartingTab.allCases, id: \.self) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)
                    }
                } header: {
                    Text("General")
                } footer: {
                    Text("Choose which tab appears when you open the app.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section {
                    Picker("Section Type", selection: $selectedTab) {
                        Text("METAR").tag(0)
                        Text("Advisory").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)
                } header: {
                    Text("Detail View Sections")
                }

                if selectedTab == 0 {
                    metarListSection
                } else {
                    advisoryListSection
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset") {
                        if selectedTab == 0 {
                            showMetarResetConfirm = true
                        } else {
                            showAdvisoryResetConfirm = true
                        }
                    }
                    .foregroundColor(.orange)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Reset to defaults?", isPresented: $showMetarResetConfirm, titleVisibility: .visible) {
                Button("Reset METAR Layout", role: .destructive) {
                    prefs.resetMetarToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will restore the default section order and visibility.")
            }
            .confirmationDialog("Reset to defaults?", isPresented: $showAdvisoryResetConfirm, titleVisibility: .visible) {
                Button("Reset Advisory Layout", role: .destructive) {
                    prefs.resetAdvisoryToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will restore the default section order and visibility.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - METAR List
    private var metarListSection: some View {
        Section {
            ForEach($prefs.metarSections) { $config in
                SectionConfigRow(config: $config)
            }
            .onMove { from, to in
                prefs.metarSections.move(fromOffsets: from, toOffset: to)
            }
        } header: {
            Text("Drag to reorder · tap visibility to change")
                .textCase(nil)
                .font(.caption)
                .foregroundColor(.secondary)
        } footer: {
            Text("Sections set to \"Amber or above\" appear when caution-level conditions are present. \"Red only\" appears only for warning-level conditions.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var advisoryListSection: some View {
        Section {
            ForEach($prefs.advisorySections) { $config in
                SectionConfigRow(config: $config)
            }
            .onMove { from, to in
                prefs.advisorySections.move(fromOffsets: from, toOffset: to)
            }
        } header: {
            Text("Drag to reorder · tap visibility to change")
                .textCase(nil)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Section Config Row
private struct SectionConfigRow: View {
    @Binding var config: SectionConfig

    var body: some View {
        HStack(spacing: 12) {
            // Section name
            VStack(alignment: .leading, spacing: 2) {
                Text(config.id.displayName)
                    .font(.subheadline)
                    .foregroundColor(config.visibility == .hidden ? .secondary : .primary)
            }

            Spacer()

            // Visibility picker — compact menu
            Menu {
                ForEach(config.id.availableModes, id: \.self) { mode in
                    Button {
                        config.visibility = mode
                    } label: {
                        HStack {
                            Text(mode.rawValue)
                            if config.visibility == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(visibilityColor(config.visibility))
                        .frame(width: 8, height: 8)
                    Text(config.visibility.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private func visibilityColor(_ v: SectionVisibility) -> Color {
        switch v {
        case .always:        return .green
        case .changingOnly:  return Color(red: 0.2, green: 0.5, blue: 1.0)  // blue = informational
        case .amberAndAbove: return Color(red: 1.0, green: 0.6, blue: 0.0)
        case .redOnly:       return .red
        case .hidden:        return Color(.systemGray3)
        }
    }
}

#Preview {
    LayoutSettingsView()
}
