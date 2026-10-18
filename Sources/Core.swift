import AppKit
import Carbon
import ServiceManagement

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | shiftKey))
    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    var label: String {
        var result = ""
        for (flag, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(flag) != 0 { result += symbol + " " }
        }
        return result + Self.keyName(keyCode)
    }
    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",49:"空格",50:"`",65:"小数点",67:"×",69:"+",75:"÷",78:"−",81:"=",82:"0",83:"1",84:"2",85:"3",86:"4",87:"5",88:"6",89:"7",91:"8",92:"9",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",118:"F4",120:"F2",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
        return names[code] ?? "按键 \(code)"
    }
    static func from(_ event: NSEvent) -> Shortcut {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
    }
    var validationError: String? {
        if modifiers & UInt32(cmdKey | optionKey | controlKey) == 0 { return "请搭配 ⌘、⌃ 或 ⌥ 中的至少一个修饰键。" }
        if [36,48,51,53,76,117].contains(keyCode) { return "请使用字母、数字、方向键或功能键。" }
        if modifiers == UInt32(cmdKey | shiftKey), [20,21,23].contains(keyCode) { return "这个组合用于系统截图，请换一个。" }
        if modifiers == UInt32(cmdKey), [12,48,49].contains(keyCode) { return "这个组合用于系统或应用操作，请换一个。" }
        return nil
    }
}

final class HotKeyController {
    private var current: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var counter: UInt32 = 0
    private var currentID: UInt32 = 0
    var action: () -> Void = {}
    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ref in
            guard let event = event, let ref = ref else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKeyController>.fromOpaque(ref).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == 0x536E7042, id.id == owner.currentID else { return OSStatus(eventNotHandledErr) }
            owner.action(); return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func replace(with shortcut: Shortcut) -> OSStatus {
        counter &+= 1
        var candidate: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x536E7042, id: counter)
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &candidate)
        guard result == noErr, candidate != nil else { return result == noErr ? OSStatus(paramErr) : result }
        if let old = current { UnregisterEventHotKey(old) }
        current = candidate; currentID = counter
        return noErr
    }
    deinit { if let key = current { UnregisterEventHotKey(key) }; if let handler = handler { RemoveEventHandler(handler) } }
}

enum ImageFormat: String, CaseIterable { case png = "PNG", jpg = "JPG"
    var extensionName: String { rawValue.lowercased() }
}

@MainActor final class AppModel: ObservableObject {
    let defaults: UserDefaults
    @Published var shortcut: Shortcut
    @Published var autoSave: Bool { didSet { defaults.set(autoSave, forKey: "autoSave") } }
    @Published var format: ImageFormat { didSet { defaults.set(format.rawValue, forKey: "format") } }
    @Published var showToast: Bool { didSet { defaults.set(showToast, forKey: "showToast") } }
    @Published var folder: URL
    @Published var permission = CGPreflightScreenCaptureAccess()
    @Published var shortcutError = ""
    @Published var settingsMessage = ""
    @Published var recording = false
    @Published var loginEnabled = false
    @Published var hotkeyReady = false
    @Published var busy = false
    @Published var lastSaved: URL?
    var changeShortcut: ((Shortcut) -> OSStatus)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "shortcut"), let value = try? JSONDecoder().decode(Shortcut.self, from: data), value.validationError == nil { shortcut = value } else { shortcut = .default }
        autoSave = defaults.bool(forKey: "autoSave")
        format = ImageFormat(rawValue: defaults.string(forKey: "format") ?? "PNG") ?? .png
        showToast = defaults.object(forKey: "showToast") as? Bool ?? true
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        folder = defaults.string(forKey: "folderPath").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? desktop
        if let data = defaults.data(forKey: "folderBookmark") {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { folder = resolved }
        }
        refreshStatus()
    }
    func refreshStatus() {
        permission = CGPreflightScreenCaptureAccess()
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
    @discardableResult func setShortcut(_ value: Shortcut) -> Bool {
        if let error = value.validationError { shortcutError = error; return false }
        if value == shortcut, hotkeyReady { shortcutError = ""; return true }
        let code = changeShortcut?(value) ?? OSStatus(eventNotHandledErr)
        guard code == noErr else { shortcutError = "组合键可能已被占用（\(code)），原快捷键仍保留。请换一个。"; return false }
        shortcut = value; hotkeyReady = true; shortcutError = ""
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "shortcut") }
        return true
    }
    func chooseFolder() {
        recording = false
        let panel = NSOpenPanel(); panel.title = "选择截图保存位置"; panel.prompt = "选择文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            folder = url; defaults.set(url.path, forKey: "folderPath")
            if let data = try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) { defaults.set(data, forKey: "folderBookmark") }
            settingsMessage = ""
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshStatus()
            settingsMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许轻截启动。" : ""
        } catch { settingsMessage = "开机启动设置失败：\(error.localizedDescription)"; refreshStatus() }
    }
    func openPermissions() {
        recording = false
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

enum FileStore {
    static func encode(_ image: CGImage, as format: ImageFormat) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let properties: [NSBitmapImageRep.PropertyKey: Any] = format == .jpg ? [.compressionFactor: 0.92] : [:]
        guard let data = bitmap.representation(using: format == .png ? .png : .jpeg, properties: properties) else { throw AppError.message("无法编码图片，请重试。") }
        return data
    }
    static func suggestedName(format: ImageFormat, date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HHmmss_SSS"
        return "截图_" + formatter.string(from: date) + "." + format.extensionName
    }
    static func saveAutomatically(_ image: CGImage, folder: URL, format: ImageFormat) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AppError.message("保存文件夹不存在，请在设置里重新选择。") }
        let data = try encode(image, as: format)
        let name = suggestedName(format: format)
        var url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + "_" + UUID().uuidString.prefix(6) + "." + format.extensionName) }
        try data.write(to: url, options: [.withoutOverwriting])
        return url
    }
    static func copy(_ image: CGImage) throws {
        let data = try encode(image, as: .png)
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setData(data, forType: .png) else { throw AppError.message("无法写入剪贴板，请重试。") }
        // Some native chat clients request TIFF even when PNG is available.
        if let tiff = NSBitmapImageRep(cgImage:image).tiffRepresentation { board.setData(tiff,forType:.tiff) }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
