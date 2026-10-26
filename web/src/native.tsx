import { useEffect, useState, type AnchorHTMLAttributes } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke, isTauri } from "@tauri-apps/api/core";

export const isDesktop = () => isTauri();
export async function pickPath(
  kind: "folder" | "import",
): Promise<string | null> {
  if (!isDesktop()) throw new Error("Choosing a folder or export ZIP needs the Mac app.");
  return invoke<string | null>("pick_path", { kind }).catch((error) => { throw new Error(String(error)); });
}
export async function revealPath(path: string) {
  if (isDesktop()) return invoke("reveal_path", { path });
  window.alert(path);
}
export function DownloadLink({
  name,
  disabled,
  className,
  ...props
}: AnchorHTMLAttributes<HTMLAnchorElement> & { name?: string; disabled?: boolean }) {
  const [error, setError] = useState("");
  return (<>
    <a
      {...props}
      className={`${className || ""} ${disabled ? "disabled-link" : ""}`}
      aria-disabled={disabled || undefined}
      download={name ?? props.download}
      onClick={async (event) => {
        if (disabled) {
          event.preventDefault();
          return;
        }
        if (!isDesktop()) return;
        event.preventDefault();
        setError("");
        try {
          await invoke("save_download", { path: props.href, name });
        } catch (error) {
          setError(String(error));
        }
      }}
    />{error && <span role="alert">{error}</span>}</>
  );
}

let closeHandler: () => Promise<void> = async () => { await invoke("quit"); };
export const quitDesktop = () => invoke("quit");
export function registerCloseHandler(handler: () => Promise<void>) {
  closeHandler = handler;
  return () => { closeHandler = async () => { await invoke("quit"); }; };
}
export function useNativeLifecycle() {
  useEffect(() => {
    if (!isDesktop()) return;
    let disposed = false;
    let remove: (() => void) | undefined;
    void listen("ckd-close-request", () => void closeHandler()).then((unlisten) => {
      if (disposed) unlisten(); else remove = unlisten;
    });
    return () => { disposed = true; remove?.(); };
  }, []);
}
