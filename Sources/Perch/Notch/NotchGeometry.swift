import AppKit
import Foundation

/// How the island sits on the screen.
enum NotchStyle: String, CaseIterable, Identifiable, Equatable {
    /// Flush with the top edge so it reads as the hardware notch growing wider.
    case notch
    /// Detached rounded card hanging below the menu bar. The only style that
    /// makes sense on an external display, and the only one with no notch gap
    /// down the middle of its head bar.
    case floating
    /// Merged like `.notch`, but the collapsed state drops the text label and
    /// shows only the pulse and the activity bars.
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: return "Notch"
        case .floating: return "Floating"
        case .compact: return "Compact"
        }
    }

    var blurb: String {
        switch self {
        case .notch: return "Grows out of the notch, flush with the top edge."
        case .floating: return "A separate card below the menu bar. Best on external displays."
        case .compact: return "Merged, but collapsed shows only the pulse and activity."
        }
    }

    /// Whether the head bar has to leave a hole for the physical notch.
    var mergesWithNotch: Bool { self != .floating }

    /// Distance from the top of the screen to the top of the island.
    func topGap(menuBarHeight: CGFloat) -> CGFloat {
        self == .floating ? menuBarHeight + 8 : 0
    }
}

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
