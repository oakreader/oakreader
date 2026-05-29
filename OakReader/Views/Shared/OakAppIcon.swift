import SwiftUI
import AppKit

/// The app's real icon — the same mark shown in the Dock and Finder — for inline
/// brand use. Reads `NSApp.applicationIconImage`, so it always tracks whichever icon
/// the running app ships (the Dev icon in debug builds, the release icon otherwise)
/// without hard-coding an asset name. Replaces the former monochrome `MenuBarIcon`
/// tree so inline branding matches the app's identity.
struct OakAppIcon: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Oak")
    }
}
