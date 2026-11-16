// @offerlane/core: the TypeScript port of the OfferlaneCore logic the web app and extension need (v4 P3, D2).
// Every function mirrors a Swift one; Packages/OfferlaneCore/Tests/OfferlaneCoreTests/Fixtures pins both ports.
export * from "./answers.js";
export * from "./models.js";
export * from "./pay.js";
export * from "./prompts.js";
export * from "./ranking.js";
export * from "./resume.js";
export * from "./pipeline.js";
export * from "./tailor.js";
export { stripHTML, stripTags, unescapeHTML, collapse, norm, trimSpaces, len, prefix } from "./text.js";
export * from "./adzuna.js";
export * from "./ai.js";
export * from "./sync.js";
export * from "./posting.js";
export * from "./apply.js";
export * from "./cdp.js";
export * from "./applySelfTest.js";
