import { useEffect, useRef, useState } from "react";
import {
  FlaskConical,
  Plus,
  Upload,
  Check,
  LoaderCircle,
  Download,
  Trash2,
  ArrowRight,
  RefreshCw,
  X,
  Info,
  Undo2,
  Redo2,
  Menu,
  Settings,
  Keyboard,
  RotateCcw,
} from "lucide-react";
import type {
  Analysis,
  Analyte,
  Comparison,
  Draft,
  Mode,
  Point,
  Summary,
  UreaModel,
  ClassifierModel,
} from "./types";
import {
  request,
  jsonRequest,
  numberText,
  exportFilename,
  readPreference,
  writePreference,
  homeRelative,
  nextRoiId,
  MAX_RESERVOIRS,
  MAX_ROIS,
} from "./utils";
import { ImageEditor, type Shape } from "./components/ImageEditor";
import { ResultsView } from "./components/ResultsView";
import { RangeFlag } from "./components/RangeFlag";
import { LibraryPanel } from "./components/LibraryPanel";
import { DifferencesView, calculatedText } from "./components/DifferencesView";
import { InfoView } from "./components/InfoView";
import { SettingsView } from "./components/SettingsView";
import { ShortcutsView } from "./components/ShortcutsView";
import { ConfirmDialog, type Confirmation } from "./components/ConfirmDialog";
import {
  DownloadLink,
  pickPath,
  revealPath,
  registerCloseHandler,
  quitDesktop,
} from "./native";

const blankDraft = (title: string): Draft => ({
  title,
  mode: "flower_9_manual",
  white_balance: [],
  corners: [],
  manual_patches: [],
  rois: [],
  reservoirs: [1, 2, 3, 4, 5, 6].map((id) => ({
    id,
    analyte: null,
    custom_name: "",
    condition: "",
    replicate: "",
    roi_ids: [],
    review: "needs_review" as const,
    reason: "",
  })),
  age: null,
  sex: null,
  urea_ph_model: null,
  urea_calibration: "lab",
  classifier_model: null,
});
type DrawShape = "rectangle" | "polygon";
const ANALYTE_NAMES: Record<Exclude<Analyte, "custom">, string> = {
  ph: "pH",
  urea: "Urea",
  creatinine: "Creatinine",
};
const SHAPE_NAMES: Record<DrawShape, string> = {
  rectangle: "Rectangle · 2 clicks",
  polygon: "Polygon",
};
const clearsReservoir = (draft: Draft) =>
  draft.mode !== "standard_24_grid" && draft.reservoirs.length <= 1;
const STEPS = [
  "Image",
  "White balance",
  "Calibration",
  "Reservoirs",
  "Results",
];
const CLASSIFIER_NAMES: Record<ClassifierModel, string> = {
  full: "Urea + creatinine + age + sex",
  creatinine: "Creatinine + age + sex",
  urea: "Urea + age + sex",
};
const COLORS = [
  "#0c8c85",
  "#bd691b",
  "#7276cd",
  "#ba4e71",
  "#357fbc",
  "#8b7730",
];

export default function App({
  root,
  home,
  onWorkspace,
}: {
  root: string;
  home: string;
  onWorkspace: () => void;
}) {
  const [folderId, setFolderId] = useState<string | null>(null);
  const [libraryVersion, setLibraryVersion] = useState(0);
  const [doc, setDoc] = useState<Analysis | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [step, setStep] = useState(0);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [target, setTarget] = useState<string | null>(null);
  const [reservoir, setReservoir] = useState(1);
  const [newImage, setNewImage] = useState(false);
  const [debugDefault, setDebugDefault] = useState(() =>
    readPreference("debugRasters", true),
  );
  const [debugRasters, setDebugRasters] = useState(debugDefault);
  const [comparison, setComparison] = useState<Comparison | null>(null);
  const [view, setView] = useState<"analysis" | "differences">("analysis");
  const [panel, setPanel] = useState<"analysis" | "settings" | "info" | "shortcuts">(
    "analysis",
  );
  const [sidebarOpen, setSidebarOpen] = useState(() =>
    readPreference("sidebarOpen", true),
  );
  const [shapeDefault, setShapeDefault] = useState<DrawShape>(() =>
    readPreference("roiShape", "rectangle"),
  );
  const [drawShape, setDrawShape] = useState(shapeDefault);
  const [shapeToast, setShapeToast] = useState(false);
  const [confirmation, setConfirmation] = useState<
    (Confirmation & { resolve: (confirmed: boolean) => void }) | null
  >(null);
  const [resetKey, setResetKey] = useState(0);
  const [, setHistoryVersion] = useState(0);
  const past = useRef<Draft[]>([]);
  const future = useRef<Draft[]>([]);
  const lastEdit = useRef<{ kind: string; at: number } | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const coordinatesInput = useRef<HTMLInputElement>(null);
  const jobActive =
    !!doc?.job && ["queued", "running"].includes(doc.job.status);
  const busy = working || jobActive;
  const readOnly = !!doc?.read_only;
  const locked = busy || readOnly;
  const dirty =
    !!doc && !!draft && JSON.stringify(doc.draft) !== JSON.stringify(draft);
  const hasResults = !!doc?.results;

  useEffect(() => {
    if (!doc || !hasResults || jobActive) {
      setComparison(null);
      return;
    }
    let cancelled = false;
    request<Comparison>(`/analyses/${doc.id}/comparison`)
      .then((next) => {
        if (!cancelled) setComparison(next);
      })
      .catch(() => {
        if (!cancelled) setComparison(null);
      });
    return () => {
      cancelled = true;
    };
  }, [doc?.id, doc?.revision, hasResults, jobActive]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (
        event.defaultPrevented ||
        event.repeat ||
        event.isComposing ||
        event.ctrlKey ||
        event.metaKey ||
        event.altKey ||
        event.shiftKey ||
        (event.target instanceof HTMLElement &&
          event.target.closest(
            'input, textarea, select, [contenteditable]:not([contenteditable="false"])',
          )) ||
        document.querySelector('[role="dialog"], dialog[open], [role="menu"]')
      )
        return;
      const key = event.key.toLowerCase();
      if (
        key === "enter" &&
        event.target instanceof HTMLElement &&
        event.target.closest('button, a, [role="menuitem"]')
      )
        return;
      if (key === "n") {
        if (step !== 3 || !draft?.reservoirs.length) return;
        event.preventDefault();
        const ids = draft.reservoirs.map((r) => r.id);
        setReservoir(ids[(ids.indexOf(reservoir) + 1) % ids.length]);
        return;
      }
      if (key === "t") {
        if (!document.querySelector(".shape-toggle")) return;
        event.preventDefault();
        chooseShape(drawShape === "rectangle" ? "polygon" : "rectangle");
        return;
      }
      const selector =
        key === "d" && !target
          ? "[data-draw-shortcut]"
          : key === "e" || (key === "enter" && target)
            ? "[data-finish-shortcut]"
            : key === "enter"
              ? "[data-enter-shortcut]"
              : null;
      if (!selector) return;
      const button = document.querySelector<HTMLButtonElement>(selector);
      if (!button || button.matches(":disabled")) return;
      event.preventDefault();
      button.click();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [target, drawShape, shapeDefault, step, draft?.reservoirs, reservoir]);

  useEffect(() => {
    window.dispatchEvent(
      new CustomEvent("ckd-unsaved", { detail: dirty || busy }),
    );
    return () => {
      window.dispatchEvent(new CustomEvent("ckd-unsaved", { detail: false }));
    };
  }, [dirty, busy]);

  useEffect(() => {
    if (!dirty) return;
    const warn = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [dirty]);

  const ask = (request: Confirmation) =>
    new Promise<boolean>((resolve) => setConfirmation({ ...request, resolve }));
  const install = (next: Analysis) => {
    setDoc(next);
    setDraft(next.draft);
  };
  const resetHistory = () => {
    past.current = [];
    future.current = [];
    lastEdit.current = null;
    setHistoryVersion((v) => v + 1);
  };
  const remember = (previous: Draft | null, kind?: string) => {
    if (!previous) return;
    const now = Date.now();
    if (kind && lastEdit.current?.kind === kind && now - lastEdit.current.at < 1500) {
      lastEdit.current.at = now;
      return;
    }
    lastEdit.current = kind ? { kind, at: now } : null;
    past.current = [...past.current.slice(-49), previous];
    future.current = [];
    setHistoryVersion((v) => v + 1);
  };
  const update = (next: Draft, kind?: string) => {
    if (readOnly) return;
    remember(draft, kind);
    setDraft(next);
    setError("");
    setNotice("");
  };
  const saveDraft = async (next = draft) => {
    if (!doc || !next) return null;
    if (readOnly) return doc;
    if (JSON.stringify(next) === JSON.stringify(doc.draft)) return doc;
    const saved = await request<Analysis>(
      `/analyses/${doc.id}`,
      jsonRequest("PUT", { revision: doc.revision, draft: next }),
    );
    install(saved);
    return saved;
  };
  const save = async (next = draft) => {
    setWorking(true);
    setError("");
    try {
      await saveDraft(next);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setWorking(false);
    }
  };
  const commit = (next: Draft) => {
    update(next);
    void save(next);
  };
  const travel = (from: typeof past, to: typeof past) => {
    if (!draft || !from.current.length || busy || readOnly) return;
    const next = from.current[from.current.length - 1];
    from.current = from.current.slice(0, -1);
    to.current = [...to.current, draft];
    lastEdit.current = null;
    setHistoryVersion((v) => v + 1);
    const drawingMore =
      (target === "manual" && next.manual_patches.length < 9) ||
      (target === "roi" && next.rois.length < MAX_ROIS);
    if (!drawingMore) setTarget(null);
    setDraft(next);
    void save(next);
  };
  const undo = () => travel(past, future);
  const redo = () => travel(future, past);
  const discard = async () => {
    if (!doc) return;
    setWorking(true);
    setError("");
    try {
      install(await request<Analysis>(`/analyses/${doc.id}`));
      resetHistory();
      setTarget(null);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setWorking(false);
    }
  };
  const settleDraft = async () => {
    try {
      await saveDraft();
      return true;
    } catch (e) {
      const message = (e as Error).message;
      const confirmed = await ask({
        title: "Your changes could not be saved",
        message: `${message} Discard the unsaved changes and continue?`,
        confirm: "Discard changes",
        cancel: "Keep editing",
        danger: true,
      });
      if (!confirmed) {
        setError(message);
        return false;
      }
      if (doc) setDraft(doc.draft);
      resetHistory();
      return true;
    }
  };
  const load = async (id: string) => {
    setWorking(true);
    setError("");
    try {
      if (dirty && !(await settleDraft())) return;
      const next = await request<Analysis>(`/analyses/${id}`);
      install(next);
      resetHistory();
      location.hash = id;
      setNewImage(false);
      setTarget(null);
      setView("analysis");
      setPanel("analysis");
      setStep(
        next.results
          ? 4
          : next.calibration
            ? 3
            : next.white_balance
              ? 2
              : next.render
                ? 1
                : 0,
      );
    } catch (e) {
      if ((e as Error & { status?: number }).status === 404 && doc?.id === id) {
        setDoc(null);
        setDraft(null);
        location.hash = "";
      }
      setError((e as Error).message);
    } finally {
      setWorking(false);
    }
  };
  useEffect(() => {
    const id = location.hash.slice(1);
    if (id) void load(id);
  }, []);
  useEffect(() => {
    if (!dirty || busy || error || readOnly) return;
    const timer = window.setTimeout(() => void save(), 900);
    return () => window.clearTimeout(timer);
  }, [draft, doc?.revision, busy, error, readOnly]);
  useEffect(() => {
    if (!doc || !jobActive) return;
    let cancelled = false;
    const timer = window.setInterval(async () => {
      try {
        const next = await request<Analysis>(`/analyses/${doc.id}`);
        if (cancelled) return;
        install(next);
        setError((previous) =>
          previous.startsWith("Connection interrupted.") ? "" : previous,
        );
        if (next.job?.status === "failed")
          setError(next.job.error || "Calculation failed.");
        if (next.job?.status === "completed") {
          setNotice(
            `${next.job.action.replaceAll("_", " ")} completed in ${next.job.seconds?.toFixed(1) || "?"} s.`,
          );
          if (next.job.action === "render") setStep(1);
          if (next.job.action === "white_balance") setStep(2);
          if (next.job.action === "calibrate") setStep(3);
          if (["analyze", "recompute"].includes(next.job.action)) {
            setStep(4);
            setView("analysis");
          }
        }
      } catch (e) {
        if (!cancelled)
          setError(
            `Connection interrupted. Reconnecting: ${(e as Error).message}`,
          );
      }
    }, 1000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [doc?.id, jobActive]);

  const action = async (name: string, next = draft) => {
    if (!doc || readOnly) return;
    setWorking(true);
    setError("");
    setNotice("");
    setTarget(null);
    try {
      const saved = await saveDraft(next);
      if (!saved) return;
      const result = await request<Analysis>(
        `/analyses/${doc.id}/jobs`,
        jsonRequest("POST", { revision: saved.revision, action: name }),
      );
      install(result);
      if (result.job?.status === "failed")
        setError(result.job.error || "Calculation failed.");
      if (result.job?.status === "completed") {
        setStep(
          name === "white_balance"
            ? 2
            : name === "calibrate"
              ? 3
              : ["analyze", "recompute"].includes(name)
                ? 4
                : step,
        );
        if (name === "recompute") setView("analysis");
      }
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setWorking(false);
    }
  };
  const upload = async (file: File | undefined) => {
    if (!file) return;
    setWorking(true);
    setError("");
    setNotice("");
    try {
      if (dirty && !(await settleDraft())) return;
      const form = new FormData();
      form.append("file", file);
      const created = await request<Analysis>(
        `/analyses${folderId ? `?folder_id=${encodeURIComponent(folderId)}` : ""}`,
        {
          method: "POST",
          body: form,
        },
      );
      install(created);
      resetHistory();
      location.hash = created.id;
      setNewImage(false);
      setStep(0);
      setTarget(null);
      const queued = await request<Analysis>(
        `/analyses/${created.id}/jobs`,
        jsonRequest("POST", { revision: created.revision, action: "render" }),
      );
      install(queued);
      if (queued.job?.status === "failed")
        setError(queued.job.error || "RAW rendering failed.");
      else if (queued.job?.status === "completed") setStep(1);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setWorking(false);
      if (fileInput.current) fileInput.current.value = "";
    }
  };
  const importPackage = async (file: File | undefined) => {
    if (!file || !doc || readOnly) return;
    setWorking(true);
    setError("");
    setTarget(null);
    try {
      if (file.size > 2_000_000)
        throw new Error("Coordinate package must be under 2 MB.");
      const geometry =
        draft &&
        (draft.white_balance.length ||
          draft.corners.length ||
          draft.manual_patches.length ||
          draft.rois.length);
      if (
        geometry &&
        !(await ask({
          title: "Replace the current geometry?",
          message:
            "Importing replaces the white-balance area, marker, calibration patches and ROIs, and resets reviews. You can undo it afterwards.",
          confirm: "Import coordinates",
        }))
      )
        return;
      const saved = await saveDraft();
      if (!saved) return;
      remember(saved.draft);
      const result = await request<Analysis>(
        `/analyses/${doc.id}/coordinates`,
        jsonRequest("POST", {
          revision: saved.revision,
          package: JSON.parse(await file.text()),
        }),
      );
      install(result);
      setStep(1);
      setNotice(
        "Coordinates imported. Apply white balance, then calibrate and analyze.",
      );
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setWorking(false);
      if (coordinatesInput.current) coordinatesInput.current.value = "";
    }
  };
  const complete = (points: Point[]) => {
    if (!draft) return;
    if (target === "white_balance") update({ ...draft, white_balance: points });
    else if (target === "corners") update({ ...draft, corners: points });
    else if (target === "manual")
      update({ ...draft, manual_patches: [...draft.manual_patches, points] });
    else if (target === "roi") {
      const id = nextRoiId(draft.rois);
      update({
        ...draft,
        rois: [...draft.rois, { id, label: `ROI ${id}`, points }],
        reservoirs: draft.reservoirs.map((r) =>
          r.id === reservoir
            ? { ...r, roi_ids: [...r.roi_ids, id] }
            : r,
        ),
      });
    }
    const more =
      target === "manual"
        ? draft.manual_patches.length + 1 < 9
        : target === "roi" && draft.rois.length + 1 < MAX_ROIS;
    if (!more) setTarget(null);
  };
  const redrawMarker = async () => {
    if (!draft || !doc) return;
    if (draft.corners.length) {
      if (
        (doc.calibration || doc.results || draft.rois.length) &&
        !(await ask({
          title: "Redraw the marker boundary?",
          message:
            "This deletes the current marker boundary and all ROIs, and clears the calibration and results. Reservoirs keep their analytes and notes. You can undo it afterwards.",
          confirm: "Redraw",
          danger: true,
        }))
      )
        return;
      update({
        ...draft,
        corners: [],
        rois: [],
        reservoirs: draft.reservoirs.map((r) => ({ ...r, roi_ids: [] })),
      });
    }
    setTarget("corners");
  };
  const redrawWhiteBalance = async () => {
    if (!draft || !doc) return;
    if (draft.white_balance.length) {
      const later =
        draft.corners.length ||
        draft.manual_patches.length ||
        draft.rois.length ||
        doc.calibration ||
        doc.results;
      if (
        later &&
        !(await ask({
          title: "Redraw the white-balance area?",
          message:
            "This deletes the current white-balance area, the marker corners, the calibration patches and all ROIs, and clears white balance, calibration and results. Reservoirs keep their analytes and labels. You can undo it afterwards.",
          confirm: "Redraw",
          danger: true,
        }))
      )
        return;
      update({
        ...draft,
        white_balance: [],
        corners: [],
        manual_patches: [],
        rois: [],
        reservoirs: draft.reservoirs.map((r) => ({ ...r, roi_ids: [] })),
      });
    }
    setTarget("white_balance");
  };
  const ureaControls = (save: (next: Draft) => void) => {
    if (!draft || !draft.reservoirs.some((r) => r.analyte === "urea")) return null;
    const nearest = doc?.results?.urea_ph_model?.nearest;
    return (
      <>
      <label>
        Urea pH model
        <select
          value={draft.urea_ph_model || ""}
          onChange={(e) =>
            save({ ...draft, urea_ph_model: (e.target.value || null) as UreaModel | null })
          }
        >
          <option value="">
            {nearest
              ? `Automatic (nearest to measured pH: ${nearest.slice(3)})`
              : "Automatic (nearest to measured pH)"}
          </option>
          <option value="pH_6.0">pH 6.0</option>
          <option value="pH_6.5">pH 6.5</option>
          <option value="pH_7.0">pH 7.0</option>
        </select>
      </label>
      <label>
        Urea calibration
        <select
          value={draft.urea_calibration || "lab"}
          onChange={(e) => save({ ...draft, urea_calibration: e.target.value as "lab" | "ab" })}
        >
          <option value="lab">L*a*b* (default)</option>
          <option value="ab">a*b* only</option>
        </select>
      </label>
      </>
    );
  };
  function chooseShape(value: DrawShape) {
    if (value === drawShape) return;
    setDrawShape(value);
    setShapeToast(value !== shapeDefault);
  }
  const shapeToggle = (
    <div className="shape-toggle" role="group" aria-label="Drawing shape">
      {(["rectangle", "polygon"] as const).map((value) => (
        <button
          key={value}
          aria-pressed={drawShape === value}
          className={drawShape === value ? "selected" : ""}
          aria-keyshortcuts="T"
          title="Toggle rectangle and polygon (T)"
          onClick={() => chooseShape(value)}
        >
          {SHAPE_NAMES[value]}
        </button>
      ))}
    </div>
  );
  const activeReservoir = draft?.reservoirs.find((r) => r.id === reservoir);
  const addRoi = draft && (
    <>
      <button
        className="primary full add-roi"
        disabled={draft.rois.length >= MAX_ROIS}
        onClick={() => setTarget("roi")}
        data-draw-shortcut="true"
        aria-keyshortcuts="D"
        title="Add ROI (D)"
      >
        <Plus size={20} />
        Add ROI
      </button>
      {shapeToggle}
    </>
  );
  const hasAnalytes =
    draft?.mode !== "standard_24_grid" ||
    !!draft?.reservoirs.some((r) => r.analyte && r.roi_ids.length);
  useEffect(() => {
    if (draft?.reservoirs.length && !activeReservoir)
      setReservoir(draft.reservoirs[0].id);
  }, [draft?.reservoirs, activeReservoir]);
  const addReservoir = () => {
    if (!draft) return;
    const id = nextRoiId(draft.reservoirs);
    update({
      ...draft,
      reservoirs: [
        ...draft.reservoirs,
        { id, analyte: null, roi_ids: [], review: "needs_review" as const, reason: "" },
      ].sort((a, b) => a.id - b.id),
    });
    setReservoir(id);
  };
  const resetAnalysis = async () => {
    if (!draft || !doc) return;
    if (
      !(await ask({
        title: "Reset this analysis?",
        message:
          "This deletes the white-balance area, marker corners, calibration patches, all ROIs, reservoirs and labels, age, sex and model choices, and clears white balance, calibration and results. The original image and the analysis name are kept. Use Undo right away if you change your mind.",
        confirm: "Reset analysis",
        danger: true,
      }))
    )
      return;
    setTarget(null);
    setStep(1);
    commit(blankDraft(draft.title));
  };
  const removeReservoir = async () => {
    if (!draft || !doc) return;
    const target = draft.reservoirs.find((r) => r.id === reservoir);
    if (!target) return;
    const keep = clearsReservoir(draft);
    const count = target.roi_ids.length;
    const verb = keep ? "Clear" : "Remove";
    if (
      (target.analyte || count) &&
      !(await ask({
        title: `${verb} reservoir ${target.id}?`,
        message: `${count ? `Its ${count === 1 ? "ROI is" : `${count} ROIs are`} deleted and its` : "Its"} analyte is unassigned${doc.results ? ". Results are cleared until you analyze again" : ""}. You can undo it afterwards.`,
        confirm: `${verb} reservoir`,
        danger: true,
      }))
    )
      return;
    const rois = draft.rois.filter((r) => !target.roi_ids.includes(r.id));
    const reservoirs = keep
      ? draft.reservoirs.map((r) =>
          r.id === target.id
            ? { id: r.id, analyte: null, roi_ids: [], review: "needs_review" as const, reason: "" }
            : r,
        )
      : draft.reservoirs.filter((r) => r.id !== target.id);
    update({ ...draft, rois, reservoirs });
    if (!keep) setReservoir(reservoirs[0]?.id ?? 1);
  };
  const updateReservoir = (
    changes: Partial<Draft["reservoirs"][number]>,
    kind: string,
  ) => {
    if (!draft) return;
    update(
      {
        ...draft,
        reservoirs: draft.reservoirs.map((r) =>
          r.id === reservoir ? { ...r, ...changes } : r,
        ),
      },
      `${kind}:${reservoir}`,
    );
  };
  const assignAnalyte = (analyte: Analyte | null) => {
    if (!draft) return;
    update({
      ...draft,
      reservoirs: draft.reservoirs.map((r) => (r.id === reservoir ? { ...r, analyte } : r)),
    });
  };
  const editShape = async (key: string, points: Point[]) => {
    if (!draft || !doc) return;
    const cleared =
      key === "white_balance" && doc.white_balance
        ? "white balance, calibration and results"
        : (key === "corners" || key.startsWith("manual:")) && doc.calibration
          ? "calibration and results"
          : null;
    if (
      cleared &&
      !(await ask({
        title: "Move this point?",
        message: `Moving it clears the ${cleared}. You can undo it afterwards.`,
        confirm: "Move point",
      }))
    ) {
      setResetKey((v) => v + 1);
      return;
    }
    if (key === "white_balance") update({ ...draft, white_balance: points });
    else if (key === "corners") update({ ...draft, corners: points });
    else if (key.startsWith("manual:"))
      update({
        ...draft,
        manual_patches: draft.manual_patches.map((p, i) =>
          i === Number(key.split(":")[1]) ? points : p,
        ),
      });
    else
      update({
        ...draft,
        rois: draft.rois.map((r) =>
          r.id === Number(key.split(":")[1]) ? { ...r, points } : r,
        ),
      });
  };
  const shapes: Shape[] = [];
  if (draft) {
    if (draft.white_balance.length)
      shapes.push({
        key: "white_balance",
        points: draft.white_balance,
        color: "#399ad0",
        label: "WB",
        editable: !readOnly && step === 1,
      });
    if (draft.corners.length)
      shapes.push({
        key: "corners",
        points: draft.corners,
        color: "#dcb339",
        label: "Marker",
        editable: !readOnly && step === 2,
        corners: true,
        guides:
          step === 2 && draft.mode !== "flower_9_manual" && (dirty || !doc?.calibration)
            ? draft.mode
            : undefined,
      });
    draft.manual_patches.forEach((points, i) =>
      shapes.push({
        key: `manual:${i}`,
        points,
        color: "#dcb339",
        label: `Patch ${i + 1}`,
        editable: !readOnly && step === 2,
      }),
    );
    if (!dirty)
      doc?.calibration?.patches.forEach((points, i) =>
        shapes.push({ key: `patch:${i}`, points, color: "#dcb339", label: "" }),
      );
    draft.rois.forEach((r) => {
      const owner = draft.reservoirs.find((v) => v.roi_ids.includes(r.id));
      shapes.push({
        key: `roi:${r.id}`,
        points: r.points,
        color: COLORS[((owner?.id || 1) - 1) % COLORS.length],
        label: r.label,
        editable: !readOnly && step === 3,
      });
    });
  }
  const chooseStep = (index: number) => {
    setStep(index);
    setTarget(null);
  };
  useEffect(() => registerCloseHandler(async () => {
    if (jobActive && !(await ask({
      title: "A calculation is still running",
      message: "Quit anyway? CKD quits when the current step finishes, usually within seconds. Queued calculations are cancelled and can be retried later.",
      confirm: "Quit anyway",
      cancel: "Keep working",
    }))) return;
    if (await settleDraft()) await quitDesktop();
  }), [jobActive, doc, draft]);
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (
        event.defaultPrevented ||
        !(event.metaKey || event.ctrlKey) ||
        event.key.toLowerCase() !== "z" ||
        target ||
        (event.target instanceof HTMLElement &&
          event.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])')) ||
        document.querySelector('[role="dialog"], dialog[open], [role="menu"]')
      )
        return;
      event.preventDefault();
      if (event.shiftKey) redo();
      else undo();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  });
  const toggleSidebar = () =>
    setSidebarOpen((open) => {
      writePreference("sidebarOpen", !open);
      return !open;
    });
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (
        event.defaultPrevented ||
        !(event.metaKey || event.ctrlKey) ||
        event.key !== "\\" ||
        document.querySelector('[role="dialog"], dialog[open], [role="menu"]')
      )
        return;
      event.preventDefault();
      toggleSidebar();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);
  const togglePanel = (next: "settings" | "info" | "shortcuts") =>
    setPanel((current) => (current === next ? "analysis" : next));
  const chooseShapeDefault = (value: DrawShape) => {
    writePreference("roiShape", value);
    setShapeDefault(value);
    setDrawShape(value);
    setShapeToast(false);
  };
  useEffect(() => {
    setDrawShape(shapeDefault);
    setShapeToast(false);
  }, [doc?.id]);
  useEffect(() => {
    if (!shapeToast) return;
    const timer = window.setTimeout(() => setShapeToast(false), 8000);
    return () => window.clearTimeout(timer);
  }, [shapeToast, drawShape]);
  const chooseDebugDefault = (value: boolean) => {
    writePreference("debugRasters", value);
    setDebugDefault(value);
    setDebugRasters(value);
  };
  const revealWorkspace = () =>
    void revealPath(root).catch((e) => setError(String(e)));
  const importExport = async () => {
    setWorking(true);
    setError("");
    setNotice("");
    try {
      if (!(await settleDraft())) return;
      const path = await pickPath("import");
      if (!path) return;
      const result = await request<{ path: string }>(
        "/import",
        jsonRequest("POST", { path }),
      );
      setLibraryVersion((v) => v + 1);
      setNotice(`Imported ${result.path}. The original image was preserved.`);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setWorking(false);
    }
  };
  const raster = doc?.white_balance || doc?.render;

  return (
    <div className="app-shell">
      <header className="app-header">
        <button
          className="icon-button sidebar-toggle"
          aria-label="Toggle sidebar"
          aria-expanded={sidebarOpen}
          aria-controls="library-sidebar"
          title="Show or hide the sidebar (Cmd+\)"
          onClick={toggleSidebar}
        >
          <Menu size={20} />
        </button>
        <span className="brand">
          <FlaskConical size={24} />
          <span>CKD Colorimetry</span>
        </span>
        <div className="analysis-status" aria-label="Current analysis">
          <div className="analysis-status-text">
            <strong className="header-title" title={draft?.title}>
              {draft?.title || "No analysis open"}
            </strong>
            <span role="status" className={dirty && !busy ? "unsaved" : ""}>
              {busy
                ? "Saving / processing"
                : dirty
                  ? "Unsaved changes"
                  : doc
                    ? "Saved"
                    : "Ready"}
            </span>
          </div>
          <button
            className="icon-button"
            aria-label="Undo"
            title="Undo (Cmd+Z)"
            disabled={!past.current.length || busy || readOnly}
            onClick={undo}
          >
            <Undo2 size={16} />
          </button>
          <button
            className="icon-button"
            aria-label="Redo"
            title="Redo (Cmd+Shift+Z)"
            disabled={!future.current.length || busy || readOnly}
            onClick={redo}
          >
            <Redo2 size={16} />
          </button>
          <button
            className="icon-button"
            aria-label="Reset analysis"
            title="Reset analysis: start this image over"
            disabled={
              !doc ||
              !draft ||
              busy ||
              readOnly ||
              (!doc.white_balance &&
                !doc.calibration &&
                !doc.results &&
                JSON.stringify(draft) === JSON.stringify(blankDraft(draft.title)))
            }
            onClick={() => void resetAnalysis()}
          >
            <RotateCcw size={16} />
          </button>
          {dirty && !busy && (
            <>
              <button className="compact" onClick={() => void save()}>
                Save changes
              </button>
              <button className="compact" onClick={() => void discard()}>
                Discard
              </button>
            </>
          )}
        </div>
        <button
          disabled={busy}
          onClick={async () => {
            if (await settleDraft()) onWorkspace();
          }}
        >
          Open workspace
        </button>
        <button
          className="primary"
          disabled={busy}
          onClick={() => {
            setPanel("analysis");
            setNewImage(true);
          }}
        >
          <Plus size={17} />
          New analysis
        </button>
      </header>
      <div className="app-body">
        <aside
          id="library-sidebar"
          className="library-sidebar"
          hidden={!sidebarOpen}
        >
          <section className="sidebar-folders" aria-label="Folders">
            <LibraryPanel
              root={root}
              current={doc}
              refreshKey={libraryVersion + (doc?.revision || 0)}
              disabled={busy}
              ask={ask}
              onImport={() => void importExport()}
              onBusyChange={setWorking}
              beforeChange={async () => {
                if (!(await settleDraft()))
                  throw new Error("Save or discard your changes first.");
              }}
              onOpen={(id) => void load(id)}
              onSelect={setFolderId}
              onChanged={async (oldPath, newPath) => {
                setLibraryVersion((v) => v + 1);
                if (
                  oldPath &&
                  doc &&
                  (doc.project_path === oldPath ||
                    doc.project_path.startsWith(`${oldPath}/`))
                ) {
                  if (newPath) {
                    const items = await request<Summary[]>("/analyses");
                    const path =
                      newPath + doc.project_path.slice(oldPath.length);
                    const next = items.find(
                      (item) => item.project_path === path,
                    );
                    if (next) {
                      install(await request<Analysis>(`/analyses/${next.id}`));
                      location.hash = next.id;
                      return;
                    }
                  }
                  setDoc(null);
                  setDraft(null);
                  setTarget(null);
                  location.hash = "";
                }
              }}
            />
          </section>
          <nav className="sidebar-bottom" aria-label="App">
            <button
              className={`sidebar-link ${panel === "settings" ? "selected" : ""}`}
              aria-pressed={panel === "settings"}
              onClick={() => togglePanel("settings")}
            >
              <Settings size={15} />
              Settings
            </button>
            <button
              className={`sidebar-link ${panel === "info" ? "selected" : ""}`}
              aria-pressed={panel === "info"}
              onClick={() => togglePanel("info")}
            >
              <Info size={15} />
              Equations and versions
            </button>
            <button
              className={`sidebar-link ${panel === "shortcuts" ? "selected" : ""}`}
              aria-pressed={panel === "shortcuts"}
              onClick={() => togglePanel("shortcuts")}
            >
              <Keyboard size={15} />
              Shortcuts
            </button>
          </nav>
        </aside>
        <main className="workspace">
          <div className="workflow-steps">
            {" "}
            <nav aria-label="Analysis steps">
              {STEPS.map((name, i) => {
                const done = [
                  doc?.render,
                  doc?.white_balance,
                  doc?.calibration,
                  doc?.results,
                  doc?.results &&
                    !doc.results.reservoirs.some(
                      (r) => r.review_status === "needs_review",
                    ),
                ][i];
                return (
                  <button
                    key={name}
                    aria-current={step === i ? "step" : undefined}
                    disabled={!doc || (i > 0 && !doc.render)}
                    onClick={() => chooseStep(i)}
                  >
                    <span className={`step-number ${done ? "complete" : ""}`}>
                      {done ? <Check size={15} /> : i + 1}
                    </span>
                    <span>{name}</span>
                  </button>
                );
              })}
            </nav>
          </div>
          {readOnly && (
            <div className="notice">
              This folder is read only. Copy it to a writable location to edit.
            </div>
          )}
          {(comparison?.outdated || comparison?.calculated_on === "ios") && view === "analysis" && !newImage && (
            <div className="notice version-notice" role="status">
              <span>
                {calculatedText(comparison)}.
                {comparison.affects_values &&
                  " Reviews are locked until you recompute with this version."}
              </span>
              <button onClick={() => setView("differences")}>Differences</button>
            </div>
          )}
          {jobActive && (
            <div className="notice processing" role="status">
              <LoaderCircle className="spin" size={15} />
              <span>
                {doc?.job?.action.replaceAll("_", " ")} · {doc?.job?.status}.
                Processing on this Mac.
              </span>
            </div>
          )}
          {error && (
            <div className="alert" role="alert">
              <span>{error}</span>
              <div>
                {doc && !busy && (
                  <button onClick={() => void discard()}>
                    <RefreshCw size={14} />
                    {dirty ? "Discard changes" : "Reload"}
                  </button>
                )}
                <button aria-label="Dismiss error" onClick={() => setError("")}>
                  <X size={16} />
                </button>
              </div>
            </div>
          )}
          {notice && (
            <div className="notice" role="status">
              {notice}
            </div>
          )}
          {shapeToast && (
            <div className="toast" role="status">
              <span>
                {SHAPE_NAMES[drawShape]} for this analysis only. New analyses
                use {SHAPE_NAMES[shapeDefault]}; change the default in Settings.
              </span>
              <button
                onClick={() => {
                  setShapeToast(false);
                  setPanel("settings");
                }}
              >
                Open Settings
              </button>
              <button
                className="icon-button"
                aria-label="Dismiss"
                onClick={() => setShapeToast(false)}
              >
                <X size={14} />
              </button>
            </div>
          )}
          {panel === "info" && (
            <div className="results-column">
              <InfoView onBack={() => setPanel("analysis")} />
            </div>
          )}
          {panel === "shortcuts" && (
            <div className="results-column">
              <ShortcutsView onBack={() => setPanel("analysis")} />
            </div>
          )}
          {panel === "settings" && (
            <div className="results-column">
              <SettingsView
                root={root}
                rootLabel={homeRelative(root, home)}
                disabled={busy}
                debugDefault={debugDefault}
                onDebugDefault={chooseDebugDefault}
                shapeDefault={shapeDefault}
                onShapeDefault={chooseShapeDefault}
                onSwitchWorkspace={async () => {
                  if (await settleDraft()) onWorkspace();
                }}
                onReveal={revealWorkspace}
                onImport={() => void importExport()}
                onBack={() => setPanel("analysis")}
              />
            </div>
          )}
          {panel === "analysis" && (!doc || newImage) && (
            <section className="upload-view">
              <div className="upload-symbol">
                <FlaskConical size={40} />
              </div>
              <span className="eyebrow">COLORIMETRIC ANALYSIS</span>
              <h1>Start with the original image.</h1>
              <p>
                Import a DNG or CR2 to measure your color patches,
                <br />
                review reservoir results, and export the analysis.
              </p>
              <button
                className="primary large"
                disabled={busy}
                onClick={() => fileInput.current?.click()}
              >
                <Upload size={18} />
                Choose RAW image
              </button>
              <small>Original DNG / CR2 · Up to 100 MB · Up to 50 MP</small>
              {newImage && doc && (
                <button
                  className="text-button"
                  onClick={() => setNewImage(false)}
                >
                  Return to current analysis
                </button>
              )}
              <div className="workflow-preview">
                <span>01 White balance</span>
                <ArrowRight size={14} />
                <span>02 Calibrate</span>
                <ArrowRight size={14} />
                <span>03 Review</span>
              </div>
            </section>
          )}
          {panel === "analysis" && doc && !newImage && draft && (
            <>
              {view === "differences" && comparison ? (
                <div className="results-column">
                  <DifferencesView
                    comparison={comparison}
                    disabled={locked}
                    onBack={() => setView("analysis")}
                    onRecompute={() => void action("recompute")}
                  />
                </div>
              ) : !doc.render ? (
                <section className="upload-view">
                  <LoaderCircle className={jobActive ? "spin" : ""} size={40} />
                  <h1>
                    {jobActive
                      ? "Rendering the original RAW"
                      : "Image not yet rendered"}
                  </h1>
                  <p>{doc.source.filename}</p>
                  {!locked && (
                    <button
                      className="primary"
                      onClick={() => void action("render")}
                    >
                      Retry rendering
                    </button>
                  )}
                </section>
              ) : (
                <div
                  className={`editor-layout ${step === 4 ? "results-layout" : ""}`}
                >
                  {step === 4 ? (
                    <div className="results-column">
                      {doc.results ? (
                        <ResultsView
                          results={doc.results}
                          draft={draft}
                          disabled={locked || !!comparison?.affects_values}
                          onReview={(id, review, reason) =>
                            commit({
                              ...draft,
                              reservoirs: draft.reservoirs.map((r) =>
                                r.id === id ? { ...r, review, reason } : r,
                              ),
                            })
                          }
                        />
                      ) : (
                        <div className="empty-results">
                          <FlaskConical size={34} />
                          <h2>Ready to calculate?</h2>
                          <p>
                            {!doc.calibration
                              ? "Calibrate the marker first."
                              : !draft.rois.length
                                ? "Add ROIs first."
                                : "Analyze the ROIs to calculate results."}
                          </p>
                          <button
                            className="primary"
                            disabled={
                              locked || !doc.calibration || !draft.rois.length
                            }
                            onClick={() => void action("analyze")}
                          >
                            Analyze ROIs
                          </button>
                        </div>
                      )}
                    </div>
                  ) : (
                    <ImageEditor
                      url={`/api/analyses/${doc.id}/preview?image=${raster?.preview}`}
                      width={doc.source.width!}
                      height={doc.source.height!}
                      shapes={shapes}
                      target={readOnly ? null : target}
                      disabled={locked}
                      resetKey={resetKey}
                      shape={drawShape}
                      context={
                        step === 3 && activeReservoir ? (
                          <>
                            <i
                              style={{
                                background:
                                  COLORS[(activeReservoir.id - 1) % COLORS.length],
                              }}
                            />
                            Reservoir {activeReservoir.id}
                            {activeReservoir.analyte && (
                              <em>
                                {activeReservoir.analyte === "custom"
                                  ? activeReservoir.custom_name || "Custom"
                                  : ANALYTE_NAMES[activeReservoir.analyte]}
                              </em>
                            )}
                            <small>
                              {activeReservoir.roi_ids.length}{" "}
                              {activeReservoir.roi_ids.length === 1 ? "ROI" : "ROIs"}
                            </small>
                          </>
                        ) : undefined
                      }
                      canUndo={!!past.current.length && !busy}
                      canRedo={!!future.current.length && !busy}
                      onUndo={undo}
                      onRedo={redo}
                      onComplete={complete}
                      onEdit={editShape}
                      onCancel={() => setTarget(null)}
                    />
                  )}
                  <aside className="inspector">
                    <span className="eyebrow">
                      STEP {String(step + 1).padStart(2, "0")}
                    </span>
                    <h1>{STEPS[step]}</h1>
                    <fieldset disabled={locked}>
                      {step === 0 && (
                        <>
                          <label>
                            Analysis name
                            <input
                              value={draft.title}
                              maxLength={120}
                              onChange={(e) =>
                                update({ ...draft, title: e.target.value }, "title")
                              }
                            />
                          </label>
                          <dl>
                            <dt>Original file</dt>
                            <dd>{doc.source.filename}</dd>
                            <dt>Dimensions</dt>
                            <dd>
                              {doc.source.width} × {doc.source.height} px
                            </dd>
                            <dt>Processing</dt>
                            <dd>Full resolution · LibRaw</dd>
                            <dt>Analysis ID</dt>
                            <dd>
                              <code title={doc.analysis_id}>
                                {doc.analysis_id.slice(0, 8)}
                              </code>
                            </dd>
                            {doc.copied_from && (
                              <>
                                <dt>Copied from</dt>
                                <dd title={doc.copied_from.analysis_id}>
                                  {doc.copied_from.title ||
                                    doc.copied_from.analysis_id.slice(0, 8)}
                                </dd>
                              </>
                            )}
                          </dl>
                          <button
                            className="primary full"
                            onClick={() => chooseStep(1)}
                          >
                            Continue to white balance
                            <ArrowRight size={16} />
                          </button>
                        </>
                      )}
                      {step === 1 && (
                        <>
                          <p>
                            Select an illuminated neutral patch. White balance
                            is applied by rendering the original RAW twice.
                          </p>
                          <button
                            className="full"
                            onClick={() => void redrawWhiteBalance()}
                            data-draw-shortcut="true"
                            aria-keyshortcuts="D"
                            title="Draw white-balance area (D)"
                          >
                            {draft.white_balance.length
                              ? "Redraw white-balance area"
                              : "Draw white-balance area"}
                          </button>
                          {shapeToggle}
                          <button
                            className="primary full"
                            disabled={!draft.white_balance.length}
                            data-enter-shortcut="true"
                            aria-keyshortcuts="Enter"
                            title="Apply white balance (Enter)"
                            onClick={async () => {
                              if (
                                (doc.calibration || doc.results) &&
                                !(await ask({
                                  title: "Apply white balance again?",
                                  message:
                                    "This clears the calibration and results. Calibrate and analyze again afterwards.",
                                  confirm: "Apply white balance",
                                }))
                              )
                                return;
                              void action("white_balance");
                            }}
                          >
                            {doc.white_balance && !dirty
                              ? "Re-apply white balance"
                              : "Apply white balance"}
                          </button>
                          <p className="muted">
                            Changing this area clears calibration and results.
                          </p>
                          {doc.white_balance && !dirty && (
                            <p className="success">
                              <Check size={16} />
                              White balance applied
                            </p>
                          )}
                        </>
                      )}
                      {step === 2 && (
                        <>
                          <label>
                            Marker type
                            <select
                              value={draft.mode}
                              onChange={async (e) => {
                                const mode = e.target.value as Mode;
                                if (
                                  (draft.corners.length ||
                                    draft.manual_patches.length ||
                                    draft.rois.length ||
                                    doc.calibration ||
                                    draft.reservoirs.some(
                                      (r) => r.analyte || r.roi_ids.length,
                                    )) &&
                                  !(await ask({
                                    title: "Change the marker type?",
                                    message:
                                      "This deletes the marker corners, calibration patches, all ROIs and reservoir assignments, and clears the calibration and results. You can undo it afterwards.",
                                    confirm: "Change marker type",
                                    danger: true,
                                  }))
                                )
                                  return;
                                update({
                                  ...draft,
                                  mode,
                                  corners: [],
                                  manual_patches: [],
                                  rois: [],
                                  reservoirs: Array.from({ length: 6 }, (_, i) => ({
                                    id: i + 1,
                                    analyte: null,
                                    roi_ids: [],
                                    review: "needs_review" as const,
                                    reason: "",
                                  })),
                                });
                                setTarget(null);
                              }}
                            >
                              {draft.mode === "flower_9" && (
                                <option value="flower_9">Flower 9 · marker corners</option>
                              )}
                              <option value="flower_9_manual">
                                Flower 9 · manual patches
                              </option>
                              <option value="standard_24_grid">
                                Standard 24 · legacy 24-patch
                              </option>
                            </select>
                          </label>
                          <p>
                            {draft.mode === "flower_9_manual"
                              ? "Draw nine patches in any order. Color identity is determined during calibration."
                              : drawShape === "rectangle"
                                ? "Draw a rectangle around all the patches with two clicks, then drag its corners to line up with the card. Orientation is determined during calibration."
                                : "Place four corners around the marker boundary. Orientation is determined during calibration."}
                          </p>
                          {draft.mode === "flower_9_manual" ? (
                            <>
                              <button
                                className="full"
                                disabled={draft.manual_patches.length >= 9}
                                onClick={() => setTarget("manual")}
                                data-draw-shortcut="true"
                                aria-keyshortcuts="D"
                                title="Start next patch (D)"
                              >
                                {draft.manual_patches.length >= 9
                                  ? "All 9 patches drawn"
                                  : `Draw patch ${draft.manual_patches.length + 1} of 9`}
                              </button>
                              {shapeToggle}
                              <button
                                className="full"
                                disabled={!draft.manual_patches.length}
                                onClick={async () => {
                                  const later = draft.rois.length || doc.calibration || doc.results;
                                  if (
                                    later &&
                                    !(await ask({
                                      title: "Remove the last patch?",
                                      message:
                                        "This also deletes all ROIs and clears the calibration and results. Reservoirs keep their analytes and notes. You can undo it afterwards.",
                                      confirm: "Remove patch",
                                      danger: true,
                                    }))
                                  )
                                    return;
                                  update({
                                    ...draft,
                                    manual_patches: draft.manual_patches.slice(0, -1),
                                    ...(later
                                      ? {
                                          rois: [],
                                          reservoirs: draft.reservoirs.map((r) => ({ ...r, roi_ids: [] })),
                                        }
                                      : {}),
                                  });
                                }}
                              >
                                Remove last patch
                              </button>
                            </>
                          ) : (
                            <>
                              <button
                                className="full"
                                onClick={() => void redrawMarker()}
                                data-draw-shortcut="true"
                                aria-keyshortcuts="D"
                                title="Draw marker boundary (D)"
                              >
                                {draft.corners.length
                                  ? "Redraw marker boundary"
                                  : "Draw marker boundary"}
                              </button>
                              {shapeToggle}
                            </>
                          )}
                          <button
                            className="primary full"
                            disabled={
                              !doc.white_balance ||
                              (draft.mode === "flower_9_manual"
                                ? draft.manual_patches.length !== 9
                                : draft.corners.length !== 4)
                            }
                            data-enter-shortcut="true"
                            aria-keyshortcuts="Enter"
                            title="Calibrate (Enter)"
                            onClick={() => void action("calibrate")}
                          >
                            Calibrate
                          </button>
                          {!doc.white_balance && (
                            <p className="muted">Apply white balance first.</p>
                          )}
                          {doc.calibration && !dirty && (
                            <div className="calibration-info">
                              <p className="success">
                                <Check size={16} />
                                Calibration complete
                              </p>
                              <dl>
                                <dt>RMSE (LAB)</dt>
                                <dd>{numberText(doc.calibration.rmse, 3)}</dd>
                                <dt>Orientation</dt>
                                <dd>
                                  {doc.calibration.orientation.replaceAll(
                                    "_",
                                    " ",
                                  )}
                                </dd>
                                <dt>Confidence gap</dt>
                                <dd>
                                  {numberText(doc.calibration.confidence, 3)}
                                </dd>
                              </dl>
                              <p className="muted">
                                Flower 9 has no RMSE acceptance threshold.
                              </p>
                            </div>
                          )}
                        </>
                      )}
                      {step === 3 && (
                        <>
                          <p>
                            {draft.mode === "standard_24_grid"
                              ? "Draw ROIs for calibrated LAB statistics. Add reservoirs to assign analytes; they use the same equations as Flower."
                              : "Draw one or more ROIs for each assigned reservoir. One reservoir per analyte is sufficient; included reservoirs of the same analyte are averaged."}
                          </p>
                          {draft.reservoirs.length > 0 && (
                              <label>
                                Active reservoir
                                <span className="reservoir-picker">
                                  <select
                                    value={reservoir}
                                    onChange={(e) =>
                                      e.target.value === "add"
                                        ? addReservoir()
                                        : setReservoir(Number(e.target.value))
                                    }
                                  >
                                    {draft.reservoirs.map((r) => (
                                      <option key={r.id} value={r.id}>
                                        Reservoir {r.id} · {r.roi_ids.length}{" "}
                                        {r.roi_ids.length === 1 ? "ROI" : "ROIs"}
                                      </option>
                                    ))}
                                    <option
                                      value="add"
                                      disabled={draft.reservoirs.length >= MAX_RESERVOIRS}
                                    >
                                      + Add reservoir
                                    </option>
                                  </select>
                                  {activeReservoir && (
                                    <button
                                      className="icon-button"
                                      aria-label={`${clearsReservoir(draft) ? "Clear" : "Remove"} reservoir ${reservoir}`}
                                      title={`${clearsReservoir(draft) ? "Clear" : "Remove"} reservoir ${reservoir}`}
                                      disabled={
                                        clearsReservoir(draft) &&
                                        !activeReservoir.analyte &&
                                        !activeReservoir.roi_ids.length &&
                                        !activeReservoir.condition &&
                                        !activeReservoir.replicate
                                      }
                                      onClick={(e) => {
                                        e.preventDefault();
                                        void removeReservoir();
                                      }}
                                    >
                                      <Trash2 size={15} />
                                    </button>
                                  )}
                                </span>
                              </label>
                          )}
                          {!draft.reservoirs.length && (
                            <button className="full" onClick={addReservoir}>
                              <Plus size={14} />
                              Add reservoir
                            </button>
                          )}
                          {activeReservoir && (
                            <>
                              <label>
                                Analyte
                                <select
                                  aria-label="Reservoir analyte"
                                  value={
                                    draft.reservoirs.find(
                                      (r) => r.id === reservoir,
                                    )?.analyte || ""
                                  }
                                  onChange={(e) =>
                                    assignAnalyte((e.target.value || null) as Analyte | null)
                                  }
                                >
                                  <option value="">Unassigned</option>
                                  {(
                                    [
                                      ["ph", "pH"],
                                      ["urea", "Urea"],
                                      ["creatinine", "Creatinine"],
                                    ] as [Analyte, string][]
                                  ).map(([value, label]) => (
                                    <option key={value} value={value}>
                                      {label}
                                    </option>
                                  ))}
                                  <option value="custom">Custom…</option>
                                </select>
                              </label>
                              <div className="reservoir-labels">
                                <label>
                                  Custom biomarker
                                  <input
                                    value={activeReservoir.custom_name || ""}
                                    maxLength={80}
                                    placeholder="Optional, e.g. Lactate"
                                    onChange={(e) =>
                                      updateReservoir(
                                        e.target.value.trim()
                                          ? { custom_name: e.target.value, analyte: "custom" }
                                          : { custom_name: e.target.value },
                                        "custom-name",
                                      )
                                    }
                                  />
                                </label>
                                <label>
                                  Notes
                                  <input
                                    value={activeReservoir.condition || ""}
                                    maxLength={80}
                                    placeholder="Optional"
                                    onChange={(e) =>
                                      updateReservoir({ condition: e.target.value }, "condition")
                                    }
                                  />
                                </label>
                                {activeReservoir.replicate && (
                                  <label>
                                    Replicate
                                    <input
                                      value={activeReservoir.replicate}
                                      maxLength={40}
                                      onChange={(e) =>
                                        updateReservoir({ replicate: e.target.value }, "replicate")
                                      }
                                    />
                                  </label>
                                )}
                              </div>
                              {addRoi}
                            </>
                          )}
                          {!activeReservoir && addRoi}
                          <div className="roi-list">
                            {draft.rois
                              .filter(
                                (r) =>
                                  !activeReservoir ||
                                  !draft.reservoirs.some((v) =>
                                    v.roi_ids.includes(r.id),
                                  ) ||
                                  draft.reservoirs
                                    .find((v) => v.id === reservoir)
                                    ?.roi_ids.includes(r.id),
                              )
                              .map((r) => (
                                <div key={r.id}>
                                  <span>
                                    {r.label}{" "}
                                    <small>{r.points.length} vertices</small>
                                    <RangeFlag results={doc.results} roiId={r.id} />
                                  </span>
                                  {draft.reservoirs.length > 0 && (
                                    <select
                                      className="roi-owner"
                                      aria-label={`Assign ROI ${r.id}`}
                                      value={
                                        draft.reservoirs.find((v) =>
                                          v.roi_ids.includes(r.id),
                                        )?.id || ""
                                      }
                                      onChange={(e) =>
                                        update({
                                          ...draft,
                                          reservoirs: draft.reservoirs.map(
                                            (v) => ({
                                              ...v,
                                              roi_ids:
                                                v.id === Number(e.target.value)
                                                  ? [
                                                      ...v.roi_ids.filter(
                                                        (id) => id !== r.id,
                                                      ),
                                                      r.id,
                                                    ]
                                                  : v.roi_ids.filter(
                                                      (id) => id !== r.id,
                                                    ),
                                            }),
                                          ),
                                        })
                                      }
                                    >
                                      <option value="">Unassigned</option>
                                      {draft.reservoirs.map((v) => (
                                        <option key={v.id} value={v.id}>
                                          Reservoir {v.id}
                                        </option>
                                      ))}
                                    </select>
                                  )}
                                  <button
                                    aria-label={`Remove ROI ${r.id}`}
                                    onClick={() =>
                                      update({
                                        ...draft,
                                        rois: draft.rois.filter(
                                          (v) => v.id !== r.id,
                                        ),
                                        reservoirs: draft.reservoirs.map(
                                          (v) => ({
                                            ...v,
                                            roi_ids: v.roi_ids.filter(
                                              (id) => id !== r.id,
                                            ),
                                          }),
                                        ),
                                      })
                                    }
                                  >
                                    <Trash2 size={14} />
                                  </button>
                                </div>
                              ))}
                          </div>
                          <button
                            className="primary full"
                            disabled={!doc.calibration || !draft.rois.length}
                            onClick={() => void action("analyze")}
                          >
                            Analyze ROIs
                            <ArrowRight size={16} />
                          </button>
                          {!doc.calibration && (
                            <p className="muted">Complete calibration first.</p>
                          )}
                        </>
                      )}
                      {step === 4 && (
                        <>
                          <p>
                            {hasAnalytes
                              ? "Review flagged reservoirs. In-range valid results are included automatically."
                              : "Review raw and calibrated LAB values for every ROI, then export the analysis."}
                          </p>
                          {hasAnalytes && (
                            <>
                              {ureaControls(commit)}
                              <label>
                                Age (years)
                                <input
                                  aria-label="Age (years)"
                                  type="number"
                                  min="1"
                                  value={draft.age ?? ""}
                                  onChange={(e) =>
                                    update(
                                      {
                                        ...draft,
                                        age: e.target.value
                                          ? Number(e.target.value)
                                          : null,
                                      },
                                      "age",
                                    )
                                  }
                                />
                              </label>
                              <label>
                                Sex used by research model
                                <select
                                  value={draft.sex || ""}
                                  onChange={(e) =>
                                    update({
                                      ...draft,
                                      sex: (e.target.value ||
                                        null) as Draft["sex"],
                                    })
                                  }
                                >
                                  <option value="">Not provided</option>
                                  <option value="female">Female</option>
                                  <option value="male">Male</option>
                                </select>
                              </label>
                              <label>
                                Prediction model
                                <select
                                  value={draft.classifier_model || ""}
                                  onChange={(e) =>
                                    commit({
                                      ...draft,
                                      classifier_model: (e.target.value ||
                                        null) as ClassifierModel | null,
                                    })
                                  }
                                >
                                  <option value="">
                                    {doc.results?.prediction.available_models?.length
                                      ? `Automatic (${CLASSIFIER_NAMES[doc.results.prediction.available_models[0]]})`
                                      : "Automatic"}
                                  </option>
                                  {(Object.keys(CLASSIFIER_NAMES) as ClassifierModel[]).map(
                                    (model) => (
                                      <option
                                        key={model}
                                        value={model}
                                        disabled={
                                          !!doc.results &&
                                          !doc.results.prediction.available_models?.includes(model) &&
                                          draft.classifier_model !== model
                                        }
                                      >
                                        {CLASSIFIER_NAMES[model]}
                                      </option>
                                    ),
                                  )}
                                </select>
                              </label>
                            </>
                          )}
                          <div className="divider" />
                          <label className="checkbox-row">
                            <input
                              type="checkbox"
                              checked={debugRasters}
                              onChange={(e) => setDebugRasters(e.target.checked)}
                            />
                            Include debug images (about{" "}
                            {Math.round(
                              ((doc.source.width || 0) *
                                (doc.source.height || 0) *
                                4 *
                                (doc.white_balance ? 2 : 1)) /
                                1e6,
                            )}{" "}
                            MB before compression)
                          </label>
                          <DownloadLink
                            className="button-link primary full"
                            href={`/api/analyses/${doc.id}/export?debug_rasters=${debugRasters ? 1 : 0}`}
                            name={exportFilename(draft.title)}
                            disabled={!doc.results || dirty || busy}
                          >
                            <Download size={16} />
                            Export ZIP
                          </DownloadLink>
                          <p className="muted">
                            Includes the original image, coordinates,
                            overlay, calibration and ROI measurements,
                            reservoir, analyte and prediction results, and a
                            version manifest.
                          </p>
                        </>
                      )}
                      <div className="divider" />
                      <h3>Coordinates</h3>
                      <button
                        className="full"
                        onClick={() => coordinatesInput.current?.click()}
                      >
                        <Upload size={15} />
                        Import coordinates
                      </button>
                      {!readOnly && (
                        <DownloadLink
                          className={`subtle-link ${dirty ? "disabled-link" : ""}`}
                          href={`/api/analyses/${doc.id}/coordinates`}
                          download
                        >
                          Download coordinates JSON
                        </DownloadLink>
                      )}
                    </fieldset>
                    <div className="download-panel">
                      <DownloadLink
                        href={`/api/analyses/${doc.id}/original`}
                        download
                      >
                        Download original image
                      </DownloadLink>
                      <button
                        onClick={() =>
                          void revealPath(`${root}/${doc.project_path}`).catch(
                            (e) => setError(e.message),
                          )
                        }
                      >
                        Reveal analysis in Finder
                      </button>
                    </div>
                  </aside>
                </div>
              )}
            </>
          )}
        </main>
      </div>
      <input
        ref={fileInput}
        aria-label="RAW image file"
        className="hidden"
        type="file"
        accept=".dng,.DNG,.cr2,.CR2"
        onChange={(e) => void upload(e.target.files?.[0])}
      />
      <input
        ref={coordinatesInput}
        aria-label="Coordinate package file"
        className="hidden"
        type="file"
        accept=".json"
        onChange={(e) => void importPackage(e.target.files?.[0])}
      />
      {confirmation && (
        <ConfirmDialog
          request={confirmation}
          onClose={(confirmed) => {
            confirmation.resolve(confirmed);
            setConfirmation(null);
          }}
        />
      )}
    </div>
  );
}
