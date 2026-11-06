import AppKit

let applicationVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.1"

enum AutomatoStyle {
    static let ink = NSColor(calibratedRed: 0.055, green: 0.055, blue: 0.045, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.32, green: 0.32, blue: 0.30, alpha: 1)
    static let paper = NSColor(calibratedRed: 0.977, green: 0.958, blue: 0.925, alpha: 1)
    static let yellow = NSColor(calibratedRed: 1, green: 0.79, blue: 0, alpha: 1)
    static let cream = NSColor(calibratedRed: 0.965, green: 0.953, blue: 0.91, alpha: 1)

    static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
    }

    static func symbol(_ name: String, in rect: NSRect, color: NSColor = ink) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        tinted(image, color: color).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// The supplied logo is preserved. The dark-screen rendering adapts its ink to
// cream and restores the yellow center, like the supplied black-screen design.
final class AutomatoMarkView: NSView {
    var dark = false { didSet { needsDisplay = true } }
    private let original = Bundle.main.image(forResource: "AutomatoLogo")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Логотип Автомато")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let original else { return }
        if dark {
            AutomatoStyle.tinted(original, color: AutomatoStyle.cream).draw(in: bounds)
            AutomatoStyle.yellow.setFill()
            let radius = bounds.width * 0.096
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - radius,
                y: bounds.minY + bounds.height * 0.39 - radius,
                width: radius * 2, height: radius * 2)).fill()
        } else {
            original.draw(in: bounds)
        }
    }
}

final class WarmPopupButton: NSPopUpButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSGradient(starting: NSColor(calibratedWhite: 1, alpha: 0.28),
                   ending: NSColor(calibratedRed: 0.925, green: 0.900, blue: 0.858, alpha: 0.45))?.draw(in: shape, angle: 90)
        NSColor(calibratedRed: 0.77, green: 0.745, blue: 0.70, alpha: 0.8).setStroke()
        shape.lineWidth = 1.2
        shape.stroke()
        let size = min(22, bounds.height * 0.45)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: AutomatoStyle.ink
        ]
        let title = selectedItem?.title ?? ""
        let height = title.size(withAttributes: attributes).height
        title.draw(at: NSPoint(x: 19, y: (bounds.height - height) / 2 - 1), withAttributes: attributes)
        let x = bounds.width - 25
        let y = bounds.midY
        let chevrons = NSBezierPath()
        chevrons.move(to: NSPoint(x: x - 4, y: y - 4))
        chevrons.line(to: NSPoint(x: x, y: y - 8))
        chevrons.line(to: NSPoint(x: x + 4, y: y - 4))
        chevrons.move(to: NSPoint(x: x - 4, y: y + 4))
        chevrons.line(to: NSPoint(x: x, y: y + 8))
        chevrons.line(to: NSPoint(x: x + 4, y: y + 4))
        chevrons.lineWidth = 1.8
        chevrons.lineCapStyle = .round
        chevrons.lineJoinStyle = .round
        AutomatoStyle.ink.setStroke()
        chevrons.stroke()
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

final class WarmPrimaryButton: NSButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let down = cell?.isHighlighted == true
        let rect = bounds.insetBy(dx: 2, dy: 3).offsetBy(dx: 0, dy: down ? 1 : 0)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSGraphicsContext.saveGraphicsState()
        if isEnabled && !down {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(calibratedRed: 0.50, green: 0.35, blue: 0.03, alpha: 0.20)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: 5)
            shadow.set()
        }
        let top = isEnabled ? NSColor(calibratedRed: 1, green: down ? 0.76 : 0.85, blue: 0.04, alpha: 1) : NSColor(calibratedWhite: 0.87, alpha: 1)
        let bottom = isEnabled ? NSColor(calibratedRed: 0.98, green: 0.73, blue: 0, alpha: 1) : NSColor(calibratedWhite: 0.82, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedRed: 0.88, green: 0.64, blue: 0, alpha: isEnabled ? 0.7 : 0.15).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 1.3, dy: 1.3), xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.white.withAlphaComponent(0.5).setStroke()
        inner.lineWidth = 0.7
        inner.stroke()
        let color = AutomatoStyle.ink.withAlphaComponent(isEnabled ? 1 : 0.45)
        let size = min(24, bounds.height * 0.38)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color]
        let labelSize = title.size(withAttributes: attributes)
        let groupWidth = labelSize.width + 44
        let start = (bounds.width - groupWidth) / 2
        AutomatoStyle.symbol("display", in: NSRect(x: start, y: rect.midY - 13, width: 28, height: 26), color: color)
        title.draw(at: NSPoint(x: start + 42, y: rect.midY - labelSize.height / 2 - 1), withAttributes: attributes)
        AutomatoStyle.symbol("arrow.right", in: NSRect(x: bounds.width - 49, y: rect.midY - 13, width: 26, height: 26), color: color)
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

final class WarmSetupView: NSView {
    override var isFlipped: Bool { true }
    let holdPicker: NSPopUpButton
    let autoPicker: NSPopUpButton
    let startButton: NSButton
    let permissionButton: NSButton
    let permissionLabel: NSTextField
    let statusLabel: NSTextField
    var onPreferences: (() -> Void)?
    var onAbout: (() -> Void)?
    var trusted = false {
        didSet {
            permissionLabel.isHidden = trusted
            permissionButton.isHidden = trusted
            if oldValue != trusted { needsLayout = true; needsDisplay = true }
        }
    }
    var designHeight: CGFloat { trusted ? 628 : 720 }
    private let mark = AutomatoMarkView()
    private let hero = NSImageView()
    private let brand = text("АВТОМАТО", size: 27, weight: .bold, color: AutomatoStyle.ink)
    private let studio = text("AI-студия\nРомана Лазарева", size: 12, color: AutomatoStyle.ink)
    private let heading = text("Протереть Mac", size: 48, weight: .bold, color: AutomatoStyle.ink)
    private let descriptionLabel = text("Чёрный экран для протирки клавиатуры,\nтачпада и монитора.", size: 17, weight: .medium, color: AutomatoStyle.muted)
    private let holdLabel = text("Удерживать мышь", size: 16, weight: .semibold, color: AutomatoStyle.ink)
    private let autoLabel = text("Автовыход через", size: 16, weight: .semibold, color: AutomatoStyle.ink)
    private let footer = text("Выход: удержать мышь и отпустить.\nАварийно: ⌘ ⌥ Esc.\nПри протирке обходите кнопку питания / Touch ID.", size: 12, color: AutomatoStyle.ink)
    private let gear = NSButton()
    private let info = NSButton()
    private let credits = text("Разработано в AI-студии «Автомато» · Версия \(applicationVersion) ·", size: 10.5, color: AutomatoStyle.muted)
    private let website = NSButton(title: "автомато.рф", target: nil, action: nil)
    private lazy var paperTexture: NSImage = {
        NSImage(size: NSSize(width: 128, height: 128), flipped: true) { rect in
            AutomatoStyle.paper.setFill()
            rect.fill()
            var seed: UInt64 = 0x4156544F4D41544F
            for _ in 0..<2200 {
                seed = seed &* 6364136223846793005 &+ 1
                let x = CGFloat((seed >> 32) % 1280) / 10
                seed = seed &* 6364136223846793005 &+ 1
                let y = CGFloat((seed >> 32) % 1280) / 10
                NSColor(calibratedWhite: seed & 1 == 0 ? 0.34 : 1, alpha: 0.025).setFill()
                NSRect(x: x, y: y, width: 0.65, height: 0.65).fill()
            }
            return true
        }
    }()

    init(holdPicker: NSPopUpButton, autoPicker: NSPopUpButton, startButton: NSButton,
         permissionButton: NSButton, permissionLabel: NSTextField, statusLabel: NSTextField) {
        self.holdPicker = holdPicker
        self.autoPicker = autoPicker
        self.startButton = startButton
        self.permissionButton = permissionButton
        self.permissionLabel = permissionLabel
        self.statusLabel = statusLabel
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 720))
        appearance = NSAppearance(named: .aqua)
        hero.image = Bundle.main.image(forResource: "CleaningHero")
        hero.imageScaling = .scaleProportionallyUpOrDown
        hero.setAccessibilityLabel("Ноутбук, жёлтая салфетка и лист гинкго")
        hero.setAccessibilityElement(false)
        heading.maximumNumberOfLines = 1
        for view in [hero, mark, brand, studio, heading, descriptionLabel, holdLabel, autoLabel,
                     holdPicker, autoPicker, permissionLabel, permissionButton, startButton, footer, statusLabel, gear, info, credits, website] {
            addSubview(view)
        }
        for (button, symbol, label, action) in [
            (gear, "gearshape", "Настройки удержания мыши", #selector(preferencesPressed)),
            (info, "info.circle", "О программе", #selector(aboutPressed))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
            button.contentTintColor = AutomatoStyle.ink
            button.isBordered = false
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
        for picker in [holdPicker, autoPicker] {
            picker.isBordered = false
            picker.font = .systemFont(ofSize: 22, weight: .semibold)
            picker.focusRingType = .default
        }
        startButton.setAccessibilityLabel("Начать протирку")
        statusLabel.textColor = AutomatoStyle.muted
        website.isBordered = false
        website.target = self
        website.action = #selector(openWebsite)
        website.setAccessibilityLabel("Открыть сайт автомато.рф")
        website.toolTip = "https://автомато.рф"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func preferencesPressed() { onPreferences?() }
    @objc private func aboutPressed() { onAbout?() }
    @objc private func openWebsite() {
        if let url = URL(string: "https://автомато.рф") { NSWorkspace.shared.open(url) }
    }

    override func layout() {
        super.layout()
        let sx = bounds.width / 720
        let sy = bounds.height / designHeight
        let scale = min(sx, sy)
        let permissionSpace: CGFloat = trusted ? 92 : 0
        func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            view.frame = NSRect(x: x * sx, y: y * sy, width: w * sx, height: h * sy)
        }
        place(hero, 423, 49, 295, 283)
        place(mark, 41, 70, 68, 68)
        place(brand, 122, 87, 174, 38)
        place(studio, 321, 88, 154, 40)
        place(heading, 39, 179, 562, 67)
        place(descriptionLabel, 44, 258, 414, 55)
        place(holdLabel, 73, 338, 265, 25)
        place(autoLabel, 406, 338, 270, 25)
        place(holdPicker, 40, 371, 308, 46)
        place(autoPicker, 372, 371, 308, 46)
        place(permissionLabel, 96, 440, 566, 32)
        place(permissionButton, 94, 476, 285, 27)
        place(startButton, 39, 523 - permissionSpace, 642, 63)
        place(footer, 260, 618 - permissionSpace, 434, 60)
        place(statusLabel, 42, 678 - permissionSpace, 638, 17)
        credits.font = .systemFont(ofSize: 10.5 * scale)
        let creditsWidth = credits.stringValue.size(withAttributes: [.font: credits.font!]).width / sx
        let websiteWidth: CGFloat = 72
        let creditsX = (720 - creditsWidth - websiteWidth - 2) / 2
        place(credits, creditsX, 701 - permissionSpace, creditsWidth + 2, 16)
        place(website, creditsX + creditsWidth + 2, 697 - permissionSpace, websiteWidth, 23)
        website.attributedTitle = NSAttributedString(string: "автомато.рф", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5 * scale),
            .foregroundColor: AutomatoStyle.muted,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        place(gear, 633, 8, 28, 28)
        place(info, 682, 8, 26, 28)
        for (label, size, weight) in [
            (brand, CGFloat(27), NSFont.Weight.bold), (studio, 12, .regular),
            (heading, 48, .bold), (descriptionLabel, 17, .medium),
            (holdLabel, 16, .semibold), (autoLabel, 16, .semibold),
            (footer, 12, .regular), (statusLabel, 11, .regular)
        ] { label.font = .systemFont(ofSize: size * scale, weight: weight) }
        permissionLabel.font = .systemFont(ofSize: 12 * scale)
        permissionLabel.isHidden = trusted
        permissionButton.isHidden = trusted
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(patternImage: paperTexture).setFill()
        bounds.fill()
        let transform = NSAffineTransform()
        transform.scaleX(by: bounds.width / 720, yBy: bounds.height / designHeight)
        transform.concat()
        let permissionSpace: CGFloat = trusted ? 92 : 0
        NSColor(calibratedRed: 0.82, green: 0.74, blue: 0.59, alpha: 0.10).setFill()
        NSBezierPath(ovalIn: NSRect(x: 493, y: 76, width: 384, height: 290)).fill()
        NSColor(calibratedRed: 0.90, green: 0.87, blue: 0.82, alpha: 0.75).setFill()
        NSRect(x: 0, y: 0, width: 720, height: 43).fill()
        "Протереть Mac".draw(at: NSPoint(x: 112, y: 11), withAttributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: AutomatoStyle.ink
        ])
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 306, y: 87)); line.line(to: NSPoint(x: 306, y: 117))
        line.move(to: NSPoint(x: 234, y: 614 - permissionSpace)); line.line(to: NSPoint(x: 234, y: 675 - permissionSpace))
        NSColor(calibratedWhite: 0.50, alpha: 0.5).setStroke()
        line.lineWidth = 1
        line.stroke()
        let underline = NSBezierPath()
        underline.move(to: NSPoint(x: 114, y: 238))
        underline.curve(to: NSPoint(x: 282, y: 237), controlPoint1: NSPoint(x: 169, y: 226), controlPoint2: NSPoint(x: 227, y: 228))
        underline.lineWidth = 5
        underline.lineCapStyle = .round
        AutomatoStyle.yellow.setStroke()
        underline.stroke()
        AutomatoStyle.symbol("computermouse", in: NSRect(x: 45, y: 335, width: 20, height: 25))
        AutomatoStyle.symbol("clock", in: NSRect(x: 374, y: 336, width: 23, height: 23))
        if !trusted {
            AutomatoStyle.yellow.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: NSRect(x: 40, y: 432, width: 640, height: 78), xRadius: 15, yRadius: 15).fill()
            AutomatoStyle.yellow.setFill()
            NSBezierPath(ovalIn: NSRect(x: 56, y: 444, width: 25, height: 25)).fill()
            AutomatoStyle.symbol("lock", in: NSRect(x: 62, y: 450, width: 13, height: 13))
        }
        var x: CGFloat = 44
        for (key, width) in [("⌘", CGFloat(43)), ("⌥", 43), ("Esc", 50)] {
            let box = NSRect(x: x, y: 622 - permissionSpace, width: width, height: 41)
            NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.90, alpha: 0.8).setFill()
            let keyShape = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
            keyShape.fill()
            NSColor(calibratedRed: 0.82, green: 0.79, blue: 0.73, alpha: 0.75).setStroke()
            keyShape.lineWidth = 1
            keyShape.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: key == "Esc" ? 17 : 21, weight: .medium), .foregroundColor: AutomatoStyle.ink]
            let size = key.size(withAttributes: attributes)
            key.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2 - 1), withAttributes: attributes)
            x += width + 10
        }
    }
}

func renderDesignPreviews(to directory: URL) throws {
    _ = WipeApplication.shared
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let hold = WarmPopupButton(frame: .zero, pullsDown: false)
    let auto = WarmPopupButton(frame: .zero, pullsDown: false)
    hold.addItem(withTitle: "2 с")
    auto.addItem(withTitle: "5 мин")
    let start = WarmPrimaryButton(title: "Начать протирку", target: nil, action: nil)
    let permission = NSButton(title: "Открыть «Универсальный доступ»", target: nil, action: nil)
    let permissionLabel = text("Блокировка клавиш разрешена. Всё готово.", size: 16, color: AutomatoStyle.ink)
    let root = WarmSetupView(holdPicker: hold, autoPicker: auto, startButton: start, permissionButton: permission,
        permissionLabel: permissionLabel, statusLabel: text("", size: 11))
    root.trusted = true
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: root.designHeight), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = root
    func save(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: directory.appendingPathComponent(name))
    }
    try save(root, name: "main-window.png")
    root.trusted = false
    window.setContentSize(NSSize(width: 720, height: root.designHeight))
    permissionLabel.stringValue = "Для блокировки клавиш включите «Протереть Mac» в разделе\nКонфиденциальность и безопасность → Универсальный доступ."
    start.isEnabled = false
    try save(root, name: "permission-window.png")
    let shield = ShieldView(settings: CleaningSettings(), preview: false)
    window.setContentSize(NSSize(width: 1280, height: 800))
    window.contentView = shield
    shield.update(remaining: 300, progress: 0, pressed: false)
    try save(shield, name: "cleaning-screen.png")
    window.orderOut(nil)
}
