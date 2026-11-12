view: shipments {
  sql_table_name: LOGISTICS.PUBLIC.SHIPMENTS ;;

  dimension: shipment_id {
    primary_key: yes
    type: number
    sql: ${TABLE}.shipment_id ;;
  }

  dimension: origin_depot_id {
    type: number
    hidden: yes
    sql: ${TABLE}.origin_depot_id ;;
  }

  dimension: carrier_id {
    type: number
    hidden: yes
    sql: ${TABLE}.carrier_id ;;
  }

  dimension: weight_kg {
    label: "Weight"
    type: number
    sql: ${TABLE}.wt ;;
  }

  dimension: destination_city {
    type: string
    sql: ${TABLE}."city_nm" ;;
  }

  dimension_group: shipped {
    type: time
    timeframes: [raw, date, month]
    sql: ${TABLE}.shipped_at ;;
  }

  measure: n {
    label: "Shipment Count"
    type: count
  }

  measure: total_weight {
    label: "Total Weight (kg)"
    type: sum
    sql: ${weight_kg} ;;
  }

  measure: avg_weight {
    type: average
    sql: ${weight_kg} ;;
  }
}
