-- =====================================================================
-- Peek case study — B2 limitation: is 90 days the right churn window?
-- Dialect : BigQuery Standard SQL
--
-- Reproduces the figures of the README B2 limitation "90 days is too
-- short for this purchase cycle". Reads the model persisted by
-- sql/part1_queries.sql, so it uses exactly the same definitions
-- (completed sales, order-date months, new vs returning customers).
--
-- How to run
--   1. Run sql/part1_queries.sql with persist_dataset = 'peek_case'.
--   2. Run this script from the same Google Cloud project.
-- =====================================================================

DECLARE report_month DATE DEFAULT DATE '2026-09-01';   -- last complete month


-- ---------------------------------------------------------------------
-- Gap before each return: days between a customer's last order in the
-- previous active month and their first order in the month.
-- Grain: one row per returning customer x month.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE returns_with_gap AS
SELECT
  customer_id,
  order_month,
  DATE_DIFF(
    first_order_date_in_month,
    LAG(last_order_date_in_month)
      OVER (PARTITION BY customer_id ORDER BY order_month),
    DAY)                                                         AS days_since_previous_order
FROM peek_case.int_customer_months;


-- ---------------------------------------------------------------------
-- Query 1 — Customers who came back in report_month: share who had not
-- bought for more than 90 days, i.e. counted as churned before returning.
-- ---------------------------------------------------------------------
SELECT
  order_month                                                    AS month,
  COUNT(*)                                                       AS returning_customers,
  COUNTIF(days_since_previous_order > 90)                        AS returned_after_90_days,
  ROUND(COUNTIF(days_since_previous_order > 90) / COUNT(*) * 100, 1)
                                                                 AS pct_returned_after_90_days
FROM returns_with_gap
WHERE order_month = report_month
  AND days_since_previous_order IS NOT NULL
GROUP BY order_month;


-- ---------------------------------------------------------------------
-- Query 2 — Distribution of returns by days since the previous order
-- (full history), to choose a churn window from data.
-- Grain: one row per bucket of days. cumulative_pct_returns reads as
-- "share of returns that happen within N days": the window that covers
-- most returns is the one to consider.
-- ---------------------------------------------------------------------
WITH bucketed AS (
  SELECT
    CASE
      WHEN days_since_previous_order <= 30  THEN 1
      WHEN days_since_previous_order <= 60  THEN 2
      WHEN days_since_previous_order <= 90  THEN 3
      WHEN days_since_previous_order <= 180 THEN 4
      WHEN days_since_previous_order <= 365 THEN 5
      WHEN days_since_previous_order <= 730 THEN 6
      ELSE 7
    END                                                          AS bucket_order,
    CASE
      WHEN days_since_previous_order <= 30  THEN '0-30 days'
      WHEN days_since_previous_order <= 60  THEN '31-60 days'
      WHEN days_since_previous_order <= 90  THEN '61-90 days'
      WHEN days_since_previous_order <= 180 THEN '91-180 days'
      WHEN days_since_previous_order <= 365 THEN '181-365 days'
      WHEN days_since_previous_order <= 730 THEN '1-2 years'
      ELSE 'more than 2 years'
    END                                                          AS days_since_previous_order
  FROM returns_with_gap
  WHERE days_since_previous_order IS NOT NULL
)

SELECT
  days_since_previous_order,
  COUNT(*)                                                       AS returns,
  ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 1)               AS pct_returns,
  ROUND(SUM(COUNT(*)) OVER (ORDER BY bucket_order)
        / SUM(COUNT(*)) OVER () * 100, 1)                        AS cumulative_pct_returns
FROM bucketed
GROUP BY bucket_order, days_since_previous_order
ORDER BY bucket_order;
