view: chain_a {
  sql_table_name: DEMO.SALES ;;
  dimension: id { primary_key: yes sql: ${TABLE}.ID ;; }
  dimension: customer_id { sql: ${TABLE}.CUSTOMER_ID ;; }
  dimension: amount { type: number sql: ${TABLE}.AMOUNT ;; }
  measure: total { type: sum sql: ${amount} ;; }
  measure: doubled { type: number sql: ${total} * 2 ;; }
  measure: quadrupled { type: number sql: ${doubled} * 2 ;; }
  measure: broken { type: number sql: ${does_not_exist} * 2 ;; }
}

view: customer {
  sql_table_name: DEMO.CUSTOMER ;;
  dimension: id { primary_key: yes sql: ${TABLE}.ID ;; }
}

view: cycle_a {
  extends: [cycle_b]
  dimension: a { sql: ${TABLE}.A ;; }
}

view: cycle_b {
  extends: [cycle_a]
  dimension: b { sql: ${TABLE}.B ;; }
}
