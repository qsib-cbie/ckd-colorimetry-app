import CKDImage
import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum Overlay {
    public static func png(_ image: QCamRGBAImage, rois: [DraftROI]) throws -> Data {
        let width = image.width, height = image.height
        let space = CGColorSpaceCreateDeviceRGB()
        var pixels = image.data
        let encoded: Data? = pixels.withUnsafeMutableBytes { buffer -> Data? in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setStrokeColor(CGColor(srgbRed: 8 / 255, green: 168 / 255, blue: 156 / 255, alpha: 1))
            context.setLineWidth(CGFloat(max(2, width / 600)))
            let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(max(11, width / 150)), nil)
            for roi in rois where !roi.points.isEmpty {
                context.beginPath()
                context.move(to: CGPoint(x: roi.points[0].x, y: roi.points[0].y))
                for point in roi.points.dropFirst() { context.addLine(to: CGPoint(x: point.x, y: point.y)) }
                context.closePath()
                context.strokePath()
                let attributes: [CFString: Any] = [
                    kCTFontAttributeName: font,
                    kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 223 / 255, blue: 0, alpha: 1),
                ]
                let line = CTLineCreateWithAttributedString(
                    CFAttributedStringCreate(nil, "ROI \(roi.id)" as CFString, attributes as CFDictionary)!
                )
                context.saveGState()
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = CGPoint(x: roi.points[0].x, y: roi.points[0].y + CTFontGetAscent(font))
                CTLineDraw(line, context)
                context.restoreGState()
            }
            guard let rendered = context.makeImage() else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, rendered, nil)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }
        guard let encoded else { throw DocumentError("The ROI overlay could not be drawn.") }
        return encoded
    }
}
