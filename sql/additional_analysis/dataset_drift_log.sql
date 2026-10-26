-- =====================================================================
-- Peek case study — dataset drift log
-- Dialect : BigQuery Standard SQL. Run the whole script.
--
-- Why this file exists
-- bigquery-public-data.thelook_ecommerce is regenerated regularly,
-- including rows dated in the past: the same query returns different
-- figures from one day to the next (September 2026 revenue was
-- $113.3k, then $123.2k, then $117.5k across three runs, Oct 24-26).
-- Each run of this script appends ONE row to a log table with the run
-- time, when the source tables were last rewritten, their row counts and
-- a few fixed-period metrics. Comparing rows shows whether, and how much,
-- the data moved between two runs.
--
-- Fixed periods on purpose: a month that is over should never change.
--   * reference_month : a recent complete month (the reviewed month)
--   * past_year       : a closed year, far from the current date
--
-- The log table lives in your own project (dataset peek_case by default).
-- =====================================================================

DECLARE log_dataset     STRING DEFAULT 'peek_case';
DECLARE reference_month DATE   DEFAULT DATE '2026-09-01';
DECLARE past_year_start DATE   DEFAULT DATE '2025-01-01';

EXECUTE IMMEDIATE FORMAT(
  "CREATE SCHEMA IF NOT EXISTS `%s` OPTIONS (location = 'US')", log_dataset);

EXECUTE IMMEDIATE FORMAT("""
  CREATE TABLE IF NOT EXISTS `%s.dataset_drift_log` (
    run_at                          TIMESTAMP,
    order_items_last_modified       TIMESTAMP,
    orders_last_modified            TIMESTAMP,
    order_items_rows                INT64,
    orders_rows                     INT64,
    reference_month                 DATE,
    reference_month_revenue         NUMERIC,
    reference_month_orders          INT64,
    past_year_start                 DATE,
    past_year_revenue               NUMERIC,
    note                            STRING
  )""", log_dataset);

EXECUTE IMMEDIATE FORMAT("""
  INSERT INTO `%s.dataset_drift_log`
  WITH
  meta AS (
    SELECT
      MAX(IF(table_id = 'order_items', TIMESTAMP_MILLIS(last_modified_time), NULL)) AS order_items_last_modified,
      MAX(IF(table_id = 'orders',      TIMESTAMP_MILLIS(last_modified_time), NULL)) AS orders_last_modified,
      MAX(IF(table_id = 'order_items', row_count, NULL))                            AS order_items_rows,
      MAX(IF(table_id = 'orders',      row_count, NULL))                            AS orders_rows
    FROM `bigquery-public-data.thelook_ecommerce.__TABLES__`
    WHERE table_id IN ('order_items', 'orders')
  ),
  completed AS (
    SELECT
      oi.order_id,
      CAST(oi.sale_price AS NUMERIC)            AS revenue,
      DATE_TRUNC(DATE(o.created_at), MONTH)     AS order_month
    FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
    JOIN `bigquery-public-data.thelook_ecommerce.orders` AS o
      ON oi.order_id = o.order_id
    WHERE oi.status = 'Complete'
      AND oi.returned_at IS NULL
  )
  SELECT
    CURRENT_TIMESTAMP(),
    meta.order_items_last_modified,
    meta.orders_last_modified,
    meta.order_items_rows,
    meta.orders_rows,
    @reference_month,
    (SELECT ROUND(SUM(revenue), 2) FROM completed WHERE order_month = @reference_month),
    (SELECT COUNT(DISTINCT order_id) FROM completed WHERE order_month = @reference_month),
    @past_year_start,
    (SELECT ROUND(SUM(revenue), 2) FROM completed
      WHERE order_month >= @past_year_start
        AND order_month <  DATE_ADD(@past_year_start, INTERVAL 1 YEAR)),
    CAST(NULL AS STRING)
  FROM meta
""", log_dataset)
USING reference_month AS reference_month, past_year_start AS past_year_start;

-- Show the log, latest run first, with the change vs the previous run.
EXECUTE IMMEDIATE FORMAT("""
  SELECT
    run_at,
    order_items_last_modified,
    order_items_rows,
    orders_rows,
    reference_month_revenue,
    ROUND(SAFE_DIVIDE(reference_month_revenue
                      - LAG(reference_month_revenue) OVER (ORDER BY run_at),
                      LAG(reference_month_revenue) OVER (ORDER BY run_at)) * 100, 2)
                                                AS reference_month_revenue_change_pct,
    reference_month_orders,
    past_year_revenue,
    ROUND(SAFE_DIVIDE(past_year_revenue
                      - LAG(past_year_revenue) OVER (ORDER BY run_at),
                      LAG(past_year_revenue) OVER (ORDER BY run_at)) * 100, 2)
                                                AS past_year_revenue_change_pct,
    note
  FROM `%s.dataset_drift_log`
  ORDER BY run_at DESC
""", log_dataset);


-- ---------------------------------------------------------------------
-- One-off: seed the log with the runs made before this script existed.
-- Run this block ONCE (uncomment it), after the table has been created.
-- Values come from the runs of the case study; NULL = not recorded.
-- ---------------------------------------------------------------------
-- INSERT INTO peek_case.dataset_drift_log
--   (run_at, order_items_rows, reference_month, reference_month_revenue,
--    reference_month_orders, note)
-- VALUES
--   (TIMESTAMP '2026-10-24 12:00:00 UTC', 181648, DATE '2026-09-01',
--    113258.41, 1354, 'case study run of Oct 24 (approximate time)'),
--   (TIMESTAMP '2026-10-25 20:48:16 UTC', NULL,   DATE '2026-09-01',
--    123192.56, 1419, 'case study run before the 02:52 UTC rewrite'),
--   (TIMESTAMP '2026-10-26 04:19:52 UTC', 180996, DATE '2026-09-01',
--    117542.03, 1373, 'frozen run used for the deliverable');
