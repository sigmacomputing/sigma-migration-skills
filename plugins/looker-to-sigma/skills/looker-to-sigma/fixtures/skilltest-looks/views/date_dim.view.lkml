view: date_dim {
  sql_table_name: DEMO_DB.DEMO.DATE_DIM ;;

  dimension: date_key {
    primary_key: yes
    hidden: yes
    sql: ${TABLE}.DATE_KEY ;;
  }

  dimension_group: order {
    label: "Order"
    type: time
    timeframes: [date, week, month, month_name, quarter, year]
    datatype: date
    sql: ${TABLE}.FULL_DATE ;;
  }

  dimension: day_of_week {
    label: "Day of Week"
    sql: ${TABLE}.DAY_OF_WEEK ;;
  }
  dimension: month_name {
    label: "Month Name"
    sql: ${TABLE}.MONTH_NAME ;;
  }
  dimension: month_number {
    type: number
    sql: ${TABLE}.MONTH_NUMBER ;;
  }
  dimension: quarter_number {
    type: number
    label: "Quarter"
    sql: ${TABLE}.QUARTER ;;
  }
  dimension: year {
    type: number
    sql: ${TABLE}.YEAR ;;
  }
  dimension: is_weekend {
    type: yesno
    sql: ${TABLE}.IS_WEEKEND = 1 ;;
  }
  dimension: is_holiday {
    type: yesno
    sql: ${TABLE}.IS_HOLIDAY = 1 ;;
  }
  dimension: fiscal_period {
    label: "Fiscal Period"
    sql: ${TABLE}.FISCAL_PERIOD ;;
  }
}
