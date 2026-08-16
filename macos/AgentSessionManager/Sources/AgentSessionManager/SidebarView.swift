import AgentSessionManagerCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: SessionManagerModel
    @State private var expandedSections: Set<SidebarSection> = Set(SidebarSection.allCases)

    var body: some View {
        List {
            agentSystemsSection
            statusFilterSection

            Section {
                disclosureGroup(.projects, title: "Projects") {
                    sidebarButton(
                        label: "All Projects",
                        symbol: "shippingbox",
                        count: model.sidebarMetrics.allCurrentStatusCount,
                        selected: model.browsingScope == .project
                            && model.selectedProjectID == nil
                    ) {
                        model.selectProject(nil)
                    }
                    ForEach(model.projects, id: \.self) { project in
                        sidebarButton(
                            label: project.name,
                            symbol: "shippingbox.fill",
                            count: model.count(forProjectID: project.id),
                            selected: model.browsingScope == .project
                                && model.selectedProjectID == project.id
                        ) {
                            model.selectProject(project.id)
                        }
                        .help("\(project.rootPath) · Desktop project ID: \(project.id)")
                    }
                }

                disclosureGroup(.trustFolders, title: "Trust Folders") {
                    sidebarButton(
                        label: "All Trust Folders",
                        symbol: "checkmark.shield",
                        count: model.sidebarMetrics.trustFolderCurrentStatusCount,
                        selected: model.browsingScope == .trustFolder
                            && model.selectedTrustFolderPath == nil
                    ) {
                        model.selectTrustFolder(nil)
                    }
                    ForEach(model.trustFolders) { folder in
                        sidebarButton(
                            label: URL(fileURLWithPath: folder.path).lastPathComponent,
                            symbol: folder.state == .trusted
                                ? "checkmark.shield.fill"
                                : "shield.slash",
                            count: model.count(forTrustFolderPath: folder.path),
                            selected: model.browsingScope == .trustFolder
                                && model.selectedTrustFolderPath == folder.path
                        ) {
                            model.selectTrustFolder(folder.path)
                        }
                        .help("\(folder.path) · \(folder.state.label)")
                    }
                }

                disclosureGroup(.workingFolders, title: "Working Folders") {
                    sidebarButton(
                        label: "All Working Folders",
                        symbol: "folder",
                        count: model.sidebarMetrics.allCurrentStatusCount,
                        selected: model.browsingScope == .workingFolder
                            && model.selectedWorkingDirectory == nil
                    ) {
                        model.selectWorkingFolder(nil)
                    }
                    ForEach(model.workingDirectories, id: \.self) { directory in
                        sidebarButton(
                            label: URL(fileURLWithPath: directory).lastPathComponent,
                            symbol: "folder.fill",
                            count: model.count(forWorkingFolderPath: directory),
                            selected: model.browsingScope == .workingFolder
                                && model.selectedWorkingDirectory == directory
                        ) {
                            model.selectWorkingFolder(directory)
                        }
                        .help(directory)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("BROWSE BY", systemImage: "sidebar.left")
                        .font(.caption.weight(.semibold))
                    Text("Choose one browsing scope")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sessions")
        .safeAreaInset(edge: .bottom, spacing: 0) { statusFooter }
    }

    private var agentSystemsSection: some View {
        Section {
            disclosureGroup(
                .agentSystems,
                title: "Agent Systems",
                collapsedValue: currentAgentSystemLabel
            ) {
                ForEach(model.availableSystems) { system in
                    sidebarButton(
                        label: agentSystemLabel(system),
                        symbol: system == .codex
                            ? "eye"
                            : "chevron.left.forwardslash.chevron.right",
                        count: model.count(for: system),
                        selected: model.selectedSystem == system
                    ) {
                        model.selectAgentSystem(system)
                    }
                }
            }
        }
    }

    private var statusFilterSection: some View {
        Section {
            DisclosureGroup(
                isExpanded: expansionBinding(for: .statusFilter)
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(CollectionFilter.allCases) { filter in
                        sidebarButton(
                            label: filter.label,
                            symbol: filter.symbol,
                            count: model.count(for: filter),
                            selected: model.selectedFilter == filter
                        ) {
                            model.selectStatusFilter(filter)
                        }
                    }
                }
            } label: {
                HStack {
                    Label("Status", systemImage: "line.3.horizontal.decrease.circle.fill")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(model.selectedFilter.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
            .listRowBackground(Color.accentColor.opacity(0.055))
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                "Codex read-only · Manager classification enabled",
                systemImage: "eye"
            )
            if let diagnostic = model.currentModeDiagnostic {
                Label(
                    diagnostic.connectionState.label,
                    systemImage: diagnostic.connectionState == .ready
                        ? "checkmark.circle"
                        : "exclamationmark.triangle"
                )
                .foregroundStyle(
                    diagnostic.connectionState == .ready ? Color.green : Color.orange
                )
            }
            if let disposition = model.checkpointDisposition {
                Label(
                    checkpointLabel(disposition),
                    systemImage: disposition == .skippedIncompleteInventory
                        || disposition == .skippedExecutingRecovery
                        ? "exclamationmark.shield"
                        : "externaldrive.badge.checkmark"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func disclosureSection<Content: View>(
        _ section: SidebarSection,
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Section {
            disclosureGroup(section, title: title, content: content)
        }
    }

    private func disclosureGroup<Content: View>(
        _ section: SidebarSection,
        title: String,
        collapsedValue: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: section)) {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.leading, 5)
        } label: {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if !expandedSections.contains(section), let collapsedValue {
                    Text(collapsedValue)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
            }
        }
    }

    private var currentAgentSystemLabel: String {
        agentSystemLabel(model.selectedSystem)
    }

    private func agentSystemLabel(_ system: AgentSystem) -> String {
        system == .codex ? "Codex Live" : system.label
    }

    private func expansionBinding(for section: SidebarSection) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(section) },
            set: { expanded in
                if expanded {
                    expandedSections.insert(section)
                } else {
                    expandedSections.remove(section)
                }
            }
        )
    }

    private func checkpointLabel(_ disposition: CheckpointCommitDisposition) -> String {
        switch disposition {
        case .advanced: "SQLite checkpoint advanced"
        case .unchanged: "SQLite checkpoint unchanged"
        case .skippedIncompleteInventory: "SQLite checkpoint not advanced"
        case .skippedExecutingRecovery: "SQLite checkpoint held for recovery"
        }
    }

    private func sidebarButton(
        label: String,
        symbol: String,
        count: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)

                HStack {
                    Label(label, systemImage: symbol)
                        .lineLimit(1)
                    Spacer()
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 31)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private enum SidebarSection: String, CaseIterable {
    case statusFilter
    case agentSystems
    case projects
    case trustFolders
    case workingFolders
}
