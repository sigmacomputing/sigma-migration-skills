# Persisted PDT (datagroup_trigger) → materialize (author deemed it expensive).
view: perf_pdt {
  derived_table: {
    sql: SELECT region, SUM(amount) AS revenue FROM demo.sales GROUP BY region ;;
    datagroup_trigger: demo_default_datagroup
    cluster_keys: ["region"]
  }
  dimension: region { sql: ${TABLE}.region ;; }
  measure: revenue { type: sum  sql: ${TABLE}.revenue ;; }
}
