// The Mac sidebar (App/Sources/AppModel.swift SidebarItem): same ids, titles, groups and order.
export const GROUPS = ["Today", "Find", "Pipeline", "Grow", "Profile"] as const;
export const ITEMS = [
  { id: "home", title: "Today", group: "Today" },
  { id: "find", title: "Discover", group: "Find" },
  { id: "review", title: "Review", group: "Find" },
  { id: "applications", title: "Pipeline", group: "Pipeline" },
  { id: "interview", title: "Interview Prep", group: "Pipeline" },
  { id: "goals", title: "Goals", group: "Grow" },
  { id: "skills", title: "Skills", group: "Grow" },
  { id: "resumes", title: "Resumes", group: "Profile" },
  { id: "connectAI", title: "Connect AI", group: "Profile" },
  { id: "settings", title: "Settings", group: "Profile" },
] as const;
export type ViewId = (typeof ITEMS)[number]["id"];
// SHORTCUT: one view state + URL hash instead of a router library (H2); add a router if views need nested paths.
export const viewFromHash = (h: string): ViewId => ITEMS.find((i) => `#/${i.id}` === h)?.id ?? "home";
