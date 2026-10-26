-- =====================================================================
-- Peek case study — A1 top finding: impact of month attribution
-- Dataset : bigquery-public-data.thelook_ecommerce
-- Dialect : BigQuery Standard SQL, standalone script (run it whole)
--
-- Finding: order_items.created_at does not match orders.created_at, so a
-- line item can fall in a different month than its order. This script
-- sizes the impact (README impact table) by comparing two attributions:
--   * by line item date : DATE_TRUNC(DATE(order_items.created_at), MONTH)
--   * by order date     : DATE_TRUNC(DATE(orders.created_at), MONTH)
--                         (the attribution used by part1_queries.sql)
-- Completed sales only (status 'Complete' and not returned).
-- =====================================================================

DECLARE as_of_date       DATE DEFAULT CURRENT_DATE();
DECLARE report_end_month DATE DEFAULT
  DATE_SUB(DATE_TRUNC(as_of_date, MONTH), INTERVAL 1 MONTH);   -- last complete month

-- Completed sales with both month attributions
CREATE TEMP TABLE completed_items AS
SELECT
  oi.order_id,
  CAST(oi.sale_price AS NUMERIC)                                 AS revenue,
  DATE_TRUNC(DATE(oi.created_at), MONTH)                         AS item_month,
  DATE_TRUNC(DATE(o.created_at), MONTH)                          AS order_month
FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
JOIN `bigquery-public-data.thelook_ecommerce.orders` AS o
  ON oi.order_id = o.order_id
WHERE oi.status = 'Complete'
  AND oi.returned_at IS NULL;


-- ---------------------------------------------------------------------
-- 1. Line items attributed to a different month than their order
--    (all line items, any status)
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                                                       AS order_items,
  COUNTIF(DATE_TRUNC(DATE(oi.created_at), MONTH)
          != DATE_TRUNC(DATE(o.created_at), MONTH))              AS items_in_different_month,
  ROUND(COUNTIF(DATE_TRUNC(DATE(oi.created_at), MONTH)
                != DATE_TRUNC(DATE(o.created_at), MONTH))
        / COUNT(*) * 100, 1)                                     AS pct_items_in_different_month
FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
JOIN `bigquery-public-data.thelook_ecommerce.orders` AS o
  ON oi.order_id = o.order_id;


-- ---------------------------------------------------------------------
-- 2. Revenue and MoM growth over the last 12 complete months
--    MoM is computed on the full history before filtering.
-- ---------------------------------------------------------------------
WITH
by_item_month AS (
  SELECT item_month AS month, SUM(revenue) AS revenue_by_item_month
  FROM completed_items
  GROUP BY item_month
),

by_order_month AS (
  SELECT order_month AS month, SUM(revenue) AS revenue_by_order_month
  FROM completed_items
  GROUP BY order_month
),

monthly AS (
  SELECT
    COALESCE(i.month, o.month)                                   AS month,
    IFNULL(i.revenue_by_item_month, 0)                           AS revenue_by_item_month,
    IFNULL(o.revenue_by_order_month, 0)                          AS revenue_by_order_month
  FROM by_item_month AS i
  FULL OUTER JOIN by_order_month AS o
    ON i.month = o.month
),

with_growth AS (
  SELECT
    month,
    revenue_by_item_month,
    revenue_by_order_month,
    SAFE_DIVIDE(revenue_by_item_month - revenue_by_order_month,
                revenue_by_order_month) * 100                    AS revenue_diff_pct,
    SAFE_DIVIDE(revenue_by_item_month - LAG(revenue_by_item_month) OVER w,
                LAG(revenue_by_item_month) OVER w) * 100
    - SAFE_DIVIDE(revenue_by_order_month - LAG(revenue_by_order_month) OVER w,
                  LAG(revenue_by_order_month) OVER w) * 100      AS mom_diff_pts
  FROM monthly
  WINDOW w AS (ORDER BY month)
)

SELECT
  ROUND(SUM(revenue_by_item_month), 2)                           AS total_revenue_by_item_month,
  ROUND(SUM(revenue_by_order_month), 2)                          AS total_revenue_by_order_month,
  ROUND(MIN(revenue_diff_pct), 2)                                AS min_monthly_revenue_diff_pct,
  ROUND(MAX(revenue_diff_pct), 2)                                AS max_monthly_revenue_diff_pct,
  ROUND(MAX(IF(month = report_end_month, revenue_diff_pct, NULL)), 2)
                                                                 AS reported_month_revenue_diff_pct,
  ROUND(MAX(ABS(mom_diff_pts)), 2)                               AS max_mom_diff_pts
FROM with_growth
WHERE month BETWEEN DATE_SUB(report_end_month, INTERVAL 11 MONTH)
                AND report_end_month;


-- ---------------------------------------------------------------------
-- 3. Orders counted in two months (full history)
--    By line item month, an order whose lines fall in two months is
--    counted in both; by order month, it is counted once.
-- ---------------------------------------------------------------------
WITH
orders_by_item_month AS (
  SELECT item_month, COUNT(DISTINCT order_id) AS orders
  FROM completed_items
  GROUP BY item_month
),

orders_by_order_month AS (
  SELECT order_month, COUNT(DISTINCT order_id) AS orders
  FROM completed_items
  GROUP BY order_month
)

SELECT
  (SELECT SUM(orders) FROM orders_by_item_month)                 AS sum_monthly_orders_by_item_month,
  (SELECT SUM(orders) FROM orders_by_order_month)                AS sum_monthly_orders_by_order_month,
  (SELECT SUM(orders) FROM orders_by_item_month)
  - (SELECT SUM(orders) FROM orders_by_order_month)              AS orders_double_counted;
