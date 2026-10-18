import AppKit
import SwiftUI

enum Palette {
    static let accent = Color(nsColor:NSColor(name:nil) { $0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(srgbRed:0.48,green:0.61,blue:1,alpha:1) : NSColor(srgbRed:0.32,green:0.44,blue:0.84,alpha:1) })
    static let surface = Color(nsColor:.controlBackgroundColor)
    static let canvas = Color(nsColor:.windowBackgroundColor)
}

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    var capture: () -> Void
    var settings: () -> Void
    var body: some View {
        VStack(spacing:16) {
            HStack(spacing:10) {
                Image(systemName:"viewfinder").font(.system(size:21,weight:.medium)).foregroundColor(.white).frame(width:38,height:38).background(Palette.accent,in:RoundedRectangle(cornerRadius:12))
                VStack(alignment:.leading,spacing:2) { Text("轻截").font(.system(size:17,weight:.semibold)); Text("SnapBar").font(.system(size:10,weight:.medium)).tracking(0.6).foregroundColor(.secondary) }
                Spacer()
            }
            Button(action:capture) {
                HStack { Image(systemName:"plus.viewfinder"); Text(model.busy ? "截图中…" : "开始截图"); Spacer(); Text(model.shortcut.label).font(.system(size:12,weight:.medium)).padding(.horizontal,7).padding(.vertical,4).background(.white.opacity(0.14),in:RoundedRectangle(cornerRadius:5)) }
                .font(.system(size:13,weight:.medium)).foregroundColor(.white).padding(.horizontal,12).frame(height:44).background(Palette.accent,in:RoundedRectangle(cornerRadius:10))
            }.buttonStyle(.plain).disabled(model.busy)
            HStack(spacing:5) { Circle().fill(model.permission ? Color.green : Color.orange).frame(width:6,height:6); Text(model.permission ? "截图就绪" : "需要屏幕录制权限"); Spacer(); Text(model.autoSave ? "复制并保存" : "复制到剪贴板") }.font(.system(size:11)).foregroundColor(.secondary)
            if !model.hotkeyReady { Text("快捷键注册失败，请在设置里更换组合键。").font(.system(size:11)).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
            if let url = model.lastSaved {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { HStack { Image(systemName:"folder"); Text("查看刚保存的截图"); Spacer(); Image(systemName:"arrow.up.right") }.font(.system(size:11)).foregroundColor(.secondary) }.buttonStyle(.plain)
            }
            Divider()
            HStack { Button(action:settings) { Label("设置…",systemImage:"slider.horizontal.3") }; Spacer(); Button { NSApp.terminate(nil) } label: { Label("退出",systemImage:"power") } }.buttonStyle(.plain).font(.system(size:12)).foregroundColor(.secondary)
        }.padding(18).frame(width:314).background(Palette.canvas).tint(Palette.accent)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    private func box<Content:View>(@ViewBuilder _ content:()->Content) -> some View {
        VStack(spacing:0,content:content).padding(.horizontal,14).background(Palette.surface,in:RoundedRectangle(cornerRadius:11)).overlay(RoundedRectangle(cornerRadius:11).strokeBorder(Color.primary.opacity(0.07)))
    }
    private func heading(_ text: String) -> some View { Text(text).font(.system(size:11,weight:.medium)).foregroundColor(.secondary).frame(maxWidth:.infinity,alignment:.leading) }
    private func action(_ title:String,perform:@escaping ()->Void) -> some View {
        Button(action:perform) { Text(title).font(.system(size:12)).foregroundColor(.primary).padding(.horizontal,10).padding(.vertical,5).background(Palette.canvas,in:RoundedRectangle(cornerRadius:6)).overlay(RoundedRectangle(cornerRadius:6).strokeBorder(Color.primary.opacity(0.12))) }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Group {
            heading("截图快捷键")
            box {
                HStack { Text("全局截图"); Spacer(); ShortcutRecorder(model:model).frame(width:150,height:32) }.padding(.vertical,10)
            }
            Text(model.shortcutError.isEmpty ? "点击组合键后录入新快捷键；Esc 取消修改。" : model.shortcutError).font(.system(size:11)).foregroundColor(model.shortcutError.isEmpty ? .secondary : .red).fixedSize(horizontal:false,vertical:true).frame(minHeight:28,alignment:.top)
            }
            Group {
            heading("截图与保存")
            box {
                HStack { Text("完成后"); Spacer(); Picker("完成后",selection:$model.autoSave) { Text("仅复制").tag(false); Text("复制并自动保存").tag(true) }.labelsHidden().frame(width:180) }.padding(.vertical,10)
                Divider()
                HStack(spacing:12) { VStack(alignment:.leading,spacing:3) { Text("默认保存位置"); Text(model.folder.path).font(.system(size:10)).foregroundColor(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }; Spacer(minLength:4); action("选择…") { model.chooseFolder() } }.padding(.vertical,10)
                Divider()
                HStack { Text("图片格式"); Spacer(); Picker("图片格式",selection:$model.format) { ForEach(ImageFormat.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden().pickerStyle(.segmented).frame(width:130) }.padding(.vertical,10)
            }
            Text("工具条的保存按钮始终可用，支持另存为。JPG 使用高质量压缩。截图仅在本机处理。").font(.system(size:11)).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true).padding(.bottom,5)
            }
            heading("通用")
            box {
                HStack { Text("登录时自动启动");Spacer();Toggle("登录时自动启动",isOn:Binding(get:{model.loginEnabled},set:{model.setLogin($0)})).labelsHidden().toggleStyle(.switch).controlSize(.small) }.padding(.vertical,10)
                Divider()
                HStack { Text("截图完成提示");Spacer();Toggle("截图完成提示",isOn:$model.showToast).labelsHidden().toggleStyle(.switch).controlSize(.small) }.padding(.vertical,10)
            }
            if !model.settingsMessage.isEmpty { Text(model.settingsMessage).font(.system(size:11)).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
            heading("系统权限")
            box {
                HStack { VStack(alignment:.leading,spacing:3) { Text("屏幕录制"); Text(model.permission ? "已授权" : "未授权 · 截图需要此权限").font(.system(size:11)).foregroundColor(model.permission ? .secondary : .orange) }; Spacer(); action(model.permission ? "系统设置…" : "去授权…") { model.openPermissions() } }.padding(.vertical,10)
            }
            HStack { Text("轻截 \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.1.0")"); Spacer(); Text("Enter 完成 · Esc 取消") }.font(.system(size:10)).foregroundColor(.secondary).padding(.top,6)
        }.font(.system(size:13)).padding(22).frame(width:494).background(Palette.canvas).tint(Palette.accent)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context:Context) -> RecorderButton { let button = RecorderButton();button.model=model;return button }
    func updateNSView(_ button:RecorderButton,context:Context) { button.model=model;button.title=model.recording ? "请按组合键…" : model.shortcut.label;button.contentTintColor=model.recording ? .systemBlue : .labelColor }
}

final class RecorderButton: NSButton {
    weak var model: AppModel?
    override var acceptsFirstResponder: Bool { true }
    init() { super.init(frame:.zero);bezelStyle = .rounded;target=self;action=#selector(beginRecording);font = .systemFont(ofSize:13,weight:.medium) }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() { model?.recording=true;model?.shortcutError="";window?.makeFirstResponder(self) }
    override func keyDown(with event:NSEvent) {
        guard let model = model, model.recording else { super.keyDown(with:event);return }
        if event.keyCode == 53 { model.recording=false;return }
        if model.setShortcut(Shortcut.from(event)) { model.recording=false }
    }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        if model?.recording == true { keyDown(with:event);return true };return super.performKeyEquivalent(with:event)
    }
    override func resignFirstResponder() -> Bool { model?.recording=false;return super.resignFirstResponder() }
}
