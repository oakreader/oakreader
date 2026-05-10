import SwiftUI

struct LibrarySideNavView: View {
    @Binding var tab: LibraryDetailTab?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(LibraryDetailTab.allCases) { mode in
                Button {
                    if tab == mode {
                        tab = nil
                    } else {
                        tab = mode
                    }
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: mode == .chat ? 14 : OakStyle.Font.icon))
                        .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == mode ? Color.accentColor : Color(nsColor: .labelColor))
                .help(mode.label)
            }

            Spacer()
        }
        .padding(.top, 6)
        .frame(width: OakStyle.Size.sidenavWidth)
        .background(.thinMaterial)
    }
}
