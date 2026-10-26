import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  Stage,
  Layer,
  Image as CanvasImage,
  Line,
  Circle,
  Text,
} from "react-konva";
import type Konva from "konva";
import {
  Hand,
  PenTool,
  Scan,
  Plus,
  Minus,
  Check,
  X,
} from "lucide-react";
import type { Point } from "../types";
import {
  imagePoint,
  cyclicPoints,
  polygonProblem,
  rectanglePoints,
  markerPatches,
} from "../utils";

export type Shape = {
  key: string;
  points: Point[];
  color: string;
  label: string;
  editable?: boolean;
  corners?: boolean;
  guides?: string;
};
type Props = {
  url: string;
  width: number;
  height: number;
  shapes: Shape[];
  target: string | null;
  disabled: boolean;
  resetKey?: number;
  shape?: "rectangle" | "polygon";
  context?: ReactNode;
  canUndo?: boolean;
  canRedo?: boolean;
  onUndo?: () => void;
  onRedo?: () => void;
  onComplete: (points: Point[]) => void;
  onEdit: (key: string, points: Point[]) => void;
  onCancel: () => void;
};

export function ImageEditor({
  url,
  width,
  height,
  shapes,
  target,
  disabled,
  resetKey = 0,
  shape = "polygon",
  context,
  canUndo = false,
  canRedo = false,
  onUndo,
  onRedo,
  onComplete,
  onEdit,
  onCancel,
}: Props) {
  const host = useRef<HTMLDivElement>(null);
  const stage = useRef<Konva.Stage>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const fittedSource = useRef<string | null>(null);
  const sourceKey = `${url.split("?")[0]}:${width}:${height}`;
  const [image, setImage] = useState<HTMLImageElement>();
  const [imageError, setImageError] = useState(false);
  const [scale, setScale] = useState(0.15);
  const [offset, setOffset] = useState<Point>({ x: 0, y: 0 });
  const [drawing, setDrawing] = useState<Point[]>([]);
  const [hover, setHover] = useState<Point | null>(null);
  const [problem, setProblem] = useState("");
  const rectangle = shape === "rectangle";
  const [pan, setPan] = useState(false);
  const [spacePan, setSpacePan] = useState(false);
  const [commandPan, setCommandPan] = useState(false);
  const panning = pan || spacePan || commandPan || !target;
  const [selected, setSelected] = useState<string | null>(null);
  const [live, setLive] = useState<{ key: string; points: Point[] } | null>(null);
  const pointsOf = (shape: Shape) => (live?.key === shape.key ? live.points : shape.points);
  const fit = () => {
    const s = Math.min((size.width - 12) / width, (size.height - 12) / height);
    setScale(s);
    setOffset({
      x: (size.width - width * s) / 2,
      y: (size.height - height * s) / 2,
    });
  };
  useEffect(() => {
    const element = host.current;
    if (!element) return;
    const observer = new ResizeObserver((entries) => {
      const { width, height } = entries[0].contentRect;
      setSize({ width, height });
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    if (
      size.width <= 12 ||
      size.height <= 12 ||
      width <= 0 ||
      height <= 0 ||
      fittedSource.current === sourceKey
    )
      return;
    fit();
    fittedSource.current = sourceKey;
  }, [sourceKey, width, height, size.width, size.height]);
  useEffect(() => {
    let cancelled = false;
    setImageError(false);
    const next = new window.Image();
    next.onload = () => {
      if (!cancelled) setImage(next);
    };
    next.onerror = () => {
      if (!cancelled) setImageError(true);
    };
    next.src = url;
    return () => {
      cancelled = true;
    };
  }, [url]);
  useEffect(() => {
    setProblem("");
  }, [drawing.length]);
  useEffect(() => {
    setDrawing([]);
    setHover(null);
  }, [rectangle]);
  const previousTarget = useRef(target);
  useEffect(() => {
    setDrawing([]);
    setPan(false);
    setSpacePan(false);
    setCommandPan(false);
    setSelected(previousTarget.current === "corners" && !target ? "corners" : null);
    previousTarget.current = target;
  }, [target]);
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (
        event.defaultPrevented || event.isComposing || event.altKey ||
        (event.target instanceof HTMLElement &&
          event.target.closest(
            'input, textarea, select, [contenteditable]:not([contenteditable="false"])',
          )) ||
        document.querySelector('[role="dialog"], dialog[open]')
      ) return;
      const key = event.key.toLowerCase();
      if (event.metaKey) setCommandPan(true);
      if (event.ctrlKey || event.metaKey) {
        if (key !== "z" || disabled || !target) return;
        if (!event.shiftKey && drawing.length) {
          event.preventDefault();
          if (!event.repeat) setDrawing((points) => points.slice(0, -1));
        } else if (!event.shiftKey && canUndo) {
          event.preventDefault();
          if (!event.repeat) onUndo?.();
        } else if (event.shiftKey && !drawing.length && canRedo) {
          event.preventDefault();
          if (!event.repeat) onRedo?.();
        }
        return;
      }
      if (event.shiftKey) return;
      if (event.code === "Space") {
        event.preventDefault();
        setSpacePan(true);
      } else if (!event.repeat && key === "p" && target) {
        event.preventDefault();
        setPan((previous) => !previous);
      } else if (!event.repeat && key === "d" && target && !disabled) {
        event.preventDefault();
        setPan(false);
      }
    };
    const releasePan = () => {
      setSpacePan(false);
      setCommandPan(false);
    };
    const onKeyUp = (event: KeyboardEvent) => {
      if (event.code === "Space") setSpacePan(false);
      if (!event.metaKey) setCommandPan(false);
    };
    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("keyup", onKeyUp);
    window.addEventListener("blur", releasePan);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("keyup", onKeyUp);
      window.removeEventListener("blur", releasePan);
    };
  }, [disabled, drawing.length, target, canUndo, canRedo, onUndo, onRedo]);
  const complete = (points = drawing) => {
    if (points.length < 3) return;
    const issue = polygonProblem(points, target === "corners");
    if (issue) {
      setDrawing(points);
      setProblem(issue);
      return;
    }
    onComplete(points);
    setDrawing([]);
  };
  const addPoint = (point: Point) => {
    if (rectangle) {
      if (!drawing.length) {
        setHover(point);
        return setDrawing([point]);
      }
      const points = rectanglePoints(drawing[0], point);
      const issue = polygonProblem(points, false);
      if (issue) return setProblem(issue);
      onComplete(points);
      setDrawing([]);
      return;
    }
    const first = drawing[0];
    if (
      target !== "corners" &&
      drawing.length >= 3 &&
      Math.hypot(point.x - first.x, point.y - first.y) <= 8 / scale
    )
      return complete();
    const last = drawing[drawing.length - 1];
    if (last && last.x === point.x && last.y === point.y) return;
    const next = [...drawing, point];
    if (next.length > 128) return;
    if (target === "corners" && next.length === 4) complete(next);
    else setDrawing(next);
  };
  const zoom = (
    factor: number,
    anchor = { x: size.width / 2, y: size.height / 2 },
  ) => {
    const next = Math.max(0.01, Math.min(8, scale * factor));
    setOffset({
      x: anchor.x - ((anchor.x - offset.x) * next) / scale,
      y: anchor.y - ((anchor.y - offset.y) * next) / scale,
    });
    setScale(next);
  };
  return (
    <section className="canvas-column" aria-label="Image editor">
      <div className="canvas-toolbar">
        <button
          className={panning ? "selected" : ""}
          onClick={() => setPan(true)}
          aria-pressed={panning}
          aria-keyshortcuts="P Space"
          title="Pan (P); hold Cmd or Space and drag for temporary pan"
        >
          <Hand size={16} />
          Pan
        </button>
        <button
          disabled={!target || disabled}
          className={target && !panning ? "selected" : ""}
          onClick={() => setPan(false)}
          aria-pressed={!!target && !panning}
          aria-keyshortcuts="D"
          title="Draw (D)"
        >
          <PenTool size={16} />
          Draw
        </button>
        <button onClick={fit}>
          <Scan size={16} />
          Fit
        </button>
        {context && <div className="canvas-context">{context}</div>}
        <div className="zoom-controls">
          <button aria-label="Zoom out" onClick={() => zoom(0.8)}>
            <Minus size={16} />
          </button>
          <span>{Math.round(scale * 100)}%</span>
          <button aria-label="Zoom in" onClick={() => zoom(1.25)}>
            <Plus size={16} />
          </button>
        </div>
      </div>
      <div
        ref={host}
        className={`canvas-surface ${target && !panning ? "drawing" : ""}`}
        data-testid="canvas-surface"
        onPointerEnter={(event) => setCommandPan(event.metaKey)}
        onPointerDownCapture={(event) => setCommandPan(event.metaKey)}
      >
      {target && (
        <div className="draw-banner">
          <span>
            {problem ? (
              <strong className="draw-problem" role="alert">{problem}</strong>
            ) : panning
              ? commandPan ? "Release Cmd to return to the previous tool." : spacePan ? "Release Space to return to the previous tool." : "Pan the image, then press D to draw."
              : rectangle
                ? `Click two opposite corners · ${drawing.length} of 2 placed`
                : `${target === "corners" ? "Place 4 corners on the outer edge of the marker" : "Click to add vertices"} · ${drawing.length} placed`}
          </span>
          <div>
            {!rectangle && (
              <button
                disabled={drawing.length < 3 || target === "corners" || disabled}
                onClick={() => complete()}
                data-finish-shortcut={target !== "corners" ? "true" : undefined}
                aria-keyshortcuts={target !== "corners" ? "E Enter" : undefined}
                title={target !== "corners" ? "Finish polygon (E or Enter)" : undefined}
              >
                <Check size={15} />
                Finish
                {target !== "corners" && <kbd aria-hidden="true">E</kbd>}
              </button>
            )}
            <button
              aria-label="Cancel drawing"
              onClick={() => {
                setDrawing([]);
                onCancel();
              }}
            >
              <X size={16} />
            </button>
          </div>
        </div>
      )}
        {imageError && (
          <div role="alert" className="canvas-error">
            Image preview failed to load. Reload the analysis to retry.
          </div>
        )}
        <Stage
          ref={stage}
          width={size.width}
          height={size.height}
          x={offset.x}
          y={offset.y}
          scaleX={scale}
          scaleY={scale}
          draggable={panning}
          onDragStart={(event) => {
            if (event.target !== stage.current || !rectangle) return;
            setDrawing([]);
            setHover(null);
          }}
          onDragEnd={(event) => {
            if (event.target === stage.current)
              setOffset(event.target.position());
          }}
          onMouseMove={() => {
            if (!rectangle || drawing.length !== 1 || panning) return;
            const pointer = stage.current?.getPointerPosition();
            if (pointer) setHover(imagePoint(pointer, offset, scale, width, height));
          }}
          onWheel={(event) => {
            event.evt.preventDefault();
            zoom(
              event.evt.deltaY > 0 ? 0.9 : 1.1,
              stage.current?.getPointerPosition() || undefined,
            );
          }}
          onClick={(event) => {
            if (
              disabled ||
              panning ||
              event.evt.metaKey ||
              !target ||
              event.target.getClassName() === "Circle"
            )
              return;
            const pointer = stage.current?.getPointerPosition();
            if (!pointer) return;
            addPoint(imagePoint(pointer, offset, scale, width, height));
          }}
        >
          <Layer>
            <CanvasImage image={image} width={width} height={height} />
            {shapes.map((shape) => (
              <Line
                key={shape.key}
                points={(shape.corners
                  ? cyclicPoints(pointsOf(shape))
                  : pointsOf(shape)
                ).flatMap((p) => [p.x, p.y])}
                closed
                stroke={shape.color}
                strokeWidth={2 / scale}
                fill={`${shape.color}16`}
                onClick={() => setSelected(shape.key)}
              />
            ))}
            {shapes
              .filter((s) => s.guides)
              .flatMap((s) =>
                markerPatches(s.guides!, pointsOf(s)).map((points, i) => (
                  <Line
                    key={`guide-${s.key}-${i}`}
                    points={points.flatMap((p) => [p.x, p.y])}
                    closed
                    stroke={s.color}
                    strokeWidth={1.5 / scale}
                    dash={[5 / scale, 3 / scale]}
                    listening={false}
                  />
                )),
              )}
            {shapes
              .filter((s) => s.label)
              .map((s) => (
                <Text
                  key={`text-${s.key}`}
                  x={s.points[0]?.x}
                  y={(s.points[0]?.y || 0) - 20 / scale}
                  text={s.label}
                  fill={s.color}
                  fontSize={12 / scale}
                  stroke="#ffffff"
                  strokeWidth={0.2 / scale}
                  listening={false}
                />
              ))}
            {!target &&
              !disabled &&
              shapes
                .filter((s) => s.editable && s.key === selected)
                .flatMap((shape) =>
                  shape.points.map((p, i) => (
                    <Circle
                      key={`${shape.key}-${i}-${resetKey}`}
                      x={p.x}
                      y={p.y}
                      radius={6 / scale}
                      fill="white"
                      stroke={shape.color}
                      strokeWidth={2 / scale}
                      draggable={!pan && !spacePan && !commandPan}
                      onDragMove={(event) => {
                        event.cancelBubble = true;
                        setLive({
                          key: shape.key,
                          points: shape.points.map((v, k) =>
                            k === i ? { x: event.target.x(), y: event.target.y() } : v,
                          ),
                        });
                      }}
                      onDragEnd={(event) => {
                        event.cancelBubble = true;
                        setLive(null);
                        const points = shape.points.map((v, k) =>
                          k === i
                            ? {
                                x: Math.max(
                                  0,
                                  Math.min(width - 1, event.target.x()),
                                ),
                                y: Math.max(
                                  0,
                                  Math.min(height - 1, event.target.y()),
                                ),
                              }
                            : v,
                        );
                        onEdit(shape.key, points);
                      }}
                    />
                  )),
                )}
            <Line
              points={(rectangle && drawing.length === 1 && hover
                ? rectanglePoints(drawing[0], hover)
                : drawing
              ).flatMap((p) => [p.x, p.y])}
              closed={rectangle}
              dash={rectangle ? [6 / scale, 4 / scale] : undefined}
              stroke="#f1b434"
              strokeWidth={2 / scale}
              listening={false}
            />
            {drawing.map((p, i) => (
              <Circle
                key={i}
                x={p.x}
                y={p.y}
                radius={4 / scale}
                fill="#f1b434"
                listening={false}
              />
            ))}
          </Layer>
        </Stage>
      </div>
    </section>
  );
}
