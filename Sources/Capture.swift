import AppKit

final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ActionButton: NSButton {
    var invoke: () -> Void = {}
    init(symbol:String,help:String,action:@escaping ()->Void) {
        super.init(frame:.zero);self.invoke=action;self.toolTip=help
        image = NSImage(systemSymbolName:symbol,accessibilityDescription:help);imagePosition = .imageOnly
        bezelStyle = .texturedRounded;isBordered=false;target=self;self.action=#selector(performAction)
        setAccessibilityLabel(help)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func performAction() { invoke() }
}

final class CaptureCoordinator {
    private var windows: [CaptureWindow] = []
    private var views: [CaptureView] = []
    private var screenObserver: NSObjectProtocol?
    var completed: ((CGImage,Bool)->Void)?
    var cancelled: (()->Void)?
    var failed: ((String)->Void)?
    var active: Bool { !windows.isEmpty }

    func start() throws {
        guard windows.isEmpty else { return }
        var snapshots: [(NSScreen,CGImage)] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, let image = CGDisplayCreateImage(CGDirectDisplayID(number.uint32Value)) else { continue }
            snapshots.append((screen,image))
        }
        guard !snapshots.isEmpty else { throw AppError.message("无法读取屏幕，请确认屏幕录制权限已打开；刚授权后可能需要退出并重新打开轻截。") }
        for (screen,image) in snapshots {
            let window = CaptureWindow(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false)
            window.setFrame(screen.frame,display:false)
            window.isOpaque=true;window.backgroundColor = .black;window.hasShadow=false;window.isReleasedWhenClosed=false
            window.level = NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.screenSaverWindow)))
            window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
            window.acceptsMouseMovedEvents=true;window.isMovable=false
            let view = CaptureView(source:image,viewSize:screen.frame.size)
            view.canTakeKeyboardOnHover = { [weak self] in !(self?.views.contains(where:{$0.hasSelection}) ?? false) }
            view.onSelect = { [weak self,weak view] in
                guard let self = self, let view = view else { return }
                for peer in self.views where peer !== view { peer.resetSelection() }
            }
            view.onCancel = { [weak self] in self?.close();self?.cancelled?() }
            view.onComplete = { [weak self] image,save in self?.close();self?.completed?(image,save) }
            view.onError = { [weak self] message in self?.close();self?.failed?(message) }
            window.contentView=view;window.makeFirstResponder(view)
            windows.append(window);views.append(view)
        }
        NSApp.activate(ignoringOtherApps:true)
        for window in windows { window.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        if let window = windows.first(where:{$0.frame.contains(mouse)}) ?? windows.first { window.makeKey();window.makeFirstResponder(window.contentView) }
        screenObserver=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in self?.close();self?.failed?("显示器布局发生变化，请重新截图。") }
    }
    func close() {
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer);screenObserver=nil }
        windows.forEach { $0.orderOut(nil);$0.close() };windows.removeAll();views.removeAll()
    }
    deinit { close() }
}

private struct EditState { var selection: CGRect?; var annotations: [Annotation] }
private enum DragMode {
    case none, region, moveRegion, resize(Int), annotation(Int), resizeAnnotation(Int,Int), drawing
}

final class CaptureView: NSView, NSTextFieldDelegate {
    let source: CGImage
    let logicalSize: CGSize
    private let preferences:UserDefaults?
    var onSelect: ()->Void = {}
    var onCancel: ()->Void = {}
    var onComplete: (CGImage,Bool)->Void = {_,_ in}
    var onError: (String)->Void = {_ in}
    var canTakeKeyboardOnHover: ()->Bool = { true }
    var hasSelection: Bool { selection != nil }
    private var selection: CGRect?
    private var annotations: [Annotation] = []
    private var pending: Annotation?
    private var tool: Tool = .select
    private var color = NSColor(srgbRed:0.96,green:0.27,blue:0.26,alpha:1)
    private var strokeWidth: CGFloat = 3
    private var fontSize: CGFloat = 22
    private var dragMode: DragMode = .none
    private var dragStart: CGPoint = .zero
    private var dragInitialRect: CGRect = .zero
    private var dragInitialAnnotations: [Annotation] = []
    private var beforeDrag: EditState?
    private var undoStates: [EditState] = []
    private var redoStates: [EditState] = []
    private var selectedAnnotation: Int?
    private var hoverPoint: CGPoint = .zero
    private var toolbar: NSVisualEffectView!
    private var toolButtons: [Tool:ActionButton] = [:]
    private var colorButtons: [(ActionButton,NSColor)] = []
    private var undoButton: ActionButton!
    private var redoButton: ActionButton!
    private var widthSlider: NSSlider!
    private var fontPicker: NSPopUpButton!
    private var propertyBar:NSStackView!
    private var widthLabel:NSTextField!
    private var fontLabel:NSTextField!
    private var editor: NSTextField?
    private var editingIndex: Int?
    private var editingOrigin: CGPoint = .zero
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(source:CGImage,viewSize:CGSize,preferences:UserDefaults? = .standard) {
        self.source=source;self.logicalSize=viewSize;self.preferences=preferences
        if let rgb=preferences?.array(forKey:"markupColor") as? [Double],rgb.count==3 {color=NSColor(srgbRed:rgb[0],green:rgb[1],blue:rgb[2],alpha:1)}
        if let width=preferences?.object(forKey:"markupWidth") as? Double {strokeWidth=CGFloat(max(1,min(8,width)))}
        if let font=preferences?.object(forKey:"markupFont") as? Double {fontSize=CGFloat(max(16,min(48,font)))}
        super.init(frame:CGRect(origin:.zero,size:viewSize));buildToolbar()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }

    func resetSelection() {
        selection=nil;annotations=[];pending=nil;undoStates=[];redoStates=[];selectedAnnotation=nil
        editor?.removeFromSuperview();editor=nil;toolbar.isHidden=true;needsDisplay=true
    }
    func configurePreview(text:Bool=false) {
        selection=CGRect(x:145,y:123,width:655,height:332)
        annotations=[Annotation(tool:.rectangle,points:[CGPoint(x:158,y:236),CGPoint(x:575,y:276)],color:color,width:3),Annotation(tool:.arrow,points:[CGPoint(x:660,y:185),CGPoint(x:575,y:235)],color:color,width:3)]
        if text {
            tool = .text;beginText(at:CGPoint(x:190,y:300),index:nil);editor?.stringValue="这里是重点\n支持多行说明，直接输入即可";resizeTextEditor()
        } else { tool = .arrow;selectedAnnotation=1 }
        updateToolbar();positionToolbar();needsDisplay=true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let area = tracking { removeTrackingArea(area) }
        let area = NSTrackingArea(rect:bounds,options:[.mouseMoved,.cursorUpdate,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);tracking=area
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
    override func cursorUpdate(with event:NSEvent) { updateCursor(at:convert(event.locationInWindow,from:nil)) }
    private func handle(at point:CGPoint,in rect:CGRect)->Int? {
        handles(rect).firstIndex(where:{abs($0.x-point.x)<=9 && abs($0.y-point.y)<=9})
    }
    private func updateCursor(at point:CGPoint) {
        if !toolbar.isHidden,toolbar.frame.contains(point) { NSCursor.arrow.set();return }
        if let editor=editor,editor.frame.contains(point) { NSCursor.iBeam.set();return }
        guard let rect=selection else { NSCursor.crosshair.set();return }
        if let index=handle(at:point,in:rect) {
            switch index {
            case 1,5:NSCursor.resizeUpDown.set()
            case 3,7:NSCursor.resizeLeftRight.set()
            default:Self.cornerCursors[index==0 || index==4 ? 0 : 1].set()
            }
        } else if annotationHandle(at:point) != nil { NSCursor.crosshair.set() }
        else if rect.contains(point),tool == .select || annotation(at:point) != nil { NSCursor.openHand.set() }
        else if rect.contains(point),tool == .text { NSCursor.iBeam.set() }
        else { NSCursor.crosshair.set() }
    }
    private static let cornerCursors:[NSCursor] = [true,false].map { reverse in
        let image=NSImage(size:CGSize(width:24,height:24),flipped:false) { rect in
            let path=NSBezierPath();path.lineWidth=2;path.lineCapStyle = .round;path.lineJoinStyle = .round
            let a=CGPoint(x:5,y:reverse ? 19 : 5),b=CGPoint(x:19,y:reverse ? 5 : 19)
            path.move(to:a);path.line(to:b)
            path.move(to:CGPoint(x:a.x,y:a.y+(reverse ? -6 : 6)));path.line(to:a);path.line(to:CGPoint(x:a.x+6,y:a.y))
            path.move(to:CGPoint(x:b.x-6,y:b.y));path.line(to:b);path.line(to:CGPoint(x:b.x,y:b.y+(reverse ? 6 : -6)))
            NSColor.white.setStroke();path.lineWidth=4;path.stroke();NSColor.black.setStroke();path.lineWidth=2;path.stroke();return true
        }
        return NSCursor(image:image,hotSpot:CGPoint(x:12,y:12))
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        ImageRenderer.drawUpright(source,in:bounds,context:context)
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.40).cgColor)
        if let rect = selection, rect.width > 0, rect.height > 0 {
            let path=CGMutablePath();path.addRect(bounds);path.addRect(rect);context.addPath(path);context.fillPath(using:.evenOdd)
            context.saveGState();context.clip(to:rect)
            for (i,annotation) in annotations.enumerated() where i != editingIndex { ImageRenderer.draw(annotation,in:context,source:source,viewSize:logicalSize) }
            if let pending = pending { ImageRenderer.draw(pending,in:context,source:source,viewSize:logicalSize) }
            context.restoreGState()
            context.setStrokeColor(NSColor(srgbRed:0.43,green:0.64,blue:1,alpha:1).cgColor);context.setLineWidth(1)
            context.stroke(rect.insetBy(dx:-0.5,dy:-0.5))
            for point in handles(rect) {
                let square=CGRect(x:point.x-3,y:point.y-3,width:6,height:6)
                context.setFillColor(NSColor.white.cgColor);context.fill(square);context.stroke(square)
            }
            if let index=selectedAnnotation,index<annotations.count {
                context.saveGState();context.setLineDash(phase:0,lengths:[4,3]);context.stroke(annotations[index].bounds.insetBy(dx:-5,dy:-5));context.restoreGState()
                for point in annotationHandles(annotations[index]) {
                    let box=CGRect(x:point.x-3,y:point.y-3,width:6,height:6);context.setFillColor(NSColor.white.cgColor);context.fill(box);context.stroke(box)
                }
            }
            if let pixels=CaptureGeometry.pixelRect(selection:rect,viewSize:logicalSize,imageWidth:source.width,imageHeight:source.height) {
                drawBadge("\(Int(pixels.width)) × \(Int(pixels.height))",at:CGPoint(x:rect.minX,y:max(7,rect.minY-29)))
            }
            if toolbar.isHidden == false {
                let hint = editor != nil ? "Enter 换行 · ⌘Enter 完成 · 点击空白确认文字" : tool == .select ? "拖动调整选区 · 双击 / Enter 完成 · Esc 取消" : "\(tool.name.components(separatedBy:" (").first ?? "") · 拖动标注可修改 · Enter 完成"
                drawBadge(hint,at:CGPoint(x:18,y:bounds.height-36))
            }
        } else {
            context.fill(bounds)
            drawBadge("拖动框选区域 · Esc 取消",at:CGPoint(x:bounds.midX-100,y:60))
            drawMagnifier(context)
        }
        context.restoreGState()
    }
    private func drawBadge(_ text:String,at point:CGPoint) {
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.white]
        let size=(text as NSString).size(withAttributes:attributes)
        let x=max(5,min(bounds.width-size.width-21,point.x)),y=max(5,min(bounds.height-size.height-17,point.y))
        NSColor(srgbRed:0.14,green:0.16,blue:0.20,alpha:0.95).setFill()
        NSBezierPath(roundedRect:CGRect(x:x,y:y,width:size.width+16,height:size.height+10),xRadius:5,yRadius:5).fill()
        (text as NSString).draw(at:CGPoint(x:x+8,y:y+5),withAttributes:attributes)
    }
    private func drawMagnifier(_ context:CGContext) {
        guard bounds.contains(hoverPoint),hoverPoint != .zero else { return }
        let sx=CGFloat(source.width)/logicalSize.width,sy=CGFloat(source.height)/logicalSize.height
        let crop=CGRect(x:max(0,hoverPoint.x*sx-12),y:max(0,hoverPoint.y*sy-12),width:24,height:24).intersection(CGRect(x:0,y:0,width:source.width,height:source.height))
        guard let image=source.cropping(to:crop) else { return }
        let rect=CGRect(x:min(bounds.width-110,hoverPoint.x+24),y:min(bounds.height-125,hoverPoint.y+24),width:96,height:96)
        context.saveGState();context.interpolationQuality = .none;ImageRenderer.drawUpright(image,in:rect,context:context)
        context.setStrokeColor(NSColor.white.cgColor);context.setLineWidth(2);context.stroke(rect)
        context.setStrokeColor(NSColor.systemBlue.cgColor);context.setLineWidth(1)
        context.move(to:CGPoint(x:rect.midX,y:rect.minY));context.addLine(to:CGPoint(x:rect.midX,y:rect.maxY))
        context.move(to:CGPoint(x:rect.minX,y:rect.midY));context.addLine(to:CGPoint(x:rect.maxX,y:rect.midY));context.strokePath();context.restoreGState()
    }
    override func mouseMoved(with event:NSEvent) {
        hoverPoint=convert(event.locationInWindow,from:nil)
        if window?.isKeyWindow == false,canTakeKeyboardOnHover() { window?.makeKey();window?.makeFirstResponder(self) }
        updateCursor(at:hoverPoint)
        if selection == nil { needsDisplay=true }
    }
    private func handles(_ rect:CGRect) -> [CGPoint] {
        [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.midX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.midY),CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.midX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.midY)]
    }
    private func annotation(at point:CGPoint)->Int? {
        annotations.indices.reversed().first { index in
            tool == .select ? annotations[index].bounds.insetBy(dx:-6,dy:-6).contains(point) : annotations[index].hitTest(point)
        }
    }
    private func annotationHandles(_ value:Annotation)->[CGPoint] {
        switch value.tool {
        case .rectangle,.ellipse,.mosaic:return handles(value.bounds)
        case .arrow:return [value.points.first ?? .zero,value.points.last ?? .zero]
        default:return []
        }
    }
    private func annotationHandle(at point:CGPoint)->(Int,Int)? {
        guard let index=selectedAnnotation,index<annotations.count,let handle=annotationHandles(annotations[index]).firstIndex(where:{abs($0.x-point.x)<=7 && abs($0.y-point.y)<=7}) else {return nil}
        return (index,handle)
    }
    private func selectAnnotation(_ index:Int) {
        selectedAnnotation=index;color=annotations[index].color;strokeWidth=annotations[index].width;fontSize=annotations[index].fontSize
        widthSlider.doubleValue=Double(strokeWidth);fontPicker.selectItem(withTitle:String(Int(fontSize)));updateToolbar()
    }
    private func state() -> EditState { EditState(selection:selection,annotations:annotations) }
    private func pushUndo(_ value:EditState) { undoStates.append(value);if undoStates.count>80 { undoStates.removeFirst() };redoStates=[];updateToolbar() }
    private func restore(_ value:EditState) { selection=value.selection;annotations=value.annotations;selectedAnnotation=nil;pending=nil;updateToolbar();positionToolbar();needsDisplay=true }
    private func undo() {
        commitText();guard let previous=undoStates.popLast() else { return };redoStates.append(state());restore(previous)
    }
    private func redo() {
        commitText();guard let next=redoStates.popLast() else { return };undoStates.append(state());restore(next)
    }
    override func mouseDown(with event:NSEvent) {
        let point=CaptureGeometry.clamp(convert(event.locationInWindow,from:nil),to:bounds)
        commitText();window?.makeKey();window?.makeFirstResponder(self);onSelect()
        dragStart=point;beforeDrag=state();dragInitialRect=selection ?? .zero;dragInitialAnnotations=annotations
        if let rect=selection,rect.width>2,rect.height>2 {
            if let handle=handle(at:point,in:rect) { selectedAnnotation=nil;dragMode = .resize(handle);toolbar.isHidden=true }
            else if let (index,handle)=annotationHandle(at:point) {dragMode = .resizeAnnotation(index,handle)}
            else if rect.contains(point) {
                if let index=annotation(at:point) {
                    selectAnnotation(index)
                    if event.clickCount == 2,annotations[index].tool == .text { beginText(at:annotations[index].points[0],index:index);dragMode = .none;return }
                    dragMode = .annotation(index);NSCursor.closedHand.set()
                } else if tool == .select {
                    selectedAnnotation=nil
                    if event.clickCount==2 { finish(save:false);return }
                    else { dragMode = .moveRegion;toolbar.isHidden=true;NSCursor.closedHand.set() }
                } else if tool == .text { beginText(at:point,index:nil);dragMode = .none;return }
                else { selectedAnnotation=nil;pending=Annotation(tool:tool,points:[point],color:color,width:strokeWidth,fontSize:fontSize);dragMode = .drawing }
            } else { beginRegion(at:point) }
        } else { beginRegion(at:point) }
        needsDisplay=true
    }
    private func beginRegion(at point:CGPoint) {
        dragMode = .region;selection=CGRect(origin:point,size:.zero);annotations=[];pending=nil;selectedAnnotation=nil;toolbar.isHidden=true
    }
    override func mouseDragged(with event:NSEvent) {
        let point=CaptureGeometry.clamp(convert(event.locationInWindow,from:nil),to:bounds)
        var dx=point.x-dragStart.x,dy=point.y-dragStart.y
        switch dragMode {
        case .none: return
        case .region: selection=CaptureGeometry.normalized(dragStart,point)
        case .moveRegion:
            let rect=CaptureGeometry.moved(dragInitialRect,dx:dx,dy:dy,within:bounds);dx=rect.minX-dragInitialRect.minX;dy=rect.minY-dragInitialRect.minY
            selection=rect;annotations=dragInitialAnnotations.map{$0.translated(dx:dx,dy:dy)}
        case .resize(let handle):
            var left=dragInitialRect.minX,right=dragInitialRect.maxX,top=dragInitialRect.minY,bottom=dragInitialRect.maxY
            if [0,6,7].contains(handle) { left=point.x };if [2,3,4].contains(handle) { right=point.x }
            if [0,1,2].contains(handle) { top=point.y };if [4,5,6].contains(handle) { bottom=point.y }
            selection=CaptureGeometry.normalized(CGPoint(x:left,y:top),CGPoint(x:right,y:bottom))
        case .annotation(let index):
            guard let rect=selection else { return };let box=dragInitialAnnotations[index].bounds
            dx=max(rect.minX-box.minX,min(rect.maxX-box.maxX,dx));dy=max(rect.minY-box.minY,min(rect.maxY-box.maxY,dy))
            annotations[index]=dragInitialAnnotations[index].translated(dx:dx,dy:dy)
        case .resizeAnnotation(let index,let handle):
            guard let selection=selection else{return};let p=CaptureGeometry.clamp(point,to:selection),original=dragInitialAnnotations[index]
            if original.tool == .arrow {annotations[index].points[handle]=p}
            else {
                let box=original.bounds;var left=box.minX,right=box.maxX,top=box.minY,bottom=box.maxY
                if [0,6,7].contains(handle){left=p.x};if [2,3,4].contains(handle){right=p.x}
                if [0,1,2].contains(handle){top=p.y};if [4,5,6].contains(handle){bottom=p.y}
                annotations[index].points=[CGPoint(x:left,y:top),CGPoint(x:right,y:bottom)]
            }
        case .drawing:
            guard let rect=selection else { return };var p=CaptureGeometry.clamp(point,to:rect)
            if event.modifierFlags.contains(.shift) {
                if tool == .rectangle || tool == .ellipse {let side=min(abs(p.x-dragStart.x),abs(p.y-dragStart.y));p=CGPoint(x:dragStart.x+(p.x<dragStart.x ? -side : side),y:dragStart.y+(p.y<dragStart.y ? -side : side))}
                else if tool == .arrow {let angle=(atan2(p.y-dragStart.y,p.x-dragStart.x)/(.pi/4)).rounded()*(.pi/4),length=hypot(p.x-dragStart.x,p.y-dragStart.y);p=CaptureGeometry.clamp(CGPoint(x:dragStart.x+length*cos(angle),y:dragStart.y+length*sin(angle)),to:rect)}
            }
            if pending?.tool == .pen { pending?.points.append(p) } else { pending?.points=[dragStart,p] }
        }
        needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        let mode=dragMode;dragMode = .none
        let point=convert(event.locationInWindow,from:nil)
        if case .annotation(let index)=mode,annotations[index].tool == .text,hypot(point.x-dragStart.x,point.y-dragStart.y)<3 {
            beforeDrag=nil;beginText(at:annotations[index].points[0],index:index);return
        }
        switch mode {
        case .none: return
        case .drawing:
            if let pending=pending,pending.tool == .pen || (pending.bounds.width+pending.bounds.height)>3 {
                if let old=beforeDrag { pushUndo(old) };annotations.append(pending);selectedAnnotation=annotations.count-1
            }
            pending=nil
        default:
            if let rect=selection,rect.width<3 || rect.height<3 { if let old=beforeDrag { restore(old) } }
            else if let old=beforeDrag,selection != old.selection || hypot(event.locationInWindow.x-convert(dragStart,to:nil).x,event.locationInWindow.y-convert(dragStart,to:nil).y)>1 { pushUndo(old) }
        }
        beforeDrag=nil;updateToolbar();positionToolbar();updateCursor(at:convert(event.locationInWindow,from:nil));needsDisplay=true
    }
    override func rightMouseDown(with event:NSEvent) { commitText();onCancel() }
    override func keyDown(with event:NSEvent) {
        if event.keyCode==53 { onCancel();return }
        let command=event.modifierFlags.contains(.command)
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": event.modifierFlags.contains(.shift) ? redo() : undo();return
            case "s": finish(save:true);return
            case "c": finish(save:false);return
            default: break
            }
        }
        if event.keyCode==36 || event.keyCode==76 { finish(save:false);return }
        if event.keyCode==51 || event.keyCode==117 {
            if let index=selectedAnnotation,index<annotations.count { pushUndo(state());annotations.remove(at:index);selectedAnnotation=nil;needsDisplay=true };return
        }
        let shortcuts:[String:Tool]=["v":.select,"r":.rectangle,"o":.ellipse,"a":.arrow,"p":.pen,"t":.text,"m":.mosaic]
        if let value=shortcuts[event.charactersIgnoringModifiers?.lowercased() ?? ""] { setTool(value);return }
        super.keyDown(with:event)
    }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),event.keyCode==36 || event.keyCode==76 {finish(save:false);return true}
        if editor == nil,event.modifierFlags.contains(.command),["z","s","c"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") { keyDown(with:event);return true }
        return super.performKeyEquivalent(with:event)
    }
    private func setTool(_ value:Tool) { commitText();tool=value;selectedAnnotation=nil;window?.makeFirstResponder(self);updateToolbar();positionToolbar();needsDisplay=true }
    private func beginText(at point:CGPoint,index:Int?) {
        guard let selection=selection else { return }
        selectedAnnotation=nil;editingIndex=index;editingOrigin=point
        let field=NSTextField(frame:CGRect(x:point.x,y:point.y,width:max(50,min(320,selection.maxX-point.x)),height:fontSize+12))
        field.delegate=self;field.font = .systemFont(ofSize:fontSize,weight:.medium);field.textColor=color;field.backgroundColor=editorBackground(color)
        field.isBordered=true;field.isEditable=true;field.isSelectable=true;field.focusRingType = .none;field.maximumNumberOfLines=0
        field.cell?.wraps=true;field.cell?.isScrollable=false;field.cell?.usesSingleLineMode=false
        field.placeholderString="输入文字"
        if let index=index { field.stringValue=annotations[index].text;field.font = .systemFont(ofSize:annotations[index].fontSize,weight:.medium);field.textColor=annotations[index].color;field.backgroundColor=editorBackground(annotations[index].color) }
        editor=field;addSubview(field);resizeTextEditor();window?.makeFirstResponder(field);updateToolbar();positionToolbar();needsDisplay=true
    }
    private func editorBackground(_ color:NSColor)->NSColor {
        guard let rgb=color.usingColorSpace(.sRGB) else{return .white}
        let luminance=0.2126*rgb.redComponent+0.7152*rgb.greenComponent+0.0722*rgb.blueComponent
        return luminance>0.5 ? NSColor.black.withAlphaComponent(0.88) : NSColor.white.withAlphaComponent(0.96)
    }
    private func resizeTextEditor() {
        guard let field=editor,let selection=selection else{return}
        let font=field.font ?? NSFont.systemFont(ofSize:fontSize,weight:.medium)
        let text=field.stringValue.isEmpty ? "输入文字" : field.stringValue+"\u{200b}"
        let available=max(32,selection.maxX-editingOrigin.x-8)
        let natural=(text as NSString).boundingRect(with:CGSize(width:10000,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font])
        let width=min(available,max(80,ceil(natural.width)+4))
        let measured=(text as NSString).boundingRect(with:CGSize(width:width,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font])
        let height=min(max(fontSize+12,ceil(measured.height)+12),max(fontSize+12,selection.maxY-editingOrigin.y))
        field.setFrameSize(CGSize(width:width+8,height:height))
    }
    func controlTextDidChange(_ obj:Notification) {resizeTextEditor()}
    private func commitText() {
        guard let field=editor else { return }
        if let text=field.currentEditor() as? NSTextView {text.unmarkText();field.stringValue=text.string}
        let value=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),index=editingIndex
        editor=nil;editingIndex=nil
        if !value.isEmpty {
            pushUndo(state())
            if let index=index,index<annotations.count { annotations[index].text=value;annotations[index].textBoxWidth=max(1,field.frame.width-8);annotations[index].fontSize=field.font?.pointSize ?? fontSize;annotations[index].color=field.textColor ?? color }
            else { annotations.append(Annotation(tool:.text,points:[editingOrigin],color:color,width:strokeWidth,text:value,fontSize:fontSize,textBoxWidth:max(1,field.frame.width-8))) }
        }
        field.delegate=nil;field.removeFromSuperview();window?.makeFirstResponder(self);updateToolbar();positionToolbar();needsDisplay=true
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {finish(save:false)}
            else {textView.insertNewlineIgnoringFieldEditor(nil);resizeTextEditor()}
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { editor?.delegate=nil;editor?.removeFromSuperview();editor=nil;editingIndex=nil;window?.makeFirstResponder(self);updateToolbar();positionToolbar();needsDisplay=true;return true }
        return false
    }
    func controlTextDidEndEditing(_ obj:Notification) { commitText() }
    private func finish(save:Bool) {
        commitText();guard let rect=selection,rect.width>=3,rect.height>=3 else { NSSound.beep();return }
        do { let image=try ImageRenderer.render(source:source,viewSize:logicalSize,selection:rect,annotations:annotations);onComplete(image,save) } catch { onError(error.localizedDescription) }
    }
    private func buildToolbar() {
        toolbar=NSVisualEffectView(frame:CGRect(x:0,y:0,width:560,height:46))
        toolbar.material = .hudWindow;toolbar.blendingMode = .withinWindow;toolbar.state = .active;toolbar.appearance=NSAppearance(named:.darkAqua)
        toolbar.wantsLayer=true;toolbar.layer?.cornerRadius=11;toolbar.layer?.masksToBounds=true;toolbar.isHidden=true
        addSubview(toolbar)
        let top=NSStackView();top.orientation = .horizontal;top.spacing=4;top.alignment = .centerY;top.distribution = .fill
        top.translatesAutoresizingMaskIntoConstraints=false;toolbar.addSubview(top)
        for value in Tool.allCases {
            let button=ActionButton(symbol:value.symbol,help:value.name) { [weak self] in
                guard let self=self else{return};self.setTool(self.tool == value ? .select : value)
            }
            button.setButtonType(.toggle);button.widthAnchor.constraint(equalToConstant:30).isActive=true;button.heightAnchor.constraint(equalToConstant:30).isActive=true
            toolButtons[value]=button;top.addArrangedSubview(button)
        }
        top.addArrangedSubview(separator())
        undoButton=ActionButton(symbol:"arrow.uturn.backward",help:"撤销 (⌘Z)") { [weak self] in self?.undo() }
        redoButton=ActionButton(symbol:"arrow.uturn.forward",help:"重做 (⇧⌘Z)") { [weak self] in self?.redo() }
        for button in [undoButton!,redoButton!] { button.widthAnchor.constraint(equalToConstant:30).isActive=true;top.addArrangedSubview(button) }
        top.addArrangedSubview(separator())
        let save=ActionButton(symbol:"square.and.arrow.down",help:"另存为 (⌘S)") { [weak self] in self?.finish(save:true) };save.widthAnchor.constraint(equalToConstant:32).isActive=true;top.addArrangedSubview(save)
        let cancel=ActionButton(symbol:"xmark",help:"取消 (Esc)") { [weak self] in self?.onCancel() };cancel.widthAnchor.constraint(equalToConstant:30).isActive=true;top.addArrangedSubview(cancel)
        let done=NSButton(title:"完成",target:self,action:#selector(finishClicked));done.bezelStyle = .rounded;done.bezelColor = .systemBlue;done.contentTintColor = .white;done.widthAnchor.constraint(equalToConstant:65).isActive=true;top.addArrangedSubview(done)
        let bottom=NSStackView();propertyBar=bottom;bottom.orientation = .horizontal;bottom.alignment = .centerY;bottom.spacing=8;bottom.translatesAutoresizingMaskIntoConstraints=false;toolbar.addSubview(bottom)
        let colors:[NSColor]=[NSColor(srgbRed:0.96,green:0.27,blue:0.26,alpha:1),.systemOrange,.systemBlue,.systemGreen,.white,.black]
        let names=["红色","橙色","蓝色","绿色","白色","黑色"]
        for (index,value) in colors.enumerated() {
            let button=ActionButton(symbol:"circle.fill",help:names[index]) { [weak self] in self?.setColor(value) }
            button.contentTintColor=value;button.widthAnchor.constraint(equalToConstant:23).isActive=true;button.heightAnchor.constraint(equalToConstant:24).isActive=true
            colorButtons.append((button,value));bottom.addArrangedSubview(button)
        }
        bottom.addArrangedSubview(separator())
        widthLabel=NSTextField(labelWithString:"粗细");widthLabel.font = .systemFont(ofSize:11);bottom.addArrangedSubview(widthLabel)
        widthSlider=NSSlider(value:Double(strokeWidth),minValue:1,maxValue:8,target:self,action:#selector(widthChanged));widthSlider.controlSize = .small;widthSlider.widthAnchor.constraint(equalToConstant:78).isActive=true;widthSlider.setAccessibilityLabel("标注线条粗细");bottom.addArrangedSubview(widthSlider)
        fontLabel=NSTextField(labelWithString:"字号");fontLabel.font = .systemFont(ofSize:11);bottom.addArrangedSubview(fontLabel)
        fontPicker=NSPopUpButton(frame:.zero,pullsDown:false);fontPicker.addItems(withTitles:["16","22","28","36","48"]);fontPicker.selectItem(withTitle:String(Int(fontSize)));fontPicker.controlSize = .small;fontPicker.target=self;fontPicker.action=#selector(fontChanged);fontPicker.widthAnchor.constraint(equalToConstant:58).isActive=true;fontPicker.setAccessibilityLabel("文字字号");bottom.addArrangedSubview(fontPicker)
        NSLayoutConstraint.activate([top.topAnchor.constraint(equalTo:toolbar.topAnchor,constant:8),top.centerXAnchor.constraint(equalTo:toolbar.centerXAnchor),bottom.topAnchor.constraint(equalTo:top.bottomAnchor,constant:4),bottom.centerXAnchor.constraint(equalTo:toolbar.centerXAnchor)])
        updateToolbar()
    }
    private func separator() -> NSView { let view=NSBox();view.boxType = .separator;view.widthAnchor.constraint(equalToConstant:1).isActive=true;view.heightAnchor.constraint(equalToConstant:18).isActive=true;return view }
    private func setColor(_ value:NSColor) {
        color=value
        if let index=selectedAnnotation,index<annotations.count,annotations[index].tool != .mosaic { pushUndo(state());annotations[index].color=value }
        editor?.textColor=value;editor?.backgroundColor=editorBackground(value)
        if let text=editor?.currentEditor() as? NSTextView {text.textColor=value;text.typingAttributes[.foregroundColor]=value}
        saveStyle();updateToolbar();positionToolbar();needsDisplay=true
    }
    @objc private func widthChanged() {
        strokeWidth=CGFloat(widthSlider.doubleValue)
        if let index=selectedAnnotation,index<annotations.count { pushUndo(state());annotations[index].width=strokeWidth };saveStyle();needsDisplay=true
    }
    @objc private func fontChanged() {
        fontSize=CGFloat(Int(fontPicker.titleOfSelectedItem ?? "22") ?? 22)
        if let index=selectedAnnotation,index<annotations.count,annotations[index].tool == .text { pushUndo(state());annotations[index].fontSize=fontSize }
        editor?.font = .systemFont(ofSize:fontSize,weight:.medium)
        if let text=editor?.currentEditor() as? NSTextView {text.font=editor?.font}
        saveStyle();resizeTextEditor();needsDisplay=true
    }
    private func saveStyle() {
        if let rgb=color.usingColorSpace(.sRGB) {preferences?.set([Double(rgb.redComponent),Double(rgb.greenComponent),Double(rgb.blueComponent)],forKey:"markupColor")}
        preferences?.set(Double(strokeWidth),forKey:"markupWidth");preferences?.set(Double(fontSize),forKey:"markupFont")
    }
    @objc private func finishClicked() { finish(save:false) }
    private func updateToolbar() {
        let active:Tool = editor != nil ? .text : selectedAnnotation.flatMap{$0<annotations.count ? annotations[$0].tool : nil} ?? tool
        for (value,button) in toolButtons { button.state=value == active ? .on : .off;button.contentTintColor=value == active ? .systemBlue : .labelColor }
        if propertyBar != nil {
            let properties=active != .select && active != .mosaic
            propertyBar.isHidden = !properties
            toolbar.setFrameSize(CGSize(width:560,height:properties ? 76 : 46))
            let text=active == .text
            widthLabel.isHidden=text;widthSlider.isHidden=text;fontLabel.isHidden = !text;fontPicker.isHidden = !text
        }
        undoButton?.isEnabled = !undoStates.isEmpty;redoButton?.isEnabled = !redoStates.isEmpty
        for (button,value) in colorButtons { button.wantsLayer=true;button.layer?.cornerRadius=5;button.layer?.borderWidth=value.isEqual(color) ? 1 : 0;button.layer?.borderColor=NSColor.white.cgColor }
    }
    private func positionToolbar() {
        guard let rect=selection,rect.width>=3,rect.height>=3 else { toolbar.isHidden=true;return }
        let x=max(12,min(bounds.width-toolbar.frame.width-12,rect.maxX-toolbar.frame.width))
        let below=rect.maxY+12
        let y=below+toolbar.frame.height<bounds.height-12 ? below : max(12,rect.minY-toolbar.frame.height-12)
        toolbar.setFrameOrigin(CGPoint(x:x,y:y));toolbar.isHidden=false
    }
}
