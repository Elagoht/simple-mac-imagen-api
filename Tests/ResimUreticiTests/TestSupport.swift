import CoreGraphics
import Vapor
@testable import resimuretici

enum TestImages {
    static func solid(size: Int = 4) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }
}

/// Vapor Response gövdesini Data olarak alır (ByteBuffer sarmalamaları arasında taşınabilir).
func bodyData(_ response: Response) -> Data {
    if let data = response.body.data { return data }
    return Data((response.body.string ?? "").utf8)
}
