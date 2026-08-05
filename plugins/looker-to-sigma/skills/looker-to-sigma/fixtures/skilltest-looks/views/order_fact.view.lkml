view: order_fact {
  sql_table_name: DEMO_DB.DEMO.ORDER_FACT ;;

  # ---------- keys ----------
  dimension: order_line_id {
    primary_key: yes
    hidden: yes
    sql: ${order_id} || '-' || ${order_line} ;;
  }
  dimension: order_id {
    label: "Order ID"
    sql: ${TABLE}.ORDER_ID ;;
    # link: feature — drill to an external order page
    link: {
      label: "View order in OMS"
      url: "https://oms.example.com/orders/{{ value }}"
    }
  }
  dimension: order_line {
    type: number
    sql: ${TABLE}.ORDER_LINE ;;
  }
  dimension: customer_key {
    hidden: yes
    sql: ${TABLE}.CUSTOMER_KEY ;;
  }
  dimension: product_key {
    hidden: yes
    sql: ${TABLE}.PRODUCT_KEY ;;
  }
  dimension: order_store_key {
    hidden: yes
    sql: ${TABLE}.ORDER_STORE_KEY ;;
  }
  dimension: promo_key {
    hidden: yes
    sql: ${TABLE}.PROMO_KEY ;;
  }
  dimension: order_date_key {
    hidden: yes
    sql: ${TABLE}.ORDER_DATE_KEY ;;
  }

  # ---------- attribute dimensions ----------
  dimension: order_channel {
    label: "Order Channel"
    sql: ${TABLE}.ORDER_CHANNEL ;;
  }
  dimension: ship_method {
    label: "Ship Method"
    sql: ${TABLE}.SHIP_METHOD ;;
  }
  dimension: order_status {
    label: "Order Status"
    sql: ${TABLE}.ORDER_STATUS ;;
    # html: feature — colored status pill
    html: <span style="color: {% if value == 'Cancelled' %}#c0392b{% else %}#27ae60{% endif %}">{{ value }}</span> ;;
  }
  dimension: is_first_order {
    type: yesno
    sql: ${TABLE}.IS_FIRST_ORDER = 1 ;;
  }
  dimension: is_returned {
    type: yesno
    sql: ${TABLE}.IS_RETURNED = 1 ;;
  }
  dimension: is_cancelled {
    type: yesno
    sql: ${TABLE}.IS_CANCELLED = 1 ;;
  }

  # ---------- tier / bucket dimensions ----------
  dimension: order_value_tier {
    label: "Order Value Tier"
    type: tier
    tiers: [0, 25, 50, 100, 250, 500]
    style: integer
    sql: ${TABLE}.NET_REVENUE ;;
  }
  dimension: days_to_ship_tier {
    label: "Days to Ship Bucket"
    type: tier
    tiers: [0, 2, 5, 8]
    style: integer
    sql: ${TABLE}.DAYS_TO_SHIP ;;
  }

  # ---------- CASE / derived dimensions ----------
  dimension: profitability_band {
    label: "Profitability Band"
    sql:
      CASE
        WHEN ${TABLE}.NET_PROFIT < 0 THEN 'Loss'
        WHEN ${TABLE}.NET_PROFIT < 20 THEN 'Low'
        WHEN ${TABLE}.NET_PROFIT < 100 THEN 'Medium'
        ELSE 'High'
      END ;;
  }

  # ---------- numeric dimensions ----------
  dimension: net_revenue {
    type: number
    value_format_name: usd
    sql: ${TABLE}.NET_REVENUE ;;
  }
  dimension: net_profit {
    type: number
    value_format_name: usd
    sql: ${TABLE}.NET_PROFIT ;;
  }
  dimension: quantity_ordered {
    type: number
    sql: ${TABLE}.QUANTITY_ORDERED ;;
  }
  dimension: quantity_returned {
    type: number
    sql: ${TABLE}.QUANTITY_RETURNED ;;
  }
  dimension: unit_price {
    type: number
    value_format_name: usd
    sql: ${TABLE}.UNIT_PRICE ;;
  }
  dimension: days_to_ship {
    type: number
    sql: ${TABLE}.DAYS_TO_SHIP ;;
  }

  # ---------- measures: simple aggregates ----------
  measure: order_count {
    label: "Order Lines"
    type: count
  }
  measure: distinct_order_count {
    label: "Orders"
    type: count_distinct
    sql: ${order_id} ;;
  }
  measure: distinct_customers {
    label: "Active Customers"
    type: count_distinct
    sql: ${customer_key} ;;
  }
  measure: total_net_revenue {
    label: "Net Revenue"
    type: sum
    sql: ${TABLE}.NET_REVENUE ;;
    value_format_name: usd
    drill_fields: [order_id, order_channel, order_status, net_revenue]
  }
  measure: total_gross_revenue {
    label: "Gross Revenue"
    type: sum
    sql: ${TABLE}.GROSS_REVENUE ;;
    value_format_name: usd
  }
  measure: total_net_profit {
    label: "Net Profit"
    type: sum
    sql: ${TABLE}.NET_PROFIT ;;
    value_format_name: usd
  }
  measure: total_gross_profit {
    label: "Gross Profit"
    type: sum
    sql: ${TABLE}.GROSS_PROFIT ;;
    value_format_name: usd
  }
  measure: total_quantity {
    label: "Units Ordered"
    type: sum
    sql: ${TABLE}.QUANTITY_ORDERED ;;
  }

  # ---------- measures: statistical ----------
  measure: avg_unit_price {
    label: "Avg Unit Price"
    type: average
    sql: ${TABLE}.UNIT_PRICE ;;
    value_format_name: usd
  }
  measure: median_net_revenue {
    label: "Median Line Revenue"
    type: median
    sql: ${TABLE}.NET_REVENUE ;;
    value_format_name: usd
  }
  measure: p90_net_revenue {
    label: "P90 Line Revenue"
    type: percentile
    percentile: 90
    sql: ${TABLE}.NET_REVENUE ;;
    value_format_name: usd
  }

  # ---------- measures: filtered ----------
  measure: cancelled_order_count {
    label: "Cancelled Lines"
    type: count
    filters: [is_cancelled: "yes"]
  }
  measure: first_order_revenue {
    label: "First-Order Net Revenue"
    type: sum
    sql: ${TABLE}.NET_REVENUE ;;
    filters: [is_first_order: "yes"]
    value_format_name: usd
  }
  measure: returned_units {
    label: "Returned Units"
    type: sum
    sql: ${TABLE}.QUANTITY_RETURNED ;;
    filters: [is_returned: "yes"]
  }

  # ---------- measures: ratios (reference other measures) ----------
  measure: average_order_value {
    label: "Avg Order Value"
    type: number
    sql: 1.0 * ${total_net_revenue} / NULLIF(${distinct_order_count}, 0) ;;
    value_format_name: usd
  }
  measure: gross_margin_pct {
    label: "Gross Margin %"
    type: number
    sql: ${total_gross_profit} / NULLIF(${total_gross_revenue}, 0) ;;
    value_format_name: percent_1
  }
  measure: return_rate {
    label: "Return Rate"
    type: number
    sql: 1.0 * ${returned_units} / NULLIF(${total_quantity}, 0) ;;
    value_format_name: percent_1
  }

  # ---------- measure gated by a model access_grant (T4 security tier) ----------
  measure: secured_net_profit {
    label: "Net Profit (Secured)"
    type: sum
    sql: ${TABLE}.NET_PROFIT ;;
    value_format_name: usd
    required_access_grants: [can_view_profit]
  }

  # ---------- measures: custom value_format ----------
  measure: revenue_thousands {
    label: "Net Revenue ($K)"
    type: sum
    sql: ${TABLE}.NET_REVENUE / 1000.0 ;;
    value_format: "$#,##0.0\"K\""
  }

  # ---------- parameter + Liquid-templated measure ----------
  parameter: revenue_metric_picker {
    label: "Revenue Metric"
    type: unquoted
    allowed_value: {
      label: "Net Revenue"
      value: "NET_REVENUE"
    }
    allowed_value: {
      label: "Gross Revenue"
      value: "GROSS_REVENUE"
    }
    default_value: "NET_REVENUE"
  }
  measure: selected_revenue {
    label_from_parameter: revenue_metric_picker
    type: sum
    sql: ${TABLE}.{% parameter revenue_metric_picker %} ;;
    value_format_name: usd
  }

  set: order_detail {
    fields: [order_id, order_channel, order_status, net_revenue, total_net_revenue]
  }
}
