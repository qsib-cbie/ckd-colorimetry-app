import CKDDocument
import CKDImage
import SwiftUI

struct CanvasShape: Identifiable {
    let id: String
    let points: [QCamPoint]
    let color: Color
    let label: String?
    let emphasized: Bool
    var editable = false
    var closed = true
    var ordered = true
    var guides: String?
}

enum DrawingTool: String, Equatable {
    case none, rectangle, polygon, corners

    var isDrawing: Bool { self != .none }

    var title: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .polygon: return "Polygon"
        case .corners: return "Corners"
        case .none: return ""
        }
    }

    var icon: String {
        switch self {
        case .rectangle: return "rectangle.dashed"
        case .polygon: return "pentagon"
        case .corners: return "viewfinder"
        case .none: return ""
        }
    }
}

struct CanvasLayout {
    let view: CGSize
    let image: CGSize
    let zoom: CGFloat
    let offset: CGSize

    var scale: CGFloat { min(view.width / max(image.width, 1), view.height / max(image.height, 1)) * zoom }

    var imageRect: CGRect {
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (view.width - size.width) / 2 + offset.width, y: (view.height - size.height) / 2 + offset.height,
                      width: size.width, height: size.height)
    }

    func point(_ p: QCamPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: rect.minX + (p.x + 0.5) * scale, y: rect.minY + (p.y + 0.5) * scale)
    }

    func imagePoint(_ v: CGPoint) -> QCamPoint {
        let rect = imageRect
        let x = ((v.x - rect.minX) / scale - 0.5).rounded()
        let y = ((v.y - rect.minY) / scale - 0.5).rounded()
        return QCamPoint(x: min(max(x, 0), image.width - 1), y: min(max(y, 0), image.height - 1))
    }
}

struct ImageCanvas: View {
    struct Grab {
        let shape: String
        let index: Int
        let origin: CGPoint
        var point: QCamPoint
    }

    let image: CGImage?
    let imageSize: CGSize
    let shapes: [CanvasShape]
    @Binding var tool: DrawingTool
    @Binding var points: [QCamPoint]
    @Binding var selected: String?
    var selectionLabel: String?
    var keepDrawing: () -> Bool = { false }
    let onComplete: ([QCamPoint]) -> Void
    let onEdit: (String, [QCamPoint]) -> Void

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var grab: Grab?
    @State private var decided = false
    @State private var dragStart: QCamPoint?
    @State private var dragEnd: QCamPoint?
    @State private var panning = false
    @State private var lastMagnify = Date.distantPast

    var body: some View {
        GeometryReader { geometry in
            let layout = CanvasLayout(view: geometry.size, image: imageSize, zoom: zoom, offset: offset)
            Canvas { context, _ in
                if let image {
                    context.draw(Image(decorative: image, scale: 1), in: layout.imageRect)
                }
                for shape in shapes { draw(shape, in: &context, layout: layout) }
                if let shape = shapes.first(where: { $0.id == selected && $0.editable }) {
                    for point in displayed(shape) {
                        let p = layout.point(point)
                        let handle = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                        context.fill(handle, with: .color(.white))
                        context.stroke(handle, with: .color(shape.color), lineWidth: 2)
                    }
                }
                if let start = dragStart, let end = dragEnd {
                    draw(CanvasShape(id: "draft", points: Self.rectangle(start, end), color: .white, label: nil, emphasized: true),
                         in: &context, layout: layout)
                }
                if !points.isEmpty {
                    draw(CanvasShape(id: "draft", points: points, color: .white, label: nil, emphasized: true, closed: false),
                         in: &context, layout: layout)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(layout))
            .simultaneousGesture(magnifyGesture)
            .accessibilityElement()
            .accessibilityIdentifier("canvas")
            .accessibilityLabel("Image canvas")
            .accessibilityValue(selectionLabel ?? "")
            .overlay(alignment: .topTrailing) { zoomControls }
            .overlay(alignment: .bottom) { drawingControls }
        }
        .background(Color(white: 0.12))
        .clipped()
        .onChange(of: tool) { _, _ in
            points = []
            dragStart = nil
            dragEnd = nil
            panning = false
        }
    }

    static func rectangle(_ a: QCamPoint, _ b: QCamPoint) -> [QCamPoint] {
        let left = min(a.x, b.x), right = max(a.x, b.x), top = min(a.y, b.y), bottom = max(a.y, b.y)
        return [QCamPoint(x: left, y: top), QCamPoint(x: right, y: top), QCamPoint(x: right, y: bottom), QCamPoint(x: left, y: bottom)]
    }

    private func displayed(_ shape: CanvasShape) -> [QCamPoint] {
        var points = shape.points
        if let grab, grab.shape == shape.id, points.indices.contains(grab.index) { points[grab.index] = grab.point }
        return points
    }

    private func handle(at location: CGPoint, _ layout: CanvasLayout) -> Grab? {
        guard let shape = shapes.first(where: { $0.id == selected && $0.editable }) else { return nil }
        let nearest = shape.points.indices.min { hypot(layout.point(shape.points[$0]).x - location.x, layout.point(shape.points[$0]).y - location.y)
            < hypot(layout.point(shape.points[$1]).x - location.x, layout.point(shape.points[$1]).y - location.y) }
        guard let index = nearest else { return nil }
        let origin = layout.point(shape.points[index])
        guard hypot(origin.x - location.x, origin.y - location.y) <= 28 else { return nil }
        return Grab(shape: shape.id, index: index, origin: origin, point: shape.points[index])
    }

    private func shape(at location: CGPoint, _ layout: CanvasLayout) -> String? {
        shapes.filter { shape in
            guard shape.editable, shape.points.count >= 3 else { return false }
            var path = Path()
            path.addLines(shape.points.map(layout.point))
            path.closeSubpath()
            return path.contains(location, eoFill: false)
        }.min { area($0) < area($1) }?.id
    }

    private func area(_ shape: CanvasShape) -> Double {
        let xs = shape.points.map(\.x), ys = shape.points.map(\.y)
        return (xs.max()! - xs.min()!) * (ys.max()! - ys.min()!)
    }

    private func draw(_ shape: CanvasShape, in context: inout GraphicsContext, layout: CanvasLayout) {
        guard !shape.points.isEmpty else { return }
        var ordered = displayed(shape)
        if !shape.ordered, ordered.count == 4 {
            let cx = ordered.map(\.x).reduce(0, +) / 4, cy = ordered.map(\.y).reduce(0, +) / 4
            ordered.sort { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
        }
        var path = Path()
        path.move(to: layout.point(ordered[0]))
        for point in ordered.dropFirst() { path.addLine(to: layout.point(point)) }
        if shape.closed { path.closeSubpath() }
        context.stroke(path, with: .color(shape.color), lineWidth: shape.emphasized ? 3 : 1.5)
        if let mode = shape.guides, let patches = try? MacCalibration.markerPolygons(mode: mode, corners: displayed(shape)) {
            for patch in patches where !patch.isEmpty {
                var outline = Path()
                outline.addLines(patch.map(layout.point))
                outline.closeSubpath()
                context.stroke(outline, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        }
        if shape.emphasized || !shape.closed {
            for point in ordered {
                let p = layout.point(point)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(shape.color))
            }
        }
        if let label = shape.label {
            let anchor = layout.point(ordered[0])
            context.draw(Text(label).font(.caption2.bold()).foregroundStyle(shape.color),
                         at: CGPoint(x: anchor.x + 4, y: anchor.y - 8), anchor: .leading)
        }
    }

    private func dragGesture(_ layout: CanvasLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard Date().timeIntervalSince(lastMagnify) > 0.3 else { return }
                if !tool.isDrawing && !decided {
                    decided = true
                    grab = handle(at: value.startLocation, layout)
                }
                if var current = grab {
                    current.point = layout.imagePoint(CGPoint(x: current.origin.x + value.translation.width,
                                                              y: current.origin.y + value.translation.height))
                    grab = current
                } else if !tool.isDrawing || panning {
                    offset = CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height)
                } else if tool == .rectangle {
                    dragStart = layout.imagePoint(value.startLocation)
                    dragEnd = layout.imagePoint(value.location)
                }
            }
            .onEnded { value in
                decided = false
                let moved = hypot(value.translation.width, value.translation.height)
                guard Date().timeIntervalSince(lastMagnify) > 0.3 else {
                    dragStart = nil
                    dragEnd = nil
                    grab = nil
                    return
                }
                if let current = grab {
                    grab = nil
                    if moved >= 3, let shape = shapes.first(where: { $0.id == current.shape }), shape.points.indices.contains(current.index) {
                        var edited = shape.points
                        edited[current.index] = current.point
                        if edited != shape.points { onEdit(shape.id, edited) }
                    }
                    return
                }
                if !tool.isDrawing || panning {
                    baseOffset = offset
                    if !tool.isDrawing && moved < 10 { selected = shape(at: value.location, layout) }
                    return
                }
                switch tool {
                case .rectangle:
                    let start = layout.imagePoint(value.startLocation), end = layout.imagePoint(value.location)
                    dragStart = nil
                    dragEnd = nil
                    if abs(start.x - end.x) >= 1 && abs(start.y - end.y) >= 1 {
                        onComplete(Self.rectangle(start, end))
                        if !keepDrawing() { tool = .none }
                    }
                case .polygon where moved < 10:
                    if points.count >= 3, let first = points.first {
                        let anchor = layout.point(first)
                        if hypot(anchor.x - value.location.x, anchor.y - value.location.y) <= 20 {
                            finishPolygon()
                            return
                        }
                    }
                    let point = layout.imagePoint(value.location)
                    if points.last != point { points.append(point) }
                case .corners where moved < 10:
                    points.append(layout.imagePoint(value.location))
                    if points.count == 4 {
                        onComplete(points)
                        tool = .none
                    }
                default:
                    break
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                lastMagnify = Date()
                let next = min(max(baseZoom * value.magnification, 1), 40)
                let ratio = next / zoom
                offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
                zoom = next
            }
            .onEnded { _ in
                lastMagnify = Date()
                baseZoom = zoom
                baseOffset = offset
            }
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { setZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { setZoom(1); offset = .zero; baseOffset = .zero } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .accessibilityLabel("Fit image")
            Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
            if tool.isDrawing {
                Toggle(isOn: $panning) { Image(systemName: "hand.raised") }
                    .toggleStyle(.button)
                    .accessibilityLabel("Pan")
            }
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }

    private func setZoom(_ value: CGFloat) {
        let next = min(max(value, 1), 40)
        let ratio = next / zoom
        offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
        baseOffset = offset
        zoom = next
        baseZoom = next
    }

    @ViewBuilder
    private var drawingControls: some View {
        if tool.isDrawing {
            HStack(spacing: 12) {
                Text(instructions).font(.footnote)
                if tool == .polygon || tool == .corners {
                    Button("Undo point") { _ = points.popLast() }.disabled(points.isEmpty)
                }
                if tool == .polygon {
                    Button("Finish") { finishPolygon() }
                    .disabled(points.count < 3)
                    .keyboardShortcut(.defaultAction)
                    .bold()
                }
                Button("Cancel", role: .cancel) { tool = .none }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
        }
    }

    private func finishPolygon() {
        let finished = points
        points = []
        onComplete(finished)
        if !keepDrawing() { tool = .none }
    }

    private var instructions: String {
        switch tool {
        case .rectangle: return panning ? "Panning" : "Drag across the area"
        case .polygon: return panning ? "Panning" : "Tap to add vertices, tap the first one to finish · \(points.count) placed"
        case .corners: return panning ? "Panning" : "Tap the four outer corners of the marker · \(points.count) of 4"
        case .none: return ""
        }
    }
}
