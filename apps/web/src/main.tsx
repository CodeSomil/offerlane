import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "../../../Packages/design-tokens/tokens.css";
import "./styles.css";
import { App } from "./App.js";
import { applyTheme, savedTheme } from "./theme.js";
import { signedIn } from "./auth.js";

applyTheme(savedTheme());
void signedIn().catch(() => undefined);  // Settings shows the outcome
createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
