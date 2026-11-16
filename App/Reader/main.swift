import AppKit

/// Retained for the process lifetime. NSApplication.delegate does not keep it alive.
let readerDelegate = AppDelegate()

autoreleasepool {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.delegate = readerDelegate
    application.run()
}
