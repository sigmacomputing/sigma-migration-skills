#!/usr/bin/env bash
# Offline regression for verify-workbook.sh: every unresolved-column marker
# Sigma embeds in compiled SQL must fail the gate. Stubs `curl` on PATH, so no
# Sigma credentials or network are needed (requires jq, like the script).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$HERE/verify-workbook.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/wb"

# Fake curl: the last argument is the URL. /elements lists $TMP/wb/elements.json;
# /elements/<eid>/query serves $TMP/wb/<eid>.json (404-ish empty body if absent).
cat >"$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
url="\${@: -1}"
case "\$url" in
  */elements) cat "$TMP/wb/elements.json" ;;
  */elements/*/query) eid="\${url%/query}"; eid="\${eid##*/}"; cat "$TMP/wb/\$eid.json" 2>/dev/null || true ;;
esac
STUB
chmod +x "$TMP/bin/curl"

export PATH="$TMP/bin:$PATH" SIGMA_BASE_URL="https://sigma.test" SIGMA_API_TOKEN="test-token"

FAILED=0
# set_element <eid> <sql> — register an element whose compiled SQL is <sql>
# (empty sql => non-queryable element, like a control).
set_element() {
  local eid="$1" sql="$2"
  if [ -n "$sql" ]; then jq -n --arg sql "$sql" '{sql: $sql}' >"$TMP/wb/$eid.json"; else rm -f "$TMP/wb/$eid.json"; fi
  jq -n --arg eid "$eid" '{elementId: $eid, name: ("el-" + $eid)}'
}
# run_case <label> <expected-exit> <expected-output-substring> <eid:sql>...
run_case() {
  local label="$1" want_rc="$2" want_out="$3"; shift 3
  rm -f "$TMP"/wb/*.json
  local entries=() pair
  for pair in "$@"; do entries+=("$(set_element "${pair%%:*}" "${pair#*:}")"); done
  printf '%s\n' "${entries[@]}" | jq -s '{entries: .}' >"$TMP/wb/elements.json"
  local out rc=0
  out="$(bash "$VERIFY" wb-test 2>&1)" || rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want_out"; then
    echo "ok   - $label"
  else
    echo "FAIL - $label (exit $rc, wanted $want_rc; wanted output containing: $want_out)"
    printf '%s\n' "$out" | sed 's/^/       /'
    FAILED=1
  fi
}

run_case "clean SQL passes" 0 "All 1 element(s) compile cleanly." \
  "a:select Region, sum(Amount) from t group by 1"

run_case "Unknown column literal fails" 1 'Unknown column "[ORDER_TOTAL]"' \
  "a:select 'Unknown column \"[ORDER_TOTAL]\"' V_44 from t"

run_case "Circular reference literal fails" 1 "Circular column reference to [Quarter]" \
  "a:select 'Circular column reference to [Quarter]' V_11 from t"

# Dropped data-model column: Sigma escapes the slash inside the brackets.
run_case "Column ... does not exist (escaped slash) fails" 1 \
  'Column "[Sales/inode-7Jj1KzywNyddp0npaXXyIl\/SALES_AMOUNT]" does not exist' \
  "a:select 'Column \"[Sales/inode-7Jj1KzywNyddp0npaXXyIl\\/SALES_AMOUNT]\" does not exist' V_5 from t"

run_case "Column ... does not exist (plain slash) fails" 1 \
  'Column "[OT Summary/OT_HOURS]" does not exist' \
  "a:select 'Column \"[OT Summary/OT_HOURS]\" does not exist' V_2 from t"

run_case "Column '...' does not exist (single quotes) fails" 1 \
  "does not exist" \
  "a:select 'Column ''[Element/col-id]'' does not exist' V_3 from t"

run_case "one bad element among clean ones fails the run" 1 "1 of 3 element(s)" \
  "a:select 1 from t" \
  "b:select 'Column \"[Sales/inode-x\\/AMT]\" does not exist' V_1 from t" \
  "c:select 2 from t"

run_case "non-queryable element is skipped, not failed" 0 "All 2 element(s) compile cleanly." \
  "a:select 1 from t" "ctl:"

exit "$FAILED"
