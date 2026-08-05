connection: "demo_wh"

include: "/views/*.view.lkml"

label: "Demo thelook"

# ---- Explore 1: order line fact (star schema, snowflake joins) ----
explore: order_fact {
  label: "Orders"
  description: "Order line fact joined to customer, product, store, order date and promotion dimensions."

  # Row-level security: restrict rows to the region(s) in the user's allowed_region user attribute.
  access_filter: {
    field: customer_dim.region
    user_attribute: allowed_region
  }

  join: customer_dim {
    type: left_outer
    sql_on: ${order_fact.customer_key} = ${customer_dim.customer_key} ;;
    relationship: many_to_one
  }
  join: product_dim {
    type: left_outer
    sql_on: ${order_fact.product_key} = ${product_dim.product_key} ;;
    relationship: many_to_one
  }
  join: store_dim {
    type: left_outer
    sql_on: ${order_fact.order_store_key} = ${store_dim.store_key} ;;
    relationship: many_to_one
  }
  join: order_date {
    from: date_dim
    type: left_outer
    sql_on: ${order_fact.order_date_key} = ${order_date.date_key} ;;
    relationship: many_to_one
  }
  join: promo_dim {
    type: left_outer
    sql_on: ${order_fact.promo_key} = ${promo_dim.promo_key} ;;
    relationship: many_to_one
  }
}

# ---- Explore 2: customer 360 (dim + derived-table summary) ----
explore: customer_dim {
  label: "Customer 360"
  description: "Customer dimension enriched with a derived-table lifetime order summary."

  join: customer_order_summary {
    type: left_outer
    sql_on: ${customer_dim.customer_key} = ${customer_order_summary.customer_key} ;;
    relationship: one_to_one
  }
}

# ---- Explore 3: secured orders (exercises explore-level access/filter features) ----
explore: orders_secure {
  from: order_fact
  label: "Orders (Secured)"
  description: "Exercises sql_always_where, always_filter, full_outer + field-limited joins."

  # row-level + default filters
  sql_always_where: ${orders_secure.order_status} != 'Cancelled' ;;
  always_filter: {
    filters: [orders_secure.order_channel: "Online,App"]
  }

  join: customer_dim {
    type: full_outer
    relationship: many_to_one
    sql_on: ${orders_secure.customer_key} = ${customer_dim.customer_key} ;;
    fields: [customer_dim.region, customer_dim.loyalty_tier, customer_dim.customer_segment]
  }
  join: product_dim {
    type: left_outer
    relationship: many_to_one
    sql_on: ${orders_secure.product_key} = ${product_dim.product_key} ;;
    fields: [product_dim.category, product_dim.brand]
  }
}

# ============================================================
# Benchmark additions (2026-06-22) — escalating-complexity tiers
# ============================================================

# Datagroup driving the customer_order_summary PDT persistence (T3).
datagroup: daily_refresh {
  sql_trigger: SELECT CURRENT_DATE ;;
  max_cache_age: "24 hours"
}

# Model access grant — gates order_fact.secured_net_profit (T4).
# Default-allows so existing dashboards are unaffected; converter still notes it.
access_grant: can_view_profit {
  user_attribute: can_view_profit
  allowed_values: ["yes"]
}

# ---- T1: trivial single-view explore (no joins, no RLS) ----
explore: product_catalog {
  from: product_dim
  label: "Product Catalog"
  description: "Single-view product dimension — no joins, no RLS (T1)."
}

# ---- T2: star-join orders explore (multi-join, NO RLS) ----
explore: orders_basic {
  from: order_fact
  label: "Orders (Basic)"
  description: "Order line fact joined to customer/product/order date. Star schema, no RLS (T2)."

  join: customer_dim {
    type: left_outer
    sql_on: ${orders_basic.customer_key} = ${customer_dim.customer_key} ;;
    relationship: many_to_one
  }
  join: product_dim {
    type: left_outer
    sql_on: ${orders_basic.product_key} = ${product_dim.product_key} ;;
    relationship: many_to_one
  }
  join: order_date {
    from: date_dim
    type: left_outer
    sql_on: ${orders_basic.order_date_key} = ${order_date.date_key} ;;
    relationship: many_to_one
  }
}

# ---- T4: secured orders explore (access_filter RLS + sql_always_where + access_grant) ----
explore: orders_secured {
  from: order_fact
  label: "Orders (Region-Secured)"
  description: "Region RLS via access_filter + sql_always_where + access-grant-gated profit (T4)."

  access_filter: {
    field: customer_dim.region
    user_attribute: allowed_region
  }
  sql_always_where: ${orders_secured.order_status} != 'Cancelled' ;;

  join: customer_dim {
    type: left_outer
    sql_on: ${orders_secured.customer_key} = ${customer_dim.customer_key} ;;
    relationship: many_to_one
  }
  join: order_date {
    from: date_dim
    type: left_outer
    sql_on: ${orders_secured.order_date_key} = ${order_date.date_key} ;;
    relationship: many_to_one
  }
}
