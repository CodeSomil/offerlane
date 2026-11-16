// The user's records in IndexedDB (store.ts kv), read back through the libs/core lenient decoders so an old or
// hand-edited value never crashes a view. Everything stays on this device until sync (P3.7) encrypts it.
import { newProfile, profile, resumeVersion, type Profile, type ResumeVersion } from "@offerlane/core";
import { getItem, setItem } from "./store.js";

export const loadResume = async (): Promise<ResumeVersion | undefined> => { const v = await getItem("resume"); return v === undefined ? undefined : resumeVersion(v); };
export const saveResume = (v: ResumeVersion) => setItem("resume", v);
export const loadProfile = async (): Promise<Profile> => { const v = await getItem("profile"); return v === undefined ? newProfile() : profile(v); };
export const saveProfile = (p: Profile) => setItem("profile", p);
