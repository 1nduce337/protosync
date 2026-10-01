import AppKit
import SwiftUI

final class DemoDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = MockModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = NSHostingView(rootView: DemoRootView(model: model))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "ProtoSync UI Demo · Signal Foundry"
        window.contentView = contentView
        window.minSize = NSSize(width: 480, height: 620)
        window.center()
        window.setFrameAutosaveName("ProtoSyncUIDemoSignal")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = DemoDelegate()
app.delegate = delegate
app.run()
