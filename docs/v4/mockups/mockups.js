// Shared sidebar (v4 navigation: Today, Find, Pipeline, Grow, Profile) and the light/dark pair.
// Each page has one <section class="mac" data-active="..."> holding only its <main>; this adds the sidebar and a dark copy.
(() => {
  const items = [
    ["today", "☀", "Today", ""], ["find", "⌕", "Find", "18"], ["pipeline", "▦", "Pipeline", "9"],
  ];
  const sidebar = (active) => `
    <aside class="sidebar" aria-label="Navigation">
      <div class="lights" aria-hidden="true"><i></i><i></i><i></i></div>
      <div class="brand"><img src="../../../Branding/offerlane-icon.svg" alt="">Offerlane</div>
      ${items.map(([id, sym, name, n]) => `<a class="nav${id === active ? " on" : ""}" href="#"><span class="sym">${sym}</span>${name}<span class="count">${n}</span></a>`).join("")}
      <div class="group">Grow</div>
      <a class="nav sub" href="#">Goals</a><a class="nav sub" href="#">Skills</a><a class="nav sub" href="#">Interview</a>
      <a class="nav" href="#"><span class="sym">◉</span>Profile</a>
      <span class="ai-chip" title="AI connected and healthy">AI ready · OpenRouter</span>
    </aside>`;
  for (const mac of document.querySelectorAll(".mac")) {
    mac.insertAdjacentHTML("afterbegin", sidebar(mac.dataset.active));
    const wrap = document.createElement("div"), darkWrap = document.createElement("div");
    wrap.innerHTML = '<p class="label">Light</p>'; darkWrap.innerHTML = '<p class="label">Dark</p>';
    const dark = mac.cloneNode(true); dark.dataset.theme = "dark"; mac.dataset.theme = "light";
    mac.replaceWith(wrap); wrap.append(mac); darkWrap.append(dark); wrap.after(darkWrap);
  }
})();
