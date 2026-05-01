import SwiftUI
import UniformTypeIdentifiers

/// L-shaped filled border: 1px top + left edges with a rounded top-left corner.
/// Uses a filled path instead of stroke so it renders fully inside the view bounds.
private struct TopLeftBorderFill: Shape {
    let radius: CGFloat
    let thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let t = thickness
        let r = radius
        var path = Path()

        // Outer edge
        path.move(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: r, y: 0))
        path.addArc(center: CGPoint(x: r, y: r), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: 0, y: rect.maxY))

        // Inner edge (back up)
        path.addLine(to: CGPoint(x: t, y: rect.maxY))
        path.addLine(to: CGPoint(x: t, y: r))
        path.addArc(center: CGPoint(x: r, y: r), radius: r - t,
                     startAngle: .degrees(180), endAngle: .degrees(-90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: t))
        path.closeSubpath()

        return path
    }
}

// 3-pane layout: sidebar, table, detail panel
struct LibraryRootView: View {
    @Bindable var appState: AppState

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        HStack(spacing: 0) {
            // Left pane: Sidebar (no right divider)
            if appState.isLibrarySidebarVisible {
                LibrarySidebarView(appState: appState)
                    .frame(width: 280)
                    .background(OakStyle.Colors.sidebarBackground)
            }

            // Middle + Right in HSplitView
            HSplitView {
                // Table — rounded top-left corner, top + left border only
                VStack(spacing: 0) {
                    LibraryTableToolbar(appState: appState)
                    Divider()
                    LibraryTableView(appState: appState, selection: $appState.selectedLibraryItemIDs)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: OakStyle.Radius.standard,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                ))
                .overlay(
                    TopLeftBorderFill(radius: OakStyle.Radius.standard, thickness: 1)
                        .fill(Color(nsColor: .separatorColor))
                )

                // Right pane: sidenav always visible + conditional content
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 0) {
                        if appState.libraryDetailTab == .chat {
                            AIChatView(chatVM: appState.libraryChatVM)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let item = appState.selectedLibraryItem {
                            LibrarySidebarPanel(item: item, appState: appState)
                        } else {
                            Spacer()
                        }

                        LibrarySideNavView(tab: $appState.libraryDetailTab)
                    }
                }
                .background(Color(hex: "F2F2F2"))
                .frame(minWidth: 200, idealWidth: 358, maxWidth: 800)
            }
        }
    }
}
