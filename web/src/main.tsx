import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { WorkspaceGate } from "./components/WorkspaceGate";
import { initTheme } from "./theme";
import "./style.css";
initTheme();
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <WorkspaceGate />
  </StrictMode>,
);
