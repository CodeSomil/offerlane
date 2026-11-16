#!/usr/bin/env python3
"""WCAG contrast check for the design tokens used as text (App/Sources/DesignSystem/Tokens.swift).
Each text colour must reach 4.5:1 on the light and dark backgrounds it sits on, including the 12-14% tinted
pill/badge fills. Run by scripts/test.sh."""
import re, sys, pathlib
src = pathlib.Path(__file__).resolve().parent.parent / "App/Sources/DesignSystem/Tokens.swift"
tokens = dict(re.findall(r"static let (\w+) = dynamic\(light: 0x([0-9A-Fa-f]{6}), dark: 0x([0-9A-Fa-f]{6})\)", src.read_text()) and
              [(n, (l, d)) for n, l, d in re.findall(r"static let (\w+) = dynamic\(light: 0x([0-9A-Fa-f]{6}), dark: 0x([0-9A-Fa-f]{6})\)", src.read_text())])
def rgb(h): return [int(h[i:i+2], 16) / 255 for i in (0, 2, 4)]
def lum(c): return sum(w * (v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4) for w, v in zip((0.2126, 0.7152, 0.0722), c))
def ratio(a, b): la, lb = sorted((lum(a), lum(b)), reverse=True); return (la + 0.05) / (lb + 0.05)
def mix(fg, bg, alpha): return [f * alpha + b * (1 - alpha) for f, b in zip(fg, bg)]
BG = {"light": [rgb("FFFFFF"), rgb("ECECEC")], "dark": [rgb("1E1E1E"), rgb("2A2A2A"), rgb("24242C")]}
TEXT = ["accent", "offer", "warning", "danger", "info", "accentStrong", "textSecondary"]
fails = 0
for name in TEXT:
    light, dark = tokens[name]
    for mode, hexv in (("light", light), ("dark", dark)):
        fg = rgb(hexv)
        for bg in BG[mode]:
            for tint in (0, 0.14):   # plain background, and the tinted pill/badge fill behind the text
                r = ratio(fg, mix(fg, bg, tint))
                if r < 4.5:
                    fails += 1; print(f"FAIL {name} {mode} #{hexv} on bg{' +tint' if tint else ''}: {r:.2f}:1")
r = ratio(rgb("FFFFFF"), rgb(tokens["accentFill"][0])); r2 = ratio(rgb("FFFFFF"), rgb(tokens["accentFill"][1]))
if min(r, r2) < 4.5: fails += 1; print(f"FAIL white on accentFill {r:.2f}/{r2:.2f}")
# Glass: text sits on glassTint (alpha) over the backdrop colours, and screen headers sit on the backdrop directly.
glass = re.search(r"static let glassTint = dynamic\(light: 0x(\w{6}), dark: 0x(\w{6}), alpha: ([\d.]+)\)", src.read_text())
for mode, i in (("light", 0), ("dark", 1)):
    tint = rgb(glass.group(i + 1)); a = float(glass.group(3))
    for stop in ("backdropBase", "backdropA", "backdropB"):
        back = rgb(tokens[stop][i])
        for label, bg in (("on glass over", mix(tint, back, a)), ("on", back)):
            for name in TEXT + ["textPrimary"]:
                fg = rgb(("1D1D1F", "F5F5F7")[i]) if name == "textPrimary" else rgb(tokens[name][i])
                r = ratio(fg, bg)
                if r < 4.5: fails += 1; print(f"FAIL {name} {mode} {label} {stop}: {r:.2f}:1")
print("contrast: all text tokens >= 4.5:1" if not fails else f"contrast: {fails} failures"); sys.exit(1 if fails else 0)
