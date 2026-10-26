-- =====================================================================
-- Peek case study — Visual 3 (slide "Next steps and recommendations")
-- Dialect : BigQuery Standard SQL
--
-- Supports the recommendation slide; not part of the Part 1 deliverable.
-- Reads the models persisted by sql/part1_queries.sql, so it uses exactly
-- the same definitions (completed sales, order-date months, new vs
-- returning customers).
--
-- How to run
--   1. Run sql/part1_queries.sql with persist_dataset = 'peek_case'.
--   2. Run this script from the same Google Cloud project (peek_case is
--      resolved in the project running the query).
-- =====================================================================

DECLARE report_month DATE DEFAULT DATE '2026-09-01';   -- last complete month


-- ---------------------------------------------------------------------
-- Query 1 — Returning revenue by acquisition date (left chart)
-- Grain: one row per month, last 13 months up to report_month.
-- Splits returning customers by when they were acquired:
--   * recent      = first completed order in the 3 months before the month
--   * established = acquired earlier
-- The 3-month window is relative to each month (Sep 2026 -> Jun to Aug).
-- Shows that new customers also feed returning revenue, increasingly.
-- ---------------------------------------------------------------------
SELECT
  order_month                                                    AS month,
  COUNTIF(first_order_month >= DATE_SUB(order_month, INTERVAL 3 MONTH))
                                                                 AS returning_recent,
  COUNTIF(first_order_month <  DATE_SUB(order_month, INTERVAL 3 MONTH))
                                                                 AS returning_established,
  ROUND(SUM(IF(first_order_month >= DATE_SUB(order_month, INTERVAL 3 MONTH),
               revenue, 0)), 2)                                  AS revenue_recent,
  ROUND(SUM(IF(first_order_month <  DATE_SUB(order_month, INTERVAL 3 MONTH),
               revenue, 0)), 2)                                  AS revenue_established,
  ROUND(SAFE_DIVIDE(
    SUM(IF(first_order_month >= DATE_SUB(order_month, INTERVAL 3 MONTH), revenue, 0)),
    SUM(revenue)) * 100, 1)                                      AS pct_returning_revenue_recent
FROM peek_case.int_customer_months
WHERE NOT is_new_customer
  AND order_month BETWEEN DATE_SUB(report_month, INTERVAL 12 MONTH) AND report_month
GROUP BY month
ORDER BY month;


-- ---------------------------------------------------------------------
-- Query 2 — New customers by acquisition channel (right table)
-- Grain: one row per traffic_source, for report_month.
-- channel_type: Organic = Free, every other channel = Paid.
-- assumed_cost_rank / level: ASSUMED relative budget (no cost data in the
-- dataset), based on typical e-commerce spend; 1 = highest, 5 = lowest.
--   Search   : paid search, competitive auctions, usually the largest budget
--   Facebook : social ads, interest targeting, awareness and retargeting
--   Organic  : SEO salaries, content and agencies, smoothed over time
--   Display  : low CPM, but large awareness campaigns add up
--   Email    : platform and staff costs low compared with volumes
-- ---------------------------------------------------------------------
SELECT
  u.traffic_source,
  IF(u.traffic_source = 'Organic', 'Free', 'Paid')      AS channel_type,
  CASE u.traffic_source
    WHEN 'Search'   THEN 1
    WHEN 'Facebook' THEN 2
    WHEN 'Organic'  THEN 3
    WHEN 'Display'  THEN 4
    WHEN 'Email'    THEN 5
  END                                                   AS assumed_cost_rank,
  CASE u.traffic_source
    WHEN 'Search'   THEN 'Highest'
    WHEN 'Facebook' THEN 'High'
    WHEN 'Organic'  THEN 'Medium'
    WHEN 'Display'  THEN 'Low'
    WHEN 'Email'    THEN 'Lowest'
  END                                                   AS assumed_cost_level,
  COUNT(*)                                              AS new_customers,
  ROUND(SUM(cm.revenue), 2)                             AS revenue,
  ROUND(SUM(cm.revenue) / SUM(SUM(cm.revenue)) OVER () * 100, 1) AS pct_new_revenue
FROM peek_case.int_customer_months AS cm
JOIN `bigquery-public-data.thelook_ecommerce.users` AS u
  ON cm.customer_id = u.id
WHERE cm.order_month = report_month
  AND cm.is_new_customer
GROUP BY 1, 2, 3, 4
ORDER BY assumed_cost_rank;
