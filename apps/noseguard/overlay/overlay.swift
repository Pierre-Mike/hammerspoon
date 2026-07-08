// Hidden-from-capture HANDS DOWN flash.
// Borderless fullscreen red window with sharingType = .none, so macOS excludes
// it from screen recording / sharing (Zoom, Teams, ScreenCaptureKit, CGWindowList)
// while it stays visible to the local user. Auto-dismisses after a duration.
//
// Usage: overlay [seconds]   (default 1.2)

import Cocoa

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 1.2 : 1.2

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no menubar

let screen = NSScreen.main!
let win = NSWindow(
    contentRect: screen.frame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
win.sharingType = .none                // <-- excluded from screen capture
win.level = .screenSaver               // above normal windows
win.isOpaque = false
win.backgroundColor = .clear
win.ignoresMouseEvents = true
win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

let view = NSView(frame: screen.frame)
view.wantsLayer = true
view.layer?.backgroundColor = NSColor(red: 0.9, green: 0.05, blue: 0.18, alpha: 0.82).cgColor

let label = NSTextField(labelWithString: "✋ HANDS DOWN")
label.font = .systemFont(ofSize: 96, weight: .bold)
label.textColor = .white
label.alignment = .center
label.sizeToFit()
label.frame.origin = NSPoint(
    x: (screen.frame.width - label.frame.width) / 2,
    y: screen.frame.height * 0.45
)
view.addSubview(label)

win.contentView = view
win.makeKeyAndOrderFront(nil)
win.orderFrontRegardless()

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    app.terminate(nil)
}
app.run()
