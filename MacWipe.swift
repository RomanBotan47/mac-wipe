import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import IOKit.pwr_mgt

// This application uses Apple frameworks only. It has no networking or updater.
private let appTitle = "Протереть Mac"
private let maximumMinutes = 15
private let clockScale: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000_000
}()
private func now() -> TimeInterval { Double(mach_continuous_time()) * clockScale }

struct CleaningSettings: Equatable {
    var holdSeconds: Int
    var autoMinutes: Int

    init(holdSeconds: Int = 2, autoMinutes: Int = 5) {
        self.holdSeconds = min(10, max(1, holdSeconds))
        self.autoMinutes = min(maximumMinutes, max(1, autoMinutes))
    }

    static func load(from store: UserDefaults = .standard) -> CleaningSettings {
        let hold = (store.object(forKey: "holdSeconds") as? NSNumber)?.intValue ?? 2
        let auto = (store.object(forKey: "autoMinutes") as? NSNumber)?.intValue ?? 5
        return CleaningSettings(holdSeconds: hold, autoMinutes: auto)
    }

    func save(to store: UserDefaults = .standard) {
        store.set(holdSeconds, forKey: "holdSeconds")
        store.set(autoMinutes, forKey: "autoMinutes")
    }

    var timeout: TimeInterval { Double(autoMinutes * 60) }
}

struct HoldState {
    private(set) var started: TimeInterval?

    mutating func begin(at time: TimeInterval) { started = time }
    mutating func cancel() { started = nil }

    func progress(at time: TimeInterval, duration: TimeInterval) -> Double {
        guard let started else { return 0 }
        return min(1, max(0, (time - started) / duration))
    }

    mutating func release(at time: TimeInterval, inside: Bool, duration: TimeInterval) -> Bool {
        let shouldUnlock = inside && started != nil && progress(at: time, duration: duration) >= 1
        cancel()
        return shouldUnlock
    }
}

enum InputDecision { case block, pointer, emergency }

// The policy never records keys or text. Only the emergency chord needs a key code.
func inputDecision(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> InputDecision {
    if type == .keyDown && keyCode == 53 && flags.contains([.maskCommand, .maskAlternate]) {
        return .emergency
    }
    switch type {
    case .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged: return .pointer
    default: return .block
    }
}

final class SessionGuard {
    private var process: Process?
    private var writer: FileHandle?

    func start(timeout: TimeInterval) throws {
        guard let executable = Bundle.main.executableURL else { throw GuardError.start }
        let input = Pipe()
        let output = Pipe()
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--guard", String(getpid()), String(timeout + 1)]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        writer = input.fileHandleForWriting
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 1500) > 0,
              output.fileHandleForReading.readData(ofLength: 6) == Data("READY\n".utf8) else {
            stop()
            throw GuardError.start
        }
        output.fileHandleForReading.closeFile()
        guard beat() else { stop(); throw GuardError.start }
    }

    func beat() -> Bool {
        guard process?.isRunning == true, let writer else { return false }
        var byte: UInt8 = 1
        return Darwin.write(writer.fileDescriptor, &byte, 1) == 1
    }

    func stop() {
        writer?.closeFile()
        writer = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    deinit { stop() }
    enum GuardError: Error { case start }
}

// A child of this exact app only: no launch agent, service, or persistent process.
// It releases a frozen app within 4 seconds, or at the chosen absolute deadline.
func runGuard(parent: pid_t, timeout: TimeInterval) -> Never {
    guard parent > 1, getppid() == parent, timeout.isFinite, timeout >= 1, timeout <= 901 else { exit(64) }
    signal(SIGPIPE, SIG_IGN)
    let flags = fcntl(STDIN_FILENO, F_GETFL)
    guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else { exit(65) }
    let ready = Array("READY\n".utf8)
    ready.withUnsafeBytes { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, ready.count) }
    let deadline = now() + timeout
    var lastHeartbeat = now()
    var buffer = [UInt8](repeating: 0, count: 512)
    while getppid() == parent {
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        if count > 0 { lastHeartbeat = now() }
        if count == 0 { exit(0) } // Normal cleanup closes the pipe.
        if count < 0 && errno != EAGAIN && errno != EINTR { exit(66) }
        if now() >= deadline || now() - lastHeartbeat > 4 {
            // Recheck the parent relationship to avoid acting on a recycled PID.
            if getppid() == parent { kill(parent, SIGTERM) }
            usleep(500_000)
            if getppid() == parent { kill(parent, SIGKILL) }
            exit(0)
        }
        usleep(50_000)
    }
    exit(0)
}

final class InputBlocker {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onPointer: ((CGEventType, CGPoint) -> Void)?
    var onFailure: (() -> Void)?
    var onEmergency: (() -> Void)?
    private(set) var active = false

    func start() throws {
        guard AXIsProcessTrusted() else { throw BlockError.permission }
        // Include system-defined media keys and gesture events in addition to
        // the public keyboard / pointer CGEventType constants.
        let types: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 18, 19, 20, 22, 25, 26, 27, 29, 30, 31, 32, 33]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let blocker = Unmanaged<InputBlocker>.fromOpaque(context).takeUnretainedValue()
            return blocker.filter(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            throw BlockError.unavailable
        }
        tap = port
        source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        active = true
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else { stop(); throw BlockError.unavailable }
    }

    var healthy: Bool { active && tap.map { CGEvent.tapIsEnabled(tap: $0) } == true }

    private func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            active = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            DispatchQueue.main.async { [weak self] in self?.onFailure?() }
            return Unmanaged.passUnretained(event)
        }
        guard active else { return Unmanaged.passUnretained(event) }
        switch inputDecision(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags) {
        case .emergency:
            active = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            DispatchQueue.main.async { [weak self] in self?.onEmergency?() }
            return nil
        case .block:
            return nil
        case .pointer:
            onPointer?(type, event.location)
            if type == .mouseMoved {
                // A cloth can move the cursor; it can never click another app.
                event.flags = []
                return Unmanaged.passUnretained(event)
            }
            return nil // Mouse-down/up are consumed here, including unlock release.
        }
    }

    func stop() {
        active = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    deinit { stop() }
    enum BlockError: Error { case permission, unavailable }
}

func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    return label
}

final class HoldButton: NSView {
    var onDown: (() -> Void)?
    var onUp: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var holdSeconds = 2
    var pressed = false { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateAccessibility() {
        setAccessibilityLabel("Отменить и выйти. Удерживайте мышь \(holdSeconds) с и отпустите.")
        setAccessibilityHelp("Обычное короткое нажатие и клавиши не разблокируют экран.")
    }
    override func accessibilityPerformPress() -> Bool { false } // Physical hold only.
    override func mouseDown(with event: NSEvent) { onDown?() }
    override func mouseUp(with event: NSEvent) {
        if let window { onUp?(window.convertPoint(toScreen: event.locationInWindow)) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let window { onDrag?(window.convertPoint(toScreen: event.locationInWindow)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSGradient(starting: NSColor(calibratedRed: 1, green: pressed ? 0.78 : 0.85, blue: 0.04, alpha: 1),
                   ending: AutomatoStyle.yellow)?.draw(in: shape, angle: -90)
        if progress > 0 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor.black.withAlphaComponent(0.10).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width * progress, height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let title = progress >= 1 ? "Отпустите мышь" : "Отменить и выйти"
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: AutomatoStyle.ink]
        let titleSize = title.size(withAttributes: titleAttributes)
        let groupWidth = titleSize.width + 55
        let start = bounds.midX - groupWidth / 2
        title.draw(at: NSPoint(x: start, y: bounds.midY - titleSize.height / 2), withAttributes: titleAttributes)
        let badge = NSRect(x: start + titleSize.width + 17, y: bounds.midY - 13, width: 39, height: 26)
        AutomatoStyle.ink.setStroke()
        let border = NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5)
        border.lineWidth = 1.4
        border.stroke()
        let caption = progress >= 1 ? "✓" : "\(holdSeconds) с"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: AutomatoStyle.ink]
        let captionSize = caption.size(withAttributes: attributes)
        caption.draw(at: NSPoint(x: badge.midX - captionSize.width / 2, y: badge.midY - captionSize.height / 2), withAttributes: attributes)
    }
}

final class ShieldView: NSView {
    let button = HoldButton(frame: .zero)
    private let timerLabel = text("", size: 12, color: NSColor(white: 0.48, alpha: 1))
    private let emergencyLabel = text("Аварийный выход: ⌘ ⌥ Esc", size: 11, color: NSColor(white: 0.40, alpha: 1))
    private let logo = AutomatoMarkView()
    private let brandLabel = text("АВТОМАТО", size: 40, weight: .bold, color: AutomatoStyle.cream)
    private let subtitle = text("Протирка Mac", size: 25, color: AutomatoStyle.cream)
    private let holdLabel = text("", size: 12, color: NSColor(white: 0.62, alpha: 1))
    private let previewLabel = text("Проверка экрана · системный ввод свободен", size: 11, color: .secondaryLabelColor)

    init(settings: CleaningSettings, preview: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        logo.dark = true
        button.holdSeconds = settings.holdSeconds
        button.updateAccessibility()
        holdLabel.stringValue = "Удерживайте мышь \(settings.holdSeconds) с, затем отпустите"
        for view in [logo, brandLabel, subtitle, button, holdLabel, timerLabel, emergencyLabel, previewLabel] { addSubview(view) }
        brandLabel.alignment = .center
        subtitle.alignment = .center
        holdLabel.alignment = .center
        timerLabel.alignment = .center
        emergencyLabel.alignment = .center
        previewLabel.alignment = .center
        previewLabel.isHidden = !preview
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let center = bounds.midY + 28
        button.frame = NSRect(x: (bounds.width - 350) / 2, y: center - 105, width: 350, height: 58)
        holdLabel.frame = NSRect(x: 20, y: button.frame.minY - 36, width: bounds.width - 40, height: 20)
        timerLabel.frame = NSRect(x: 20, y: holdLabel.frame.minY - 26, width: bounds.width - 40, height: 20)
        emergencyLabel.frame = NSRect(x: 20, y: timerLabel.frame.minY - 25, width: bounds.width - 40, height: 20)
        logo.frame = NSRect(x: bounds.midX - 55, y: center + 98, width: 110, height: 110)
        brandLabel.frame = NSRect(x: 20, y: center + 33, width: bounds.width - 40, height: 54)
        subtitle.frame = NSRect(x: 20, y: center - 14, width: bounds.width - 40, height: 34)
        previewLabel.frame = NSRect(x: 20, y: 24, width: bounds.width - 40, height: 20)
    }

    func update(remaining: TimeInterval, progress: Double, pressed: Bool) {
        let seconds = max(0, Int(ceil(remaining)))
        timerLabel.stringValue = String(format: "Автовыход через %d:%02d", seconds / 60, seconds % 60)
        button.progress = progress
        button.pressed = pressed
    }

    var globalButtonRect: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(button.frame, to: nil))
    }
}

final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WipeApplication: NSApplication {
    weak var controller: AppController?
    override func sendEvent(_ event: NSEvent) {
        if controller?.cleaning == true {
            if event.type == .keyDown && event.keyCode == 53 && event.modifierFlags.contains([.command, .option]) {
                controller?.finish(message: "Протирка завершена аварийной командой.")
            }
            if [.keyDown, .keyUp, .flagsChanged, .systemDefined, .scrollWheel, .swipe, .magnify, .rotate, .smartMagnify, .quickLook].contains(event.type) { return }
        }
        super.sendEvent(event)
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var settings = CleaningSettings.load()
    private var setupWindow: NSWindow?
    private var setupView: WarmSetupView?
    private var holdPicker = WarmPopupButton(frame: .zero, pullsDown: false)
    private var autoPicker = WarmPopupButton(frame: .zero, pullsDown: false)
    private var startButton = NSButton()
    private var permissionButton = NSButton()
    private var permissionLabel = text("", size: 12)
    private var statusLabel = text("", size: 12, color: .secondaryLabelColor)
    private var permissionTimer: Timer?
    private var windows: [NSWindow] = []
    private var shields: [ShieldView] = []
    private var blocker: InputBlocker?
    private var guardProcess: SessionGuard?
    private var tickTimer: Timer?
    private var deadline: TimeInterval = 0
    private var hold = HoldState()
    private weak var pressedShield: ShieldView?
    private var previousPresentation: NSApplication.PresentationOptions = []
    private var sleepAssertion = IOPMAssertionID(0)
    private var hasSleepAssertion = false
    private var observers: [NSObjectProtocol] = []
    private var preview = false
    private var testSession = false
    private var primaryTop: CGFloat = 0
    private var screenLayout: [String] = []
    private(set) var cleaning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        (NSApp as? WipeApplication)?.controller = self
        makeMenu()
        observeInterruptions()
        makeSetupWindow()
        let arguments = CommandLine.arguments
        preview = arguments.contains("--preview")
        testSession = arguments.contains("--test-session")
        if preview || testSession {
            startSession(timeoutOverride: 20)
        } else {
            showSetup()
        }
    }

    private func makeMenu() {
        let menu = NSMenu()
        let root = NSMenuItem()
        menu.addItem(root)
        let appMenu = NSMenu()
        let preferences = NSMenuItem(title: "Настройки…", action: #selector(showPreferences), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить \(appTitle)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu
        NSApp.mainMenu = menu
    }

    private func makeSetupWindow() {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1400, height: 1000)
        let size = min(720, available.height - 110, available.width - 80)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = appTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = AutomatoStyle.paper
        window.center()
        for number in 1...10 { holdPicker.addItem(withTitle: "\(number) с"); holdPicker.lastItem?.tag = number }
        for number in 1...maximumMinutes { autoPicker.addItem(withTitle: "\(number) мин"); autoPicker.lastItem?.tag = number }
        holdPicker.selectItem(withTag: settings.holdSeconds)
        autoPicker.selectItem(withTag: settings.autoMinutes)
        holdPicker.setAccessibilityLabel("Удерживать мышь, секунд")
        autoPicker.setAccessibilityLabel("Автовыход, минут")
        for picker in [holdPicker, autoPicker] { picker.target = self; picker.action = #selector(settingsChanged) }
        startButton = WarmPrimaryButton(title: "Начать протирку", target: self, action: #selector(startCleaning))
        permissionButton = NSButton(title: "Открыть «Универсальный доступ»", target: self, action: #selector(openPermissionSettings))
        permissionButton.bezelStyle = .rounded
        permissionButton.font = .systemFont(ofSize: 12)
        let root = WarmSetupView(holdPicker: holdPicker, autoPicker: autoPicker,
            startButton: startButton, permissionButton: permissionButton,
            permissionLabel: permissionLabel, statusLabel: statusLabel)
        root.onPreferences = { [weak self] in self?.showPreferences() }
        root.onAbout = { [weak self] in self?.showAbout() }
        window.contentView = root
        setupView = root
        setupWindow = window
        refreshPermission()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            if self?.cleaning == false { self?.refreshPermission() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func showAbout() {
        guard !cleaning, let window = setupWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Протереть Mac · Автомато"
        alert.informativeText = "Версия \(applicationVersion)\n\nУтилита для протирки клавиатуры, тачпада и монитора.\n\nДля выхода удерживайте мышь на жёлтой кнопке и отпустите. Аварийный выход: ⌘ ⌥ Esc.\n\nНастройки сохраняются на этом Mac."
        alert.addButton(withTitle: "Готово")
        let logo = NSImageView(frame: NSRect(x: 0, y: 0, width: 270, height: 152))
        logo.image = Bundle.main.image(forResource: "AutomatoFullLogo")
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("Автомато · AI-студия Романа Лазарева")
        alert.accessoryView = logo
        alert.beginSheetModal(for: window)
    }

    @objc private func settingsChanged() {
        settings = CleaningSettings(holdSeconds: holdPicker.selectedTag(), autoMinutes: autoPicker.selectedTag())
        settings.save()
        statusLabel.stringValue = "Настройки сохранены на этом Mac."
    }

    private func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        permissionLabel.stringValue = trusted ? "" : "Для блокировки клавиш включите «Протереть Mac» в разделе\nКонфиденциальность и безопасность → Универсальный доступ."
        permissionLabel.textColor = AutomatoStyle.ink
        startButton.isEnabled = trusted
        let changed = setupView?.trusted != trusted
        setupView?.trusted = trusted
        if changed, let root = setupView, let window = setupWindow {
            let targetHeight = root.designHeight * root.bounds.width / 720
            let delta = targetHeight - root.bounds.height
            var frame = window.frame
            frame.origin.y -= delta
            frame.size.height += delta
            window.setFrame(frame, display: true)
            root.layoutSubtreeIfNeeded()
        }
    }

    @objc private func openPermissionSettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showPreferences() {
        if !cleaning { showSetup(); setupWindow?.makeFirstResponder(holdPicker); holdPicker.performClick(nil) }
    }
    private func showSetup() {
        refreshPermission()
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func startCleaning() { startSession() }

    private func startSession(timeoutOverride: TimeInterval? = nil) {
        guard !cleaning else { return }
        guard preview || AXIsProcessTrusted() else { statusLabel.stringValue = "Сначала разрешите блокировку клавиш."; showSetup(); return }
        guard !NSScreen.screens.isEmpty else { statusLabel.stringValue = "Не найден экран. Протирка не запущена."; showSetup(); return }
        settings = CleaningSettings.load()
        let timeout = timeoutOverride ?? settings.timeout
        let sessionGuard = SessionGuard()
        do { try sessionGuard.start(timeout: timeout) } catch {
            statusLabel.stringValue = "Не удалось запустить страховочный таймер. Протирка не запущена."
            showSetup()
            return
        }
        guardProcess = sessionGuard
        primaryTop = NSScreen.screens[0].frame.maxY
        screenLayout = currentScreenLayout()
        previousPresentation = NSApp.presentationOptions
        deadline = now() + timeout
        cleaning = true
        hold.cancel()
        setupWindow?.orderOut(nil)
        for screen in NSScreen.screens {
            let window = ShieldWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.setFrame(screen.frame, display: false)
            window.level = .floating // System safety panels can remain above it.
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            let shield = ShieldView(settings: settings, preview: preview)
            window.contentView = shield
            shield.button.onDown = { [weak self, weak shield] in self?.beginHold(on: shield) }
            shield.button.onUp = { [weak self] point in self?.releaseHold(at: point) }
            shield.button.onDrag = { [weak self] point in self?.moveHold(to: point) }
            shields.append(shield)
            windows.append(window)
            window.orderFrontRegardless()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        if !preview {
            let input = InputBlocker()
            input.onPointer = { [weak self] type, point in self?.handlePointer(type: type, point: point) }
            input.onFailure = { [weak self] in self?.finish(message: "Протирка остановлена: macOS сняла блокировку ввода.") }
            input.onEmergency = { [weak self] in self?.finish(message: "Протирка завершена аварийной командой.") }
            do { try input.start(); blocker = input } catch {
                input.stop()
                finish(message: "macOS не разрешила блокировку ввода. Проверьте «Универсальный доступ».")
                return
            }
        }
        hasSleepAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Протирка Mac" as CFString, &sleepAssertion) == kIOReturnSuccess
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        tick()
    }

    private func handlePointer(type: CGEventType, point: CGPoint) {
        let location = NSPoint(x: point.x, y: primaryTop - point.y)
        switch type {
        case .leftMouseDown:
            if let shield = shields.first(where: { $0.globalButtonRect.contains(location) }) { beginHold(on: shield) }
        case .leftMouseUp: releaseHold(at: location)
        case .mouseMoved, .leftMouseDragged: moveHold(to: location)
        default: break
        }
    }

    private func beginHold(on shield: ShieldView?) {
        guard cleaning, let shield else { return }
        pressedShield = shield
        hold.begin(at: now())
        updateShields()
    }
    private func moveHold(to location: NSPoint) {
        if let pressedShield, !pressedShield.globalButtonRect.contains(location) {
            hold.cancel()
            self.pressedShield = nil
            updateShields()
        }
    }
    private func releaseHold(at location: NSPoint) {
        let inside = pressedShield?.globalButtonRect.contains(location) == true
        let unlock = hold.release(at: now(), inside: inside, duration: Double(settings.holdSeconds))
        pressedShield = nil
        if unlock {
            // Allow the callback to return first; the mouse-up never reaches another app.
            DispatchQueue.main.async { [weak self] in self?.finish(message: "Готово. Можно пользоваться Mac.") }
        } else { updateShields() }
    }

    private func tick() {
        guard cleaning else { return }
        if now() >= deadline { finish(message: "Протирка завершена по таймеру."); return }
        guard guardProcess?.beat() == true else { finish(message: "Протирка остановлена: страховочный таймер недоступен."); return }
        if !preview && blocker?.healthy != true { finish(message: "Протирка остановлена: блокировка ввода снята."); return }
        updateShields()
    }

    private func updateShields() {
        for shield in shields {
            shield.update(remaining: deadline - now(),
                progress: shield === pressedShield ? hold.progress(at: now(), duration: Double(settings.holdSeconds)) : 0,
                pressed: shield === pressedShield)
        }
    }

    func finish(message: String, showWindow: Bool = true) {
        guard cleaning else { return }
        // Input is released before windows, timers, or other resources are touched.
        cleaning = false
        blocker?.stop()
        blocker = nil
        tickTimer?.invalidate()
        tickTimer = nil
        hold.cancel()
        pressedShield = nil
        NSApp.presentationOptions = previousPresentation
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        shields.removeAll()
        if hasSleepAssertion { IOPMAssertionRelease(sleepAssertion); hasSleepAssertion = false }
        guardProcess?.stop()
        guardProcess = nil
        statusLabel.stringValue = message
        if showWindow { showSetup() }
    }

    private func observeInterruptions() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.finish(message: "Протирка остановлена: сеанс Mac изменился.", showWindow: false)
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.cleaning, self.currentScreenLayout() != self.screenLayout else { return }
            self.finish(message: "Протирка остановлена: экраны изменились.")
        })
    }
    private func currentScreenLayout() -> [String] {
        NSScreen.screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? ""
            return "\(number):\(NSStringFromRect(screen.frame))"
        }.sorted()
    }
    func applicationDidResignActive(_ notification: Notification) {
        if cleaning { finish(message: "Протирка остановлена: активно другое приложение.", showWindow: false) }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if !cleaning, setupView != nil { refreshPermission() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !cleaning { showSetup() }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === setupWindow { NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        finish(message: "", showWindow: false)
        permissionTimer?.invalidate()
        guardProcess?.stop()
    }
}

func selfTest() -> Never {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        count += 1
    }
    check(CleaningSettings(holdSeconds: -10, autoMinutes: 0) == CleaningSettings(holdSeconds: 1, autoMinutes: 1), "settings lower safety bounds")
    check(CleaningSettings(holdSeconds: 999, autoMinutes: 999) == CleaningSettings(holdSeconds: 10, autoMinutes: 15), "settings upper safety bounds")
    let store = UserDefaults(suiteName: "ru.avtomato.macwipe.tests.\(UUID().uuidString)")!
    let saved = CleaningSettings(holdSeconds: 7, autoMinutes: 11)
    saved.save(to: store)
    check(CleaningSettings.load(from: store) == saved, "settings save and reload")
    for key in ["holdSeconds", "autoMinutes"] { store.removeObject(forKey: key) }
    check(CleaningSettings.load(from: store) == CleaningSettings(), "defaults restored after empty store")
    var hold = HoldState()
    hold.begin(at: 10)
    check(!hold.release(at: 10.1, inside: true, duration: 2), "short cloth click cannot unlock")
    hold.begin(at: 10)
    check(!hold.release(at: 15, inside: false, duration: 2), "release outside cannot unlock")
    hold.begin(at: 10)
    hold.cancel()
    check(!hold.release(at: 15, inside: true, duration: 2), "dragging away cancels hold")
    hold.begin(at: 10)
    check(hold.release(at: 12, inside: true, duration: 2), "full hold and release unlock")
    check(!hold.release(at: 15, inside: true, duration: 2), "release cannot unlock twice")
    for key: Int64 in [0, 12, 49, 53] {
        check(inputDecision(type: .keyDown, keyCode: key, flags: []) == .block, "ordinary keys blocked")
    }
    check(inputDecision(type: .keyDown, keyCode: 12, flags: .maskCommand) == .block, "command Q blocked")
    check(inputDecision(type: .keyDown, keyCode: 53, flags: [.maskCommand, .maskAlternate]) == .emergency, "emergency chord always available")
    check(inputDecision(type: .flagsChanged, keyCode: 0, flags: .maskCommand) == .block, "modifier presses blocked")
    check(inputDecision(type: CGEventType(rawValue: 14)!, keyCode: 0, flags: []) == .block, "media keys blocked")
    check(inputDecision(type: .scrollWheel, keyCode: 0, flags: []) == .block, "scrolling blocked")
    check(inputDecision(type: .rightMouseDown, keyCode: 0, flags: []) == .block, "context menu blocked")
    check(inputDecision(type: .leftMouseDown, keyCode: 0, flags: []) == .pointer, "mouse unlock path reachable")
    print("PASS: \(count) safety and persistence checks")
    exit(0)
}

@main
struct MacWipeMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        if arguments.count == 4 && arguments[1] == "--guard", let parent = Int32(arguments[2]), let timeout = Double(arguments[3]) {
            runGuard(parent: parent, timeout: timeout)
        }
        if arguments.contains("--self-test") { selfTest() }
        if arguments.contains("--print-settings") {
            let settings = CleaningSettings.load()
            print("holdSeconds=\(settings.holdSeconds) autoMinutes=\(settings.autoMinutes)")
            exit(0)
        }
        if arguments.count == 3 && arguments[1] == "--render-previews" {
            do {
                try renderDesignPreviews(to: URL(fileURLWithPath: arguments[2], isDirectory: true))
                print("Rendered interface previews")
                exit(0)
            } catch { fputs("Preview rendering failed: \(error)\n", stderr); exit(74) }
        }
        if arguments.count == 3 && ["--guard-test-parent", "--guard-test-ignore-term", "--guard-test-cleanup"].contains(arguments[1]), let timeout = Double(arguments[2]) {
            if arguments[1] == "--guard-test-ignore-term" { signal(SIGTERM, SIG_IGN) }
            let guardProcess = SessionGuard()
            do { try guardProcess.start(timeout: timeout) } catch { exit(71) }
            if arguments[1] == "--guard-test-cleanup" {
                for _ in 0..<10 {
                    usleep(100_000)
                    if !guardProcess.beat() { exit(73) }
                }
                guardProcess.stop()
                usleep(200_000)
                exit(0)
            }
            // Deliberately stop heartbeats in an isolated, headless test process.
            sleep(20)
            exit(72)
        }
        let app = WipeApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        app.run()
    }
}
