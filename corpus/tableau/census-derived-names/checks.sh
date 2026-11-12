#!/usr/bin/env bash
# census-derived-names — executable expectations (offline, creds-free).
#
# A store-operations dashboard whose census held YELLOW although every value
# and visual gate passed:
#   1. The gap scan translates both calcs (Revenue Rank chart_only via the RANK
#      window translator, Low Margin Flag spec), so neither is a converter gap.
#   2. The builder emits them under DERIVED column names — the table calc under
#      its Tableau CSV export header ("Revenue Rank along Store Name") and the
#      Color-shelf flag as its hidden "(flag)" conditional-format driver. The
#      census must account both migrated against that built spec, not
#      needs-review ("no matching built column").
#   3. parse-twb-layout stamps the map styling signal; build-charts' plan
#      carries the light basemap (mapStyle.baseStyle) and names exactly two
#      residuals (washout, 8-step ramp) keyed to their candidate catalog ids.
set -euo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
S="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

cp "$CASE_DIR/workbook-content.twb" "$CASE_DIR/wb-spec.json" "$CASE_DIR/chart-provenance.json" "$TMP/"
(cd "$TMP" && ruby "$S/scan-workbook-gaps.rb" workbook-content.twb >/dev/null 2>&1)
ruby "$S/parse-twb-layout.rb" "$TMP/workbook-content.twb" "$TMP/dashboard-layout.json" >/dev/null 2>&1
echo '{"status":"PASS"}' > "$TMP/parity-final.json"
ruby "$S/build-source-object-census.rb" --workdir "$TMP" >/dev/null

python3 - "$TMP" <<'PY'
import json, os, sys
d = sys.argv[1]
audit = {r["caption"]: r for r in json.load(open(os.path.join(d, "formula-audit.json"), encoding="utf-8"))["formulas"]}
assert audit["Revenue Rank"]["status"] == "chart_only", audit["Revenue Rank"]
assert audit["Revenue Rank"]["sigma_formula"] == 'Rank(Sum([Net Revenue]), "desc")', audit["Revenue Rank"]
assert audit["Low Margin Flag"]["status"] == "spec", audit["Low Margin Flag"]
census = json.load(open(os.path.join(d, "source-object-census.json"), encoding="utf-8"))
calcs = {o["name"]: o for o in census["objects"] if o["type"] == "calculation"}
for name in ("Revenue Rank", "Low Margin Flag"):
    assert calcs[name]["status"] == "migrated", (name, calcs[name])
layout = json.load(open(os.path.join(d, "dashboard-layout.json"), encoding="utf-8"))
zone = next(z for dash in layout for z in dash["zones"] if z.get("caption") == "Store State Map" and z.get("kind") == "chart")
assert zone["map_style"] == {"formats": {"washout": "0.25", "map-style": "light"}, "sources": ["Tableau"], "color_steps": 8}, zone.get("map_style")
json.dump(zone["map_style"], open(os.path.join(d, "map-style.json"), "w"))
PY

ruby -rjson -e '
  src = File.read(ARGV[0])
  eval(src[/^# ---- Tableau map styling → Sigma region-map mapStyle -+\n.*?(?=^def platform_difference_ids)/m])
  plan = region_map_style_plan(JSON.parse(File.read(ARGV[1])))
  abort "baseStyle #{plan[:base_style].inspect}" unless plan[:base_style] == "light"
  ids = plan[:residuals].map { |r| r[:catalog_id] }
  abort "residual ids #{ids.inspect}" unless ids == %w[map-basemap-washout map-stepped-color-scale]
  abort "open with both catalogued" unless map_open_residuals(plan[:residuals], ids).empty?
' "$S/build-charts-from-signals.rb" "$TMP/map-style.json"
echo "census-derived-names: ok"
