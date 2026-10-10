import SwiftUI
import AppKit

private final class TagMP3AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

@main
struct TagMP3App: App {
    @NSApplicationDelegateAdaptor(TagMP3AppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(environment)
        }
        .commands {
            AppCommands(environment: environment)
        }

        Window("About tagmp3", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

private struct AboutView: View {
    private var icon: NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: iconURL)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "1"
    }

    var body: some View {
        VStack(spacing: 12) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
            }
            Text("TagMP3")
                .font(.title2.weight(.semibold))
            Text("Version \(version)")
            Text("Copyright © 2026 tagmp3")
        }
        .frame(width: 360, height: 260)
        .padding()
    }
}
