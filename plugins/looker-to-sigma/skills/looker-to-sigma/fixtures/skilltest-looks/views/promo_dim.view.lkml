view: promo_dim {
  sql_table_name: DEMO_DB.DEMO.PROMO_DIM ;;
  view_label: "Promotion"

  dimension: promo_key {
    primary_key: yes
    hidden: yes
    sql: ${TABLE}.PROMO_KEY ;;
  }
  dimension: promo_id {
    label: "Promo ID"
    group_label: "Promo Attributes"
    sql: ${TABLE}.PROMO_ID ;;
  }
  dimension: promo_name {
    label: "Promo Name"
    group_label: "Promo Attributes"
    sql: ${TABLE}.PROMO_NAME ;;
  }
  dimension: promo_type {
    label: "Promo Type"
    group_label: "Promo Attributes"
    sql: ${TABLE}.PROMO_TYPE ;;
  }
  dimension: channel {
    label: "Promo Channel"
    sql: ${TABLE}.CHANNEL ;;
  }
  dimension: discount_pct {
    type: number
    value_format_name: percent_1
    sql: ${TABLE}.DISCOUNT_PCT / 100.0 ;;
  }
  dimension: target_segment {
    label: "Target Segment"
    sql: ${TABLE}.TARGET_SEGMENT ;;
  }

  # legacy `case:` parameter (when/then/else) — distinct from a sql CASE expression
  dimension: discount_band {
    label: "Discount Band"
    case: {
      when: {
        sql: ${TABLE}.DISCOUNT_PCT >= 30 ;;
        label: "Deep (30%+)"
      }
      when: {
        sql: ${TABLE}.DISCOUNT_PCT >= 15 ;;
        label: "Medium (15-29%)"
      }
      else: "Light (<15%)"
    }
  }

  # duration dimension_group (days/weeks between two dates)
  dimension_group: campaign_length {
    type: duration
    intervals: [day, week]
    sql_start: ${TABLE}.START_DATE ;;
    sql_end: ${TABLE}.END_DATE ;;
  }

  measure: promo_count {
    label: "Promotions"
    type: count_distinct
    sql: ${promo_key} ;;
  }
  measure: avg_discount_pct {
    label: "Avg Discount %"
    type: average
    sql: ${TABLE}.DISCOUNT_PCT / 100.0 ;;
    value_format_name: percent_1
  }
}
