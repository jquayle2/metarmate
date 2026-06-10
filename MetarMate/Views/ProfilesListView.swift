import SwiftUI
import SwiftData

// MARK: - ProfilesListView
// Manage minimums profiles: create, clone, edit, delete. Reached from the Alerts profile area.
struct ProfilesListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MinimumsProfile.name) private var profiles: [MinimumsProfile]
    @AppStorage("activeMinimumsProfileID") private var activeProfileID: String = ""
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(profiles) { profile in
                    NavigationLink(value: profile) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(profile.name).font(.headline)
                                if profile.isBuiltIn {
                                    Text("Built-in")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.systemGray5))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(summary(profile))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !profile.isBuiltIn {
                            Button(role: .destructive) { delete(profile) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        Button { clone(profile) } label: {
                            Label("Clone", systemImage: "doc.on.doc")
                        }
                        .tint(.indigo)
                    }
                }
            }
            .navigationTitle("Minimums Profiles")
            .navigationDestination(for: MinimumsProfile.self) { ProfileEditorView(profile: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { createNew() } label: { Image(systemName: "plus") }
                }
            }
        }
    }

    private func createNew() {
        let profile = MinimumsProfile(name: "New Profile", isBuiltIn: false)
        context.insert(profile)
        try? context.save()
        path.append(profile)
    }

    private func clone(_ source: MinimumsProfile) {
        let copy = MinimumsProfile(
            name: "\(source.name) copy",
            isBuiltIn: false,
            maxCrosswindKt: source.maxCrosswindKt,
            maxGustKt: source.maxGustKt,
            minVisibilitySM: source.minVisibilitySM,
            minCeilingFt: source.minCeilingFt,
            minFlightCategory: source.minCategory,
            maxSustainedWindKt: source.maxSustainedWindKt
        )
        context.insert(copy)
        try? context.save()
        path.append(copy)
    }

    private func delete(_ profile: MinimumsProfile) {
        guard !profile.isBuiltIn else { return }   // built-ins reset, never delete
        let wasActive = profile.uuid.uuidString == activeProfileID
        context.delete(profile)
        try? context.save()
        // If we just deleted the active profile, re-anchor to a sensible default. resolve()
        // already falls back transparently, but this keeps the stored pointer valid.
        if wasActive,
           let fallback = profiles.first(where: { $0.name == "VFR day" })
                       ?? profiles.first(where: { $0.isBuiltIn }) {
            ActiveMinimumsProfile.set(fallback.uuid)
        }
    }

    private func summary(_ p: MinimumsProfile) -> String {
        var parts: [String] = []
        if let v = p.maxCrosswindKt { parts.append("XW \(v)kt") }
        if let v = p.maxGustKt { parts.append("Gust \(v)kt") }
        if let v = p.minVisibilitySM { parts.append("Vis \(v.visibilityString) SM") }
        if let v = p.minCeilingFt { parts.append("Ceil \(v)ft") }
        if let c = p.minCategory { parts.append(c.displayName) }
        if let v = p.maxSustainedWindKt { parts.append("Wind \(v)kt") }
        return parts.isEmpty ? "No factors set" : parts.joined(separator: " · ")
    }
}

// MARK: - ProfileEditorView
struct ProfileEditorView: View {
    @Bindable var profile: MinimumsProfile
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section("Name") {
                if profile.isBuiltIn {
                    // Built-in names are fixed so "Reset to Default" can match by name.
                    HStack {
                        Text(profile.name)
                        Spacer()
                        Text("Built-in").foregroundColor(.secondary)
                    }
                } else {
                    TextField("Profile name", text: $profile.name)
                }
            }

            Section {
                IntFactorRow(title: "Max crosswind", unit: "kt", value: $profile.maxCrosswindKt)
                IntFactorRow(title: "Max gust", unit: "kt", value: $profile.maxGustKt)
                DoubleFactorRow(title: "Min visibility", unit: "SM", value: $profile.minVisibilitySM)
                IntFactorRow(title: "Min ceiling", unit: "ft", value: $profile.minCeilingFt)
                categoryRow
                IntFactorRow(title: "Max sustained wind", unit: "kt", value: $profile.maxSustainedWindKt)
            } header: {
                Text("Minimums")
            } footer: {
                Text("Leave a factor blank to skip it. Crosswind is always checked against at least your global minimum, even when blank.")
            }

            if profile.isBuiltIn {
                Section {
                    Button("Reset to Default") {
                        profile.resetToBuiltInDefault()
                        try? context.save()
                    }
                }
            }
        }
        .navigationTitle(profile.name.isEmpty ? "New Profile" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? context.save() }
    }

    private var categoryRow: some View {
        Picker("Min flight category", selection: Binding<FlightCategory?>(
            get: { profile.minCategory },
            set: { profile.minCategory = $0 }
        )) {
            Text("Not set").tag(FlightCategory?.none)
            Text("VFR").tag(Optional(FlightCategory.vfr))
            Text("MVFR").tag(Optional(FlightCategory.mvfr))
            Text("IFR").tag(Optional(FlightCategory.ifr))
            Text("LIFR").tag(Optional(FlightCategory.lifr))
        }
    }
}

// MARK: - Factor rows
// Number-pad entry bound to an optional value: an empty field is nil (factor not evaluated).
private struct IntFactorRow: View {
    let title: String
    let unit: String
    @Binding var value: Int?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("Not set", text: Binding(
                get: { value.map(String.init) ?? "" },
                set: { value = Int($0) }      // empty / non-numeric → nil (clears the factor)
            ))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .fixedSize()
            Text(unit).foregroundColor(.secondary)
        }
    }
}

private struct DoubleFactorRow: View {
    let title: String
    let unit: String
    @Binding var value: Double?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("Not set", text: Binding(
                get: {
                    guard let v = value else { return "" }
                    return v == v.rounded() ? String(Int(v)) : String(v)
                },
                set: { value = Double($0) }   // empty / non-numeric → nil
            ))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .fixedSize()
            Text(unit).foregroundColor(.secondary)
        }
    }
}
