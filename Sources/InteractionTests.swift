import AppKit
import Carbon

@MainActor enum InteractionTests {
    static func run() -> Bool {
        _ = NSApplication.shared
        var failures:[String]=[];var count=0
        func check(_ value:@autoclosure ()->Bool,_ name:String) {count+=1;if !value(){failures.append(name);print("FAIL: \(name)")}}
        let size=CGSize(width:800,height:600)
        let source=SelfTests.sampleImage(width:1600,height:1200)
        let view=CaptureView(source:source,viewSize:size,preferences:nil)
        let window=CaptureWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=view;window.makeFirstResponder(view)
        var exported:CGImage?;var saved=false;var cancelled=false
        view.onComplete={image,save in exported=image;saved=save}
        view.onCancel={cancelled=true}
        func mouse(_ type:NSEvent.EventType,_ point:CGPoint)->NSEvent {
            NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        func drag(_ a:CGPoint,_ b:CGPoint) {view.mouseDown(with:mouse(.leftMouseDown,a));view.mouseDragged(with:mouse(.leftMouseDragged,b));view.mouseUp(with:mouse(.leftMouseUp,b))}
        func key(_ code:UInt16,_ characters:String,mods:NSEvent.ModifierFlags=[]) {
            let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:mods,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
            view.keyDown(with:event)
        }
        func button(_ help:String,_ parent:NSView)->NSButton? {
            for child in parent.subviews {if let value=child as? NSButton,value.toolTip==help{return value};if let value=button(help,child){return value}}
            return nil
        }
        func pixel(_ image:CGImage?,_ x:Int,_ y:Int)->[CGFloat] {
            guard let image=image,let c=NSBitmapImageRep(cgImage:image).colorAt(x:x,y:y) else{return []}
            return [c.redComponent,c.greenComponent,c.blueComponent]
        }
        drag(CGPoint(x:40,y:40),CGPoint(x:440,y:340));key(36,"\r")
        check(exported?.width==800 && exported?.height==600,"鼠标框选并 Enter 导出")
        let original=pixel(exported,80,120)
        key(15,"r");button("白色",view)?.performClick(nil)
        drag(CGPoint(x:80,y:80),CGPoint(x:240,y:180));key(36,"\r")
        check(pixel(exported,80,120)==[1,1,1],"真实工具条颜色和矩形事件")
        key(6,"z",mods:.command);key(36,"\r")
        check(pixel(exported,80,120)==original,"键盘撤销标注")
        key(6,"z",mods:[.command,.shift]);key(36,"\r")
        check(pixel(exported,80,120)==[1,1,1],"键盘重做标注")
        key(9,"v");drag(CGPoint(x:110,y:110),CGPoint(x:140,y:120));key(36,"\r")
        check(pixel(exported,140,140)==[1,1,1],"移动已选标注")
        key(51,"\u{7f}");key(36,"\r")
        check(pixel(exported,140,140) != [1,1,1],"删除已选标注")
        key(17,"t");view.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:100,y:100)))
        let editor=view.subviews.compactMap{$0 as? NSTextField}.first
        check(editor != nil,"文字编辑器出现")
        editor?.stringValue="HELLO";key(36,"\r")
        check(exported?.width==800,"文字提交并合成")
        key(1,"s",mods:.command);check(saved,"Command S 进入另存为流程")
        key(53,"\u{1b}");check(cancelled,"Esc 取消")
        view.resetSelection();key(9,"v");drag(CGPoint(x:440,y:340),CGPoint(x:40,y:40));key(36,"\r")
        check(exported?.width==800 && exported?.height==600,"反向拖动框选")
        key(0,"a");drag(CGPoint(x:440,y:340),CGPoint(x:500,y:400));key(36,"\r")
        check(exported?.width==920 && exported?.height==720,"标注工具激活时仍可调整选区大小")
        key(9,"v")
        drag(CGPoint(x:300,y:250),CGPoint(x:350,y:280));key(36,"\r")
        check(exported?.width==920 && exported?.height==720,"移动选区保留像素尺寸")

        view.resetSelection();key(9,"v");drag(CGPoint(x:40,y:40),CGPoint(x:440,y:340))
        let toolbar=view.subviews.compactMap{$0 as? NSVisualEffectView}.first
        check(toolbar?.frame.height==46,"未标注时收起属性栏")
        key(15,"r");drag(CGPoint(x:80,y:80),CGPoint(x:240,y:180))
        check(toolbar?.frame.height==76,"选择标注工具后展开属性栏")
        drag(CGPoint(x:140,y:80),CGPoint(x:150,y:90));key(36,"\r")
        check(pixel(exported,100,100)==[1,1,1],"无需切换选择工具，直接拖动矩形轮廓")
        drag(CGPoint(x:250,y:190),CGPoint(x:280,y:220));key(36,"\r")
        check(pixel(exported,480,220)==[1,1,1],"拖动矩形控制点调整标注大小")
        button("矩形 (R)",view)?.performClick(nil)
        check(toolbar?.frame.height==46,"再次点击当前工具退出标注模式")

        view.resetSelection();key(9,"v");drag(CGPoint(x:40,y:40),CGPoint(x:440,y:340))
        key(0,"a");drag(CGPoint(x:100,y:100),CGPoint(x:220,y:180))
        drag(CGPoint(x:220,y:180),CGPoint(x:260,y:120));key(36,"\r")
        check(pixel(exported,440,160)==[1,1,1],"拖动箭头端点重新指向")
        view.resetSelection();key(9,"v");drag(CGPoint(x:40,y:40),CGPoint(x:440,y:340))
        key(31,"o");drag(CGPoint(x:100,y:100),CGPoint(x:240,y:200));key(36,"\r")
        check(pixel(exported,120,220)==[1,1,1] && pixel(exported,260,220) != [1,1,1],"椭圆工具合成轮廓与透明内部")

        view.resetSelection();key(9,"v");drag(CGPoint(x:40,y:40),CGPoint(x:440,y:340))
        key(17,"t");view.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:100,y:100)))
        if let field=view.subviews.compactMap({$0 as? NSTextField}).first {
            field.stringValue="第一行\n第二行";view.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field))
            check(field.frame.height>45,"文字框按多行内容自动扩展")
            if let text=field.currentEditor() as? NSTextView {
                text.setSelectedRange(NSRange(location:(text.string as NSString).length,length:0))
                _ = view.control(field,textView:text,doCommandBy:#selector(NSResponder.insertNewline(_:)))
                check(text.string.contains("\n"),"文字编辑器 Enter 保留换行")
            } else {check(false,"文字编辑器 Enter 保留换行")}
            let enter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
            check(view.performKeyEquivalent(with:enter) && view.subviews.compactMap{$0 as? NSTextField}.isEmpty,"Command Enter 直接提交文字并完成")
            view.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:110,y:110)));view.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:110,y:110)))
            check(!view.subviews.compactMap{$0 as? NSTextField}.isEmpty,"单击已有文字即可再次编辑")
        } else {check(false,"文字框按多行内容自动扩展")}
        window.close()

        // Register actual Carbon hotkeys without synthesizing system input.
        do {
            let first=HotKeyController(),second=HotKeyController(),probe=HotKeyController()
            let mods=UInt32(cmdKey|controlKey|optionKey|shiftKey)
            let a=Shortcut(keyCode:UInt32(kVK_F10),modifiers:mods),b=Shortcut(keyCode:UInt32(kVK_F11),modifiers:mods)
            let one=first.replace(with:a),two=second.replace(with:b)
            check(one==noErr && two==noErr,"系统全局快捷键注册")
            if one==noErr && two==noErr {
                check(first.replace(with:b) != noErr,"检测已注册的全局组合键冲突")
                check(probe.replace(with:a) != noErr,"注册失败仍保留旧快捷键")
            }
        }
        let suite="com.local.SnapBar.Tests."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let model=AppModel(defaults:defaults)
        model.autoSave=true;model.format = .jpg;model.showToast=false
        let restored=AppModel(defaults:defaults)
        check(restored.autoSave && restored.format == .jpg && !restored.showToast,"保存设置并重新加载")
        let styleView=CaptureView(source:source,viewSize:size,preferences:defaults)
        button("蓝色",styleView)?.performClick(nil)
        let remembered=defaults.array(forKey:"markupColor") as? [Double]
        check(remembered?.count==3 && defaults.double(forKey:"markupWidth")==3 && defaults.double(forKey:"markupFont")==22,"记住标注颜色、粗细和字号")
        print("\(count) interaction checks, \(failures.count) failures")
        return failures.isEmpty
    }
}
