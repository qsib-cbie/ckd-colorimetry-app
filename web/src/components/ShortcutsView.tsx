import { ArrowLeft } from "lucide-react";

const GROUPS: [string, [string, string][]][] = [
  [
    "Drawing on the image",
    [
      ["D", "Start drawing: white-balance area, calibration patch, marker corners or ROI"],
      ["T", "Switch between rectangle and polygon"],
      ["Click, click", "Rectangle: two opposite corners; drawing stays on for the next one"],
      ["Click the first point, E or Enter", "Finish the polygon being drawn"],
      ["Cmd+Z", "Remove the last point; with none placed, undo the last shape"],
      ["Cmd+Shift+Z", "Redo"],
      ["P", "Toggle pan while drawing"],
      ["Space or Cmd, then drag", "Pan temporarily"],
      ["Scroll", "Zoom the image"],
    ],
  ],
  [
    "Analysis steps",
    [
      ["Enter", "Apply white balance or calibrate on those steps"],
      ["N", "Next reservoir on the Reservoirs step"],
      ["Cmd+Z", "Undo the last change"],
      ["Cmd+Shift+Z", "Redo"],
    ],
  ],
  [
    "Library, menus and dialogs",
    [
      ["Enter", "Save a name while renaming"],
      ["Escape", "Cancel renaming, close a menu or dialog"],
      ["Up and Down arrows", "Move through menu items"],
      ["Home or End", "First or last menu item"],
    ],
  ],
  ["Window", [["Cmd+\\", "Show or hide the sidebar"]]],
];

export function ShortcutsView({ onBack }: { onBack: () => void }) {
  return (
    <section className="results-view" aria-label="Shortcuts">
      <div className="section-heading">
        <div>
          <span className="eyebrow">KEYBOARD AND MOUSE</span>
          <h2>Shortcuts</h2>
        </div>
        <button onClick={onBack}>
          <ArrowLeft size={15} />
          Back
        </button>
      </div>
      {GROUPS.map(([title, rows]) => (
        <div key={title}>
          <h3>{title}</h3>
          <div className="table-scroll">
            <table>
              <tbody>
                {rows.map(([keys, action]) => (
                  <tr key={keys + action}>
                    <td>
                      <kbd>{keys}</kbd>
                    </td>
                    <td>{action}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      ))}
      <p className="muted">
        Shortcuts are ignored while typing in a field or when a dialog is open.
        Enter does not run Analyze ROIs.
      </p>
    </section>
  );
}
