// Render the original Ruxi vector mark for native launchers. Run from repository root on macOS.
import AppKit
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func render(_ size: Int, _ path: String) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.scaleBy(x: CGFloat(size)/512, y: CGFloat(size)/512)
    context.translateBy(x: 0, y: 512); context.scaleBy(x: 1, y: -1)
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r/255, green: g/255, blue: b/255, alpha: 1) }
    let gold = color(243,173,71), green = color(153,185,172)
    context.setFillColor(color(16,20,22)); context.fill(CGRect(x:0,y:0,width:512,height:512))
    context.setStrokeColor(gold); context.setLineWidth(24); context.setLineJoin(.round)
    for x in [140,290] {
        context.move(to: CGPoint(x:x,y:372)); context.addLine(to: CGPoint(x:x,y:140)); context.addLine(to: CGPoint(x:x+82,y:140)); context.addLine(to: CGPoint(x:x+82,y:372)); context.strokePath()
    }
    context.setFillColor(gold); context.move(to: CGPoint(x:232,y:220)); context.addLine(to: CGPoint(x:232,y:332)); context.addLine(to: CGPoint(x:310,y:276)); context.closePath(); context.fillPath()
    for x in [180,256,332] { context.setFillColor(x == 256 ? gold : green); context.fillEllipse(in:CGRect(x:x-12,y:92,width:24,height:24)) }
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    try rep.representation(using:.png, properties:[:])!.write(to:root.appendingPathComponent(path), options:.atomic)
}
for (density,size) in [("mdpi",48),("hdpi",72),("xhdpi",96),("xxhdpi",144),("xxxhdpi",192)] {
    try render(size,"apps/mobile/android/app/src/main/res/mipmap-\(density)/ic_launcher.png")
}
let folder="apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/"
let json = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent(folder+"Contents.json"))) as! [String:Any]
for image in json["images"] as! [[String:String]] {
    let side=Double(image["size"]!.split(separator:"x")[0])!, scale=Double(image["scale"]!.dropLast())!
    try render(Int(side*scale),folder+image["filename"]!)
}
print("Rendered original Ruxi icons for Android and iOS.")
