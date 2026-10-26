import CKDRaw
import Foundation

public struct QCamRawRenderResult: Sendable {
    public let image: QCamRGBAImage
    public let cameraWhiteBalance: [Double]
    public let libRawVersion: String
    public let rawDimensions: QCamImageDimensions
    public let visibleDimensions: QCamImageDimensions
}

public enum QCamRawImport {
    public static let supportedExtensions = ["dng", "cr2"]
    public static let renderMethod = "libraw_0_22_1_rawpy_equivalent_rgba8888_v1"

    public static var libRawVersion: String { CKDLibRawRenderer.libRawVersion() }

    public static var libRawVersionTriple: String {
        let number = CKDLibRawRenderer.libRawVersionNumber()
        return "\(number >> 16).\((number >> 8) & 0xFF).\(number & 0xFF)"
    }

    public static func validate(url: URL) throws {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw QCamError.unsupportedFileType(ext.isEmpty ? "none" : ext)
        }
        if usesJPEGXL(url: url) { throw QCamError.jpegXLCompressedDNG }
    }

    /// True when a full-resolution image in this TIFF/DNG is JPEG XL compressed (compression 52546).
    public static func usesJPEGXL(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data? {
            guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count),
                  data.count == count else { return nil }
            return data
        }
        guard let header = read(0, 8), header.prefix(2) == Data("II".utf8) || header.prefix(2) == Data("MM".utf8) else { return false }
        let little = header.prefix(2) == Data("II".utf8)
        func number(_ data: Data, _ at: Int, _ size: Int) -> UInt32 {
            let bytes = data[data.startIndex + at..<data.startIndex + at + size]
            return (little ? bytes.reversed() : Array(bytes)).reduce(0) { $0 << 8 | UInt32($1) }
        }
        guard number(header, 2, 2) == 42 else { return false }
        var pending = [number(header, 4, 4)], seen = Set<UInt32>()
        while let offset = pending.popLast(), seen.count < 64 {
            guard offset != 0, seen.insert(offset).inserted, let countData = read(UInt64(offset), 2) else { continue }
            let count = Int(number(countData, 0, 2))
            guard let block = read(UInt64(offset) + 2, 12 * count + 4) else { continue }
            var compression: UInt32?, subfile: UInt32 = 0
            for index in 0..<count {
                let tag = number(block, 12 * index, 2), kind = number(block, 12 * index + 2, 2)
                let items = number(block, 12 * index + 4, 4), value = 12 * index + 8
                if (tag == 254 || tag == 259) && items == 1 {
                    let field = kind == 3 ? number(block, value, 2) : number(block, value, 4)
                    if tag == 259 { compression = field } else { subfile = field }
                } else if tag == 330 && (kind == 4 || kind == 13) {
                    if items == 1 {
                        pending.append(number(block, value, 4))
                    } else if items < 1024, let list = read(UInt64(number(block, value, 4)), 4 * Int(items)) {
                        pending += (0..<Int(items)).map { number(list, 4 * $0, 4) }
                    }
                }
            }
            if compression == 52546 && subfile == 0 { return true }
            pending.append(number(block, 12 * count, 4))
        }
        return false
    }

    public static func inspect(url: URL) throws -> (pixels: Int, linear: Bool) {
        if usesJPEGXL(url: url) { throw QCamError.jpegXLCompressedDNG }
        do {
            let info = try CKDLibRawRenderer.inspectImage(atPath: url.path)
            return (info.pixelCount, info.linear)
        } catch {
            throw QCamError.failedToRenderLibRawImage(url, error.localizedDescription)
        }
    }

    public static func render(url: URL) throws -> QCamRawRenderResult {
        let options = baseOptions(userWhiteBalance: [0, 0, 0, 0], brightness: 1.0)
        options.useCameraWhiteBalance = true
        return try render(url: url, options: options)
    }

    public static func render(url: URL, explicitWhiteBalance: [Double], brightness: Double) throws -> QCamRawRenderResult {
        try render(url: url, options: baseOptions(userWhiteBalance: explicitWhiteBalance, brightness: brightness))
    }

    private static func render(url: URL, options: CKDLibRawRenderOptions) throws -> QCamRawRenderResult {
        try autoreleasepool {
            let rendered: CKDLibRawRenderedImage
            do {
                rendered = try CKDLibRawRenderer.renderImage(atPath: url.path, options: options)
            } catch {
                if usesJPEGXL(url: url) { throw QCamError.jpegXLCompressedDNG }
                throw QCamError.failedToRenderLibRawImage(url, error.localizedDescription)
            }
            return result(from: rendered)
        }
    }

    private static func result(from rendered: CKDLibRawRenderedImage) -> QCamRawRenderResult {
        QCamRawRenderResult(
            image: QCamRGBAImage(width: rendered.width, height: rendered.height, data: rendered.rgba8888Data),
            cameraWhiteBalance: rendered.cameraWhiteBalance.map(\.doubleValue),
            libRawVersion: rendered.libRawVersion,
            rawDimensions: QCamImageDimensions(width: rendered.rawWidth, height: rendered.rawHeight),
            visibleDimensions: QCamImageDimensions(width: rendered.visibleWidth, height: rendered.visibleHeight)
        )
    }

    private static func baseOptions(userWhiteBalance: [Double], brightness: Double) -> CKDLibRawRenderOptions {
        let padded = Array((userWhiteBalance + [0.0, 0.0, 0.0, 0.0]).prefix(4))
        let options = CKDLibRawRenderOptions(
            redMultiplier: padded[0],
            greenMultiplier: padded[1],
            blueMultiplier: padded[2],
            fourthMultiplier: padded[3],
            brightness: brightness
        )
        options.noAutoBright = true
        options.useCameraWhiteBalance = false
        options.useAutoWhiteBalance = false
        options.outputColor = 0
        options.demosaicAlgorithm = 1
        options.outputBitsPerSample = 8
        options.userFlip = -1
        return options
    }
}

public enum QCamWhiteBalanceMetadata {
    public static let method = "rawpy_two_pass_raw_reload_v1"
    public static let normBrightness = 180.0
}

public enum QCamRawWhiteBalance {
    public static func explicitWhiteBalanceScale(
        measuredRGB: QCamRGBMean,
        currentImageWhiteBalance: [Double]
    ) throws -> [Double] {
        guard currentImageWhiteBalance.count >= 4 else { throw QCamError.missingCameraWhiteBalance }
        let color = [
            measuredRGB.red,
            measuredRGB.green,
            measuredRGB.blue,
        ]
        var scale = color.map { measuredRGB.green / max($0, 1.0e-12) }
        scale.append(1.0)
        let normScale = sqrt(scale.reduce(0.0) { $0 + $1 * $1 } / 4.0)
        scale = scale.map { $0 / normScale }
        let iwbNorm = sqrt(currentImageWhiteBalance.reduce(0.0) { $0 + $1 * $1 } / 4.0)
        var explicit = zip(scale, currentImageWhiteBalance).map { scaleValue, whiteBalanceValue in
            scaleValue * scaleValue * whiteBalanceValue / iwbNorm
        }
        explicit[3] = 0.0
        return explicit
    }

    public static func brightnessScale(afterFirstPass measuredRGB: QCamRGBMean) -> Double {
        pow(QCamWhiteBalanceMetadata.normBrightness / measuredRGB.green, 2.0)
    }
}

public struct QCamWhiteBalanceRender: Sendable {
    public let image: QCamRGBAImage
    public let initialMean: QCamRGBMean
    public let firstPassWhiteBalance: [Double]
    public let firstPassMean: QCamRGBMean
    public let explicitWhiteBalance: [Double]
    public let brightness: Double
}

public enum QCamWhiteBalancePipeline {
    public static let sampling: QCamPolygonSampling = .boundaryInclusivePolygon

    public static func render(
        url: URL,
        initialImage: QCamRGBAImage,
        cameraWhiteBalance: [Double],
        polygon: QCamPolygon,
        afterFirstPass: (QCamRGBAImage) -> Void = { _ in }
    ) throws -> QCamWhiteBalanceRender {
        try render(
            url: url,
            initialMean: try initialImage.rgbMean(for: polygon, sampling: sampling),
            cameraWhiteBalance: cameraWhiteBalance,
            polygon: polygon,
            afterFirstPass: afterFirstPass
        )
    }

    public static func render(
        url: URL,
        initialMean: QCamRGBMean,
        cameraWhiteBalance: [Double],
        polygon: QCamPolygon,
        afterFirstPass: (QCamRGBAImage) -> Void = { _ in }
    ) throws -> QCamWhiteBalanceRender {
        let firstPassWhiteBalance = try QCamRawWhiteBalance.explicitWhiteBalanceScale(
            measuredRGB: initialMean,
            currentImageWhiteBalance: cameraWhiteBalance
        )
        let firstPassMean = try autoreleasepool {
            let firstPass = try QCamRawImport.render(
                url: url,
                explicitWhiteBalance: firstPassWhiteBalance,
                brightness: 1.0
            )
            afterFirstPass(firstPass.image)
            return try firstPass.image.rgbMean(for: polygon, sampling: sampling)
        }
        let finalWhiteBalance = try QCamRawWhiteBalance.explicitWhiteBalanceScale(
            measuredRGB: firstPassMean,
            currentImageWhiteBalance: firstPassWhiteBalance
        )
        let brightness = QCamRawWhiteBalance.brightnessScale(afterFirstPass: firstPassMean)
        let finalPass = try QCamRawImport.render(
            url: url,
            explicitWhiteBalance: finalWhiteBalance,
            brightness: brightness
        )
        return QCamWhiteBalanceRender(
            image: finalPass.image,
            initialMean: initialMean,
            firstPassWhiteBalance: firstPassWhiteBalance,
            firstPassMean: firstPassMean,
            explicitWhiteBalance: finalWhiteBalance,
            brightness: brightness
        )
    }
}
