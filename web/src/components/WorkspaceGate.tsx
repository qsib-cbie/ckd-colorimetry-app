import { useEffect, useState } from "react";
import { Folder, FolderOpen, FlaskConical, X } from "lucide-react";
import App from "../App";
import type { Workspace } from "../types";
import { homeRelative, jsonRequest, request } from "../utils";
import { pickPath, useNativeLifecycle } from "../native";

export function WorkspaceGate() {
  useNativeLifecycle();
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [choosing, setChoosing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    void request<Workspace>("/workspace")
      .then(setWorkspace)
      .catch((e) => setError(e.message));
  }, [choosing]);
  const open = async (path?: string) => {
    setError("");
    setBusy(true);
    try {
      const selected = path || (await pickPath("folder"));
      if (!selected) return;
      const next = await request<Workspace>(
        "/workspace",
        jsonRequest("POST", { path: selected }),
      );
      location.hash = "";
      setWorkspace(next);
      setChoosing(false);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const forget = async (path: string) => {
    setError("");
    try {
      setWorkspace(
        await request<Workspace>(
          "/workspace/forget",
          jsonRequest("POST", { path }),
        ),
      );
    } catch (e) {
      setError((e as Error).message);
    }
  };
  if (workspace?.root && !choosing)
    return (
      <App
        key={workspace.root}
        root={workspace.root}
        home={workspace.home}
        onWorkspace={() => setChoosing(true)}
      />
    );
  return (
    <main className="workspace-welcome">
      <FlaskConical size={36} />
      <h1>CKD Colorimetry</h1>
      <p>
        Choose a folder for your research. Images, analysis settings, and
        results stay together on your Mac.
      </p>
      {error && (
        <p className="alert" role="alert">
          {error}
        </p>
      )}
      <button
        className="primary"
        disabled={busy || !workspace}
        onClick={() => void open()}
      >
        <FolderOpen size={18} />
        Open workspace folder
      </button>
      {workspace?.root && (
        <button disabled={busy} onClick={() => setChoosing(false)}>
          Return to current workspace
        </button>
      )}
      {!!workspace?.recent.length && (
        <section className="recent-workspaces" aria-labelledby="recent-heading">
          <h2 id="recent-heading">Recent folders</h2>
          <ul>
            {workspace.recent.map((path) => {
              const name = path.split("/").pop() || path;
              const missing = workspace.missing.includes(path);
              return (
                <li key={path} className={missing ? "missing" : ""}>
                  <button
                    className="recent-open"
                    disabled={busy || missing}
                    onClick={() => void open(path)}
                    title={path}
                  >
                    <Folder size={20} />
                    <span className="recent-text">
                      <span className="recent-name">{name}</span>
                      <em className="recent-path">
                        {missing && "Not found · "}
                        {homeRelative(path, workspace.home)}
                      </em>
                    </span>
                  </button>
                  <button
                    className="icon-button recent-remove"
                    aria-label={`Remove ${name} from recent folders`}
                    title="Remove from recent folders"
                    disabled={busy}
                    onClick={() => void forget(path)}
                  >
                    <X size={15} />
                  </button>
                </li>
              );
            })}
          </ul>
        </section>
      )}
      <p className="muted">
        No account or internet connection required. Share saved analysis folders
        using Finder.
      </p>
    </main>
  );
}
