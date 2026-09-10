view: enrollment_metrics {
  derived_table: {
    sql:
      SELECT
        period_date,
        content_domain,
        country_group,
        SUM(enrollments) AS enrollments,
        SUM(module_1_completions) AS module_1_completions,
        SUM(course_completions) AS course_completions,
        SUM(freemium_conversions) AS freemium_conversions,
        AVG(active_days_30) AS active_days_30,
        MAX(overall_revenue_rank) AS overall_revenue_rank
      FROM FIXTURE.COURSE_FUNNEL
      GROUP BY period_date, content_domain, country_group ;;
  }

  parameter: funnel_metric {
    type: unquoted
    default_value: "enrollments"
    allowed_value: { label: "Enrollments" value: "enrollments" }
    allowed_value: { label: "Module 1 Completion Rate" value: "m1_rate" }
    allowed_value: { label: "F30D" value: "f30d" }
    allowed_value: { label: "Course Completion Rate" value: "completion_rate" }
    allowed_value: { label: "Freemium Conversion Rate" value: "conversion_rate" }
  }

  parameter: group_by {
    type: unquoted
    default_value: "content_domain"
    allowed_value: { label: "Content Domain" value: "content_domain" }
    allowed_value: { label: "Country Group" value: "country_group" }
  }

  parameter: time_grain {
    type: unquoted
    default_value: "month"
    allowed_value: { label: "Month" value: "month" }
    allowed_value: { label: "Week" value: "week" }
  }

  dimension: period_date {
    type: date
    sql: ${TABLE}.period_date ;;
  }

  dimension: content_domain {
    type: string
    sql: ${TABLE}.content_domain ;;
  }

  dimension: country_group {
    type: string
    sql: ${TABLE}.country_group ;;
  }

  dimension: overall_revenue_rank {
    type: number
    sql: ${TABLE}.overall_revenue_rank ;;
  }

  dimension: enrollments {
    hidden: yes
    type: number
    sql: ${TABLE}.enrollments ;;
  }

  dimension: module_1_completions {
    hidden: yes
    type: number
    sql: ${TABLE}.module_1_completions ;;
  }

  dimension: course_completions {
    hidden: yes
    type: number
    sql: ${TABLE}.course_completions ;;
  }

  dimension: freemium_conversions {
    hidden: yes
    type: number
    sql: ${TABLE}.freemium_conversions ;;
  }

  dimension: active_days_30 {
    hidden: yes
    type: number
    sql: ${TABLE}.active_days_30 ;;
  }

  dimension: selected_metric {
    label: "Selected Funnel Metric"
    type: number
    sql:
      {% if funnel_metric._parameter_value == 'm1_rate' %}
        1.0 * ${TABLE}.module_1_completions / NULLIF(${TABLE}.enrollments, 0)
      {% elsif funnel_metric._parameter_value == 'f30d' %}
        ${TABLE}.active_days_30
      {% elsif funnel_metric._parameter_value == 'completion_rate' %}
        1.0 * ${TABLE}.course_completions / NULLIF(${TABLE}.enrollments, 0)
      {% elsif funnel_metric._parameter_value == 'conversion_rate' %}
        1.0 * ${TABLE}.freemium_conversions / NULLIF(${TABLE}.enrollments, 0)
      {% else %}
        ${TABLE}.enrollments
      {% endif %} ;;
  }

  dimension: selected_group {
    label: "Selected Group"
    type: string
    sql:
      {% if group_by._parameter_value == 'country_group' %}
        ${TABLE}.country_group
      {% else %}
        ${TABLE}.content_domain
      {% endif %} ;;
  }

  dimension: selected_period {
    label: "Selected Period"
    type: date
    sql:
      {% if time_grain._parameter_value == 'week' %}
        DATE_TRUNC('WEEK', ${TABLE}.period_date)
      {% else %}
        DATE_TRUNC('MONTH', ${TABLE}.period_date)
      {% endif %} ;;
  }

  measure: selected_metric_sum {
    label: "Selected Metric Sum"
    type: sum
    sql: ${selected_metric} ;;
  }

  measure: enrollments_total {
    type: sum
    sql: ${enrollments} ;;
  }
}
