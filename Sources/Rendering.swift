import AppKit

enum Tool: String, CaseIterable {
    case select, rectangle, ellipse, arrow, pen, text, mosaic
    var symbol: String { switch self { case .select: return "cursorarrow"; case .rectangle: return "rectangle"; case .ellipse: return "oval"; case .arrow: return "arrow.up.right"; case .pen: return "pencil.tip"; case .text: return "textformat"; case .mosaic: return "square.grid.3x3.fill" } }
    var name: String { switch self { case .select: return "选择 / 移动 (V)"; case .rectangle: return "矩形 (R)"; case .ellipse: return "椭圆 (O)"; case .arrow: return "箭头 (A)"; case .pen: return "画笔 (P)"; case .text: return "文字 (T)"; case .mosaic: return "马赛克 (M)" } }
}

struct Annotation {
    var id = UUID()
    var tool: Tool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var fontSize: CGFloat = 22
    var textBoxWidth: CGFloat? = nil
    var bounds: CGRect {
        if tool == .text {
            let size = (text as NSString).boundingRect(with:CGSize(width:textBoxWidth ?? 10000,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:fontSize,weight:.medium)]).size
            return CGRect(origin:points.first ?? .zero,size:CGSize(width:max(textBoxWidth ?? 0,max(ceil(size.width),20)),height:max(ceil(size.height)+2,fontSize+4)))
        }
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { current, point in
            CGRect(x: min(current.minX, point.x), y: min(current.minY, point.y), width: max(current.maxX, point.x) - min(current.minX, point.x), height: max(current.maxY, point.y) - min(current.minY, point.y))
        }
    }
    func hitTest(_ point:CGPoint,tolerance:CGFloat=6)->Bool {
        let rect=bounds
        guard rect.insetBy(dx:-tolerance,dy:-tolerance).contains(point) else{return false}
        switch tool {
        case .select:return false
        case .text,.mosaic:return true
        case .rectangle:return !rect.insetBy(dx:tolerance,dy:tolerance).contains(point)
        case .ellipse:
            guard rect.width>0,rect.height>0 else{return false}
            let x=(point.x-rect.midX)/(rect.width/2),y=(point.y-rect.midY)/(rect.height/2)
            return abs(sqrt(x*x+y*y)-1)*min(rect.width,rect.height)/2<=tolerance
        case .arrow,.pen:
            guard points.count>1 else{return hypot(point.x-rect.midX,point.y-rect.midY)<=tolerance}
            return zip(points,points.dropFirst()).contains { a,b in
                let dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
                let t=length>0 ? max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/length)) : 0
                return hypot(point.x-a.x-t*dx,point.y-a.y-t*dy)<=max(tolerance,width/2)
            }
        }
    }
    func translated(dx: CGFloat, dy: CGFloat) -> Annotation {
        var copy = self; copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }; return copy
    }
}

enum CaptureGeometry {
    static func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
    }
    static func pixelRect(selection: CGRect, viewSize: CGSize, imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0, imageWidth > 0, imageHeight > 0 else { return nil }
        let logical = selection.standardized.intersection(CGRect(origin: .zero, size: viewSize))
        guard !logical.isNull, logical.width >= 1, logical.height >= 1 else { return nil }
        let sx = CGFloat(imageWidth) / viewSize.width, sy = CGFloat(imageHeight) / viewSize.height
        let x0 = floor(logical.minX * sx), y0 = floor(logical.minY * sy)
        let x1 = ceil(logical.maxX * sx), y1 = ceil(logical.maxY * sy)
        return CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    }
    static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: max(bounds.minX,min(bounds.maxX,point.x)),y:max(bounds.minY,min(bounds.maxY,point.y)))
    }
    static func moved(_ rect: CGRect, dx: CGFloat, dy: CGFloat, within bounds: CGRect) -> CGRect {
        CGRect(x: max(bounds.minX,min(bounds.maxX-rect.width,rect.minX+dx)), y: max(bounds.minY,min(bounds.maxY-rect.height,rect.minY+dy)), width: rect.width, height: rect.height)
    }
}

enum ImageRenderer {
    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    static func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
    }
    static func pixelated(source: CGImage, logicalRect: CGRect, viewSize: CGSize) -> CGImage? {
        guard let crop = CaptureGeometry.pixelRect(selection: logicalRect, viewSize: viewSize, imageWidth: source.width, imageHeight: source.height), let image = source.cropping(to: crop) else { return nil }
        let w = max(1, Int(ceil(logicalRect.width / 12))), h = max(1, Int(ceil(logicalRect.height / 12)))
        guard let small = makeContext(width: w, height: h) else { return nil }
        small.interpolationQuality = .low; small.draw(image, in: CGRect(x: 0,y: 0,width:w,height:h))
        return small.makeImage()
    }
    static func draw(_ annotation: Annotation, in context: CGContext, source: CGImage, viewSize: CGSize) {
        guard let a = annotation.points.first else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(annotation.color.cgColor); context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(annotation.width); context.setLineCap(.round); context.setLineJoin(.round)
        switch annotation.tool {
        case .select: break
        case .rectangle:
            context.stroke(annotation.bounds)
        case .ellipse:
            context.strokeEllipse(in:annotation.bounds)
        case .arrow:
            guard let b = annotation.points.last else { return }
            context.move(to:a); context.addLine(to:b); context.strokePath()
            let angle = atan2(b.y-a.y,b.x-a.x), length = max(12,annotation.width*4)
            context.move(to:b)
            context.addLine(to:CGPoint(x:b.x-length*cos(angle-0.45),y:b.y-length*sin(angle-0.45)))
            context.move(to:b)
            context.addLine(to:CGPoint(x:b.x-length*cos(angle+0.45),y:b.y-length*sin(angle+0.45))); context.strokePath()
        case .pen:
            if annotation.points.count == 1 { context.fillEllipse(in:CGRect(x:a.x-annotation.width/2,y:a.y-annotation.width/2,width:annotation.width,height:annotation.width)) }
            else { context.addLines(between:annotation.points); context.strokePath() }
        case .text:
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
            (annotation.text as NSString).draw(with:annotation.bounds,options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:annotation.fontSize,weight:.medium),.foregroundColor:annotation.color])
            NSGraphicsContext.restoreGraphicsState()
        case .mosaic:
            if let image = pixelated(source:source,logicalRect:annotation.bounds,viewSize:viewSize) {
                context.interpolationQuality = .none; drawUpright(image,in:annotation.bounds,context:context)
            }
        }
    }
    static func render(source: CGImage, viewSize: CGSize, selection: CGRect, annotations: [Annotation]) throws -> CGImage {
        guard let pixels = CaptureGeometry.pixelRect(selection:selection,viewSize:viewSize,imageWidth:source.width,imageHeight:source.height), let cropped = source.cropping(to:pixels) else { throw AppError.message("选区太小，请重新框选。") }
        if annotations.isEmpty { return cropped }
        guard let context = makeContext(width:cropped.width,height:cropped.height) else { throw AppError.message("无法创建截图，请缩小截图范围后重试。") }
        context.draw(cropped,in:CGRect(x:0,y:0,width:cropped.width,height:cropped.height))
        let sx = CGFloat(source.width)/viewSize.width, sy = CGFloat(source.height)/viewSize.height
        context.translateBy(x:0,y:CGFloat(cropped.height));context.scaleBy(x:sx,y:-sy)
        context.translateBy(x:-pixels.minX/sx,y:-pixels.minY/sy)
        for annotation in annotations { draw(annotation,in:context,source:source,viewSize:viewSize) }
        guard let image = context.makeImage() else { throw AppError.message("截图合成失败。") }
        return image
    }
}
