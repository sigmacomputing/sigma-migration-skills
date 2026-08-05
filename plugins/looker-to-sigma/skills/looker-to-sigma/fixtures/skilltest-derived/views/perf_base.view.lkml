# Fixture (synthetic demo data — no customer content). Exercises the
# derived-table performance scanner (detect_derived_perf.py).

# Simple ephemeral derived table, no persistence, trivial SQL → leave-inline.
view: perf_base {
  derived_table: {
    sql: SELECT id, region, amount FROM demo.sales ;;
  }
  dimension: id { primary_key: yes  sql: ${TABLE}.id ;; }
  dimension: region { sql: ${TABLE}.region ;; }
  measure: total_amount { type: sum  sql: ${TABLE}.amount ;; }
}
