connection: "demo"

include: "/views/*.view.lkml"

explore: perf_explore {
  from: perf_nested
  join: perf_pdt {
    type: left_outer
    sql_on: ${perf_explore.region} = ${perf_pdt.region} ;;
    relationship: many_to_one
  }
}
