import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "../../../Packages/design-tokens/tokens.css";
import "../../web/src/styles.css";
import "./panel.css";
import { Panel } from "./Panel.js";

// Follows the system light/dark setting live (tokens.css keys off data-theme).
const media = window.matchMedia("(prefers-color-scheme: dark)");
const theme = () => { document.documentElement.dataset.theme = media.matches ? "dark" : "light"; };
media.onchange = theme;
theme();
createRoot(document.getElementById("root")!).render(<StrictMode><Panel /></StrictMode>);
