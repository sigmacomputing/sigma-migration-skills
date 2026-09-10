- dashboard: skilltest_course_performance
  title: SKILLTEST Course Performance Diagnostic
  layout: newspaper
  preferred_viewer: dashboards-next

  filters:
  - name: Content Domain
    title: Content Domain
    type: field_filter
    model: course_performance
    explore: enrollment_metrics
    field: enrollment_metrics.content_domain
    allow_multiple_values: true

  elements:
  - name: Dimensions View
    title: Dimensions View
    model: course_performance
    explore: enrollment_metrics
    type: table
    fields:
    - enrollment_metrics.selected_period
    - enrollment_metrics.selected_group
    - enrollment_metrics.selected_metric
    listen:
      Content Domain: enrollment_metrics.content_domain
    row: 0
    col: 0
    width: 24
    height: 8

  - name: Ratio Bridge
    title: Ratio Bridge
    model: course_performance
    explore: enrollment_metrics
    type: table
    fields:
    - enrollment_metrics.period_date
    - enrollment_metrics.content_domain
    - period_bridge.period_enrollments
    - period_bridge.prior_period_enrollments
    listen:
      Content Domain: enrollment_metrics.content_domain
    row: 8
    col: 0
    width: 24
    height: 8

  - name: Volatility
    title: Volatility
    model: course_performance
    explore: enrollment_metrics
    type: table
    fields:
    - enrollment_metrics.period_date
    - enrollment_metrics.content_domain
    - enrollment_metrics.enrollments_total
    dynamic_fields:
    - table_calculation: rolling_mean
      label: Rolling Mean
      expression: "moving_average(${enrollment_metrics.enrollments_total}, 2)"
    row: 16
    col: 0
    width: 24
    height: 8

  - name: Title Level
    title: Title Level
    model: course_performance
    explore: enrollment_metrics
    type: table
    fields:
    - enrollment_metrics.content_domain
    - enrollment_metrics.country_group
    - enrollment_metrics.overall_revenue_rank
    - enrollment_metrics.enrollments_total
    filters:
      enrollment_metrics.overall_revenue_rank: "NOT NULL"
    listen:
      Content Domain: enrollment_metrics.content_domain
    row: 24
    col: 0
    width: 24
    height: 8
