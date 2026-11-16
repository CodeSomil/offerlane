// chrome.storage.local: "answers" (profile + approved roles' answers from the web app) and "saved" (jobs saved here,
// waiting for the web app to take them). The browser keeps it unencrypted on this device; "Forget" in the panel clears it.
import type { JobAnswers, Profile } from "@offerlane/core";

export type AnswerSet = { profile: Profile; jobs: JobAnswers[]; at: string };

export async function getLocal<T>(key: string, fallback: T): Promise<T> {
  const v = (await chrome.storage.local.get(key))[key];
  return v === undefined ? fallback : (v as T);
}
export const setLocal = (key: string, value: unknown) => chrome.storage.local.set({ [key]: value });
