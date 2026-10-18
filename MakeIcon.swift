import AppKit
let destination=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
let sizes=[(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),(128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),(512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")]
for (size,name) in sizes {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.current!.cgContext.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    let background=NSBezierPath(roundedRect:NSRect(x:32,y:32,width:960,height:960),xRadius:216,yRadius:216)
    NSGradient(starting:NSColor(srgbRed:0.42,green:0.58,blue:0.98,alpha:1),ending:NSColor(srgbRed:0.22,green:0.32,blue:0.72,alpha:1))!.draw(in:background,angle:-65)
    NSColor.white.withAlphaComponent(0.10).setFill();NSBezierPath(roundedRect:NSRect(x:244,y:244,width:536,height:536),xRadius:24,yRadius:24).fill()
    let corners=[(CGPoint(x:255,y:590),CGPoint(x:255,y:755),CGPoint(x:420,y:755)),(CGPoint(x:604,y:755),CGPoint(x:769,y:755),CGPoint(x:769,y:590)),(CGPoint(x:769,y:434),CGPoint(x:769,y:269),CGPoint(x:604,y:269)),(CGPoint(x:420,y:269),CGPoint(x:255,y:269),CGPoint(x:255,y:434))]
    NSColor.white.setStroke()
    for (a,b,c) in corners { let path=NSBezierPath();path.lineWidth=54;path.lineCapStyle = .round;path.lineJoinStyle = .round;path.move(to:a);path.line(to:b);path.line(to:c);path.stroke() }
    NSColor.white.setFill();NSBezierPath(ovalIn:NSRect(x:482,y:482,width:60,height:60)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent(name+".png"))
}
let types=[("icp4","icon_16x16"),("icp5","icon_32x32"),("icp6","icon_32x32@2x"),("ic07","icon_128x128"),("ic08","icon_256x256"),("ic09","icon_512x512"),("ic10","icon_512x512@2x"),("ic11","icon_16x16@2x"),("ic12","icon_32x32@2x"),("ic13","icon_128x128@2x"),("ic14","icon_256x256@2x")]
func lengthData(_ n:Int)->Data { var big=UInt32(n).bigEndian;return withUnsafeBytes(of:&big){Data($0)} }
var payload=Data()
for (type,name) in types { let png=try Data(contentsOf:destination.appendingPathComponent(name+".png"));payload.append(Data(type.utf8));payload.append(lengthData(png.count+8));payload.append(png) }
var icon=Data("icns".utf8);icon.append(lengthData(payload.count+8));icon.append(payload)
try icon.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
