view: customer_dim {
  sql_table_name: DEMO_DB.DEMO.CUSTOMER_DIM ;;

  dimension: customer_key {
    primary_key: yes
    hidden: yes
    sql: ${TABLE}.CUSTOMER_KEY ;;
  }
  dimension: customer_id {
    label: "Customer ID"
    sql: ${TABLE}.CUSTOMER_ID ;;
  }
  dimension: first_name {
    sql: ${TABLE}.FIRST_NAME ;;
  }
  dimension: last_name {
    sql: ${TABLE}.LAST_NAME ;;
  }
  dimension: full_name {
    label: "Customer Name"
    sql: ${TABLE}.FIRST_NAME || ' ' || ${TABLE}.LAST_NAME ;;
  }
  dimension: email {
    sql: ${TABLE}.EMAIL ;;
  }
  dimension: city {
    sql: ${TABLE}.CITY ;;
  }
  dimension: state {
    sql: ${TABLE}.STATE ;;
  }
  dimension: region {
    label: "Region"
    sql: ${TABLE}.REGION ;;
  }
  dimension: customer_segment {
    label: "Customer Segment"
    sql: ${TABLE}.CUSTOMER_SEGMENT ;;
  }
  dimension: loyalty_tier {
    label: "Loyalty Tier"
    sql: ${TABLE}.LOYALTY_TIER ;;
  }
  dimension: acquisition_channel {
    label: "Acquisition Channel"
    sql: ${TABLE}.ACQUISITION_CHANNEL ;;
  }
  dimension: lifetime_revenue {
    type: number
    value_format_name: usd
    sql: ${TABLE}.LIFETIME_REVENUE ;;
  }

  measure: customer_count {
    label: "Customers"
    type: count_distinct
    sql: ${customer_key} ;;
  }
  measure: total_lifetime_revenue {
    label: "Lifetime Revenue"
    type: sum
    sql: ${TABLE}.LIFETIME_REVENUE ;;
    value_format_name: usd
  }
}
