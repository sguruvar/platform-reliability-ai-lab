#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IN_DIR="${ROOT_DIR}/diagrams"
OUT_DIR="${ROOT_DIR}/docs/diagrams"

mkdir -p "${OUT_DIR}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1" >&2; exit 1; }; }
need node
need npx

echo "Rendering Mermaid diagrams to ${OUT_DIR}"

# Use mermaid-cli via npx (no repo install needed).
# Outputs both SVG (crisp for web) and PNG (upload-friendly).
for f in "${IN_DIR}"/*.mmd; do
  base="$(basename "${f}" .mmd)"
  echo "- ${base}"
  npx -y @mermaid-js/mermaid-cli@latest -i "${f}" -o "${OUT_DIR}/${base}.svg" -b transparent >/dev/null
  npx -y @mermaid-js/mermaid-cli@latest -i "${f}" -o "${OUT_DIR}/${base}.png" -b transparent >/dev/null
done

echo "Done."

