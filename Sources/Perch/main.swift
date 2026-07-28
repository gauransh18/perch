import AppKit

// NSApplication.delegate is weak, so the delegate needs an owner that outlives run().
nonisolated(unsafe) var perchDelegate: AppDelegate?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    perchDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
