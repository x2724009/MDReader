import AppKit
let args = CommandLine.arguments
let text = TextDecoding.decode(try! Data(contentsOf: URL(fileURLWithPath: args[1])))
let size = CGFloat(Double(args[3]) ?? 512)
let rep = MarkdownThumbnail.image(markdown: text, maximumSize: CGSize(width: size, height: size))!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("ok", rep.pixelsWide, rep.pixelsHigh)
