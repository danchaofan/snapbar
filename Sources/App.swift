import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let hotkey = HotKeyController()
    private let capture = CaptureCoordinator()
    private var settingsWindow: NSWindow?
    private var toastWindow: NSPanel?
    private var previousApp: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []
    private var toastWork: DispatchWorkItem?
    private var saving = false

    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory);installMenu()
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        if let button=statusItem.button {
            button.image=NSImage(systemSymbolName:"viewfinder",accessibilityDescription:"轻截")
            button.image?.isTemplate=true;button.target=self;button.action=#selector(togglePopover)
            button.sendAction(on:[.leftMouseUp,.rightMouseUp]);button.toolTip="轻截 · \(model.shortcut.label)"
        }
        popover.behavior = .transient;popover.animates=true
        hotkey.action = { [weak self] in DispatchQueue.main.async {
            guard let self=self else { return }
            if self.model.recording { self.model.recording=false;self.model.shortcutError="" }
            else { self.beginCapture() }
        } }
        model.changeShortcut = { [weak self] shortcut in
            guard let self=self else { return -1 }
            let result=self.hotkey.replace(with:shortcut)
            if result==noErr { self.statusItem.button?.toolTip="轻截 · \(shortcut.label)" }
            return result
        }
        let result=hotkey.replace(with:model.shortcut);model.hotkeyReady=result==noErr
        if result != noErr { model.shortcutError="快捷键注册失败（\(result)），请录入其他组合。" }
        capture.completed = { [weak self] image,save in self?.handleCapture(image,manualSave:save) }
        capture.cancelled = { [weak self] in self?.model.busy=false;self?.restorePreviousApp() }
        capture.failed = { [weak self] error in self?.model.busy=false;self?.showError("截图未完成",detail:error) }
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor [weak self] in self?.model.refreshStatus() } })
        observers.append(DistributedNotificationCenter.default().addObserver(forName:Notification.Name("com.local.SnapBar.show"),object:nil,queue:.main) { [weak self] _ in Task { @MainActor [weak self] in self?.showPopover() } })
        if !model.defaults.bool(forKey:"hasLaunched") {
            model.defaults.set(true,forKey:"hasLaunched")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.showPopover() }
        }
    }
    private func installMenu() {
        let menu=NSMenu();let appItem=NSMenuItem();menu.addItem(appItem)
        let appMenu=NSMenu();appMenu.addItem(withTitle:"退出轻截",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");appItem.submenu=appMenu
        let editItem=NSMenuItem();menu.addItem(editItem);let edit=NSMenu(title:"编辑");editItem.submenu=edit
        for (title,selector,key) in [("撤销",Selector(("undo:")),"z"),("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:selector,keyEquivalent:key) }
        NSApp.mainMenu=menu
    }
    @objc private func togglePopover() {
        guard !model.busy else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu=NSMenu()
            for (title,action) in [("开始截图",#selector(beginCapture)),("设置…",#selector(showSettings))] { let item=menu.addItem(withTitle:title,action:action,keyEquivalent:"");item.target=self }
            menu.addItem(.separator());menu.addItem(withTitle:"退出轻截",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            statusItem.menu=menu;statusItem.button?.performClick(nil);statusItem.menu=nil
        } else if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard !model.busy,let button=statusItem?.button else { return }
        if let front=NSWorkspace.shared.frontmostApplication,front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp=front }
        model.refreshStatus()
        let view=MenuPanel(model:model,capture:{ [weak self] in self?.beginCapture() },settings:{ [weak self] in self?.showSettings() })
        let controller=NSHostingController(rootView:view);popover.contentViewController=controller
        popover.contentSize=controller.view.fittingSize
        NSApp.activate(ignoringOtherApps:true);popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    @objc func showSettings() {
        popover.performClose(nil);model.refreshStatus()
        if settingsWindow==nil {
            let host=NSHostingView(rootView:SettingsView(model:model))
            let window=NSWindow(contentRect:CGRect(x:0,y:0,width:494,height:690),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="轻截设置";window.isReleasedWhenClosed=false;window.delegate=self
            window.contentView=host;window.setContentSize(CGSize(width:494,height:host.fittingSize.height+12));window.center();settingsWindow=window
        }
        NSApp.activate(ignoringOtherApps:true);settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification:Notification) { model.recording=false }
    @objc func beginCapture() {
        guard !model.busy,!model.recording,!saving else { return }
        let front=NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp=front }
        model.refreshStatus()
        guard model.permission else {
            popover.performClose(nil)
            let alert=NSAlert();alert.messageText="允许轻截读取屏幕";alert.informativeText="截图需要 macOS 的屏幕录制权限。请在系统设置里允许「轻截」，然后再次截图。刚授权后，系统可能要求退出并重新打开 App。"
            alert.addButton(withTitle:"去授权");alert.addButton(withTitle:"暂不")
            NSApp.activate(ignoringOtherApps:true)
            if alert.runModal() == .alertFirstButtonReturn { model.openPermissions() }
            return
        }
        let dismissingUI=popover.isShown || settingsWindow?.isVisible == true || toastWindow?.isVisible == true
        model.busy=true;popover.performClose(nil);settingsWindow?.orderOut(nil);toastWindow?.orderOut(nil)
        if dismissingUI,let app=previousApp,!app.isTerminated { app.activate(options:[.activateIgnoringOtherApps]) }
        DispatchQueue.main.asyncAfter(deadline:.now()+(dismissingUI ? 0.12 : 0)) { [weak self] in
            guard let self=self else { return }
            do { try self.capture.start() } catch { self.model.busy=false;self.showError("无法开始截图",detail:error.localizedDescription) }
        }
    }
    private func handleCapture(_ image:CGImage,manualSave:Bool) {
        model.busy=false
        do { try FileStore.copy(image) } catch { showError("无法复制截图",detail:error.localizedDescription);return }
        if manualSave { saveAs(image);return }
        if model.autoSave {
            do { let url=try FileStore.saveAutomatically(image,folder:model.folder,format:model.format);model.lastSaved=url;restorePreviousApp();showToast("已复制并保存",detail:url.lastPathComponent) }
            catch {
                let alert=NSAlert();alert.messageText="截图已复制，保存失败";alert.informativeText=error.localizedDescription+"\n图片仍在剪贴板中，也可以现在另存为。";alert.addButton(withTitle:"另存为…");alert.addButton(withTitle:"稍后")
                NSApp.activate(ignoringOtherApps:true)
                if alert.runModal() == .alertFirstButtonReturn { saveAs(image) } else { restorePreviousApp() }
            }
        } else { restorePreviousApp();showToast("已复制到剪贴板",detail:"可直接粘贴到聊天或文档") }
    }
    private func saveAs(_ image:CGImage) {
        saving=true;defer { saving=false }
        NSApp.activate(ignoringOtherApps:true)
        let panel=NSSavePanel();panel.title="保存截图";panel.prompt="保存";panel.directoryURL=model.folder
        panel.nameFieldStringValue=FileStore.suggestedName(format:model.format);panel.canCreateDirectories=true;panel.isExtensionHidden=false
        let accessory=SaveFormatAccessory(panel:panel,format:model.format);panel.accessoryView=accessory.view
        while true {
            guard panel.runModal() == .OK,let url=panel.url else { restorePreviousApp();showToast("已复制到剪贴板",detail:"已取消保存文件");return }
            do {
                try FileStore.encode(image,as:accessory.format).write(to:url,options:.atomic)
                model.lastSaved=url;restorePreviousApp();showToast("已复制并保存",detail:url.lastPathComponent);return
            } catch {
                let alert=NSAlert();alert.messageText="无法保存图片";alert.informativeText=error.localizedDescription+"\n截图已经复制到剪贴板。";alert.addButton(withTitle:"重新选择位置");alert.addButton(withTitle:"取消")
                if alert.runModal() != .alertFirstButtonReturn { restorePreviousApp();return }
            }
        }
    }
    private func restorePreviousApp() { if let app=previousApp,!app.isTerminated { app.activate(options:[.activateIgnoringOtherApps]) } }
    private func showToast(_ title:String,detail:String) {
        guard model.showToast else { return }
        toastWork?.cancel();toastWindow?.close()
        let view=ToastView(title:title,detail:detail)
        let panel=NSPanel(contentRect:CGRect(x:0,y:0,width:350,height:78),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isFloatingPanel=true;panel.isReleasedWhenClosed=false;panel.level = .floating;panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true;panel.ignoresMouseEvents=true
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.contentView=NSHostingView(rootView:view)
        let screen=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main
        if let frame=screen?.visibleFrame { panel.setFrameOrigin(CGPoint(x:frame.midX-175,y:frame.minY+50)) }
        panel.orderFrontRegardless();toastWindow=panel
        let task=DispatchWorkItem { [weak self,weak panel] in panel?.close();self?.toastWindow=nil };toastWork=task
        DispatchQueue.main.asyncAfter(deadline:.now()+2.4,execute:task)
    }
    private func showError(_ title:String,detail:String) {
        NSApp.activate(ignoringOtherApps:true);let alert=NSAlert();alert.messageText=title;alert.informativeText=detail;alert.addButton(withTitle:"好");alert.runModal()
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { showPopover();return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationWillTerminate(_ notification:Notification) { capture.close();for observer in observers { NotificationCenter.default.removeObserver(observer);DistributedNotificationCenter.default().removeObserver(observer) } }
}

struct ToastView: View {
    var title:String;var detail:String
    var body: some View { HStack(spacing:12) { Image(systemName:"checkmark.circle.fill").font(.system(size:24)).foregroundColor(.green);VStack(alignment:.leading,spacing:3) { Text(title).font(.system(size:13,weight:.medium));Text(detail).font(.system(size:11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle) };Spacer(minLength:0) }.padding(16).frame(width:350,height:78).background(.regularMaterial,in:RoundedRectangle(cornerRadius:13)) }
}

final class SaveFormatAccessory: NSObject {
    let view=NSView(frame:CGRect(x:0,y:0,width:280,height:34))
    private let picker=NSPopUpButton(frame:CGRect(x:90,y:4,width:120,height:26),pullsDown:false)
    private weak var panel:NSSavePanel?
    var format:ImageFormat { picker.indexOfSelectedItem==1 ? .jpg : .png }
    init(panel:NSSavePanel,format:ImageFormat) {
        self.panel=panel;super.init()
        let label=NSTextField(labelWithString:"图片格式：");label.frame=CGRect(x:8,y:8,width:80,height:20);view.addSubview(label)
        picker.addItems(withTitles:["PNG","JPG"]);picker.selectItem(at:format == .png ? 0 : 1);picker.target=self;picker.action=#selector(changed);view.addSubview(picker);applyType()
    }
    private func applyType() { panel?.allowedContentTypes=[format == .png ? .png : .jpeg] }
    @objc private func changed() {
        guard let panel=panel else { return };let base=(panel.nameFieldStringValue as NSString).deletingPathExtension
        applyType();panel.nameFieldStringValue=base+"."+format.extensionName
    }
}

@main enum SnapBarMain {
    @MainActor static func main() {
        let args=CommandLine.arguments
        if args.contains("--quit-running") {
            let running=NSRunningApplication.runningApplications(withBundleIdentifier:"com.local.SnapBar").filter{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}
            running.forEach{_ = $0.terminate()}
            let deadline=Date().addingTimeInterval(3)
            while running.contains(where:{!$0.isTerminated}) && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.05))}
            exit(running.allSatisfy{$0.isTerminated} ? 0 : 1)
        }
        if args.contains("--self-test") { exit(SelfTests.run() ? 0 : 1) }
        if args.contains("--interaction-test") { exit(InteractionTests.run() ? 0 : 1) }
        if let index=args.firstIndex(of:"--render"),args.count>index+1 {
            Preview.render(path:args[index+1],settings:args.contains("--settings"),dark:args.contains("--dark"),capture:args.contains("--capture") || args.contains("--text-editor"),text:args.contains("--text-editor"));return
        }
        let app=NSApplication.shared
        if NSRunningApplication.runningApplications(withBundleIdentifier:"com.local.SnapBar").contains(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.local.SnapBar.show"),object:nil,userInfo:nil,deliverImmediately:true);return
        }
        let delegate=AppDelegate();app.delegate=delegate;app.run();withExtendedLifetime(delegate) {}
    }
}
