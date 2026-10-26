import Foundation

public enum QCamError: LocalizedError, Equatable {
    case unsupportedFileType(String)
    case failedToRenderLibRawImage(URL, String)
    case jpegXLCompressedDNG
    case missingCameraWhiteBalance
    case incompleteColorChecker
    case incompleteManualFlowerCalibration(Int)
    case invalidCalibrationPatch(QCamROIPolygonIssue)
    case calibrationPatchOutsideImage
    case emptyPolygon
    case singularCalibration
    case colorCalibrationRMSETooHigh(Double, Double)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return "Choose a DNG (iPhone RAW or ProRAW) or CR2 file. This file's extension is \(ext)."
        case .failedToRenderLibRawImage(let url, let reason):
            return "The RAW image could not be rendered by LibRaw: \(url.lastPathComponent). \(reason)"
        case .jpegXLCompressedDNG:
            return "This DNG uses JPEG XL compression, which CKD Colorimetry cannot read. On the iPhone, choose the most compatible ProRAW format in the Camera settings and take the photo again."
        case .missingCameraWhiteBalance:
            return "The RAW file did not provide camera white-balance multipliers needed for raw white balance."
        case .incompleteColorChecker:
            return "Color Calibration requires four ColorChecker corner points."
        case .incompleteManualFlowerCalibration(let count):
            return "Flower Manual calibration requires exactly nine valid patch polygons. Current count: \(count)."
        case .invalidCalibrationPatch(let issue):
            return "This calibration patch \(issue.message). Adjust its points before adding it."
        case .calibrationPatchOutsideImage:
            return "Keep every calibration patch point inside the image."
        case .emptyPolygon:
            return "The selected polygon contains no image pixels."
        case .singularCalibration:
            return "Color Calibration could not solve a stable affine transform."
        case .colorCalibrationRMSETooHigh(let rmse, let maximum):
            return "Color Calibration RMSE \(String(format: "%.3f", rmse)) exceeds the allowed maximum of \(String(format: "%.1f", maximum)). Refit the ColorChecker corners."
        }
    }
}
