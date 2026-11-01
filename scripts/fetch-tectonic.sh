#!/bin/bash
# Vendors tectonic (MIT) for the app bundle: the official 0.17.0 release for arm64 + x86_64 (checksums pinned),
# merged into one universal binary, plus a pre-warmed package cache so the first LaTeX build works offline.
# Output (git-ignored): Vendor/tectonic/bin/tectonic, Vendor/tectonic/cache/
set -euo pipefail
cd "$(dirname "$0")/.."
VER=0.17.0
ARM_SHA=a3f1cac7c5678f01661a92212f58480ae3b0634115d880dbc59e2953ded45667
X86_SHA=7c90ef5b6ddb1eb1937e4337add5237b79338e4b9676459fa91187d24d6cdf80
OUT=Vendor/tectonic; mkdir -p "$OUT/bin" "$OUT/cache"
if [[ ! -x "$OUT/bin/tectonic" ]]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  for arch in aarch64 x86_64; do
    url="https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%40$VER/tectonic-$VER-$arch-apple-darwin.tar.gz"
    curl -fsSL --retry 3 -o "$TMP/$arch.tgz" "$url"
    want=$([[ $arch == aarch64 ]] && echo $ARM_SHA || echo $X86_SHA)
    echo "$want  $TMP/$arch.tgz" | shasum -a 256 -c - >/dev/null
    mkdir -p "$TMP/$arch" && tar -xzf "$TMP/$arch.tgz" -C "$TMP/$arch"
  done
  lipo -create "$TMP/aarch64/tectonic" "$TMP/x86_64/tectonic" -output "$OUT/bin/tectonic"
  chmod +x "$OUT/bin/tectonic"
fi
lipo -archs "$OUT/bin/tectonic"
# Pre-warm: compile the sample resume and any resume templates passed as arguments (their packages land in the cache).
WARM="$(mktemp -d)"
for tex in Packages/OfferlaneCore/Tests/OfferlaneCoreTests/Fixtures/sample_resume.tex "$@"; do
  [[ -f "$tex" ]] || continue
  sed -E 's/^[[:space:]]*\\(input\{glyphtounicode\}|pdfgentounicode[[:space:]]*=[[:space:]]*1|pdfglyphtounicode).*$/% &/' "$tex" > "$WARM/r.tex"
  TECTONIC_CACHE_DIR="$PWD/$OUT/cache" "$OUT/bin/tectonic" --untrusted -o "$WARM" "$WARM/r.tex" >/dev/null 2>&1 && echo "warmed: $tex" || echo "warm failed: $tex"
done
rm -rf "$WARM"
du -sh "$OUT/cache"
