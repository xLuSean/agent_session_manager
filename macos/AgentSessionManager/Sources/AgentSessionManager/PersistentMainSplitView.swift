import AppKit
import SwiftUI

enum MainWindowLayout {
    static let minimumWidth: CGFloat = 860
    static let minimumHeight: CGFloat = 560
}

/// AppKit owns the split container so divider positions and collapsed state
/// have one stable autosave identity across app launches and rebuilds.
struct PersistentMainSplitView: NSViewControllerRepresentable {
    let model: SessionManagerModel

    func makeNSViewController(context: Context) -> PersistentMainSplitViewController {
        PersistentMainSplitViewController(model: model)
    }

    func updateNSViewController(
        _ controller: PersistentMainSplitViewController,
        context: Context
    ) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: PersistentMainSplitViewController,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: max(proposal.width ?? MainWindowLayout.minimumWidth, MainWindowLayout.minimumWidth),
            height: max(proposal.height ?? MainWindowLayout.minimumHeight, MainWindowLayout.minimumHeight)
        )
    }
}

@MainActor
final class PersistentMainSplitViewController: NSSplitViewController {
    private static let autosaveName = "AgentSessionManager.MainSplit.v1"

    private let sidebarController: NSHostingController<AnyView>
    private let contentController: NSHostingController<AnyView>
    private let inspectorController: NSHostingController<AnyView>

    init(model: SessionManagerModel) {
        sidebarController = Self.hostingController(rootView: Self.sidebarRoot(model: model))
        contentController = Self.hostingController(rootView: Self.contentRoot(model: model))
        inspectorController = Self.hostingController(rootView: Self.inspectorRoot(model: model))
        super.init(nibName: nil, bundle: nil)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = Self.autosaveName

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .init(252)

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 400
        contentItem.holdingPriority = .init(250)

        let inspectorItem = NSSplitViewItem(viewController: inspectorController)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 520
        inspectorItem.canCollapse = false
        inspectorItem.holdingPriority = .init(251)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func hostingController(rootView: AnyView) -> NSHostingController<AnyView> {
        let controller = NSHostingController(rootView: rootView)
        // The split view owns the pane sizes. Do not let SwiftUI's intrinsic,
        // minimum, or maximum content sizes constrain the AppKit container.
        controller.sizingOptions = []
        return controller
    }

    private static func sidebarRoot(model: SessionManagerModel) -> AnyView {
        AnyView(
            SidebarView()
                .environmentObject(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
    }

    private static func contentRoot(model: SessionManagerModel) -> AnyView {
        AnyView(
            SessionTableView()
                .environmentObject(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    private static func inspectorRoot(model: SessionManagerModel) -> AnyView {
        AnyView(
            SessionInspectorView()
                .environmentObject(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
    }
}
