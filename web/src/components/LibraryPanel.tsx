import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type DragEvent,
  type MouseEvent,
  type ReactNode,
} from "react";
import {
  AlertTriangle,
  ChevronDown,
  ChevronRight,
  FileImage,
  FolderPlus,
  MoreHorizontal,
  RefreshCw,
} from "lucide-react";
import type { LibraryData, Analysis } from "../types";
import { jsonRequest, request } from "../utils";
import { revealPath } from "../native";
import { Menu, type MenuItem } from "./Menu";
import type { Confirmation } from "./ConfirmDialog";

type Kind = "workspace" | "folder" | "analysis";
type MenuState = {
  kind: Kind;
  path: string;
  x: number;
  y: number;
  moving: boolean;
  trigger: HTMLElement | null;
};
type Props = {
  root: string;
  current: Analysis | null;
  refreshKey: number;
  disabled: boolean;
  ask: (confirmation: Confirmation) => Promise<boolean>;
  beforeChange: () => Promise<void>;
  onBusyChange: (busy: boolean) => void;
  onOpen: (id: string) => void;
  onSelect: (id: string | null) => void;
  onImport: () => void;
  onChanged: (oldPath?: string, newPath?: string) => Promise<void>;
};

const parentOf = (path: string) =>
  path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
const nameOf = (path: string) => path.split("/").pop() || path;
const within = (path: string, folder: string) =>
  path === folder || path.startsWith(`${folder}/`);

function InlineName({
  label,
  initial,
  onSubmit,
  onCancel,
}: {
  label: string;
  initial: string;
  onSubmit: (value: string) => void;
  onCancel: () => void;
}) {
  const [value, setValue] = useState(initial);
  const finished = useRef(false);
  const finish = (save: boolean) => {
    if (finished.current) return;
    finished.current = true;
    if (save && value.trim() && value.trim() !== initial) onSubmit(value.trim());
    else onCancel();
  };
  return (
    <input
      className="tree-input"
      aria-label={label}
      autoFocus
      maxLength={120}
      value={value}
      onFocus={(e) => e.currentTarget.select()}
      onChange={(e) => setValue(e.target.value)}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          finish(true);
        } else if (e.key === "Escape") {
          e.preventDefault();
          e.stopPropagation();
          finish(false);
        }
      }}
      onBlur={() => finish(true)}
    />
  );
}

export function LibraryPanel({
  root,
  current,
  refreshKey,
  disabled,
  ask,
  beforeChange,
  onBusyChange,
  onOpen,
  onSelect,
  onImport,
  onChanged,
}: Props) {
  const [data, setData] = useState<LibraryData>({
    root,
    folders: [],
    analyses: [],
    problems: [],
  });
  const [selected, setSelected] = useState("");
  const [search, setSearch] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [menu, setMenu] = useState<MenuState | null>(null);
  const [renaming, setRenaming] = useState<string | null>(null);
  const [creating, setCreating] = useState<string | null>(null);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [dragging, setDragging] = useState<{ kind: Kind; path: string } | null>(
    null,
  );
  const [dropTarget, setDropTarget] = useState<string | null>(null);
  const expandTimer = useRef<{ folder: string; timer: number } | null>(null);
  const locked = disabled || busy;
  const refresh = useCallback(async () => {
    try {
      setData(await request<LibraryData>("/library"));
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);
  useEffect(() => {
    void refresh();
  }, [refresh, refreshKey]);
  useEffect(() => {
    const focus = () => {
      if (!locked) void refresh();
    };
    window.addEventListener("focus", focus);
    return () => window.removeEventListener("focus", focus);
  }, [refresh, locked]);
  const choose = (path: string) => {
    setSelected(path);
    onSelect(path || null);
  };
  const relocate = (oldPath: string, newPath?: string) => {
    if (!within(selected, oldPath)) return;
    choose(newPath ? newPath + selected.slice(oldPath.length) : parentOf(oldPath));
  };
  const expand = (path: string) =>
    setCollapsed((previous) => {
      const next = new Set(previous);
      for (let folder = path; folder; folder = parentOf(folder))
        next.delete(folder);
      return next;
    });
  const change = async (operation: () => Promise<void>) => {
    setBusy(true);
    onBusyChange(true);
    setError("");
    setNotice("");
    try {
      await beforeChange();
      await operation();
      await refresh();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
      onBusyChange(false);
    }
  };
  const createFolder = (parent: string, name: string) =>
    change(async () => {
      const result = await request<{ path: string }>(
        "/folders",
        jsonRequest("POST", { name, parent: parent || null }),
      );
      choose(result.path);
      await onChanged();
    });
  const move = (path: string, name: string, parent: string) =>
    change(async () => {
      const result = await request<{ path: string }>(
        "/folders/move",
        jsonRequest("POST", { path, name, parent: parent || null }),
      );
      relocate(path, result.path);
      expand(parent);
      await onChanged(path, result.path);
    });
  const renameAnalysis = (id: string, path: string, title: string) =>
    change(async () => {
      const result = await request<{ path: string }>(
        `/analyses/${id}/rename`,
        jsonRequest("POST", { title }),
      );
      await onChanged(path, result.path);
    });
  const duplicate = (id: string) =>
    change(async () => {
      const copy = await request<Analysis>(`/analyses/${id}/duplicate`, {
        method: "POST",
      });
      await onChanged();
      onOpen(copy.id);
    });
  const renewId = (id: string) =>
    change(async () => {
      await request(`/analyses/${id}/new-id`, { method: "POST" });
      await onChanged();
      if (current?.id === id) onOpen(id);
    });
  const trash = async (path: string, label: string, folder: boolean) => {
    const confirmed = await ask({
      title: `Move “${label}” to the Trash?`,
      message: folder
        ? "This moves the folder and everything inside it to the Mac Trash. Restore it from the Trash in Finder if needed."
        : "This moves the analysis folder, with its original image and results, to the Mac Trash. Restore it from the Trash in Finder if needed.",
      confirm: "Move to Trash",
      danger: true,
    });
    if (!confirmed) return;
    await change(async () => {
      await request("/folders/trash", jsonRequest("POST", { path }));
      relocate(path);
      await onChanged(path);
    });
  };
  const restore = (path: string) =>
    change(async () => {
      await request("/folders/restore", jsonRequest("POST", { path }));
      await onChanged();
      setNotice(
        "Restored the last readable version. The damaged file was kept in the analysis folder.",
      );
    });
  const reveal = (path: string) =>
    void revealPath(path ? `${root}/${path}` : root).catch((e) =>
      setError(String(e)),
    );
  const startCreating = (parent: string) => {
    expand(parent);
    setCreating(parent);
  };
  const canDrop = (target: string) =>
    !!dragging &&
    parentOf(dragging.path) !== target &&
    (dragging.kind !== "folder" || !within(target, dragging.path));
  const stopExpanding = () => {
    if (expandTimer.current) window.clearTimeout(expandTimer.current.timer);
    expandTimer.current = null;
  };
  const endDrag = () => {
    stopExpanding();
    setDragging(null);
    setDropTarget(null);
  };
  const draggable = (kind: Kind, path: string) => ({
    draggable: !locked && renaming !== path,
    onDragStart: (event: DragEvent<HTMLElement>) => {
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", path);
      setMenu(null);
      setDragging({ kind, path });
    },
    onDragEnd: endDrag,
  });
  const dropZone = (target: string) => ({
    onDragOver: (event: DragEvent<HTMLElement>) => {
      if (!canDrop(target)) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
      setDropTarget(target);
      if (target && collapsed.has(target) && expandTimer.current?.folder !== target) {
        stopExpanding();
        expandTimer.current = {
          folder: target,
          timer: window.setTimeout(() => expand(target), 600),
        };
      }
    },
    onDragLeave: (event: DragEvent<HTMLElement>) => {
      if (!event.currentTarget.contains(event.relatedTarget as Node)) {
        setDropTarget((current) => (current === target ? null : current));
        if (expandTimer.current?.folder === target) stopExpanding();
      }
    },
    onDrop: (event: DragEvent<HTMLElement>) => {
      event.preventDefault();
      const source = dragging;
      endDrag();
      if (source && canDrop(target))
        void move(source.path, nameOf(source.path), target);
    },
  });
  const dragClasses = (path: string, target?: string) =>
    `${dragging?.path === path ? "dragging" : ""} ${
      target !== undefined && dropTarget === target ? "drop-target" : ""
    }`;
  const openMenu = (
    event: MouseEvent<HTMLElement>,
    kind: Kind,
    path: string,
    fromButton: boolean,
  ) => {
    event.preventDefault();
    event.stopPropagation();
    const box = event.currentTarget.getBoundingClientRect();
    setMenu({
      kind,
      path,
      x: fromButton ? box.left : event.clientX,
      y: fromButton ? box.bottom + 4 : event.clientY,
      moving: false,
      trigger: fromButton ? event.currentTarget : null,
    });
  };
  const closeMenu = (restoreFocus = false) => {
    if (restoreFocus) menu?.trigger?.focus();
    setMenu(null);
  };
  const act = (action: () => void) => () => {
    setMenu(null);
    action();
  };
  const menuItems = (state: MenuState): MenuItem[] => {
    const { kind, path } = state;
    const item = data.analyses.find((a) => a.project_path === path);
    const label = item?.draft.title || nameOf(path);
    if (state.moving) {
      const from = parentOf(path);
      return [
        { label: "← Back", onSelect: () => setMenu({ ...state, moving: false }) },
        {
          label: from ? "Workspace folder" : "Workspace folder (current)",
          disabled: !from,
          separated: true,
          onSelect: act(() => void move(path, nameOf(path), "")),
        },
        ...data.folders
          .filter((f) => kind !== "folder" || !within(f.id, path))
          .map((f) => ({
            label: f.id === from ? `${f.id} (current)` : f.id,
            disabled: f.id === from,
            onSelect: act(() => void move(path, nameOf(path), f.id)),
          })),
      ];
    }
    if (kind === "workspace")
      return [
        { label: "New folder", disabled: locked, onSelect: act(() => startCreating("")) },
        { label: "Import export ZIP…", disabled: locked, onSelect: act(onImport) },
        { label: "Reveal in Finder", onSelect: act(() => reveal("")) },
        { label: "Refresh folders", disabled: locked, onSelect: act(() => void refresh()) },
      ];
    const shared: MenuItem[] = [
      { label: "Rename…", disabled: locked, onSelect: act(() => setRenaming(path)) },
      {
        label: "Move to…",
        disabled: locked,
        onSelect: () => setMenu({ ...state, moving: true }),
      },
    ];
    const tail: MenuItem[] = [
      { label: "Reveal in Finder", onSelect: act(() => reveal(path)) },
      {
        label: "Move to Trash…",
        danger: true,
        separated: true,
        disabled: locked,
        onSelect: act(() => void trash(path, label, kind === "folder")),
      },
    ];
    if (kind === "folder")
      return [
        {
          label: "New folder inside",
          disabled: locked,
          onSelect: act(() => startCreating(path)),
        },
        ...shared,
        ...tail,
      ];
    return [
      { label: "Open", disabled: locked || !item, onSelect: act(() => item && onOpen(item.id)) },
      ...shared,
      {
        label: "Duplicate",
        disabled: locked || !item,
        onSelect: act(() => item && void duplicate(item.id)),
      },
      ...(item?.duplicate_id
        ? [
            {
              label: "Give this copy its own ID",
              disabled: locked,
              onSelect: act(() => void renewId(item.id)),
            },
          ]
        : []),
      ...tail,
    ];
  };
  const options = (kind: Kind, path: string, label: string) => (
    <button
      className="tree-menu"
      aria-label={`Options for ${label}`}
      aria-haspopup="menu"
      aria-expanded={menu?.path === path && menu.kind === kind}
      onClick={(e) =>
        menu?.path === path && menu.kind === kind
          ? closeMenu()
          : openMenu(e, kind, path, true)
      }
    >
      <MoreHorizontal size={15} />
    </button>
  );
  const newFolder = (parent: string) =>
    creating === parent && (
      <div className="tree-row">
        <InlineName
          label="New folder name"
          initial=""
          onSubmit={(name) => {
            setCreating(null);
            void createFolder(parent, name);
          }}
          onCancel={() => setCreating(null)}
        />
      </div>
    );
  const analyses = (parent: string) =>
    data.analyses
      .filter(
        (item) =>
          (search ? true : parentOf(item.project_path) === parent) &&
          `${item.draft.title} ${item.project_path}`
            .toLowerCase()
            .includes(search.toLowerCase()),
      )
      .map((item) => (
        <div
          className={`tree-row tree-analysis ${current?.id === item.id ? "selected" : ""} ${dragClasses(item.project_path)}`}
          key={item.id}
          onContextMenu={(e) => openMenu(e, "analysis", item.project_path, false)}
          {...draggable("analysis", item.project_path)}
        >
          {renaming === item.project_path ? (
            <InlineName
              label={`Rename ${item.draft.title}`}
              initial={item.draft.title}
              onSubmit={(title) => {
                setRenaming(null);
                void renameAnalysis(item.id, item.project_path, title);
              }}
              onCancel={() => setRenaming(null)}
            />
          ) : (
            <button
              className="tree-label"
              disabled={locked}
              title={item.project_path}
              onClick={() => onOpen(item.id)}
            >
              <FileImage size={14} />
              <span>{item.draft.title}</span>
              {item.duplicate_id && (
                <AlertTriangle
                  size={13}
                  className="duplicate-flag"
                  role="img"
                  aria-label="Shares its ID with another analysis"
                />
              )}
            </button>
          )}
          {options("analysis", item.project_path, item.draft.title)}
        </div>
      ));
  const tree = (parent: string | null): ReactNode =>
    data.folders
      .filter((folder) => folder.parent_id === parent)
      .map((folder) => {
        const open = !collapsed.has(folder.id);
        return (
          <div className="tree-node" key={folder.id}>
            <div
              className={`tree-row tree-folder ${selected === folder.id ? "selected" : ""} ${dragClasses(folder.id, folder.id)}`}
              onContextMenu={(e) => openMenu(e, "folder", folder.id, false)}
              {...draggable("folder", folder.id)}
              {...dropZone(folder.id)}
            >
              <button
                className="tree-toggle"
                aria-label={`${open ? "Collapse" : "Expand"} ${folder.name}`}
                aria-expanded={open}
                onClick={() =>
                  setCollapsed((previous) => {
                    const next = new Set(previous);
                    if (open) next.add(folder.id);
                    else next.delete(folder.id);
                    return next;
                  })
                }
              >
                {open ? <ChevronDown size={13} /> : <ChevronRight size={13} />}
              </button>
              {renaming === folder.id ? (
                <InlineName
                  label={`Rename ${folder.name}`}
                  initial={folder.name}
                  onSubmit={(name) => {
                    setRenaming(null);
                    void move(folder.id, name, parentOf(folder.id));
                  }}
                  onCancel={() => setRenaming(null)}
                />
              ) : (
                <button
                  className="tree-label"
                  disabled={locked}
                  onClick={() => choose(folder.id)}
                >
                  {folder.name}
                </button>
              )}
              {options("folder", folder.id, folder.name)}
            </div>
            {open && (
              <div className="tree-children">
                {newFolder(folder.id)}
                {tree(folder.id)}
                {analyses(folder.id)}
              </div>
            )}
          </div>
        );
      });
  return (
    <>
      <div className="library-heading">
        <strong>Folders</strong>
        <button
          title="Refresh folders"
          aria-label="Refresh folders"
          disabled={locked}
          onClick={() => void refresh()}
        >
          <RefreshCw size={15} />
        </button>
        <button
          title="New folder"
          aria-label="Create folder"
          disabled={locked}
          onClick={() => startCreating(selected)}
        >
          <FolderPlus size={17} />
        </button>
      </div>
      <div
        className={`tree-row workspace-root ${!selected ? "selected" : ""} ${dragClasses("", "")}`}
        onContextMenu={(e) => openMenu(e, "workspace", "", false)}
        {...dropZone("")}
      >
        <button
          className="tree-label"
          title={root}
          disabled={locked}
          onClick={() => choose("")}
        >
          {nameOf(root)}
        </button>
        {options("workspace", "", nameOf(root))}
      </div>
      <input
        className="library-search"
        aria-label="Find an analysis"
        placeholder="Find an analysis..."
        value={search}
        onChange={(e) => setSearch(e.target.value)}
      />
      <div className="folder-tree">
        {newFolder("")}
        {!search && tree(null)}
        {analyses("")}
      </div>
      <p className="library-hint">
        {disabled
          ? "Folder changes are paused while processing."
          : `New analyses save in ${selected || "the workspace folder"}.`}
      </p>
      {notice && (
        <p className="notice" role="status">
          {notice}
        </p>
      )}
      {error && (
        <p className="alert" role="alert">
          {error}
        </p>
      )}
      {data.problems.map((item) => (
        <div className="alert library-problem" key={item.path}>
          <span>
            {item.path}: {item.error}
          </span>
          {!/Update this app|Unsupported project version/.test(item.error) && (
            <button disabled={locked} onClick={() => void restore(item.path)}>
              Restore last saved version
            </button>
          )}
        </div>
      ))}
      {menu && (
        <Menu
          label={`Options for ${
            menu.kind === "workspace"
              ? nameOf(root)
              : data.analyses.find((a) => a.project_path === menu.path)?.draft
                  .title || nameOf(menu.path)
          }`}
          x={menu.x}
          y={menu.y}
          items={menuItems(menu)}
          onClose={closeMenu}
        />
      )}
    </>
  );
}
