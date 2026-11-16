// apps/web's platform module inside the Windows shell (P4.3); the browser one is apps/web/src/platform.ts.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import autofill from "../../../App/Resources/autofill.js?raw";
import { getItem, updateItem } from "../../web/src/store.js";
import type { Platform } from "../../web/src/platform.js";
import { shellFill } from "./apply.js";
import { credentialSecrets, type Approvals } from "./bridge.js";

const KEY = "apply-approvals";  // host -> the company the human allowed an account for (Vault.swift's SiteAccount)
const table = (v: unknown): Record<string, string> => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, string>) : {});
const approvals: Approvals = {
  get: async (host) => { const c = table(await getItem(KEY))[host]; return typeof c === "string" ? c : undefined; },
  set: async (host, company) => { await updateItem(KEY, (old) => ({ ...table(old), [host]: company })); },
};

export const platform: Platform = { name: "windows", secrets: credentialSecrets(invoke), fill: shellFill(invoke, listen, approvals, autofill).fill };
