-- =====================================================================
-- Peek case study — A1: full set of data quality checks (17)
-- Dataset : bigquery-public-data.thelook_ecommerce
-- Dialect : BigQuery Standard SQL, standalone script (run it whole)
--
-- Every check written during the analysis, kept for reference and for the
-- discussion. sql/part1_queries.sql keeps only the most relevant ones.
-- All checks run on the RAW tables, so no transformation can introduce or
-- hide an issue. Output: one row per check (check_name, severity,
-- failed_rows, total_rows, pct_failed).
-- severity: error = would distort a published figure; warn = to monitor.
-- Same parameters and reporting window as part1_queries.sql.
-- =====================================================================

DECLARE as_of_date         DATE DEFAULT CURRENT_DATE();
DECLARE report_start_month DATE DEFAULT NULL;
DECLARE report_end_month   DATE DEFAULT NULL;

-- Resolve reporting window (incomplete months are excluded)
-- * End   : last complete month before as_of_date (the as_of_date month
--           is still running).
-- * Start : first complete month of order data (the first month of the
--           dataset may start mid-month). Computed on raw orders, all
--           statuses: it describes data coverage, not a business rule.
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

-- 3. Order items whose inventory item is missing (NULL or orphaned key).
--    No inventory item = no cost: the line counts in revenue but not in
--    gross profit, which understates gross profit and margin.
--    dbt equivalent: relationships (order_items.inventory_item_id ->
--    inventory_items.id)
chk_orphan_inventory_items AS (
  SELECT
    'order_items: inventory_item_id missing in inventory_items' AS check_name,
    'error'                                           AS severity,
    COUNTIF(ii.id IS NULL)                            AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
  LEFT JOIN (SELECT DISTINCT id
             FROM `bigquery-public-data.thelook_ecommerce.inventory_items`) AS ii
    ON oi.inventory_item_id = ii.id
),

-- 4. Calendar days without any order item, within the reporting window.
--    An ecommerce business should sell every day: a day with no order
--    item at all (any status) suggests a data gap rather than a quiet day.
--    Severity warn: a zero-sale day is possible at low volume (early
--    history of the dataset).
--    dbt equivalent: custom test (date spine)
chk_missing_sales_days AS (
  SELECT
    'order_items: calendar days without any order item' AS check_name,
    'warn'                                            AS severity,
    COUNTIF(s.order_date IS NULL)                     AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM UNNEST(GENERATE_DATE_ARRAY(report_start_month,
                                  LAST_DAY(report_end_month))) AS calendar_date
  LEFT JOIN (SELECT DISTINCT DATE(created_at) AS order_date
             FROM `bigquery-public-data.thelook_ecommerce.order_items`) AS s
    ON calendar_date = s.order_date
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

-- 7. Funnel events (department, purchase) without a user_id.
--    Scoped to the two event types used by session_conversion_rate (A3).
--    NULL user_id is expected for anonymous (not logged-in) visitors, so
--    this is a measure, not an error. Session conversion is computed per
--    session and does not need user_id; a high share limits any
--    user-level funnel or attribution (e.g. linking sessions to customers).
--    dbt equivalent: not_null (with a where config) and severity warn
chk_events_null_user AS (
  SELECT
    'events (department, purchase): NULL user_id'     AS check_name,
    'warn'                                            AS severity,
    COUNTIF(user_id IS NULL)                          AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.events`
  WHERE event_type IN ('department', 'purchase')
),

-- Shared by checks 8 and 9: one row per non-NULL session, with funnel
-- event counts. NULL session_ids are measured separately (check 10).
raw_sessions AS (
  SELECT
    session_id,
    COUNTIF(event_type = 'department')                AS department_events,
    COUNTIF(event_type = 'purchase')                  AS purchase_events
  FROM `bigquery-public-data.thelook_ecommerce.events`
  WHERE session_id IS NOT NULL
  GROUP BY session_id
),

-- 8. Sessions with more than one purchase event.
--    No effect on session_conversion_rate ("at least one" logic), but
--    documents that conversion counts sessions that buy, not orders
--    (several orders in one visit, or duplicated events).
--    dbt equivalent: custom test, severity warn
chk_sessions_multiple_purchases AS (
  SELECT
    'events: sessions with more than one purchase'    AS check_name,
    'warn'                                            AS severity,
    COUNTIF(purchase_events > 1)                      AS failed_rows,
    COUNTIF(purchase_events >= 1)                     AS total_rows
  FROM raw_sessions
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

-- 10. Funnel events without a session_id.
--     In int_sessions, GROUP BY session_id would merge ALL of them into a
--     single "NULL session", counted once in the conversion rate.
--     If any, NULL session_ids must be excluded in int_sessions.
--     dbt equivalent: not_null (with a where config)
chk_events_null_session AS (
  SELECT
    'events (department, purchase): NULL session_id'  AS check_name,
    'error'                                           AS severity,
    COUNTIF(session_id IS NULL)                       AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.events`
  WHERE event_type IN ('department', 'purchase')
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
),

-- 13. 'Complete' order items without a delivery date.
--     A completed sale should have been delivered. A 'Complete' line with
--     no delivered_at is counted in revenue by the case convention, but
--     its status is not backed by the fulfilment timestamps.
--     failed_rows = Complete items with delivered_at NULL ;
--     total_rows  = Complete items.
--     dbt equivalent: not_null on delivered_at (where status = 'Complete')
chk_complete_without_delivery AS (
  SELECT
    'order_items: Complete without delivered_at'      AS check_name,
    'error'                                           AS severity,
    COUNTIF(delivered_at IS NULL)                     AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status = 'Complete'
),

-- 14. Order item status different from its order status.
--     The case convention works at item level, so published revenue does
--     not depend on orders.status. A mismatch would mean that a count of
--     "completed orders" from the orders table would not match ours.
--     IS DISTINCT FROM also flags items whose order is missing.
--     dbt equivalent: custom test (relationships + expression)
chk_item_vs_order_status AS (
  SELECT
    'order_items: status differs from orders.status'  AS check_name,
    'warn'                                            AS severity,
    COUNTIF(oi.status IS DISTINCT FROM o.status)      AS failed_rows,
    COUNT(*)                                          AS total_rows
  FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
  LEFT JOIN `bigquery-public-data.thelook_ecommerce.orders` AS o
    ON oi.order_id = o.order_id
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
  UNION ALL SELECT * FROM chk_orphan_inventory_items
  UNION ALL SELECT * FROM chk_missing_sales_days
  UNION ALL SELECT * FROM chk_status_vs_returned_at
  UNION ALL SELECT * FROM chk_future_dated_order_items
  UNION ALL SELECT * FROM chk_future_dated_orders
  UNION ALL SELECT * FROM chk_item_vs_order_month
  UNION ALL SELECT * FROM chk_events_null_user
  UNION ALL SELECT * FROM chk_sessions_multiple_purchases
  UNION ALL SELECT * FROM chk_purchase_without_department
  UNION ALL SELECT * FROM chk_events_null_session
  UNION ALL SELECT * FROM chk_purchase_sessions_vs_order_items
  UNION ALL SELECT * FROM chk_sessions_multiple_products
  UNION ALL SELECT * FROM chk_complete_without_delivery
  UNION ALL SELECT * FROM chk_item_vs_order_status
);


-- ---------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------
SELECT *
FROM a1_data_quality
ORDER BY severity, check_name;
