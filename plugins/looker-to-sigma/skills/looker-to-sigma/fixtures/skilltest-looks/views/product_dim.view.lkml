view: product_dim {
  sql_table_name: DEMO_DB.DEMO.PRODUCT_DIM ;;

  dimension: product_key {
    primary_key: yes
    hidden: yes
    sql: ${TABLE}.PRODUCT_KEY ;;
  }
  dimension: product_id {
    label: "Product ID"
    sql: ${TABLE}.PRODUCT_ID ;;
  }
  dimension: product_name {
    label: "Product Name"
    sql: ${TABLE}.PRODUCT_NAME ;;
  }
  dimension: category {
    label: "Category"
    sql: ${TABLE}.CATEGORY ;;
  }
  dimension: subcategory {
    label: "Subcategory"
    sql: ${TABLE}.SUBCATEGORY ;;
  }
  dimension: brand {
    label: "Brand"
    sql: ${TABLE}.BRAND ;;
  }
  dimension: is_private_label {
    type: yesno
    sql: ${TABLE}.IS_PRIVATE_LABEL = 1 ;;
  }
  dimension: is_seasonal {
    type: yesno
    sql: ${TABLE}.IS_SEASONAL = 1 ;;
  }

  measure: product_count {
    label: "Products"
    type: count_distinct
    sql: ${product_key} ;;
  }
}
