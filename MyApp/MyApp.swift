import SwiftUI
#if canImport(AppKit)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif

@main struct MyApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        WindowGroup("QRDrop") {
            ContentView()
                #if os(macOS)
                .frame(minWidth: 700, idealWidth: 780, minHeight: 620, idealHeight: 700)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
                #endif
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 780, height: 700)
        #endif
    }
}
