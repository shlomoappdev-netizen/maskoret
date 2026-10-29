import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few things that differ between the Mac and the iPhone/iPad app.
enum Platform {
    static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func pastedString() -> String {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string) ?? ""
        #else
        return UIPasteboard.general.string ?? ""
        #endif
    }

    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// The user's home folder on the Mac; the app's Documents folder on iOS.
    static var homeDirectory: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    static var didBecomeActive: Notification.Name {
        #if os(macOS)
        return NSApplication.didBecomeActiveNotification
        #else
        return UIApplication.didBecomeActiveNotification
        #endif
    }
}

extension View {
    /// A plain text-like button (`.link` on the Mac, `.borderless` on iOS).
    @ViewBuilder func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}

extension View {
    /// A checkbox on the Mac; a tappable check-square on iOS (which has no checkbox style).
    @ViewBuilder func checkboxToggle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(CheckSquareToggleStyle())
        #endif
    }
}

#if os(iOS)
struct CheckSquareToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}
#endif

/// Remembers a folder the user picked (in iCloud Drive / Files) across launches.
/// On iOS the folder can only be reached through the picker's security-scoped URL, so a bookmark is kept.
struct FolderBookmark {
    let key: String

    var url: URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale { save(url) }
        return url
    }

    func save(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// Runs `body` with access to the folder (needed on iOS for folders outside the app).
    static func access<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
