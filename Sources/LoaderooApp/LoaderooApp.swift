import AppKit
import SwiftUI
import LoaderooCore

@main
struct LoaderooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var demo = ProcessInfo.processInfo.arguments.contains("--demo")
        || ProcessInfo.processInfo.environment["LOADEROO_DEMO_ROOT"] != nil

    init() {
        // The default cache holds 20 MB and skips entries beyond 5% of that, which leaves posters and
        // sprite sheets to be downloaded again whenever a card scrolls back into view.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 1 << 30)
        URLProtocol.registerClass(DemoMedia.self)
    }

    var body: some Scene {
        Window("Loaderoo", id: "library") {
            // Either mode is the same workspace. The demo has its own library and simulated services.
            LiveFeedView(demo: demo, openDemo: { demo = true }).id(demo)
        }
        .commands {
            CommandMenu("Workspace") {
                Button(demo ? "Open Live Feed" : "Open Local Demo") { demo.toggle() }
            }
        }
    }
}

/// Serves the demo's bundled artwork where the live app downloads an image from PRDB.
final class DemoMedia: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url.flatMap(Demo.media(for:)) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let file = Demo.media(for: url), let image = try? Data(contentsOf: file),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "image/jpeg"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: image)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(sizeInitialWindow(_:)),
                                               name: NSWindow.didBecomeMainNotification, object: nil)
    }

    @objc private func sizeInitialWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !(window is NSPanel),
              let screen = window.screen else { return }
        // Size the workspace once, on the display macOS chose when restoring the window.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
        if !window.styleMask.contains(.fullScreen) {
            window.setFrame(screen.visibleFrame, display: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
