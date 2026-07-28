import AppKit

struct NotchGeometry: Equatable {
    var screenID: CGDirectDisplayID
    var screenFrame: CGRect
    var hasNotch: Bool
    /// In global screen coordinates (bottom-left origin).
    var notchRect: CGRect

    var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == screenID }
    }

    static func current(preferred: NSScreen? = nil) -> NotchGeometry {
        let screen = preferred
            ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first!

        let inset = screen.safeAreaInsets.top
        if inset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            let rect = CGRect(x: screen.frame.midX - width / 2,
                              y: screen.frame.maxY - inset,
                              width: width,
                              height: inset)
            return .init(screenID: screen.displayID, screenFrame: screen.frame,
                         hasNotch: true, notchRect: rect)
        }

        // No notch: synthesise a menu-bar-height island so the UI is identical.
        let height = max(NSStatusBar.system.thickness, 24)
        let width: CGFloat = 180
        let rect = CGRect(x: screen.frame.midX - width / 2,
                          y: screen.frame.maxY - height,
                          width: width, height: height)
        return .init(screenID: screen.displayID, screenFrame: screen.frame,
                     hasNotch: false, notchRect: rect)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
