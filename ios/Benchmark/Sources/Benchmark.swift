import CKDImage
import CoreGraphics
import Foundation
import UIKit

struct StageResult: Codable {
    let file: String
    let mode: String
    let stage: String
    let seconds: Double
    let beforeMB: Double
    let peakMB: Double
    let afterMB: Double
    let availableAfterMB: Double
}

struct DeviceInfo: Codable {
    let machine: String
    let system: String
    let physicalMemoryMB: Double
    let footprintMB: Double
    let availableMB: Double
    let limitEstimateMB: Double
}

struct Report: Codable {
    let device: DeviceInfo
    let stages: [StageResult]
}

enum BenchmarkMode: String, CaseIterable {
    case lean
    case qdaq
}

final class BenchmarkRunner: @unchecked Sendable {
    private let log: (String) -> Void
    private var results: [StageResult] = []
    private let reportURL: URL

    init(log: @escaping (String) -> Void) {
        self.log = log
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        reportURL = Self.documents.appendingPathComponent("benchmark-\(stamp).json")
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static func inputFiles() -> [URL] {
        let bundled = ["SampleImg1.CR2", "iPhoneRAW.DNG"].compactMap {
            Bundle.main.url(forResource: $0, withExtension: nil)
        }
        let documents = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        let added = documents
            .filter { QCamRawImport.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return bundled + added
    }

    static func deviceInfo() -> DeviceInfo {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        let footprint = mb(MemoryProbe.footprint())
        let available = mb(MemoryProbe.available())
        return DeviceInfo(
            machine: machine,
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            physicalMemoryMB: mb(ProcessInfo.processInfo.physicalMemory),
            footprintMB: footprint,
            availableMB: available,
            limitEstimateMB: footprint + available
        )
    }

    func run(modes: [BenchmarkMode]) {
        let device = Self.deviceInfo()
        log("CKDBENCH device \(json(device))")
        for url in Self.inputFiles() {
            for mode in modes {
                do {
                    try run(url: url, mode: mode)
                } catch {
                    log("CKDBENCH error \(url.lastPathComponent) \(mode.rawValue): \(error.localizedDescription)")
                }
            }
        }
        log("CKDBENCH done \(reportURL.lastPathComponent)")
    }

    private func run(url: URL, mode: BenchmarkMode) throws {
        let name = url.lastPathComponent
        var initial: QCamRawRenderResult? = try measure(name, mode, "render") {
            try QCamRawImport.render(url: url)
        }
        let width = initial!.image.width
        let height = initial!.image.height
        let cameraWhiteBalance = initial!.cameraWhiteBalance
        log("CKDBENCH size \(name) \(width)x\(height) \(String(format: "%.1f", Double(width * height) / 1e6)) MP")
        let side = Double(min(width, height)) / 10
        let polygon = QCamPolygon(points: [
            QCamPoint(x: Double(width) / 2 - side, y: Double(height) / 2 - side),
            QCamPoint(x: Double(width) / 2 + side, y: Double(height) / 2 - side),
            QCamPoint(x: Double(width) / 2 + side, y: Double(height) / 2 + side),
            QCamPoint(x: Double(width) / 2 - side, y: Double(height) / 2 + side),
        ])
        let initialMean = try initial!.image.rgbMean(for: polygon, sampling: QCamWhiteBalancePipeline.sampling)

        var display: CGImage?
        if mode == .lean {
            try measure(name, mode, "cache_write_initial") {
                try initial!.image.data.write(to: Self.cache.appendingPathComponent("initial.rgba"), options: .atomic)
            }
            initial = nil
        }

        let balanced = try measure(name, mode, "white_balance") {
            try QCamWhiteBalancePipeline.render(
                url: url,
                initialMean: initialMean,
                cameraWhiteBalance: cameraWhiteBalance,
                polygon: polygon
            )
        }

        switch mode {
        case .lean:
            try measure(name, mode, "cache_write_final") {
                try balanced.image.data.write(to: Self.cache.appendingPathComponent("final.rgba"), options: .atomic)
            }
            try measure(name, mode, "cache_mapped_mean") {
                let mapped = try Data(contentsOf: Self.cache.appendingPathComponent("initial.rgba"), options: .alwaysMapped)
                _ = try QCamRGBAImage(width: width, height: height, data: mapped)
                    .rgbMean(for: polygon, sampling: QCamWhiteBalancePipeline.sampling)
            }
            display = try measure(name, mode, "preview_4096") {
                try downsampled(balanced.image, longSide: 4096)
            }
        case .qdaq:
            display = try measure(name, mode, "full_resolution_display") {
                try downsampled(balanced.image, longSide: max(width, height))
            }
        }

        try measure(name, mode, "roi_statistics_24") {
            let roiSide = Double(min(width, height)) / 40
            for index in 0..<24 {
                let x = Double(width) * (Double(index % 6) + 0.5) / 6
                let y = Double(height) * (Double(index / 6) + 0.5) / 4
                let roi = QCamPolygon(points: [
                    QCamPoint(x: x - roiSide, y: y - roiSide),
                    QCamPoint(x: x + roiSide, y: y - roiSide),
                    QCamPoint(x: x + roiSide, y: y + roiSide),
                    QCamPoint(x: x - roiSide, y: y + roiSide),
                ])
                _ = try balanced.image.labStats(for: roi, sampling: QCamAnalysisPipeline.roiSampling)
            }
        }
        withExtendedLifetime((initial, display)) {}
    }

    private func downsampled(_ image: QCamRGBAImage, longSide: Int) throws -> CGImage {
        let scale = Double(longSide) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: image.data as CFData),
              let source = CGImage(
                width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: bitmapInfo
              ) else {
            throw CocoaError(.featureUnsupported)
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw CocoaError(.featureUnsupported) }
        return output
    }

    @discardableResult
    private func measure<T>(_ file: String, _ mode: BenchmarkMode, _ stage: String, _ body: () throws -> T) throws -> T {
        let before = MemoryProbe.footprint()
        let sampler = PeakSampler()
        let start = Date()
        let value = try body()
        let seconds = Date().timeIntervalSince(start)
        let peak = sampler.stop()
        let result = StageResult(
            file: file,
            mode: mode.rawValue,
            stage: stage,
            seconds: seconds,
            beforeMB: Self.mb(before),
            peakMB: Self.mb(peak),
            afterMB: Self.mb(MemoryProbe.footprint()),
            availableAfterMB: Self.mb(MemoryProbe.available())
        )
        results.append(result)
        log("CKDBENCH stage \(json(result))")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Report(device: Self.deviceInfo(), stages: results)) {
            try? data.write(to: reportURL, options: .atomic)
        }
        return value
    }

    private func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "{}"
    }

    private static func mb(_ bytes: UInt64) -> Double {
        (Double(bytes) / 1_048_576 * 10).rounded() / 10
    }
}
