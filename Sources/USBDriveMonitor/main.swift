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
    var lastSystemErrorTime = "暂无"
    var lastSystemErrorReason = "暂无"
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

struct SystemErrorRecord: Codable, Equatable, Sendable {
    let timestamp: Date
    let message: String
    let critical: Bool
}

@MainActor
final class MonitorModel {
    private static let lastSystemErrorTimeKey = "lastSystemErrorTime"
    private static let systemErrorRecordsKey = "systemErrorRecords"
    private static let showThroughputInStatusBarKey = "showThroughputInStatusBar"
    private static let maxSystemErrorAge: TimeInterval = 24 * 60 * 60
    private static let maxSystemErrorRecords = 100
    private static let maxSystemErrorStorageBytes = 64 * 1024

    var ecoMode = true { didSet { restartTimer() } }
    private(set) var showsThroughputInStatusBar = false
    var onStatusBarPresentationChange: (() -> Void)?
    private(set) var snapshot = DriveSnapshot()
    private var timer: Timer?
    private var logProcess: Process?
    private var logPipe: Pipe?
    private var wasConnected: Bool?
    private var errorCount = 0
    private var systemErrorRecords = [SystemErrorRecord]()
    private var lastLogPrune = Date.distantPast

    init() {
        showsThroughputInStatusBar = UserDefaults.standard.bool(forKey: Self.showThroughputInStatusBarKey)
        systemErrorRecords = Self.loadSystemErrorRecords()
        errorCount = systemErrorRecords.count
        if let latest = systemErrorRecords.last {
            snapshot.lastSystemErrorTime = Self.formatTimestamp(latest.timestamp)
            snapshot.lastSystemErrorReason = latest.message
            snapshot.lastEvent = latest.message
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastSystemErrorTimeKey)
        }
    }

    func setShowsThroughputInStatusBar(_ enabled: Bool) {
        guard showsThroughputInStatusBar != enabled else { return }
        showsThroughputInStatusBar = enabled
        UserDefaults.standard.set(enabled, forKey: Self.showThroughputInStatusBarKey)
        onStatusBarPresentationChange?()
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(deviceChanged), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(deviceChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        startLogListener()
        restoreRecentSystemErrors()
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
        pruneSystemErrorRecordsIfNeeded()
        var next = result
        next.errors = errorCount
        next.lastSystemErrorTime = snapshot.lastSystemErrorTime
        next.lastSystemErrorReason = snapshot.lastSystemErrorReason
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
            "--predicate", "eventMessage CONTAINS[c] 'USB' OR eventMessage CONTAINS[c] 'disk' OR eventMessage CONTAINS[c] 'I/O' OR eventMessage CONTAINS[c] 'media'"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.recordSystemErrors(from: text) }
        }
        do {
            try process.run()
            logProcess = process
            logPipe = pipe
        } catch {
            snapshot.lastEvent = "无法监听系统错误日志"
        }
    }

    private func recordSystemErrors(from text: String) {
        for line in text.split(separator: "\n").map(String.init) {
            recordSystemError(line)
        }
    }

    private func recordSystemError(_ text: String) {
        let targetTokens = [snapshot.device.lowercased(), snapshot.name.lowercased()].filter { $0 != "—" && !$0.isEmpty }
        let line = text.split(separator: "\n").map(String.init).first { candidate in
            Self.isRelevantStorageError(candidate, targetTokens: targetTokens)
        }
        guard let line else { return }
        let lower = line.lowercased()
        let timestamp = Date()
        let critical = lower.contains("i/o error") || lower.contains("reset") || lower.contains("not responding") || lower.contains("unable") || errorCount + 1 >= 3
        let message = String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        let eventTimestamp = Self.timestamp(from: line) ?? timestamp
        guard !systemErrorRecords.contains(where: { $0.timestamp == eventTimestamp && $0.message == message }) else { return }
        systemErrorRecords.append(SystemErrorRecord(timestamp: eventTimestamp, message: message, critical: critical))
        systemErrorRecords = Self.prunedSystemErrorRecords(systemErrorRecords, now: timestamp)
        errorCount = systemErrorRecords.count
        persistSystemErrorRecords()
        snapshot.errors = errorCount
        snapshot.lastSystemErrorTime = Self.formatTimestamp(eventTimestamp)
        snapshot.lastSystemErrorReason = message
        snapshot.health = critical ? .critical : .warning
        snapshot.lastEvent = message
    }

    private func restoreRecentSystemErrors() {
        let task = Task.detached(priority: .utility) { Self.readRecentSystemLogText() }
        Task { @MainActor [weak self] in
            guard let self, let text = await task.value else { return }
            self.recordSystemErrors(from: text)
        }
    }

    private func pruneSystemErrorRecordsIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastLogPrune) >= 60 else { return }
        lastLogPrune = now
        let pruned = Self.prunedSystemErrorRecords(systemErrorRecords, now: now)
        guard pruned != systemErrorRecords else { return }
        systemErrorRecords = pruned
        errorCount = pruned.count
        persistSystemErrorRecords()
        if let latest = pruned.last {
            snapshot.lastSystemErrorTime = Self.formatTimestamp(latest.timestamp)
            snapshot.lastSystemErrorReason = latest.message
        } else {
            snapshot.lastSystemErrorTime = "暂无"
            snapshot.lastSystemErrorReason = "暂无"
        }
    }

    private func persistSystemErrorRecords() {
        guard let data = try? JSONEncoder().encode(systemErrorRecords) else { return }
        UserDefaults.standard.set(data, forKey: Self.systemErrorRecordsKey)
        if let latest = systemErrorRecords.last {
            UserDefaults.standard.set(Self.formatTimestamp(latest.timestamp), forKey: Self.lastSystemErrorTimeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastSystemErrorTimeKey)
        }
    }

    private static func loadSystemErrorRecords() -> [SystemErrorRecord] {
        guard let data = UserDefaults.standard.data(forKey: systemErrorRecordsKey),
              let records = try? JSONDecoder().decode([SystemErrorRecord].self, from: data) else { return [] }
        let relevantRecords = records.filter { isRelevantStorageError($0.message, targetTokens: []) }
        let pruned = prunedSystemErrorRecords(relevantRecords, now: Date())
        if let prunedData = try? JSONEncoder().encode(pruned) {
            UserDefaults.standard.set(prunedData, forKey: systemErrorRecordsKey)
        }
        return pruned
    }

    private static func isRelevantStorageError(_ text: String, targetTokens: [String]) -> Bool {
        let lower = text.lowercased()
        if lower.contains("filtering the log data using") { return false }
        let hasError = lower.contains("error") || lower.contains("reset") || lower.contains("timeout") || lower.contains("failed") || lower.contains("not responding") || lower.contains("unavailable")
        guard hasError else { return false }

        let namesTarget = targetTokens.contains(where: { !$0.isEmpty && lower.contains($0) })
        let hasUSBStorageMarker = lower.contains("iousb") || lower.contains("usbmsc") || lower.contains("usb mass storage") || lower.contains("usbhost") || lower.range(of: #"\busb\s+(device|error|reset|timeout|failed|storage)\b"#, options: .regularExpression) != nil
        let hasDiskStorageMarker = lower.range(of: #"(?:/dev/)?disk\d+\b"#, options: .regularExpression) != nil || lower.range(of: #"\bdisk\s+(error|reset|timeout|failed|i/o|not responding)\b"#, options: .regularExpression) != nil
        let hasStorageIO = lower.contains("i/o error") || lower.contains("io error") || lower.contains("media error") || lower.contains("media not present")
        return namesTarget || hasUSBStorageMarker || hasDiskStorageMarker || (hasStorageIO && (lower.contains("usb") || lower.contains("disk") || lower.contains("media")))
    }

    private static func prunedSystemErrorRecords(_ records: [SystemErrorRecord], now: Date) -> [SystemErrorRecord] {
        var kept = records.filter { now.timeIntervalSince($0.timestamp) <= maxSystemErrorAge }
        if kept.count > maxSystemErrorRecords {
            kept.removeFirst(kept.count - maxSystemErrorRecords)
        }
        while kept.count > 1,
              let data = try? JSONEncoder().encode(kept),
              data.count > maxSystemErrorStorageBytes {
            kept.removeFirst()
        }
        return kept
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func timestamp(from line: String) -> Date? {
        let prefix = String(line.prefix(23))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: prefix)
    }

    nonisolated private static func readRecentSystemLogText() -> String? {
        let maxReadBytes = 64 * 1024
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "24h", "--style", "compact", "--level", "error",
            "--predicate", "eventMessage CONTAINS[c] 'USB' OR eventMessage CONTAINS[c] 'disk' OR eventMessage CONTAINS[c] 'I/O' OR eventMessage CONTAINS[c] 'media'"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readData(ofLength: maxReadBytes + 1)
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return String(data: data.prefix(maxReadBytes), encoding: .utf8)
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
final class TwoLineStatusBarView: NSView {
    private let statusLabel = NSTextField(labelWithString: "")
    private let throughputLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [statusLabel, throughputLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 66),
            heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        statusLabel.font = .menuBarFont(ofSize: 0)
        throughputLabel.font = .systemFont(ofSize: 9)
        throughputLabel.textColor = .secondaryLabelColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(mark: String, color: NSColor, throughput: String) {
        statusLabel.stringValue = "USB \(mark)"
        statusLabel.textColor = color
        throughputLabel.stringValue = throughput
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MonitorModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var twoLineStatusBarView: TwoLineStatusBarView?
    private var statusBarPresentation: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.title = "USB"
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "USB Drive Monitor")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        popover = NSPopover(); popover.behavior = .transient; popover.contentSize = NSSize(width: 350, height: 470)
        popover.contentViewController = MonitorViewController(model: model, quit: quit)
        model.onStatusBarPresentationChange = { [weak self] in self?.updateStatus() }
        model.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateStatus() } }
        updateStatus()
    }

    @objc private func togglePopover() {
        let anchor: NSView?
        if model.showsThroughputInStatusBar {
            anchor = twoLineStatusBarView
        } else {
            anchor = statusItem.button
        }
        guard let anchor else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    private func updateStatus() {
        let health = model.snapshot.health
        let mark: String; let color: NSColor
        switch health { case .normal: mark = "●"; color = .systemGreen; case .warning: mark = "⚠"; color = .systemOrange; case .critical: mark = "✕"; color = .systemRed; case .disconnected: mark = "–"; color = .secondaryLabelColor; case .unknown: mark = "?"; color = .systemPurple }
        statusItem.isVisible = true
        if statusBarPresentation != model.showsThroughputInStatusBar {
            statusBarPresentation = model.showsThroughputInStatusBar
            if model.showsThroughputInStatusBar {
                let view = twoLineStatusBarView ?? TwoLineStatusBarView(frame: NSRect(x: 0, y: 0, width: 66, height: 26))
                view.onClick = { [weak self] in self?.togglePopover() }
                twoLineStatusBarView = view
                statusItem.view = view
                statusItem.length = 66
            } else {
                statusItem.view = nil
                statusItem.length = NSStatusItem.variableLength
                statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "USB Drive Monitor")
                statusItem.button?.imagePosition = .imageLeading
                statusItem.button?.target = self
                statusItem.button?.action = #selector(togglePopover)
            }
        }
        if model.showsThroughputInStatusBar {
            twoLineStatusBarView?.update(mark: mark, color: color, throughput: model.snapshot.throughput)
        } else {
            statusItem.button?.attributedTitle = NSAttributedString(string: "USB \(mark)", attributes: [.foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0)])
        }
    }

    private func quit() {
        model.stop(); popover.performClose(nil); statusItem.isVisible = false; NSApp.terminate(nil)
    }
}

@MainActor
final class MonitorViewController: NSViewController {
    private let model: MonitorModel
    private let quitAction: () -> Void
    private let fields = (0..<11).map { _ in NSTextField(labelWithString: "") }
    private let trend = NSTextField(labelWithString: "")
    private let eco = NSSwitch()
    private let ecoState = NSTextField(labelWithString: "")
    private let statusBarThroughput = NSSwitch()
    private let statusBarThroughputState = NSTextField(labelWithString: "")

    init(model: MonitorModel, quit: @escaping () -> Void) { self.model = model; self.quitAction = quit; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 470))
        fields[0].font = .boldSystemFont(ofSize: 17); fields[1].font = .boldSystemFont(ofSize: 14); fields[2].textColor = .secondaryLabelColor; trend.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        trend.translatesAutoresizingMaskIntoConstraints = false
        trend.widthAnchor.constraint(equalToConstant: 314).isActive = true
        trend.maximumNumberOfLines = 1; trend.lineBreakMode = .byTruncatingTail
        fields[10].lineBreakMode = .byWordWrapping; fields[10].maximumNumberOfLines = 2; fields[10].preferredMaxLayoutWidth = 314
        let stack = NSStackView(views: [fields[0], fields[1], fields[2], separator(), fields[3], fields[4], throughputRow(), fields[6], fields[7], fields[8], fields[9], fields[10], separator(), NSTextField(labelWithString: "最近趋势（内存，约 10 分钟）"), trend, ecoRow(), NSTextField(labelWithString: "Eco：10 秒采样；异常：2 秒采样\n增强：5 秒采样；异常：1 秒采样"), button("退出工具", action: #selector(quit))])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16)])
        eco.state = .on; eco.isEnabled = true; eco.target = self; eco.action = #selector(toggleEco); ecoState.font = .systemFont(ofSize: 12, weight: .medium); view = root
        statusBarThroughput.target = self; statusBarThroughput.action = #selector(toggleStatusBarThroughput); statusBarThroughputState.font = .systemFont(ofSize: 12, weight: .medium)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }; refresh()
    }

    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func row(_ text: String, _ control: NSControl) -> NSStackView { NSStackView(views: [NSTextField(labelWithString: text), control]) }
    private func throughputRow() -> NSStackView {
        let row = NSStackView(views: [fields[5], statusBarThroughput, statusBarThroughputState])
        row.alignment = .centerY; row.spacing = 6
        return row
    }
    private func ecoRow() -> NSStackView { NSStackView(views: [NSTextField(labelWithString: "Eco 模式"), eco, ecoState]) }
    private func button(_ title: String, action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button }
    @objc private func toggleEco() { model.ecoMode = eco.state == .on; refresh() }
    @objc private func toggleStatusBarThroughput() { model.setShowsThroughputInStatusBar(statusBarThroughput.state == .on); refresh() }
    @objc private func quit() { quitAction() }

    private func refresh() {
        let snap = model.snapshot
        fields[0].stringValue = snap.name; fields[1].stringValue = "状态：\(snap.health.rawValue)"; fields[2].stringValue = snap.lastEvent
        fields[1].textColor = snap.health == .normal ? .systemGreen : (snap.health == .warning ? .systemOrange : .systemRed)
        fields[3].stringValue = "设备：\(snap.device)"; fields[4].stringValue = "连接：\(snap.connection)"; fields[5].stringValue = "吞吐量：\(snap.throughput)"; fields[6].stringValue = "I/O 次数：\(snap.operations)"; fields[7].stringValue = "活动状态：\(snap.activity)"; fields[8].stringValue = "系统错误：\(snap.errors)（最近 24 小时，最多 100 条）"; fields[9].stringValue = "上一次系统错误时间：\(snap.lastSystemErrorTime)"; fields[10].stringValue = "错误日志：\(snap.lastSystemErrorReason)"
        statusBarThroughput.state = model.showsThroughputInStatusBar ? .on : .off
        statusBarThroughputState.stringValue = model.showsThroughputInStatusBar ? "实时显示" : "不显示"
        statusBarThroughputState.textColor = model.showsThroughputInStatusBar ? .systemGreen : .secondaryLabelColor
        ecoState.stringValue = model.ecoMode ? "已开启 · 低负荷" : "已关闭 · 增强采样"
        ecoState.textColor = model.ecoMode ? .systemGreen : .systemOrange
        let levels = Array("▁▂▃▄▅▆▇█")
        trend.stringValue = snap.history.isEmpty ? "暂无采样" : snap.history.suffix(24).map { value in String(levels[max(0, min(levels.count - 1, Int(value / 12.5)))]) }.joined()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
