import AppKit
import Foundation

enum Health: String, Sendable {
    case normal = "正常"
    case warning = "警告"
    case critical = "严重异常"
    case disconnected = "未连接"
    case unknown = "状态未知"
}

struct DriveSnapshot: Sendable {
    var health: Health = .unknown
    var device = "—"
    var name = "USB Drive"
    var connection = "检测中"
    var throughput = "—"
    var operations = "—"
    var activity = "—"
    var errors = 0
    var lastEvent = "暂无事件"
    var sampling = "Eco：10 秒采样"
    var history = [Double]()
}

struct USBDevice: Sendable {
    let node: String
    let name: String
}

struct IOMetrics: Sendable {
    let throughput: Double
    let operations: Double
}

@MainActor
final class MonitorModel {
    var ecoMode = true { didSet { restartTimer() } }
    private(set) var snapshot = DriveSnapshot()
    private var timer: Timer?
    private var logProcess: Process?
    private var logPipe: Pipe?
    private var wasConnected: Bool?
    private var errorCount = 0

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(deviceChanged), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(deviceChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        startLogListener()
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        logPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = logProcess, process.isRunning { process.terminate() }
        logPipe = nil
        logProcess = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: ecoMode ? 10 : 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        snapshot.sampling = ecoMode ? "Eco：10 秒采样" : "增强：5 秒采样"
    }

    @objc private func deviceChanged() {
        snapshot.lastEvent = "检测到设备挂载/卸载变化"
        sample()
    }

    private func sample() {
        let task = Task.detached(priority: .utility) { Self.readSnapshot() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.apply(await task.value)
        }
    }

    private func apply(_ result: DriveSnapshot) {
        var next = result
        next.errors = errorCount
        if errorCount > 0 && next.health == .normal {
            next.health = errorCount >= 3 ? .critical : .warning
        }
        next.sampling = ecoMode ? "Eco：10 秒采样" : "增强：5 秒采样"
        next.history = Array((snapshot.history + result.history).suffix(24))
        if let wasConnected, wasConnected != (result.health != .disconnected) {
            next.lastEvent = result.health == .disconnected ? "USB drive 已断开" : "USB drive 已重新连接"
        } else if snapshot.lastEvent != "暂无事件" && snapshot.lastEvent != "检测中" {
            next.lastEvent = snapshot.lastEvent
        }
        wasConnected = result.health != .disconnected
        snapshot = next
        if result.health == .warning || result.health == .critical || result.health == .disconnected {
            restartTimerForAlert()
        } else if timer == nil {
            restartTimer()
        }
    }

    private func restartTimerForAlert() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: ecoMode ? 2 : 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func startLogListener() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--style", "compact", "--level", "error",
            "--predicate", "eventMessage CONTAINS[c] 'USB error' OR eventMessage CONTAINS[c] 'USB reset' OR eventMessage CONTAINS[c] 'USB timeout' OR eventMessage CONTAINS[c] 'USB failed' OR eventMessage CONTAINS[c] 'I/O error' OR eventMessage CONTAINS[c] 'disk error' OR eventMessage CONTAINS[c] 'device reset'"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.recordSystemError(text) }
        }
        do {
            try process.run()
            logProcess = process
            logPipe = pipe
        } catch {
            snapshot.lastEvent = "无法监听系统错误日志"
        }
    }

    private func recordSystemError(_ text: String) {
        let targetTokens = [snapshot.device.lowercased(), snapshot.name.lowercased()].filter { $0 != "—" && !$0.isEmpty }
        let line = text.split(separator: "\n").map(String.init).first { candidate in
            let lower = candidate.lowercased()
            if lower.contains("filtering the log data using") { return false }
            let pointsToTarget = lower.range(of: #"\busb\b"#, options: .regularExpression) != nil || targetTokens.contains(where: { lower.contains($0) })
            let hasError = lower.contains("error") || lower.contains("reset") || lower.contains("timeout") || lower.contains("failed") || lower.contains("i/o")
            return pointsToTarget && hasError
        }
        guard let line else { return }
        let lower = line.lowercased()
        let hasUSBWord = lower.range(of: #"\busb\b"#, options: .regularExpression) != nil
        let usbError = hasUSBWord && (lower.contains("error") || lower.contains("reset") || lower.contains("timeout") || lower.contains("failed"))
        let relevant = usbError || lower.contains("i/o error") || lower.contains("io error") || lower.contains("disk error") || lower.contains("disk failed") || lower.contains("device reset")
        guard relevant else { return }
        errorCount += 1
        snapshot.errors = errorCount
        let critical = lower.contains("i/o error") || lower.contains("reset") || lower.contains("not responding") || lower.contains("unable") || errorCount >= 3
        snapshot.health = critical ? .critical : .warning
        snapshot.lastEvent = String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
    }

    nonisolated private static func readSnapshot() -> DriveSnapshot {
        let devices = findUSBDevices()
        guard let device = devices.first else {
            return DriveSnapshot(health: .disconnected, connection: "未检测到 USB 外置物理磁盘", activity: "无目标设备", history: [0])
        }
        let metrics = readIOMetrics(for: device.node)
        guard let metrics else {
            return DriveSnapshot(health: .unknown, device: device.node, name: device.name, connection: "已连接", activity: "系统统计暂不可用", history: [0])
        }
        let active = metrics.throughput > 0.01 || metrics.operations > 0.1
        let health: Health = metrics.throughput >= 100 ? .warning : .normal
        return DriveSnapshot(health: health, device: device.node, name: device.name, connection: "已连接（USB）", throughput: String(format: "%.2f MB/s", metrics.throughput), operations: String(format: "%.1f 次/秒", metrics.operations), activity: active ? "正在活动" : "空闲", history: [min(metrics.throughput, 100)])
    }

    nonisolated private static func findUSBDevices() -> [USBDevice] {
        let listing = run("/usr/sbin/diskutil", ["list", "external", "physical"])
        let nodes = listing.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: #"/dev/disk\d+"#, options: .regularExpression) else { return nil }
            return String(line[range])
        }
        return nodes.compactMap { node in
            guard let data = runData("/usr/sbin/diskutil", ["info", "-plist", node]), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil), let info = plist as? [String: Any] else { return nil }
            let protocolName = (info["BusProtocol"] as? String ?? info["Protocol"] as? String ?? "").uppercased()
            guard protocolName.contains("USB") else { return nil }
            let name = (info["MediaName"] as? String ?? info["VolumeName"] as? String ?? node).trimmingCharacters(in: .whitespacesAndNewlines)
            return USBDevice(node: node, name: name.isEmpty ? node : name)
        }
    }

    nonisolated private static func readIOMetrics(for device: String) -> IOMetrics? {
        let deviceName = device.replacingOccurrences(of: "/dev/", with: "")
        let output = run("/usr/sbin/iostat", ["-d", "-w", "1", "-c", "2", deviceName])
        let lines = output.split(separator: "\n").map(String.init)
        guard let headerIndex = lines.firstIndex(where: { $0.range(of: #"\bdisk\d+\b"#, options: .regularExpression) != nil }) else { return nil }
        let header = lines[headerIndex].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let index = header.firstIndex(of: deviceName) else { return nil }
        for line in lines[(headerIndex + 1)...].reversed() {
            let values = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            let offset = index * 3
            if values.count >= offset + 3 { return IOMetrics(throughput: values[offset + 2], operations: values[offset + 1]) }
        }
        return nil
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> String { String(data: runData(path, args) ?? Data(), encoding: .utf8) ?? "" }

    nonisolated private static func runData(_ path: String, _ args: [String]) -> Data? {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = args; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return pipe.fileHandleForReading.readDataToEndOfFile() } catch { return nil }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MonitorModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: 76)
        statusItem.isVisible = true
        statusItem.button?.title = "USB"
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "USB Drive Monitor")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        popover = NSPopover(); popover.behavior = .transient; popover.contentSize = NSSize(width: 350, height: 430)
        popover.contentViewController = MonitorViewController(model: model, quit: quit)
        model.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateStatus() } }
        updateStatus()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) } else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    private func updateStatus() {
        let health = model.snapshot.health
        let mark: String; let color: NSColor
        switch health { case .normal: mark = "●"; color = .systemGreen; case .warning: mark = "⚠"; color = .systemOrange; case .critical: mark = "✕"; color = .systemRed; case .disconnected: mark = "–"; color = .secondaryLabelColor; case .unknown: mark = "?"; color = .systemPurple }
        statusItem.isVisible = true
        statusItem.button?.attributedTitle = NSAttributedString(string: "USB \(mark)", attributes: [.foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0)])
    }

    private func quit() {
        model.stop(); popover.performClose(nil); statusItem.isVisible = false; NSApp.terminate(nil)
    }
}

@MainActor
final class MonitorViewController: NSViewController {
    private let model: MonitorModel
    private let quitAction: () -> Void
    private let fields = (0..<9).map { _ in NSTextField(labelWithString: "") }
    private let trend = NSTextField(labelWithString: "")
    private let eco = NSSwitch()
    private let ecoIndicator = NSTextField(labelWithString: "●")
    private let ecoState = NSTextField(labelWithString: "")

    init(model: MonitorModel, quit: @escaping () -> Void) { self.model = model; self.quitAction = quit; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 430))
        fields[0].font = .boldSystemFont(ofSize: 17); fields[1].font = .boldSystemFont(ofSize: 14); fields[2].textColor = .secondaryLabelColor; trend.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let stack = NSStackView(views: [fields[0], fields[1], fields[2], separator(), fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], separator(), NSTextField(labelWithString: "最近趋势（内存，约 10 分钟）"), trend, ecoRow(), NSTextField(labelWithString: "Eco：10 秒采样；异常：2 秒采样\n增强：5 秒采样；异常：1 秒采样"), button("退出工具", action: #selector(quit))])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16)])
        eco.state = .on; eco.isEnabled = true; eco.target = self; eco.action = #selector(toggleEco); ecoIndicator.font = .systemFont(ofSize: 14, weight: .bold); ecoState.font = .systemFont(ofSize: 12, weight: .medium); view = root
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }; refresh()
    }

    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func row(_ text: String, _ control: NSControl) -> NSStackView { NSStackView(views: [NSTextField(labelWithString: text), control]) }
    private func ecoRow() -> NSStackView { NSStackView(views: [NSTextField(labelWithString: "Eco 模式"), ecoIndicator, eco, ecoState]) }
    private func button(_ title: String, action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button }
    @objc private func toggleEco() { model.ecoMode = eco.state == .on; refresh() }
    @objc private func quit() { quitAction() }

    private func refresh() {
        let snap = model.snapshot
        fields[0].stringValue = snap.name; fields[1].stringValue = "状态：\(snap.health.rawValue)"; fields[2].stringValue = snap.lastEvent
        fields[1].textColor = snap.health == .normal ? .systemGreen : (snap.health == .warning ? .systemOrange : .systemRed)
        fields[3].stringValue = "设备：\(snap.device)"; fields[4].stringValue = "连接：\(snap.connection)"; fields[5].stringValue = "吞吐量：\(snap.throughput)"; fields[6].stringValue = "I/O 次数：\(snap.operations)"; fields[7].stringValue = "活动状态：\(snap.activity)"; fields[8].stringValue = "系统错误：\(snap.errors)（被动日志监听）"
        ecoState.stringValue = model.ecoMode ? "已开启 · 低负荷" : "已关闭 · 增强采样"
        ecoState.textColor = model.ecoMode ? .systemGreen : .systemOrange
        ecoIndicator.textColor = model.ecoMode ? .systemBlue : .secondaryLabelColor
        trend.stringValue = snap.history.isEmpty ? "暂无采样" : snap.history.map { String(repeating: "▮", count: max(1, min(10, Int($0 / 10)))) }.joined(separator: " ")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
