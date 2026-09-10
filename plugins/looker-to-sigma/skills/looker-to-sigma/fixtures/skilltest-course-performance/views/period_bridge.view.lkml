view: period_bridge {
  derived_table: {
    sql:
      SELECT
        period_date,
        content_domain,
        SUM(enrollments) AS period_enrollments,
        LAG(SUM(enrollments)) OVER (
          PARTITION BY content_domain
          ORDER BY period_date
        ) AS prior_period_enrollments
      FROM FIXTURE.COURSE_FUNNEL
      GROUP BY period_date, content_domain ;;
  }

  dimension: period_date {
    type: date
    sql: ${TABLE}.period_date ;;
  }

  dimension: content_domain {
    type: string
    sql: ${TABLE}.content_domain ;;
  }

  dimension: period_enrollments {
    type: number
    sql: ${TABLE}.period_enrollments ;;
  }

  dimension: prior_period_enrollments {
    type: number
    sql: ${TABLE}.prior_period_enrollments ;;
  }
}
