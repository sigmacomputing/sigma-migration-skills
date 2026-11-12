view: carriers {
  sql_table_name: LOGISTICS.PUBLIC.CARRIERS ;;

  dimension: carrier_id {
    primary_key: yes
    type: number
    sql: ${TABLE}.carrier_id ;;
  }

  dimension: carrier_name {
    type: string
    sql: ${TABLE}.carrier_name ;;
  }

  measure: carrier_count {
    label: "Carriers"
    type: count_distinct
    sql: ${carrier_id} ;;
  }
}
