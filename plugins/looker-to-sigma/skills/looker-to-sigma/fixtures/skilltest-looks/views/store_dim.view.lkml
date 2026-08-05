view: store_dim {
  sql_table_name: DEMO_DB.DEMO.STORE_DIM ;;

  dimension: store_key {
    primary_key: yes
    hidden: yes
    sql: ${TABLE}.STORE_KEY ;;
  }
  dimension: store_id {
    label: "Store ID"
    sql: ${TABLE}.STORE_ID ;;
  }
  dimension: store_name {
    label: "Store Name"
    sql: ${TABLE}.STORE_NAME ;;
  }
  dimension: store_type {
    label: "Store Type"
    sql: ${TABLE}.STORE_TYPE ;;
  }
  dimension: city {
    sql: ${TABLE}.CITY ;;
  }
  dimension: state {
    sql: ${TABLE}.STATE ;;
  }
  dimension: region {
    label: "Store Region"
    sql: ${TABLE}.REGION ;;
  }
  dimension: district {
    label: "District"
    sql: ${TABLE}.DISTRICT ;;
  }

  measure: store_count {
    label: "Stores"
    type: count_distinct
    sql: ${store_key} ;;
  }
}
