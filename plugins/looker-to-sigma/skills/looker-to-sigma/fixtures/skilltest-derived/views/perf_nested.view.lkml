# Nested, un-persisted derived table: references another derived view's
# SQL_TABLE_NAME (inlined as a stacked CTE) + joins + group by → materialize.
view: perf_nested {
  derived_table: {
    sql:
      SELECT b.region,
             COUNT(*) AS order_count,
             SUM(b.amount) AS revenue
      FROM ${perf_base.SQL_TABLE_NAME} b
      JOIN demo.customers c ON b.id = c.order_id
      GROUP BY b.region ;;
  }
  dimension: region { sql: ${TABLE}.region ;; }
  measure: revenue { type: sum  sql: ${TABLE}.revenue ;; }
}
