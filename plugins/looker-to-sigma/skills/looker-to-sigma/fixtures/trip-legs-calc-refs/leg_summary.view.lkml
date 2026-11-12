view: leg_summary {
  derived_table: {
    sql: SELECT leg_id, distance_miles, fare_amt FROM db.s.fact_leg ;;
  }

  dimension: leg_id {
    primary_key: yes
    type: number
    sql: ${TABLE}.leg_id ;;
  }

  dimension: dist {
    type: number
    sql: ${TABLE}.distance_miles ;;
  }

  dimension: fare {
    type: number
    sql: ${TABLE}.fare_amt ;;
  }

  dimension: summary_band {
    type: string
    sql: CASE WHEN ${TABLE}.distance_miles > 100 THEN 'far' ELSE 'near' END ;;
  }

  dimension: fare_per_mile {
    type: number
    sql: ${fare} / NULLIF(${dist}, 0) ;;
  }
}
