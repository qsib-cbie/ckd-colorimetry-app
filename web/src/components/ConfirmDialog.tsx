import { useEffect, useRef } from "react";

export type Confirmation = {
  title: string;
  message: string;
  confirm: string;
  cancel?: string;
  danger?: boolean;
};

export function ConfirmDialog({
  request,
  onClose,
}: {
  request: Confirmation;
  onClose: (confirmed: boolean) => void;
}) {
  const dialog = useRef<HTMLDivElement>(null);
  const cancel = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cancel.current?.focus();
  }, []);
  return (
    <div className="modal-backdrop">
      <div
        ref={dialog}
        className="compact-modal confirm-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="confirm-title"
        aria-describedby="confirm-message"
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            event.preventDefault();
            onClose(false);
          } else if (event.key === "Tab") {
            const buttons = [...(dialog.current?.querySelectorAll("button") || [])];
            const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
            event.preventDefault();
            buttons[(index + (event.shiftKey ? buttons.length - 1 : 1)) % buttons.length]?.focus();
          }
        }}
      >
        <h2 id="confirm-title">{request.title}</h2>
        <p id="confirm-message">{request.message}</p>
        <div className="dialog-actions">
          <button ref={cancel} onClick={() => onClose(false)}>
            {request.cancel || "Cancel"}
          </button>
          <button
            className={request.danger ? "danger" : "primary"}
            onClick={() => onClose(true)}
          >
            {request.confirm}
          </button>
        </div>
      </div>
    </div>
  );
}
