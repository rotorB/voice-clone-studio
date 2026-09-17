import AppKit
import Darwin
import Foundation
import SwiftUI

final class AppInstanceLock {
    private var descriptor: Int32 = -1
    let acquired: Bool

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Voice clone Studio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appending(path: "application.lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        acquired = descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
        if acquired {
            ftruncate(descriptor, 0)
            let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
            pid.withCString { pointer in _ = Darwin.write(descriptor, pointer, strlen(pointer)) }
        } else if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = AppInstanceLock()
    var shutdown: (() -> Void)?
    var isPrimaryInstance: Bool { instanceLock.acquired }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's preferredColorScheme does not reach AppKit-drawn controls: pop-up
        // buttons and text fields would keep painting dark text on our dark surfaces.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        if !instanceLock.acquired { NSApplication.shared.terminate(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown?()
    }
}

@main
struct VoiceCloneStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = StudioModel()

    var body: some Scene {
        MenuBarExtra {
            QuickPanelView()
                .environmentObject(model)
        } label: {
            Label("Voice clone Studio", systemImage: model.isLive ? "waveform.circle.fill" : "waveform.circle")
                .onAppear {
                    guard appDelegate.isPrimaryInstance else { return }
                    appDelegate.shutdown = { model.shutdown() }
                    model.beginBoot()
                }
        }
        .menuBarExtraStyle(.window)

        Window("Voice Studio", id: "studio") {
            GraphWorkspaceView()
                .environmentObject(model)
        }
        .defaultSize(width: 1600, height: 1040)
        .windowResizability(.contentMinSize)
    }
}
