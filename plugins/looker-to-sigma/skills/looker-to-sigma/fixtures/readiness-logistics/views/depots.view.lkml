view: depots {
  sql_table_name: LOGISTICS.PUBLIC.DEPOTS ;;

  dimension: depot_id {
    primary_key: yes
    type: number
    sql: ${TABLE}.depot_id ;;
  }

  dimension: depot_name {
    label: "Depot"
    type: string
    sql: ${TABLE}.dep_nm ;;
  }

  measure: depot_count {
    type: count
  }
}
