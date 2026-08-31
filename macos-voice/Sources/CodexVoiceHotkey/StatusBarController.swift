import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    var onOpenSettings: (() -> Void)?
    var onOpenUsageStats: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let iconImage: NSImage

    override init() {
        iconImage = Self.makeIcon()

        super.init()
        if let button = statusItem.button {
            button.image = iconImage
            button.toolTip = "cliMC 设置"
        }

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let usageStats = NSMenuItem(title: "使用统计…", action: #selector(openUsageStats), keyEquivalent: "u")
        usageStats.target = self
        menu.addItem(usageStats)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 cliMC", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        log("菜单栏菜单已打开。")
    }

    func update(isRecording: Bool) {
        statusItem.button?.image = iconImage
    }

    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 32, height: 18)
        let fallback = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage(size: size)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // White rounded rect badge
        let bgPath = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()

        // Draw mic icon + "CLI" text hollowed out
        ctx.setBlendMode(.destinationOut)

        // Draw mic icon (SF Symbol)
        let micSize = NSSize(width: 10, height: 12)
        if let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) {
            micImage.size = micSize
            if let micCG = micImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let micRect = CGRect(x: 2, y: (size.height - micSize.height) / 2, width: micSize.width, height: micSize.height)
                ctx.draw(micCG, in: micRect)
            }
        }

        // Draw "CLI" text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 9, nil),
            .foregroundColor: NSColor.black,
        ]
        let attrStr = NSAttributedString(string: "CLI", attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrStr)
        let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let textX: CGFloat = 14
        let textY = (size.height - textBounds.height) / 2 - textBounds.minY
        ctx.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, ctx)

        guard let outputCG = ctx.makeImage() else { return fallback }
        return NSImage(cgImage: outputCG, size: size)
    }

    @objc private func openSettings() {
        log("菜单栏：打开设置。")
        onOpenSettings?()
    }

    func openUsageStatsForTesting() {
        openUsageStats()
    }

    @objc private func openUsageStats() {
        log("菜单栏：打开使用统计。")
        onOpenUsageStats?()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
