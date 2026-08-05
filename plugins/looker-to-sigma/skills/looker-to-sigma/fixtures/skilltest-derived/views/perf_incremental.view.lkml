# Incremental PDT → materialize (Sigma has no incremental derived table).
view: perf_incremental {
  derived_table: {
    sql:
      SELECT event_date, region, SUM(amount) AS revenue
      FROM demo.events
      WHERE {% incrementcondition %} event_date {% endincrementcondition %}
      GROUP BY event_date, region ;;
    datagroup_trigger: demo_default_datagroup
    increment_key: "event_date"
    increment_offset: 3
  }
  dimension: event_date { type: date  sql: ${TABLE}.event_date ;; }
  measure: revenue { type: sum  sql: ${TABLE}.revenue ;; }
}
