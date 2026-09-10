connection: "offline"

explore: sales {
  from: chain_a
  join: buyers {
    from: customer
    relationship: many_to_one
    type: left_outer
    sql_on: ${sales.customer_id} = ${buyers.id} ;;
  }
}
