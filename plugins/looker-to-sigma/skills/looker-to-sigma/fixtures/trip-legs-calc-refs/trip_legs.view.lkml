view: trip_legs {
  sql_table_name: db.s.fact_leg ;;

  dimension: leg_id {
    primary_key: yes
    type: number
    sql: ${TABLE}.leg_id ;;
  }

  dimension: dist {
    type: number
    sql: ${TABLE}.distance_miles ;;
  }

  dimension: price {
    type: number
    sql: ${TABLE}.price ;;
  }

  dimension: quantity {
    type: number
    sql: ${TABLE}.quantity ;;
  }

  dimension: status {
    type: string
    sql: ${TABLE}.status ;;
  }

  dimension: distance_band {
    type: string
    sql: CASE WHEN ${TABLE}.distance_miles > 100 THEN 'far' ELSE 'near' END ;;
  }

  dimension: is_long_haul {
    type: yesno
    sql: ${dist} > 500 ;;
  }

  dimension: haul_label {
    type: string
    sql: CASE WHEN ${is_long_haul} THEN 'long' ELSE 'short' END ;;
  }

  dimension: line_total {
    type: number
    sql: ${price} * ${quantity} ;;
  }

  dimension: medium_distance {
    type: yesno
    sql: ${dist} > 100 AND ${dist} < 500 ;;
  }

  dimension: active_status {
    type: yesno
    sql: ${status} = 'active' ;;
  }

  dimension: distance_alias {
    type: number
    sql: ${dist} ;;
  }

  dimension: alias_label {
    type: string
    sql: CASE WHEN ${distance_alias} > 100 THEN 'far' ELSE 'near' END ;;
  }

  parameter: unit_choice {
    type: unquoted
    allowed_value: { value: "miles" }
    allowed_value: { value: "km" }
  }

  dimension: param_only {
    type: string
    sql: ${unit_choice} ;;
  }

  dimension: param_label {
    type: string
    sql: CASE WHEN ${param_only} = 'miles' THEN 'miles' ELSE 'other' END ;;
  }

  measure: leg_count {
    type: count
  }
}
