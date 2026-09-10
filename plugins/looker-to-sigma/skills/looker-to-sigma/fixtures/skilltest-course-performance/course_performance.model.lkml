connection: "fixture"

include: "views/*.view.lkml"

explore: enrollment_metrics {
  label: "Course Performance"

  join: period_bridge {
    type: left_outer
    relationship: many_to_one
    sql_on:
      ${enrollment_metrics.period_date} = ${period_bridge.period_date}
      AND ${enrollment_metrics.content_domain} = ${period_bridge.content_domain} ;;
  }
}
