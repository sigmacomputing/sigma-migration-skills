# Plain warehouse-table view (NO derived_table) → never a finding.
view: perf_plain {
  sql_table_name: DEMO.PUBLIC.PRODUCTS ;;
  dimension: product_id { primary_key: yes  sql: ${TABLE}.product_id ;; }
  dimension: category { sql: ${TABLE}.category ;; }
}
