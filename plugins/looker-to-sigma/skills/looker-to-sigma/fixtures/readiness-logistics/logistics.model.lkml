connection: "warehouse_demo"

include: "views/*.view.lkml"

explore: shipments {
  label: "Shipments"

  join: origin_depot {
    from: depots
    type: left_outer
    relationship: many_to_one
    sql_on: ${shipments.origin_depot_id} = ${origin_depot.depot_id} ;;
  }

  join: carriers {
    type: left_outer
    relationship: many_to_one
    sql_on: ${shipments.carrier_id} = ${carriers.carrier_id} ;;
  }
}
