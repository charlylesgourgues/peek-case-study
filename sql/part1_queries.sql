-- =====================================================================
-- Peek case study — Part 1 (Tasks A & B)
-- Dataset : bigquery-public-data.thelook_ecommerce
-- Dialect : BigQuery Standard SQL, multi-statement script
-- Run     : execute the WHOLE script in one go. Each layer is a TEMP TABLE
--           that only lives for the duration of the script.
--
-- Sections follow the exercise: A1 (data quality) -> A2 (base model)
-- -> A3 (monthly health) -> B.
-- Method note: A2 and A3 were designed first, so the A1 checks could be
-- focused on the data the published metrics actually depend on. A1 is
-- placed first because it runs on the RAW tables, independently of any
-- transformation (a bug in a model cannot hide a source issue).
--
-- Layering (dbt-style, simulated with temp tables):
--   stg_*  : one model per source table. Rename, cast, nothing business-specific.
--   int_*  : business logic and grain decisions.
--   mart_* : aggregates consumed by dashboards (A3, B1, B2).
-- In a real project, each temp table would be a dbt model and the A1 checks
-- would be dbt source tests.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Parameters
-- BigQuery requires every DECLARE at the top of the script.
-- The base model is deliberately NOT date-filtered: "first-ever completed
-- order" (B1, cohorts) needs the full history. Date parameters only apply
-- to checks, marts and outputs.
--
-- as_of_date          : reference date. Defaults to today, so the window
--                       always ends at the last complete month (revenue,
--                       mix) and churn shows mature months only. Set a
--                       fixed date to reproduce a past report, e.g.
--                       DATE '2026-10-23' for the figures in the README.
--                       Note: the public dataset keeps growing, including
--                       past dates, so figures can still move slightly.
-- report_start_month  : first reported month. NULL = first COMPLETE month
--                       of order data (computed below).
-- report_end_month    : last reported month. NULL = last complete month
--                       before as_of_date (computed below).
-- persist_dataset     : BigQuery dataset where the tables behind the charts
--                       are saved (temp tables vanish after the script),
--                       e.g. 'peek_case'. Without a project prefix, it is
--                       created in the project running the query, in the
--                       US region (created if it does not exist).
--                       NULL = nothing is written (default, so anyone can
--                       run the script without creating anything).
-- ---------------------------------------------------------------------
DECLARE as_of_date         DATE   DEFAULT CURRENT_DATE();
DECLARE report_start_month DATE   DEFAULT NULL;
DECLARE report_end_month   DATE   DEFAULT NULL;
DECLARE persist_dataset    STRING DEFAULT NULL;

-- Resolve reporting window (incomplete months are excluded)
-- * End   : last complete month before as_of_date (the as_of_date month
--           is still running).
-- * Start : first complete month of order data (the first month of the
--           dataset may start mid-month). Computed on raw orders, all
--           statuses: it describes data coverage, not a business rule.
--           orders.created_at is the date used for month attribution
--           (see A2).
-- Explicit values in the DECLAREs above take precedence.
SET report_end_month = IFNULL(
  report_end_month,
  DATE_SUB(DATE_TRUNC(as_of_date, MONTH), INTERVAL 1 MONTH)
);

SET report_start_month = IFNULL(
  report_start_month,
  (
    SELECT
      IF(EXTRACT(DAY FROM MIN(DATE(created_at))) = 1,
         DATE_TRUNC(MIN(DATE(created_at)), MONTH),
         DATE_ADD(DATE_TRUNC(MIN(DATE(created_at)), MONTH), INTERVAL 1 MONTH))
    FROM `bigquery-public-data.thelook_ecommerce.orders`
  )
);


-- =====================================================================
-- A1. Data quality checks
--
-- All checks run on the RAW source tables, not on stg_ / int_ models, so
-- that a transformation cannot introduce or hide an issue.
-- Scope: only data the published metrics depend on (lineage of A2 -> A3).
-- Output: one row per check (check_name, severity, failed_rows,
-- total_rows, pct_failed).
-- severity: error = would distort a published figure; warn = to monitor.
-- =====================================================================

CREATE TEMP TABLE a1_data_quality AS
WITH

-- 1a. Duplicated order item ids.
--     A duplicate inflates revenue, units and orders at once.
--     failed_rows = every row whose id appears more than once (all copies
--     are counted, since we cannot tell which one is the right one).
--     NULL ids are excluded here (GROUP BY would group them together) and
--     covered by check 1b, so the two checks do not overlap.
--     dbt equivalent: unique on order_items.id
duplicated_order_item_ids AS (
  SELECT
    id,
    COUNT(*)                                          AS row_count
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE id IS NOT NULL
  GROUP BY id
  HAVING COUNT(*) > 1
),

chk_duplicate_order_items AS (
  SELECT
    'order_items: duplicated id'                      AS check_name,
    'error'                                           AS severity,
    (SELECT IFNULL(SUM(row_count), 0)
     FROM duplicated_order_item_ids)                  AS failed_rows,
    (SELECT COUNT(*)
     FROM `bigquery-public-data.thelook_ecommerce.order_items`) AS total_rows
),

-- 1b. NULL order item ids.
--     A line without an id cannot be deduplicated or traced back.
--     dbt equivalent: not_null on order_items.id
chk_null_order_item_ids AS (
  SELECT
    'order_items: NULL id'                            AS check_name,
    'error'                                           AS severity,
    COUNTIF(id IS NULL)                               AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

-- 2. Orders without any order item.
--    Line items are the source of every sales metric: an order without
--    items means sales data may be missing.
--    dbt equivalent: relationships (orders.order_id -> order_items.order_id)
chk_orders_without_items AS (
  SELECT
    'orders: no matching order_items'                 AS check_name,
    'error'                                           AS severity,
    COUNTIF(oi.order_id IS NULL)                      AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.orders` AS o
  LEFT JOIN (SELECT DISTINCT order_id
             FROM `bigquery-public-data.thelook_ecommerce.order_items`) AS oi
    ON o.order_id = oi.order_id
),

-- 5. Status vs returned_at consistency.
--    The completed-sale convention relies on BOTH fields
--    (status = 'Complete' AND returned_at IS NULL). If they contradict
--    each other, the revenue perimeter depends on which field is trusted.
--    Failed = 'Returned' without returned_at, or returned_at set with any
--    other status.
--    dbt equivalent: custom test (expression_is_true)
chk_status_vs_returned_at AS (
  SELECT
    'order_items: status inconsistent with returned_at' AS check_name,
    'error'                                           AS severity,
    COUNTIF(
      (status = 'Returned' AND returned_at IS NULL)
      OR (status != 'Returned' AND returned_at IS NOT NULL)
    )                                                 AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

-- 6. Order items dated in the future (after the run time).
--    A sale cannot be recorded before it happens: created_at later than
--    the moment the script runs is a data anomaly, independent of any
--    reporting parameter (rows after as_of_date are normal when as_of_date
--    is set in the past).
--    Monthly reporting is protected, since the window stops at the last
--    complete month; any period-to-date figure (month to date, last N
--    days) would include sales that have not happened yet.
--    The result depends on the run time, as for any freshness test.
--    dbt equivalent: custom test / source freshness
chk_future_dated_order_items AS (
  SELECT
    'order_items: created_at in the future (after run time)' AS check_name,
    'error'                                           AS severity,
    COUNTIF(created_at > CURRENT_TIMESTAMP())         AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

-- 6b. Orders dated in the future (after the run time).
--     Same test at order level: an order cannot be created before it
--     happens. Compared with check 6, it shows whether the anomaly sits on
--     the order itself or only on some of its line items.
--     dbt equivalent: custom test / source freshness
chk_future_dated_orders AS (
  SELECT
    'orders: created_at in the future (after run time)' AS check_name,
    'error'                                           AS severity,
    COUNTIF(created_at > CURRENT_TIMESTAMP())         AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.orders`
),

-- 6c. Order items attributed to a different month than their order.
--     TOP FINDING. order_items.created_at differs from orders.created_at
--     for almost every line (from before the order up to ~96 h after it),
--     so month attribution depends on which timestamp is used: the same
--     order can be split across two months, shifting revenue between
--     months (up to about +/-2.5% of monthly revenue over the last 12
--     months), moving MoM growth by up to ~2 points and counting an order
--     in two months.
--     Handling: month attribution uses orders.created_at (see A2);
--     escalate to the team owning the order system.
--     dbt equivalent: custom test (expression_is_true on a join)
chk_item_vs_order_month AS (
  SELECT
    'order_items: different month than their order'   AS check_name,
    'error'                                           AS severity,
    COUNTIF(DATE_TRUNC(DATE(oi.created_at), MONTH)
            != DATE_TRUNC(DATE(o.created_at), MONTH)) AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
  JOIN `bigquery-public-data.thelook_ecommerce.orders` AS o
    ON oi.order_id = o.order_id
),

-- Used by check 9: one row per non-NULL session, with funnel
-- event counts. NULL session_ids are excluded.
raw_sessions AS (
  SELECT
    session_id,
    COUNTIF(event_type = 'department')                AS department_events,
    COUNTIF(event_type = 'purchase')                  AS purchase_events
  FROM `bigquery-public-data.thelook_ecommerce.events`
  WHERE session_id IS NOT NULL
  GROUP BY session_id
),

-- 9. Sessions with a purchase but no department event.
--    If any, the literal case definition (purchase sessions / department
--    sessions) and the funnel-consistent one used in A3 (department AND
--    purchase sessions / department sessions) diverge.
--    dbt equivalent: custom test, severity warn
chk_purchase_without_department AS (
  SELECT
    'events: purchase sessions without department'    AS check_name,
    'warn'                                            AS severity,
    COUNTIF(department_events = 0)                    AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM raw_sessions
  WHERE purchase_events >= 1
),

-- 11. Reconciliation events <-> order_items, by month.
--     Observed in this dataset: every order item has exactly one purchase
--     session (and each session views a single product). The conversion
--     numerator is therefore a count of order items, not of orders.
--     This check guards that relationship: a month where purchase
--     sessions and order items diverge means tracking and sales data no
--     longer describe the same purchases.
--     Month = month of the purchase event / of order_items.created_at.
--     failed_rows = months with a mismatch ; total_rows = months compared.
--     dbt equivalent: cross-source reconciliation test (e.g.
--     dbt_utils.equality on monthly aggregates)
monthly_purchase_sessions AS (
  SELECT
    month,
    COUNT(*)                                          AS purchase_sessions
  FROM (
    SELECT
      session_id,
      DATE_TRUNC(DATE(MIN(created_at)), MONTH)        AS month
    FROM `bigquery-public-data.thelook_ecommerce.events`
    WHERE event_type = 'purchase'
      AND session_id IS NOT NULL
    GROUP BY session_id
  )
  GROUP BY month
),

monthly_order_items AS (
  SELECT
    DATE_TRUNC(DATE(created_at), MONTH)               AS month,
    COUNT(*)                                          AS order_items
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  GROUP BY month
),

chk_purchase_sessions_vs_order_items AS (
  SELECT
    'events vs order_items: monthly purchase sessions != order items' AS check_name,
    'warn'                                            AS severity,
    COUNTIF(IFNULL(s.purchase_sessions, 0)
            != IFNULL(o.order_items, 0))              AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM monthly_purchase_sessions AS s
  FULL OUTER JOIN monthly_order_items AS o
    ON s.month = o.month
),

-- 12. Sessions viewing more than one distinct product.
--     Complements check 11: in this dataset a session is the journey of a
--     single product (one session = one item). A session with several
--     product pages would break that assumption, and with it the reading
--     of the conversion numerator as "items bought".
--     Product identified by the product page uri.
--     failed_rows = sessions with > 1 distinct product uri ;
--     total_rows  = sessions with at least one product event.
--     dbt equivalent: custom test, severity warn
session_products AS (
  SELECT
    session_id,
    COUNT(DISTINCT uri)                               AS distinct_products
  FROM `bigquery-public-data.thelook_ecommerce.events`
  WHERE event_type = 'product'
    AND session_id IS NOT NULL
  GROUP BY session_id
),

chk_sessions_multiple_products AS (
  SELECT
    'events: sessions viewing more than one product'  AS check_name,
    'warn'                                            AS severity,
    COUNTIF(distinct_products > 1)                    AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM session_products
)

SELECT
  check_name,
  severity,
  failed_rows,
  total_rows,
  ROUND(SAFE_DIVIDE(failed_rows, total_rows) * 100, 4) AS pct_failed
FROM (
  SELECT * FROM chk_duplicate_order_items
  UNION ALL SELECT * FROM chk_null_order_item_ids
  UNION ALL SELECT * FROM chk_orders_without_items
  UNION ALL SELECT * FROM chk_status_vs_returned_at
  UNION ALL SELECT * FROM chk_future_dated_order_items
  UNION ALL SELECT * FROM chk_future_dated_orders
  UNION ALL SELECT * FROM chk_item_vs_order_month
  UNION ALL SELECT * FROM chk_purchase_without_department
  UNION ALL SELECT * FROM chk_purchase_sessions_vs_order_items
  UNION ALL SELECT * FROM chk_sessions_multiple_products
);


-- ---------------------------------------------------------------------
-- A1 output
-- ---------------------------------------------------------------------
SELECT *
FROM a1_data_quality
ORDER BY severity, check_name;


-- ---------------------------------------------------------------------
-- A1 top finding: impact of month attribution (check 6c)
-- Completed revenue per month, attributed with the line item date
-- (order_items.created_at) vs the order date (orders.created_at), and the
-- resulting month-over-month growth under each method.
-- Total revenue is identical; only its distribution across months moves.
-- MoM is computed on the full history before filtering, so the first
-- reported month still has a value.
-- Runs on raw tables, like the rest of A1.
-- ---------------------------------------------------------------------
WITH completed AS (
  SELECT
    CAST(oi.sale_price AS NUMERIC)                    AS revenue,
    DATE_TRUNC(DATE(oi.created_at), MONTH)            AS item_month,
    DATE_TRUNC(DATE(o.created_at), MONTH)             AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
  JOIN `bigquery-public-data.thelook_ecommerce.orders` AS o
    ON oi.order_id = o.order_id
  WHERE oi.status = 'Complete'
    AND oi.returned_at IS NULL
),

by_item_month AS (
  SELECT item_month AS month, SUM(revenue) AS revenue_by_item_month
  FROM completed
  GROUP BY item_month
),

by_order_month AS (
  SELECT order_month AS month, SUM(revenue) AS revenue_by_order_month
  FROM completed
  GROUP BY order_month
),

compared AS (
  SELECT
    COALESCE(i.month, o.month)                        AS month,
    IFNULL(i.revenue_by_item_month, 0)                AS revenue_by_item_month,
    IFNULL(o.revenue_by_order_month, 0)               AS revenue_by_order_month
  FROM by_item_month AS i
  FULL OUTER JOIN by_order_month AS o
    ON i.month = o.month
),

with_growth AS (
  SELECT
    month,
    revenue_by_item_month,
    revenue_by_order_month,
    SAFE_DIVIDE(revenue_by_item_month - LAG(revenue_by_item_month) OVER w,
                LAG(revenue_by_item_month) OVER w) * 100   AS mom_pct_by_item_month,
    SAFE_DIVIDE(revenue_by_order_month - LAG(revenue_by_order_month) OVER w,
                LAG(revenue_by_order_month) OVER w) * 100  AS mom_pct_by_order_month
  FROM compared
  WINDOW w AS (ORDER BY month)
)

SELECT
  month,
  ROUND(revenue_by_item_month, 2)                     AS revenue_by_item_month,
  ROUND(revenue_by_order_month, 2)                    AS revenue_by_order_month,
  ROUND(revenue_by_item_month - revenue_by_order_month, 2) AS revenue_diff,
  ROUND(SAFE_DIVIDE(revenue_by_item_month - revenue_by_order_month,
                    revenue_by_order_month) * 100, 2) AS revenue_diff_pct,
  ROUND(mom_pct_by_item_month, 2)                     AS mom_pct_by_item_month,
  ROUND(mom_pct_by_order_month, 2)                    AS mom_pct_by_order_month,
  ROUND(mom_pct_by_item_month - mom_pct_by_order_month, 2) AS mom_diff_pts
FROM with_growth
WHERE month BETWEEN report_start_month AND report_end_month
ORDER BY month DESC;



-- =====================================================================
-- A2. Reusable base model
--
-- Design choice: this section deliberately reuses dbt conventions and best
-- practices, so the logic can be lifted into a dbt project as-is:
--   * Layered models with dbt naming: stg_ (1:1 with a source) -> int_
--     (business logic) -> mart_ (reporting aggregates).
--   * Staging = rename, cast, no business rules, no filters.
--   * Each business rule is defined ONCE, in one model (here: the
--     "completed sale" convention lives only in int_completed_order_items).
--   * Downstream models read upstream models, never raw sources again
--     (temp tables play the role of ref()).
--   * Grain is explicit and documented for every model.
--   * Data quality checks (A1) map to dbt tests: unique, not_null,
--     relationships, accepted_values, plus custom tests.
-- Result: A3, B1, B2 and the cohort table all read the same model, so
-- revenue and customer counts cannot diverge between reports.
--
-- Scope: only what the metrics need. No product dimension is built,
-- because no analysis slices by product; product_id stays on the fact
-- as a key, so a product dimension can be joined later.
--
-- Key design decision: months are attributed with the ORDER date.
--   * The case convention "Month = DATE_TRUNC(DATE(created_at), MONTH)"
--     does not say which table's created_at. It is read here as
--     orders.created_at.
--   * Why: the order is the purchase event; an order then belongs to one
--     month only, so revenue, orders and AOV stay consistent; and
--     order_items.created_at is unreliable (before the order for most
--     lines, up to ~96 h after it, about 1% in the future, while no order
--     is dated in the future). See A1 checks 6, 6b and 6c.
--   * Total revenue is identical with both dates; only its distribution
--     across months changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- stg_order_items
-- Grain: one row per order line item (order_item_id).
-- ---------------------------------------------------------------------
CREATE TEMP TABLE stg_order_items AS
SELECT
  id                           AS order_item_id,
  order_id,
  user_id,
  product_id,
  inventory_item_id,
  status                       AS order_item_status,
  CAST(sale_price AS NUMERIC)  AS sale_price,   -- NUMERIC: exact sums, no float drift
  created_at                   AS order_item_created_at,
  shipped_at,
  delivered_at,
  returned_at
FROM `bigquery-public-data.thelook_ecommerce.order_items`;


-- ---------------------------------------------------------------------
-- stg_orders
-- Grain: one row per order (order_id).
-- Carries the order date used for month attribution.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE stg_orders AS
SELECT
  order_id,
  user_id,
  status                       AS order_status,
  created_at                   AS order_created_at,
  num_of_item
FROM `bigquery-public-data.thelook_ecommerce.orders`;


-- ---------------------------------------------------------------------
-- stg_inventory_items
-- Grain: one row per physical inventory item (inventory_item_id).
-- Carries the cost basis used for COGS.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE stg_inventory_items AS
SELECT
  id                                   AS inventory_item_id,
  product_id,
  CAST(cost AS NUMERIC)                AS cost
FROM `bigquery-public-data.thelook_ecommerce.inventory_items`;


-- ---------------------------------------------------------------------
-- int_completed_order_items  <-- SINGLE SOURCE OF TRUTH for sales
-- Grain: one row per completed order line item.
-- Completed sale (case convention): status = 'Complete' AND returned_at IS NULL
-- Revenue = sale_price ; COGS = inventory_items.cost ; GP = revenue - COGS
-- Month = DATE_TRUNC(DATE(orders.created_at), MONTH)  (timestamps are UTC)
--         = month of the ORDER, not of the line item (see A2 header).
--
-- LEFT JOINs on purpose: a missing cost or order must not silently drop
-- revenue. Missing costs are flagged (is_cost_missing); orphan keys are
-- checked in sql/additional_analysis/a1_all_data_quality_checks.sql.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE int_completed_order_items AS
SELECT
  oi.order_item_id,
  oi.order_id,
  oi.user_id,
  oi.product_id,
  oi.inventory_item_id,
  o.order_created_at,
  DATE(o.order_created_at)                     AS order_date,
  DATE_TRUNC(DATE(o.order_created_at), MONTH)  AS order_month,
  oi.order_item_created_at,                    -- kept for traceability only
  oi.sale_price                                AS revenue,
  ii.cost                                      AS cogs,
  oi.sale_price - ii.cost                      AS gross_profit,
  ii.cost IS NULL                              AS is_cost_missing
FROM stg_order_items AS oi
LEFT JOIN stg_orders AS o
  ON oi.order_id = o.order_id
LEFT JOIN stg_inventory_items AS ii
  ON oi.inventory_item_id = ii.inventory_item_id
WHERE oi.order_item_status = 'Complete'
  AND oi.returned_at IS NULL;


-- =====================================================================
-- A3. Monthly business health
-- =====================================================================

-- ---------------------------------------------------------------------
-- stg_events
-- Grain: one row per web event (event_id).
-- IP address and precise geo (city, state, postal_code) are intentionally
-- not staged: not needed by any metric, and personal data.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE stg_events AS
SELECT
  id                           AS event_id,
  session_id,
  sequence_number,
  user_id,                     -- NULL for anonymous sessions
  created_at,
  event_type,
  traffic_source,
  browser,
  uri
FROM `bigquery-public-data.thelook_ecommerce.events`;


-- ---------------------------------------------------------------------
-- int_sessions
-- Grain: one row per session (session_id).
-- A session is attributed to the month of its FIRST event, so a session
-- spanning midnight at month end is counted once.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE int_sessions AS
SELECT
  session_id,
  MIN(created_at)                                         AS session_started_at,
  DATE_TRUNC(DATE(MIN(created_at)), MONTH)                AS session_month,
  COUNT(*)                                                AS events,
  LOGICAL_OR(event_type = 'department')                   AS has_department_event,
  LOGICAL_OR(event_type = 'purchase')                     AS has_purchase_event
FROM stg_events
GROUP BY session_id;


-- ---------------------------------------------------------------------
-- mart_monthly_health
-- Grain: one row per calendar month, up to report_end_month.
-- * orders            = distinct orders with >= 1 completed item
-- * units             = completed order items
-- * aov               = revenue / orders
-- * revenue_mom_growth_pct computed on a continuous month spine BEFORE
--   filtering, so the first reported month still has a growth value and a
--   month with no sales cannot silently shift the comparison.
-- * session_conversion_rate = sessions with a department AND a purchase
--   event / sessions with a department event (funnel-consistent: bounded
--   by 1). Purchase sessions without a department event are checked in A1.
-- Note: conversion counts purchase events, which include orders later
-- cancelled or returned; revenue only counts completed sales.
-- Note: in this dataset each order ITEM has its own purchase session
-- (verified monthly, see A1 check 11), and each session views a single
-- product. The rate therefore reflects items bought per browsing
-- session, not orders: it is inflated by basket size and should be read
-- as a trend, not a level. Order-level conversion would need an order_id
-- on the purchase event (instrumentation recommendation).
-- ---------------------------------------------------------------------
CREATE TEMP TABLE mart_monthly_health AS
WITH month_spine AS (
  SELECT month
  FROM UNNEST(GENERATE_DATE_ARRAY(
         (SELECT MIN(order_month) FROM int_completed_order_items),
         report_end_month,
         INTERVAL 1 MONTH)) AS month
),

sales_monthly AS (
  SELECT
    order_month                       AS month,
    SUM(revenue)                      AS revenue,
    SUM(gross_profit)                 AS gross_profit,
    COUNT(DISTINCT order_id)          AS orders,
    COUNT(*)                          AS units
  FROM int_completed_order_items
  GROUP BY order_month
),

sessions_monthly AS (
  SELECT
    session_month                                         AS month,
    COUNTIF(has_department_event)                         AS department_sessions,
    COUNTIF(has_department_event AND has_purchase_event)  AS purchase_sessions
  FROM int_sessions
  GROUP BY session_month
),

monthly AS (
  SELECT
    ms.month,
    IFNULL(s.revenue, 0)              AS revenue,
    IFNULL(s.gross_profit, 0)         AS gross_profit,
    IFNULL(s.orders, 0)               AS orders,
    IFNULL(s.units, 0)                AS units,
    e.department_sessions,
    e.purchase_sessions
  FROM month_spine AS ms
  LEFT JOIN sales_monthly AS s
    ON ms.month = s.month
  LEFT JOIN sessions_monthly AS e
    ON ms.month = e.month
)

SELECT
  month,
  ROUND(revenue, 2)                                                   AS revenue,
  ROUND(gross_profit, 2)                                              AS gross_profit,
  ROUND(SAFE_DIVIDE(gross_profit, revenue) * 100, 2)                  AS gross_margin_pct,
  orders,
  units,
  ROUND(SAFE_DIVIDE(revenue, orders), 2)                              AS aov,
  ROUND(SAFE_DIVIDE(revenue - LAG(revenue) OVER (ORDER BY month),
                    LAG(revenue) OVER (ORDER BY month)) * 100, 2)     AS revenue_mom_growth_pct,
  ROUND(SAFE_DIVIDE(purchase_sessions, department_sessions), 4)       AS session_conversion_rate,
  department_sessions,
  purchase_sessions
FROM monthly;


-- ---------------------------------------------------------------------
-- A3 output: reporting window only (complete months)
-- ---------------------------------------------------------------------
SELECT *
FROM mart_monthly_health
WHERE month BETWEEN report_start_month AND report_end_month
ORDER BY month;


-- =====================================================================
-- B. Retention, churn and mix
--
-- Definitions
--   * Active customer (month M): at least one completed order in M.
--   * New customer (month M): M is the month of the customer's first-ever
--     completed order (computed on the full history). Otherwise returning.
--     So active = new + returning, every month.
--   * Churned 90d (month M): active in M, and no completed order in the
--     90 days after the customer's last order in M.
-- All months use the order date (orders.created_at), as in A.
-- Customer = order_items.user_id.
-- =====================================================================

-- ---------------------------------------------------------------------
-- int_customer_months
-- Grain: one row per customer x month with at least one completed order.
-- Reused by B1 (mix), B2 (churn) and the cohort table.
-- * first_order_date / first_order_month: first-ever completed order.
--   A historical fact, stable over time, so it could also live on a
--   customer dimension. The "new" flag cannot: it only exists relative
--   to a month, hence it lives at the customer x month grain.
-- * next_order_date: first completed order AFTER this month. Churn is
--   derived from it, so it does not depend on the run date.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE int_customer_months AS
WITH monthly AS (
  SELECT
    user_id                                      AS customer_id,
    order_month,
    COUNT(DISTINCT order_id)                     AS orders,
    SUM(revenue)                                 AS revenue,
    MIN(order_date)                              AS first_order_date_in_month,
    MAX(order_date)                              AS last_order_date_in_month
  FROM int_completed_order_items
  GROUP BY user_id, order_month
),

with_history AS (
  SELECT
    *,
    MIN(first_order_date_in_month) OVER (PARTITION BY customer_id) AS first_order_date,
    MIN(order_month)               OVER (PARTITION BY customer_id) AS first_order_month,
    LEAD(first_order_date_in_month)
      OVER (PARTITION BY customer_id ORDER BY order_month)         AS next_order_date
  FROM monthly
)

SELECT
  customer_id,
  order_month,
  orders,
  revenue,
  first_order_date,
  first_order_month,
  order_month = first_order_month                AS is_new_customer,
  first_order_date_in_month,
  last_order_date_in_month,
  next_order_date,
  DATE_DIFF(next_order_date, last_order_date_in_month, DAY) AS days_to_next_order,
  next_order_date IS NULL
    OR DATE_DIFF(next_order_date, last_order_date_in_month, DAY) > 90
                                                 AS is_churned_90d
FROM with_history;


-- ---------------------------------------------------------------------
-- B1. mart_customer_mix
-- Grain: one row per month.
-- Revenue reconciles with mart_monthly_health (same base model, same
-- month attribution): revenue_new + revenue_returning = revenue.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE mart_customer_mix AS
SELECT
  order_month                                              AS month,
  COUNT(*)                                                 AS active_customers,
  COUNTIF(is_new_customer)                                 AS new_customers,
  COUNTIF(NOT is_new_customer)                             AS returning_customers,
  ROUND(SUM(IF(is_new_customer, revenue, 0)), 2)           AS revenue_new,
  ROUND(SUM(IF(NOT is_new_customer, revenue, 0)), 2)       AS revenue_returning,
  ROUND(SAFE_DIVIDE(SUM(IF(NOT is_new_customer, revenue, 0)),
                    SUM(revenue)) * 100, 2)                AS pct_revenue_from_returning
FROM int_customer_months
GROUP BY order_month;


-- ---------------------------------------------------------------------
-- B2. mart_churn_90d
-- Grain: one row per month.
-- Right-censoring: a month is MATURE when its full 90-day window has
-- elapsed for every active customer, i.e. last day of the month + 90 days
-- <= as_of_date. Immature months are kept but flagged (is_mature =
-- FALSE), with churn left NULL instead of an understated rate.
-- Example: with as_of_date = 2026-10-23, the last complete month is
-- September 2026 and the last mature month is June 2026.
-- Churn is also split by new vs returning customers: a rise in total
-- churn can be a mix effect (more new customers, who churn more) rather
-- than weaker repeat behaviour.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE mart_churn_90d AS
SELECT
  order_month                                              AS month,
  DATE_ADD(LAST_DAY(order_month), INTERVAL 90 DAY)         AS churn_window_end,
  DATE_ADD(LAST_DAY(order_month), INTERVAL 90 DAY) <= as_of_date AS is_mature,
  COUNT(*)                                                 AS active_customers,
  IF(DATE_ADD(LAST_DAY(order_month), INTERVAL 90 DAY) <= as_of_date,
     COUNTIF(is_churned_90d), NULL)                        AS churned_customers_90d,
  IF(DATE_ADD(LAST_DAY(order_month), INTERVAL 90 DAY) <= as_of_date,
     ROUND(SAFE_DIVIDE(COUNTIF(is_churned_90d), COUNT(*)) * 100, 2),
     NULL)                                                 AS churn_rate_90d,
  IF(DATE_ADD(LAST_DAY(order_month), INTERVAL 90 DAY) <= as_of_date,
     ROUND(SAFE_DIVIDE(COUNTIF(is_churned_90d AND is_new_customer),
                       COUNTIF(is_new_customer)) * 100, 2),
     NULL)                                                 AS churn_rate_90d_new,
  IF(DATE_ADD(LAST_DAY(order_month), INTERVAL 90 DAY) <= as_of_date,
     ROUND(SAFE_DIVIDE(COUNTIF(is_churned_90d AND NOT is_new_customer),
                       COUNTIF(NOT is_new_customer)) * 100, 2),
     NULL)                                                 AS churn_rate_90d_returning
FROM int_customer_months
GROUP BY order_month;


-- ---------------------------------------------------------------------
-- B1 output: reporting window only (complete months)
-- ---------------------------------------------------------------------
SELECT *
FROM mart_customer_mix
WHERE month BETWEEN report_start_month AND report_end_month
ORDER BY month;


-- ---------------------------------------------------------------------
-- B2 output: reporting window, immature months flagged
-- ---------------------------------------------------------------------
SELECT *
FROM mart_churn_90d
WHERE month BETWEEN report_start_month AND report_end_month
ORDER BY month;


-- =====================================================================
-- Reporting table: mart_monthly_business_review
-- Grain: one row per month (reporting window only).
-- Wide table joining the subject marts (A3, B1, B2) for BI tools: one
-- data source, one month window for all visuals. It adds no logic: every
-- metric is defined once, upstream, so it cannot diverge from the marts.
-- Churn is only meaningful when is_churn_mature = TRUE (NULL otherwise).
-- =====================================================================
CREATE TEMP TABLE mart_monthly_business_review AS
SELECT
  h.month,
  -- Business health (A3)
  h.revenue,
  h.gross_profit,
  h.gross_margin_pct,
  h.orders,
  h.units,
  h.aov,
  h.revenue_mom_growth_pct,
  h.session_conversion_rate,
  -- Customer mix (B1)
  m.active_customers,
  m.new_customers,
  m.returning_customers,
  m.revenue_new,
  m.revenue_returning,
  m.pct_revenue_from_returning,
  -- 90-day churn (B2)
  c.is_mature                                     AS is_churn_mature,
  c.churn_window_end,
  c.churned_customers_90d,
  c.churn_rate_90d,
  c.churn_rate_90d_new,
  c.churn_rate_90d_returning,
  -- Run metadata: the public dataset keeps changing
  as_of_date,
  CURRENT_TIMESTAMP()                             AS run_at
FROM mart_monthly_health AS h
LEFT JOIN mart_customer_mix AS m
  ON h.month = m.month
LEFT JOIN mart_churn_90d AS c
  ON h.month = c.month
WHERE h.month BETWEEN report_start_month AND report_end_month;


-- ---------------------------------------------------------------------
-- Reporting table output
-- ---------------------------------------------------------------------
SELECT *
FROM mart_monthly_business_review
ORDER BY month;


-- ---------------------------------------------------------------------
-- Persist the tables behind the charts (optional)
-- Only runs when persist_dataset is set. Tables are replaced on each run.
-- * mart_monthly_business_review: visuals 1 and 2.
-- * int_completed_order_items, int_customer_months: detail for visual 3
--   (e.g. splits by traffic source or country), same definitions.
-- The dataset is created if it does not exist yet (US region, like the
-- public dataset), so no manual setup is needed.
-- ---------------------------------------------------------------------
IF persist_dataset IS NOT NULL THEN
  EXECUTE IMMEDIATE FORMAT(
    "CREATE SCHEMA IF NOT EXISTS `%s` OPTIONS (location = 'US')",
    persist_dataset);

  FOR t IN (
    SELECT table_name
    FROM UNNEST([
      'mart_monthly_business_review',
      'int_completed_order_items',
      'int_customer_months'
    ]) AS table_name
  ) DO
    EXECUTE IMMEDIATE FORMAT(
      "CREATE OR REPLACE TABLE `%s.%s` AS SELECT * FROM %s",
      persist_dataset, t.table_name, t.table_name);
  END FOR;
END IF;
