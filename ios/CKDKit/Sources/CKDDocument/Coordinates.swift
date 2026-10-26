import CKDImage
import CKDResults
import Foundation

public enum CoordinatePackage {
    public static func export(_ document: AnalysisDocument) -> JSONValue {
        let draft = document.draft
        func points(_ values: [QCamPoint]) -> JSONValue {
            .array(values.map { .object([("x", .double($0.x)), ("y", .double($0.y))]) })
        }
        return .object([
            ("schema_name", .string("qdaq_ckd_coordinate_package")), ("schema_version", .int(2)),
            ("coordinate_system", .string("top_left_image_pixels")),
            ("source_image_filename", .string(document.sourceFilename)),
            ("source_image_sha256", .string(document.sourceSHA256)),
            ("image_dimensions", .object([("width", document.width.map(JSONValue.int) ?? .null),
                                          ("height", document.height.map(JSONValue.int) ?? .null)])),
            ("calibration_marker_kind", .string(draft.mode == "standard_24_grid" ? "standard_24" : "flower_9")),
            ("calibration_mode", .string(draft.mode)),
            ("white_balance_polygon", .object([("points", points(draft.whiteBalance))])),
            ("color_calibration_corners", points(draft.corners)),
            ("manual_color_calibration_polygons", .array(draft.manualPatches.map { .object([("points", points($0))]) })),
            ("reservoir_geometry_version", .string("manual_polygon_v2")),
            ("reservoirs", .array(draft.reservoirs.map { r in
                .object([
                    ("reservoir_id", .int(r.id)), ("label", .string("Reservoir \(r.id)")), ("analyte", .text(r.analyte)),
                    ("custom_name", .string(r.customName)), ("condition", .string(r.condition)),
                    ("replicate", .string(r.replicate)), ("roi_ids", .array(r.roiIDs.map(JSONValue.int))),
                    ("review_status", .string("needs_review")), ("exclusion_reason", .null),
                ])
            })),
            ("rois", .array(draft.rois.map {
                .object([("roi_id", .int($0.id)), ("roi_label", .string($0.label)), ("polygon", .object([("points", points($0.points))]))])
            })),
        ])
    }

    public static func importDraft(_ package: JSONValue, into document: AnalysisDocument) throws -> Draft {
        guard package["schema_name"]?.stringValue == "qdaq_ckd_coordinate_package",
              let version = package["schema_version"]?.intValue, [1, 2].contains(version) else {
            throw DocumentError("Expected a QDAQ CKD coordinate package version 1 or 2.")
        }
        guard package["coordinate_system"]?.stringValue == "top_left_image_pixels" else {
            throw DocumentError("Coordinates must use top-left original image pixels.")
        }
        let dimensions = package["image_dimensions"]
        guard package["source_image_sha256"]?.stringValue == document.sourceSHA256,
              let width = document.width, let height = document.height,
              dimensions?.objectPairs?.count == 2, dimensions?["width"]?.doubleValue == Double(width), dimensions?["height"]?.doubleValue == Double(height) else {
            throw DocumentError("Coordinate source hash or dimensions do not match this image.")
        }
        let mode = package["calibration_mode"]?.stringValue
            ?? (package["calibration_marker_kind"]?.stringValue == "standard_24" ? "standard_24_grid" : "flower_9")
        let reservoirs = package["reservoirs"]?.arrayValues ?? []
        guard reservoirs.count <= Draft.maximumReservoirs else {
            throw DocumentError("Coordinate packages can contain at most \(Draft.maximumReservoirs) reservoirs.")
        }
        func text(_ value: JSONValue?) -> JSONValue {
            guard let value, let string = value.stringValue, !string.isEmpty else { return .string("") }
            return .string(string)
        }
        let draftJSON: JSONValue = .object([
            ("title", .string(document.draft.title)), ("mode", .string(mode)),
            ("white_balance", package["white_balance_polygon"]?["points"] ?? .array([])),
            ("corners", package["color_calibration_corners"] ?? .array([])),
            ("manual_patches", .array((package["manual_color_calibration_polygons"]?.arrayValues ?? []).map { $0["points"] ?? .null })),
            ("rois", .array(try (package["rois"]?.arrayValues ?? []).map { roi in
                guard let id = roi["roi_id"], let label = roi["roi_label"], let points = roi["polygon"]?["points"] else {
                    throw DocumentError("The coordinate package is incomplete or malformed.")
                }
                return .object([("id", id), ("label", label), ("points", points)])
            })),
            ("reservoirs", .array(try reservoirs.map { r in
                guard let id = r["reservoir_id"], let roiIDs = r["roi_ids"] else {
                    throw DocumentError("The coordinate package is incomplete or malformed.")
                }
                return .object([
                    ("id", id), ("analyte", r["analyte"] ?? .null), ("custom_name", text(r["custom_name"])),
                    ("condition", text(r["condition"])), ("replicate", text(r["replicate"])), ("roi_ids", roiIDs),
                ])
            })),
        ])
        return try Draft(json: draftJSON)
    }
}
