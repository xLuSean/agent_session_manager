import AppKit
import SwiftUI

struct PasteboardCopyButton: View {
    let text: String
    let help: String
    var minimumWidth: CGFloat = 72

    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(text, forType: .string) {
                didCopy = true
            }
        } label: {
            Label(
                didCopy ? "Copied" : "Copy",
                systemImage: didCopy ? "checkmark" : "doc.on.doc"
            )
            .frame(minWidth: minimumWidth, alignment: .leading)
            .foregroundStyle(didCopy ? Color.green : Color.primary)
        }
        .buttonStyle(.bordered)
        .immediateHelp(didCopy ? "Copy again" : help)
        .onChange(of: text) {
            didCopy = false
        }
    }
}
