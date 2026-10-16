import AppKit

/// The main window, with its traffic lights centred on the tab bar.
///
/// AppKit owns the traffic lights and lays them out again whenever it lays
/// out the title bar, putting them back at the system position — about 3pt
/// above the tab titles. Moving them once after creation and on resize lost
/// that race now and then, which left them visibly higher than the tabs.
/// Re-applying after every layout pass is the only point AppKit cannot undo.
final class MainWindow: NSWindow {

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        centerTrafficLights()
    }

    private func centerTrafficLights() {
        // The tab bar is the window's top strip, so its middle is the line the
        // lights and the tab titles share.
        let centerFromTop = OakStyle.Size.tabBarHeight / 2
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type),
                  let container = button.superview else { continue }
            let y = container.frame.height - centerFromTop - button.frame.height / 2
            // Setting an unchanged origin still marks the view for display;
            // skip it so this cannot feed back into another layout pass.
            if abs(button.frame.origin.y - y) > 0.5 {
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y))
            }
        }
    }
}
