-- =====================================================================
-- Peek case study — B2 alternative: customer-base churn
-- Dataset : bigquery-public-data.thelook_ecommerce
-- Dialect : BigQuery Standard SQL, standalone script (does not need
--           part1_queries.sql). Run the whole script.
--
-- Why this file exists
-- The case defines churn transactionally: buyers of month M who do not
-- buy again within 90 days. That view needs 90 days to mature, so in the
-- October review the latest churn figure is June.
-- This file computes the alternative, a customer-base view:
--   * A customer is "alive" while their last completed order is at most
--     churn_window_days old. They LAPSE the day after, without a purchase.
--   * churn_window_days defaults to 365: 90 days misses most returns
--     (81% happen after 90 days, see sql/additional_analysis/b2_churn_window_check.sql).
--     Set it to 90 for a faster-reacting view that overstates churn.
--   * Base churn of month M = customers who lapse during M
--                             / customers alive at the start of M.
--   * Base flow: base_start + new + reactivated - churned = base_end.
-- Churn is dated when the loss happens, so month M is final at the end
-- of M: no immature months, same cadence as revenue and orders.
--
-- Same business rules as part1_queries.sql:
--   completed sale = status 'Complete' AND returned_at IS NULL;
--   dates = order date (orders.created_at); customer = order_items.user_id.
-- =====================================================================

DECLARE as_of_date       DATE DEFAULT DATE '2026-10-23';
DECLARE report_end_month DATE DEFAULT
  DATE_SUB(DATE_TRUNC(as_of_date, MONTH), INTERVAL 1 MONTH);
DECLARE churn_window_days INT64 DEFAULT 365;   -- days without purchase before a customer lapses

WITH

-- One row per customer x purchase day (several orders the same day count
-- once). Purchases after as_of_date are ignored.
completed_purchases AS (
  SELECT DISTINCT
    oi.user_id                                        AS customer_id,
    DATE(o.created_at)                                AS order_date
  FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
  JOIN `bigquery-public-data.thelook_ecommerce.orders` AS o
    ON oi.order_id = o.order_id
  WHERE oi.status = 'Complete'
    AND oi.returned_at IS NULL
    AND DATE(o.created_at) <= as_of_date
),

purchases AS (
  SELECT
    customer_id,
    order_date,
    LAG(order_date)  OVER w                           AS prev_order_date,
    LEAD(order_date) OVER w                           AS next_order_date
  FROM completed_purchases
  WINDOW w AS (PARTITION BY customer_id ORDER BY order_date)
),

-- Each purchase classified:
-- * first purchase  -> new customer
-- * previous purchase more than churn_window_days earlier -> reactivation
-- * no next purchase within churn_window_days -> the customer lapses the
--   day after the window ends
purchase_events AS (
  SELECT
    customer_id,
    order_date,
    prev_order_date IS NULL                           AS is_first_purchase,
    prev_order_date IS NOT NULL
      AND DATE_DIFF(order_date, prev_order_date, DAY) > churn_window_days
                                                      AS is_reactivation,
    IF(next_order_date IS NULL
         OR DATE_DIFF(next_order_date, order_date, DAY) > churn_window_days,
       DATE_ADD(order_date, INTERVAL churn_window_days + 1 DAY),
       NULL)                                          AS lapse_date
  FROM purchases
),

-- Reported months start once the base at the start of each month has a
-- full churn_window_days history (window rounded up to months, plus one).
months AS (
  SELECT month
  FROM UNNEST(GENERATE_DATE_ARRAY(
         DATE_ADD(DATE_TRUNC((SELECT MIN(order_date) FROM completed_purchases),
                             MONTH), INTERVAL DIV(churn_window_days + 29, 30) + 1 MONTH),
         report_end_month,
         INTERVAL 1 MONTH)) AS month
),

-- Alive at the start of M = at least one purchase in the churn_window_days
-- before M.
base_start AS (
  SELECT
    m.month,
    COUNT(DISTINCT p.customer_id)                     AS base_start
  FROM months AS m
  JOIN completed_purchases AS p
    ON p.order_date BETWEEN DATE_SUB(m.month, INTERVAL churn_window_days DAY)
                        AND DATE_SUB(m.month, INTERVAL 1 DAY)
  GROUP BY m.month
),

inflows AS (
  SELECT
    DATE_TRUNC(order_date, MONTH)                     AS month,
    COUNT(DISTINCT IF(is_first_purchase, customer_id, NULL)) AS new_customers,
    COUNT(DISTINCT IF(is_reactivation, customer_id, NULL))   AS reactivated_customers
  FROM purchase_events
  GROUP BY month
),

outflows AS (
  SELECT
    DATE_TRUNC(lapse_date, MONTH)                     AS month,
    COUNT(DISTINCT customer_id)                       AS churned_customers
  FROM purchase_events
  WHERE lapse_date IS NOT NULL
  GROUP BY month
),

monthly AS (
  SELECT
    m.month,
    IFNULL(b.base_start, 0)                           AS base_start,
    IFNULL(i.new_customers, 0)                        AS new_customers,
    IFNULL(i.reactivated_customers, 0)                AS reactivated_customers,
    IFNULL(o.churned_customers, 0)                    AS churned_customers
  FROM months AS m
  LEFT JOIN base_start AS b ON m.month = b.month
  LEFT JOIN inflows    AS i ON m.month = i.month
  LEFT JOIN outflows   AS o ON m.month = o.month
)

SELECT
  month,
  base_start,
  new_customers,
  reactivated_customers,
  churned_customers,
  base_start + new_customers + reactivated_customers - churned_customers
                                                      AS base_end,
  -- Validation: base_end must equal next month's base_start
  -- (NULL for the last month).
  LEAD(base_start) OVER (ORDER BY month)              AS base_start_next_month,
  ROUND(SAFE_DIVIDE(churned_customers, base_start) * 100, 2)
                                                      AS base_churn_rate_pct
FROM monthly
ORDER BY month;
