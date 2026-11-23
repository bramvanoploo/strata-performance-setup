#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${REPO_ROOT}/plugins/registry.tsv"

_hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
  fi
}

tmp="${OUT_FILE}.tmp.$$"
: > "$tmp"

for cat in hosts tweaks; do
  dir="${REPO_ROOT}/plugins/${cat}"
  [[ -d "$dir" ]] || continue
  for f in "$dir"/*.sh; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" == _* && "$base" != "_common.sh" ]] && continue
    id="${base%.sh}"
    name="$(awk -F': ' '/^# PLUGIN_NAME:/ {print $2; exit}' "$f" || true)"
    desc="$(awk -F': ' '/^# PLUGIN_DESC:/ {print $2; exit}' "$f" || true)"
    plat="$(awk -F': ' '/^# PLUGIN_PLATFORMS:/ {print $2; exit}' "$f" || true)"
    sha="$(_hash_file "$f")"
    printf '%s\t%s\t%s\t%s\tplugins/%s/%s\t%s\t%s\n' \
      "$cat" "$id" "${name:-$id}" "${desc:-}" "$cat" "$base" "$sha" "${plat:-all}" >> "$tmp"
  done
done

mv -f "$tmp" "$OUT_FILE"
echo "Generated ${OUT_FILE} ($(wc -l < "$OUT_FILE") entries)."
