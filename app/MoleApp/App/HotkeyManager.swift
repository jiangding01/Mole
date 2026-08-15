import AppKit
import Carbon.HIToolbox
import Observation

/// 一个快捷键组合（keyCode + 修饰键位）。设置·通用录制态与已保存快捷键共用同一类型
/// （设计 CHANGELOG §3.1）。
struct HotkeyCombo: Equatable, Hashable, Sendable {
    var keyCode: Int
    var modifierFlags: NSEvent.ModifierFlags

    static func == (lhs: HotkeyCombo, rhs: HotkeyCombo) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifierFlags.rawValue == rhs.modifierFlags.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifierFlags.rawValue)
    }

    /// 展示样式，如 `⇧⌘M`：修饰符固定顺序 ⌃⌥⇧⌘ + 按键字符（mono 字体渲染，设计 §3.1）。
    var displayString: String {
        var symbols = ""
        if modifierFlags.contains(.control) { symbols += "⌃" }
        if modifierFlags.contains(.option) { symbols += "⌥" }
        if modifierFlags.contains(.shift) { symbols += "⇧" }
        if modifierFlags.contains(.command) { symbols += "⌘" }
        return symbols + HotkeyKeyCodeMap.displayName(for: keyCode)
    }

    /// 转 Carbon 修饰键位，供 `RegisterEventHotKey` 使用。
    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        if modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }
}

/// keyCode → 显示字符映射（手写表，比 UCKeyTranslate 简单可靠）：覆盖 A-Z / 0-9 /
/// Space / F1-F12。未覆盖的 keyCode 显示 "Key<code>"（设计 §3.1 明确接受此兜底）。
enum HotkeyKeyCodeMap {
    static func displayName(for keyCode: Int) -> String {
        table[keyCode] ?? "Key\(keyCode)"
    }

    private static let table: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// 系统快捷键冲突对象（设计 §3.1 `CONFLICT` 常量表）。
enum HotkeyConflictTarget: String {
    case spotlight, inputSwitch, appSwitch, screenshot

    var localizedName: String {
        switch self {
        case .spotlight: L("settings.general.hotkey.conflict.spotlight")
        case .inputSwitch: L("settings.general.hotkey.conflict.inputSwitch")
        case .appSwitch: L("settings.general.hotkey.conflict.appSwitch")
        case .screenshot: L("settings.general.hotkey.conflict.screenshot")
        }
    }
}

/// 系统快捷键冲突表：⌘Space（聚焦搜索）/ ⌃Space（输入法切换）/ ⌘Tab（应用切换）/
/// ⌘⇧3（截屏）。命中仍允许保存，只在行下方给出提示（设计 §3.1，不阻断）。
enum HotkeyConflicts {
    private static let table: [HotkeyCombo: HotkeyConflictTarget] = [
        HotkeyCombo(keyCode: kVK_Space, modifierFlags: [.command]): .spotlight,
        HotkeyCombo(keyCode: kVK_Space, modifierFlags: [.control]): .inputSwitch,
        HotkeyCombo(keyCode: kVK_Tab, modifierFlags: [.command]): .appSwitch,
        HotkeyCombo(keyCode: kVK_ANSI_3, modifierFlags: [.command, .shift]): .screenshot,
    ]

    static func conflict(for combo: HotkeyCombo) -> HotkeyConflictTarget? {
        table[combo]
    }
}

/// 全局快捷键管理器（设计 CHANGELOG §3.1）：唤起 / 隐藏 Mole 主窗口。
///
/// 用 Carbon `RegisterEventHotKey` 而非常驻的全局 NSEvent 监听——前者是系统级热键
/// 注册 API，跟原生 App 一致、无需辅助功能权限；后者需要额外授权且更容易漏注销。
/// 持久化到 UserDefaults（`mole.hotkey.keyCode` / `mole.hotkey.modifiers`），
/// App 启动时（RootView onAppear）调用 `activateAtLaunch()` 注册已保存的组合。
@MainActor
@Observable
final class HotkeyManager {
    static let shared = HotkeyManager()

    private static let keyCodeDefaultsKey = "mole.hotkey.keyCode"
    private static let modifiersDefaultsKey = "mole.hotkey.modifiers"
    /// 'MOLE' 四字签名，避免与其他 App 注册的热键 ID 冲突。
    private static let hotKeyID = EventHotKeyID(signature: OSType(0x4D4F_4C45), id: 1)

    private(set) var current: HotkeyCombo?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        current = Self.loadStored()
    }

    /// App 启动时调用一次：安装 Carbon 事件处理器 + 注册已保存的快捷键（若有）。
    func activateAtLaunch() {
        installEventHandlerIfNeeded()
        if let current { register(current) }
    }

    /// 变更 / 清除快捷键：立即重注册（录制新组合、点击清除按钮都会走这里）。
    func update(_ combo: HotkeyCombo?) {
        unregister()
        current = combo
        let defaults = UserDefaults.standard
        if let combo {
            defaults.set(combo.keyCode, forKey: Self.keyCodeDefaultsKey)
            defaults.set(combo.modifierFlags.rawValue, forKey: Self.modifiersDefaultsKey)
            register(combo)
        } else {
            defaults.removeObject(forKey: Self.keyCodeDefaultsKey)
            defaults.removeObject(forKey: Self.modifiersDefaultsKey)
        }
    }

    private static func loadStored() -> HotkeyCombo? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeDefaultsKey) != nil,
              let rawModifiers = defaults.object(forKey: modifiersDefaultsKey) as? UInt else { return nil }
        let keyCode = defaults.integer(forKey: keyCodeDefaultsKey)
        return HotkeyCombo(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: rawModifiers))
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        // C 函数指针不能捕获上下文，回调内只能引用静态成员（HotkeyManager.shared）。
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ -> OSStatus in
                guard let eventRef else { return noErr }
                var pressedID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                if pressedID.id == HotkeyManager.hotKeyID.id {
                    Task { @MainActor in HotkeyManager.shared.trigger() }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    private func register(_ combo: HotkeyCombo) {
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode), combo.carbonModifiers, Self.hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        hotKeyRef = status == noErr ? ref : nil
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    /// 触发动作（设计 §3.1）：App 隐藏或非激活 → activate + 主窗口前置；已激活 → 隐藏。
    private func trigger() {
        if NSApp.isActive {
            NSApp.hide(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            (NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first)?.makeKeyAndOrderFront(nil)
        }
    }
}
