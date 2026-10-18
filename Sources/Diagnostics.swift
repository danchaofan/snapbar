import AppKit
import SwiftUI
import Carbon

enum SelfTests {
    static func sampleImage(width:Int=400,height:Int=300) -> CGImage {
        let context=ImageRenderer.makeContext(width:width,height:height)!
        let w=CGFloat(width),h=CGFloat(height)
        for (color,rect) in [(NSColor.red,CGRect(x:0,y:h/2,width:w/2,height:h/2)),(.green,CGRect(x:w/2,y:h/2,width:w/2,height:h/2)),(.blue,CGRect(x:0,y:0,width:w/2,height:h/2)),(.yellow,CGRect(x:w/2,y:0,width:w/2,height:h/2))] {
            context.setFillColor(color.cgColor);context.fill(rect)
        }
        return context.makeImage()!
    }
    static func run() -> Bool {
        var failures:[String]=[];var count=0
        func check(_ value:@autoclosure ()->Bool,_ name:String) { count+=1;if !value() { failures.append(name);print("FAIL: \(name)") } }
        func near(_ image:CGImage,_ x:Int,_ y:Int,_ expected:NSColor)->Bool {
            // NSBitmapImageRep returns calibrated RGB labels for raw CGImage bytes.
            // The render context is explicitly sRGB: compare those bytes without
            // applying a second display-profile conversion.
            guard let actual=NSBitmapImageRep(cgImage:image).colorAt(x:x,y:y),let want=expected.usingColorSpace(.sRGB) else { return false }
            let matches=abs(actual.redComponent-want.redComponent)<0.12 && abs(actual.greenComponent-want.greenComponent)<0.12 && abs(actual.blueComponent-want.blueComponent)<0.12
            if !matches { print("Pixel (\(x),\(y)): actual \(actual), expected \(want)") };return matches
        }
        let source=sampleImage(),size=CGSize(width:200,height:150)
        check(Shortcut.default.label=="⌃ ⇧ A","默认快捷键")
        check(Shortcut.default.validationError==nil,"允许默认快捷键")
        check(Shortcut(keyCode:0,modifiers:0).validationError != nil,"阻止无修饰键快捷键")
        check(Shortcut(keyCode:21,modifiers:UInt32(cmdKey|shiftKey)).validationError != nil,"保护系统截图快捷键")
        check(CaptureGeometry.normalized(CGPoint(x:60,y:80),CGPoint(x:20,y:10))==CGRect(x:20,y:10,width:40,height:70),"反向框选")
        check(CaptureGeometry.pixelRect(selection:CGRect(x:10.25,y:20.25,width:30.5,height:40.5),viewSize:size,imageWidth:400,imageHeight:300)==CGRect(x:20,y:40,width:62,height:82),"Retina 像素边界")
        check(CaptureGeometry.pixelRect(selection:CGRect(x:-10,y:-10,width:30,height:30),viewSize:size,imageWidth:400,imageHeight:300)==CGRect(x:0,y:0,width:40,height:40),"屏幕边界裁切")
        check(CaptureGeometry.pixelRect(selection:.zero,viewSize:size,imageWidth:400,imageHeight:300)==nil,"拒绝空选区")
        check(CaptureGeometry.moved(CGRect(x:10,y:10,width:30,height:40),dx:500,dy:-100,within:CGRect(origin:.zero,size:size))==CGRect(x:170,y:0,width:30,height:40),"移动不越界")
        do {
            let tl=try ImageRenderer.render(source:source,viewSize:size,selection:CGRect(x:5,y:5,width:40,height:30),annotations:[])
            check(tl.width==80 && tl.height==60,"Retina 导出分辨率")
            check(near(tl,10,10,.red),"左上角裁切方向")
            let br=try ImageRenderer.render(source:source,viewSize:size,selection:CGRect(x:120,y:95,width:40,height:30),annotations:[])
            check(near(br,10,10,.yellow),"右下角裁切方向")
            let crop=CGRect(x:10,y:10,width:180,height:130)
            let rectangle=Annotation(tool:.rectangle,points:[CGPoint(x:20,y:20),CGPoint(x:65,y:45)],color:.white,width:4)
            let composed=try ImageRenderer.render(source:source,viewSize:size,selection:crop,annotations:[rectangle])
            check(near(composed,20,40,.white),"矩形标注与裁切坐标一致")
            check(near(composed,5,5,.red) && near(composed,350,250,.yellow),"合成图片不翻转")
            let mosaic=Annotation(tool:.mosaic,points:[CGPoint(x:95,y:65),CGPoint(x:130,y:100)],color:.red,width:3)
            let flat=try ImageRenderer.render(source:source,viewSize:size,selection:crop,annotations:[mosaic])
            check(flat.width==360 && flat.height==260,"马赛克扁平化导出")
            check(near(flat,3,3,.red),"马赛克不影响区域外像素")
            let pen=Annotation(tool:.pen,points:[CGPoint(x:30,y:20),CGPoint(x:80,y:20)],color:.white,width:5)
            let stroke=try ImageRenderer.render(source:source,viewSize:size,selection:crop,annotations:[pen])
            check(near(stroke,60,20,.white),"画笔导出位置")
            let text=Annotation(tool:.text,points:[CGPoint(x:20,y:20)],color:.white,width:3,text:"TEST",fontSize:20)
            let textImage=try ImageRenderer.render(source:source,viewSize:size,selection:crop,annotations:[text])
            let bitmap=NSBitmapImageRep(cgImage:textImage)
            var upperText=0,lowerText=0
            for y in 0..<textImage.height { for x in 0..<150 { if let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),c.redComponent>0.9,c.greenComponent>0.9,c.blueComponent>0.9 { if y<100 {upperText+=1}else{lowerText+=1} } } }
            check(upperText>50 && lowerText==0,"文字导出方向与位置")
            for format in ImageFormat.allCases {
                let data=try FileStore.encode(composed,as:format)
                let decoded=NSBitmapImageRep(data:data)
                check(decoded?.pixelsWide==360 && decoded?.pixelsHigh==260,"\(format.rawValue) 编解码尺寸")
                check(format == .png ? data.starts(with:[137,80,78,71]) : data.starts(with:[255,216]),"\(format.rawValue) 文件头")
            }
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent("snapbar-tests-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:folder) }
            let first=try FileStore.saveAutomatically(composed,folder:folder,format:.png)
            let second=try FileStore.saveAutomatically(composed,folder:folder,format:.png)
            check(first != second && FileManager.default.fileExists(atPath:first.path),"自动保存不覆盖已有截图")
            let saved=try Data(contentsOf:first)
            check(NSBitmapImageRep(data:saved)?.pixelsWide==360,"真实本地文件可读取")
            do { _ = try FileStore.saveAutomatically(composed,folder:folder.appendingPathComponent("missing"),format:.png);check(false,"无效目录报错") } catch {check(true,"无效目录报错")}
        } catch { failures.append(error.localizedDescription) }
        print("\(count) checks, \(failures.count) failures")
        if !failures.isEmpty { print(failures.joined(separator:"\n")) }
        return failures.isEmpty
    }
}

@MainActor enum Preview {
    static func render(path:String,settings:Bool,dark:Bool,capture:Bool,text:Bool=false) {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
        let suite="com.local.SnapBar.Preview"
        let defaults=UserDefaults(suiteName:suite) ?? .standard
        defaults.removePersistentDomain(forName:suite)
        let model=AppModel(defaults:defaults);model.permission=true;model.hotkeyReady=true
        let view:NSView
        if capture {
            let sample=demoScreen()
            let editor=CaptureView(source:sample,viewSize:CGSize(width:1000,height:650),preferences:nil);editor.configurePreview(text:text);view=editor
        } else {
            let content=settings ? AnyView(SettingsView(model:model)) : AnyView(MenuPanel(model:model,capture:{},settings:{}))
            view=NSHostingView(rootView:content.environment(\.colorScheme,dark ? .dark : .light))
        }
        let size=capture ? CGSize(width:1000,height:650) : view.fittingSize
        let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:dark ? .darkAqua : .aqua);window.contentView=view;view.frame=CGRect(origin:.zero,size:size)
        RunLoop.main.run(until:Date().addingTimeInterval(0.4));view.layoutSubtreeIfNeeded()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { fputs("无法渲染预览\n",stderr);exit(1) }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]) else { exit(1) }
        do { try data.write(to:URL(fileURLWithPath:path));print("渲染成功：\(path) · \(Int(size.width)) × \(Int(size.height))") } catch { fputs(error.localizedDescription,stderr);exit(1) }
    }
    static func demoScreen()->CGImage {
        let context=ImageRenderer.makeContext(width:2000,height:1300)!
        context.translateBy(x:0,y:1300);context.scaleBy(x:2,y:-2)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
        NSColor(srgbRed:0.89,green:0.92,blue:0.97,alpha:1).setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:1000,height:650)).fill()
        NSColor.white.setFill();NSBezierPath(roundedRect:CGRect(x:110,y:75,width:740,height:480),xRadius:14,yRadius:14).fill()
        let titleAttributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:30,weight:.semibold),.foregroundColor:NSColor.darkGray]
        ("把想法，截下来。" as NSString).draw(at:CGPoint(x:165,y:145),withAttributes:titleAttributes)
        for (i,text) in ["按下快捷键，框选需要的区域","圈出重点，加一句说明","复制，或者保存为本地图片"].enumerated() {
            (text as NSString).draw(at:CGPoint(x:170,y:240+CGFloat(i)*62),withAttributes:[.font:NSFont.systemFont(ofSize:20),.foregroundColor:NSColor.darkGray])
        }
        NSGraphicsContext.restoreGraphicsState();return context.makeImage()!
    }
}
