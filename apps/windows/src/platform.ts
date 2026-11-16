// apps/web's platform module inside the Windows shell (P4.3); the browser one is apps/web/src/platform.ts.
import { invoke } from "@tauri-apps/api/core";
import type { Platform } from "../../web/src/platform.js";
import { credentialSecrets } from "./bridge.js";

export const platform: Platform = { name: "windows", secrets: credentialSecrets(invoke) };
