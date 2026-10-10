import SwiftUI
import Foundation

extension Notification.Name {
    static let tagMP3SelectAllTracks = Notification.Name("tagMP3.selectAllTracks")
}

@MainActor
struct AppCommands: Commands {
    @ObservedObject var environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About tagmp3") {
                openWindow(id: "about")
            }
        }
        CommandGroup(after: .newItem) {
            Button("Open Folder…") {
                environment.openFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open Files…") {
                environment.openFiles()
            }
            .keyboardShortcut("o", modifiers: [.command])
            Button("Open Playlist…") {
                environment.openPlaylist()
            }
            Divider()
            Button("Select All Tracks") {
                NotificationCenter.default.post(name: .tagMP3SelectAllTracks, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command])
            .disabled(environment.snapshots.isEmpty)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { environment.undoStagedEdit() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!environment.canUndo)
            Button("Redo") { environment.redoStagedEdit() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!environment.canRedo)
        }
        CommandGroup(after: .saveItem) {
            Button("Save All") {
                environment.save(environment.snapshots)
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(environment.pendingPatches.isEmpty)
        }
        CommandGroup(after: .toolbar) {
            Button("Export M3U Playlist…") { environment.exportPlaylist(asUTF8: false) }
                .disabled(environment.snapshots.isEmpty)
            Button("Export M3U8 Playlist…") { environment.exportPlaylist(asUTF8: true) }
                .disabled(environment.snapshots.isEmpty)
        }
    }
}
