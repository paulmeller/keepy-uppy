import AppKit
import SwiftUI

extension View {
    /// Takes the sidebar toggle out of the Settings window's toolbar.
    ///
    /// A settings window's sidebar is its *only* navigation — five fixed panes,
    /// no content to make room for — so a button that collapses it away leaves
    /// a window you cannot get out of without resizing it back. System Settings
    /// does not offer one, and neither should this.
    ///
    /// **Two implementations, because the declarative one is macOS 14.**
    /// `toolbar(removing: .sidebarToggle)` is the right answer and is what Ice
    /// uses, but this project ships to 13, where the button can only be removed
    /// from the `NSToolbar` after SwiftUI has installed it. The AppKit path
    /// finds it by identifier and is deliberately silent when it finds nothing:
    /// a future SwiftUI that stops adding the item, or renames it, should leave
    /// a settings window that still works rather than a crash.
    func removeSidebarToggle() -> some View {
        modifier(RemoveSidebarToggleModifier())
    }
}

private struct RemoveSidebarToggleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .toolbar(removing: .sidebarToggle)
                .toolbar { Color.clear }
        } else {
            content.background(SidebarToggleRemover())
        }
    }
}

/// The macOS 13 path: reach the hosting `NSWindow` and drop the item SwiftUI
/// added.
private struct SidebarToggleRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // After the current turn of the run loop: at `makeNSView` the view is
        // not in a window yet, so there is no toolbar to edit.
        DispatchQueue.main.async { [weak view] in
            guard let toolbar = view?.window?.toolbar else { return }
            let identifier = NSToolbarItem.Identifier("com.apple.SwiftUI.navigationSplitView.toggleSidebar")
            guard let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier })
            else { return }
            toolbar.removeItem(at: index)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
