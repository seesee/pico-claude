import AppKit
import PicoClaudeCore
import SwiftUI

struct PicoClaudeApp: App {
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        model.start()          // collect and publish from launch, not first click
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // session limit at a glance; "–" until a reading exists
            let nowS = Int(model.now.timeIntervalSince1970)
            let h5 = model.payload?.h5
            let pct = h5.map { $0.reset != 0 && $0.reset <= nowS ? 0 : $0.pct }
            Image(systemName: "asterisk")
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "–")
        }
        .menuBarExtraStyle(.window)
    }
}

@main
enum Entry {
    /// `PicoClaude --snapshot out.png` renders the panel with sample data and exits
    /// (used to check the layout without clicking the menu bar).
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let renderer = ImageRenderer(content: PanelView(model: .sample(), controls: false))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("snapshot failed\n".utf8))
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            return
        }
        PicoClaudeApp.main()
    }
}
