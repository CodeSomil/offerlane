#!/bin/bash
# The tagline is written only in Brand.swift (Brand.tagline); app code must use the constant. The old tagline is gone everywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
tag=$(sed -n 's/^ *static let tagline = "\(.*\)"$/\1/p' App/Sources/DesignSystem/Brand.swift)
[[ -n "$tag" ]] || { echo "brand: Brand.tagline not found" >&2; exit 1; }
dupes=$(grep -rnF -- "$tag" App/Sources Packages/OfferlaneCore/Sources | grep -v 'App/Sources/DesignSystem/Brand.swift' || true)
old=$(git grep -nIi -e 'lane from résumé to offer' -e 'lane from resume to offer' -- . ':!OFFERLANE_V4.md' ':!docs/PROGRESS.md' ':!scripts/check_brand.sh' || true)
[[ -z "$dupes" ]] || { echo "brand: tagline written outside Brand.swift (use Brand.tagline):"; echo "$dupes"; exit 1; }
[[ -z "$old" ]] || { echo "brand: old tagline still present:"; echo "$old"; exit 1; }
echo "brand: tagline only via Brand.tagline"
