# Peek case study — TheLook ecommerce

## Contents

- `/sql/part1_queries.sql` — Tasks A and B, plus the reporting table behind
  the charts
- `/sql/additional_analysis/` — supporting queries, outside the Part 1
  deliverable:
  - `a1_all_data_quality_checks.sql` — the full set of 17 data quality checks
    written during the analysis (standalone); Part 1 keeps the most relevant
    ones
  - `a1_top_finding_impact.sql` — computes every figure of the A1 top finding
    impact table (standalone)
  - `visual3_queries.sql` — queries behind the recommendation slide
    (returning revenue by acquisition date, new customers by channel); reads
    the tables persisted by Part 1
  - `b2_churn_window_check.sql` — reproduces the figures behind the B2 churn
    window limitation (reads the tables persisted by Part 1)
  - `b2_alternative_base_churn.sql` — optional: customer-base churn, an
    alternative to the case's churn definition
  - `dataset_drift_log.sql` — logs, at each run, how much the public dataset
    moved (see the reproducibility note)
- `/analysis/thelook_mbr_sep2026.pdf` — slides with the three visuals
- `/README.md` — this file

## How to run

**To view the visuals:** open `analysis/thelook_mbr_sep2026.pdf`. There is no
dashboard: the charts are built from the reporting table and shown in the
deck. No access to BigQuery is needed.

**To reproduce Part 1:**

1. Open a new SQL query tab in BigQuery Studio, with any Google Cloud project
   (the dataset is public: `bigquery-public-data.thelook_ecommerce`).
2. Paste `sql/part1_queries.sql` and run the **whole script** in one go. Each
   model is a `TEMP TABLE` that only lives for the duration of the script.
3. Parameters are declared at the top (`as_of_date`, `report_start_month`,
   `report_end_month`, `persist_dataset`). By default nothing is written to
   your project.
4. Outputs, in order: A1 data quality table, A1 top finding impact, A3
   monthly health, B1 new vs returning mix, B2 90-day churn, and the
   monthly reporting table.

**To reproduce the data behind the charts:** set `persist_dataset` to a dataset
name, e.g. `'peek_case'`, and run the script. The dataset is created in the
project running the query (US region) if it does not exist. It saves
`mart_monthly_business_review`, the single table behind the charts of
visuals 1 and 2. It also saves the customer-level model
`int_customer_months`, which `sql/additional_analysis/visual3_queries.sql` reads to build
visual 3 (run that script afterwards, from the same project).

**Reproducibility note:** the queries are reproducible, the figures are not.
The public dataset is regenerated regularly, including rows dated in the past
(rows are added and removed): across three runs on October 24–26, September
2026 revenue was $113.3k, then $123.2k, then $117.5k, and its MoM growth went
from +13.8% to +5.0%. All figures in this README and in the deck come from one
frozen run (2026-10-26 04:19 UTC, `as_of_date` = 2026-10-26, UTC).
`sql/additional_analysis/dataset_drift_log.sql` logs, at each run, when the source tables were
last rewritten and a few fixed-period metrics, to show how much the data moved.

## Assumptions and date ranges

**Date ranges, and why**
- **Reference date:** `as_of_date` defaults to the run date (`CURRENT_DATE()`).
  Set it to a fixed date to reproduce a past report; the figures in this
  README come from a run on 2026-10-26 (`as_of_date` = 2026-10-26, UTC).
- **Reported months:** complete months only. The window starts at the first
  complete month of order data (February 2019) and ends at the last complete
  month before `as_of_date` (September 2026); the running month is excluded
  because it is partial.
- **Churn:** mature months only. A month is reported once its 90-day window has
  closed (last day + 90 days ≤ `as_of_date`), so the latest churn month is June
  2026. Immature months are flagged, not reported as low rates.
- **Visuals:** 13 months (September 2025 to September 2026; June 2025 to June
  2026 for churn), so the year-ago month is on the chart for YoY.
- **Models are not date-filtered:** first purchases and next orders need the
  full history; the window applies to outputs only.

**Assumptions**
- Case conventions applied as given: completed sale = `status = 'Complete'`
  and `returned_at IS NULL`; revenue = `sale_price`; COGS =
  `inventory_items.cost`.
- **Month = order date** (`orders.created_at`). The convention does not say
  which table; line item dates proved unreliable (A1 top finding).
- **Timestamps are UTC**; no time zone conversion.
- **Customer = `order_items.user_id`**; new vs returning is judged on completed
  orders only.
- **Channel costs are assumed** (no cost data in the dataset): see visual 3.
- **The dataset is synthetic and regenerated regularly**, past dates included:
  see the reproducibility note above.

## Part 1 – Task A: Metric foundation & monthly health

### Part 1 – A1. Data quality checks

#### Approach

- The models (A2, A3) were designed first, so that the checks focus on the
  data the published metrics actually depend on. In the script, A1 still comes
  first, as in the exercise.
- All checks run on the **raw tables**, so that no transformation can
  introduce or hide an issue.
- Each check has a severity: `error` would distort a published figure,
  `warn` is to monitor. In production, each check would be a dbt test with
  the same severity.

#### Result: the sources behind the core metrics are reliable

None of these checks fails (0 failed rows):

- `order_items: duplicated id` — order item ids are unique.
- `order_items: NULL id` — every order item has an id.
- `orders: no matching order_items` — every order has line items.
- `order_items: status inconsistent with returned_at` — statuses agree with
  return dates.
- `events: sessions viewing more than one product` — each session is the
  journey of a single product (one session = one item).
- `events: purchase sessions without department` — every purchase session
  went through a department page, so the literal and funnel definitions of
  conversion give the same number.

One check moved with the dataset: `events vs order_items: monthly purchase
sessions != order items` (warn) passed on the October 24 run, and flags 4 of
94 months in the frozen run. These are two pairs of adjacent months, each off
by one (July/August 2023, December 2023/January 2024): one purchase session
dated in the month next to its line item. Totals still match; it is a
month-boundary timing gap, not a break in the one-session-per-item
relationship.

> **Warning: what the case's conversion rate measures.** The session checks
> show that in this dataset a purchase session is the journey of one product:
> one session per line item (almost every month), one product viewed per
> session. So "sessions with
> a purchase / sessions" is not a visit-level conversion (a visitor browsing
> several products, then buying one or more). It measures conversion at the
> level of the product (and its department) visited. It is still a valid
> trend metric here, but it would not compare with a usual e-commerce
> conversion rate, and on real data, where one visit covers several
> products, the same formula would give a different number.

#### Top finding: line item dates do not match their order dates

**What:** `order_items.created_at` differs from `orders.created_at` for almost
every line. Most line items are dated **before** their own order, the others
up to **96 hours after** it.

- `order_items: created_at in the future (after run time)` — about **1%** of
  line items are dated in the future…
- `orders: created_at in the future (after run time)` — …while no order is
  (0 failed rows): the anomaly sits on the line items, not on the orders.
- `order_items: different month than their order` — as a result, **3.3% of
  line items (5,904 of 180,996) fall in a different month than their order.**

**Impact** _(run of 2026-10-26 UTC, completed revenue, source:
`sql/additional_analysis/a1_top_finding_impact.sql`)_:

| | Value |
|---|---|
| Total revenue | Unchanged over the full history: only its distribution across months moves (−0.3% over the last 12 months, from the edge months) |
| Monthly revenue, last 12 complete months | Shifts between **−4.1% and +2.8%** depending on the date used |
| September 2026 (month under review) | **−1.0%** |
| Month-over-month growth | Up to **~7 points** |
| Orders and AOV | An order can be counted in two months when its lines are split: over the full history, the sum of monthly orders drops from 31,744 to 31,203 with the order date, i.e. **541 orders (~1.7%) were double counted** |

The month-over-month effect matters most: a swing of up to 7 points in growth
can change the story told to leadership, with no change in actual activity.

**Handling:**

- **Fix in the model:** months are attributed with the **order date**. The
  case convention `Month = DATE_TRUNC(DATE(created_at), MONTH)` does not say
  which table; it is read as `orders.created_at`, because the order is the
  purchase event, an order then belongs to a single month (revenue, orders and
  AOV stay consistent), and line item dates are not reliable.
- **Escalate:** the root cause sits in the system that generates orders. Line
  items should carry the order timestamp, or a timestamp that cannot precede
  it or be in the future.
- The impact table is computed by `sql/additional_analysis/a1_top_finding_impact.sql`
  (standalone): query 1 counts the line items in a different month, query 2
  the revenue and MoM gaps over the last 12 months, query 3 the orders
  counted in two months.

### Part 1 – A2. Reusable base model

`int_completed_order_items` is the single source of truth for sales, built in
dbt-style layers simulated with temp tables (`stg_*` → `int_*` → `mart_*`).
Grain: one row per completed order item, with revenue, COGS, gross profit,
and the order-date month. No product dimension is built, since no analysis
slices by product (`product_id` stays on the model as a key). It is not
date-filtered: first purchases need the full history. A3, B1, B2 and the
reporting table all read it. Design choices are documented in the A2 header
of `sql/part1_queries.sql`.

### Part 1 – A3. Monthly business health

`mart_monthly_health`: one row per complete month with revenue, gross profit,
gross margin %, orders, units, AOV, revenue MoM growth and session conversion
rate. Definitions below.

## Part 1 – Task B: Retention, churn & mix

### Part 1 – B1. New vs returning mix

Built on the A2 base model: `int_customer_months` aggregates
`int_completed_order_items` to one row per customer × month with a completed
order, and feeds `mart_customer_mix`: active, new and returning customers, revenue from
each, and the returning share of revenue. "New" = first-ever completed order,
on the full history. Definitions below.

### Part 1 – B2. 90-day churn

`mart_churn_90d`, built on the same `int_customer_months`: active customers,
churned customers and churn rate per month, also split by new vs returning. Right-censoring is handled with
`as_of_date`: immature months are flagged and their churn left NULL.

**Limitation of this churn definition, and how I would refine it** (required by B2)
- **90 days is too short for this purchase cycle.** 75% of the customers who
  came back in September 2026 (154 of 204) had not bought for more than 90
  days: most "churned" customers are not lost for good. In a real product I
  would set the window from the distribution of time between two purchases:
  here only 19% of returns happen within 90 days of the previous order (33%
  within 180, 54% within a year), so a window of about one year would be a
  better starting point. Figures from `sql/additional_analysis/b2_churn_window_check.sql`
  (returns over the full history):

  | Days since previous order | Returns | % of returns | Cumulative % |
  |---|---|---|---|
  | 0–30 | 171 | 5.2% | 5.2% |
  | 31–60 | 238 | 7.2% | 12.4% |
  | 61–90 | 209 | 6.3% | 18.7% |
  | 91–180 | 481 | 14.5% | 33.2% |
  | 181–365 | 670 | 20.2% | 53.5% |
  | 1–2 years | 733 | 22.2% | 75.6% |
  | More than 2 years | 807 | 24.4% | 100.0% |
- **A 3-month reporting lag.** A month's churn is only known 90 days later. A
  customer-base view (customers crossing the inactivity threshold during the
  month, `sql/additional_analysis/b2_alternative_base_churn.sql`) is final at month end, on the
  same cadence as revenue.
- **The trade-off, and what I would report.** With the case's forward-looking
  definition, a short window misses most returns (81% come after 90 days) and
  a long one delays the figure by as much. The lag comes from looking forward,
  not from the window: a backward-looking base view is final at month end
  whatever the threshold. The two views answer different questions:
  - cohort view (`mart_churn_90d`): *"Do the customers active in month M come
    back?"* It follows a group over time;
  - base view (`sql/additional_analysis/b2_alternative_base_churn.sql`): *"What share of our
    customer base did we lose this month?"* A monthly outflow relative to the
    base.

  The window itself stays an open question, with a trade-off:
  - 90 days: reacts faster, but overstates churn (most "churned" customers
    come back later);
  - 365 days: reacts more slowly, but is closer to real churn (it covers half
    of the returns).

  A good direction is to keep both, as they track two different things: the
  90-day figure as an early signal on repeat behaviour, the 365-day figure as
  the measure of customers actually lost. The base view script uses 365 days
  by default (`churn_window_days`).

## Metric definitions (Part 1 – A3, B1, B2)

All metrics read the same base model (`int_completed_order_items`), so they
share one definition of a sale and one month attribution.

**Sales**
- **Completed sale:** an order item with `status = 'Complete'` and
  `returned_at IS NULL` (case convention).
- **Revenue** = sum of `sale_price`; **COGS** = `inventory_items.cost`;
  **gross profit** = revenue − COGS; **gross margin %** = gross profit / revenue.
- **Month:** month of the **order** date (`orders.created_at`), not of the line
  item (see the A1 top finding). Timestamps in UTC.
- **Orders:** distinct orders with at least one completed item.
  **AOV** = revenue / orders, i.e. the completed basket.

**Customers**
- **Active customer (month M):** at least one completed order in M.
- **New customer (month M):** M is the month of the customer's first-ever
  completed order, computed on the full history. Otherwise **returning**. So
  active = new + returning, every month.
- **90-day churn (month M):** active in M, with no completed order in the 90
  days after their last order in M. Churn rate = churned / active.
- **Right-censoring:** a month is mature when its last day + 90 days ≤
  `as_of_date`. Immature months stay in the output, flagged
  (`is_mature = FALSE`), with churn left NULL instead of an understated rate.
  With `as_of_date` = 2026-10-26 (UTC), the last mature month is June 2026.

**Funnel**
- **Session conversion rate:** sessions with a `purchase` event / sessions with
  a `department` event, each session counted once ("at least one" event), in
  the month of its first event. In this dataset each purchase session holds
  one order item (verified month by month, see A1), so the rate reads as items
  bought per browsing session, not as the share of visits that order. Read it
  as a trend, not a level.

## Part 2 – Analysis & storytelling

### Part 2 – Visual 1. Business health: revenue, gross profit and orders

**Layout:** three KPI cards for September 2026 (revenue, gross profit,
orders), each with its MoM change (vs August 2026) and YoY change (vs
September 2025); a line chart of revenue and gross profit and a bar chart of
completed orders, September 2025 to September 2026 (13 months, so the YoY
month is visible). Months attributed with the order date.

| Sep 2026 | Value | MoM | YoY |
|---|---|---|---|
| Revenue | $117.5k | +5.0% | +98.6% |
| Gross profit | $61.2k | +4.9% | +98.1% |
| Orders | 1,373 | +8.5% | +109.0% |

**Commentary:**

> **September 2026 is the strongest month on record.** Revenue reached $117.5k
> (+5.0% MoM), in line with the average monthly pace of the last year (~6%).
>
> **Growth has been sustained since June.** Early 2026 alternated between up
> and down months. Since June, revenue and orders have grown three months in a
> row (orders +44% between June and September), with a peak in July (revenue
> +30% MoM).
>
> **Year over year, revenue, gross profit and orders roughly doubled**
> (+99%, +98%, +109%). Growth is volume-driven: orders more than doubled while
> average order value declined (−5%) and gross margin held steady at ~52%.

Built from `mart_monthly_business_review`; see slide 1 of [the deck](analysis/thelook_mbr_sep2026.pdf).

### Part 2 – Visual 2. New vs returning revenue mix, alongside 90-day churn

See slide 2 of [the deck](analysis/thelook_mbr_sep2026.pdf).

### Part 2 – Visual 3. Supporting the top recommendation

See slide 3 of [the deck](analysis/thelook_mbr_sep2026.pdf).

### Part 2 – Questions addressed (Q2, Q3) and recommendations

**Q2. The one thing leadership should know** (deck, slide 2). The CEO is half
right: growth is acquisition-led (new customers +98% YoY, 85% of active
customers), but repeat is improving, not weakening: 90-day churn fell from
98.2% to 96.6% (January–June 2025 vs January–June 2026, significant); single
months are noisy (June vs June: 96.5% to 95.9%, not significant). Confidence:
the dataset was tested extensively (see
[Part 1 – A1](#part-1--a1-data-quality-checks)), but it is regenerated between
runs, so single-month MoM figures are not robust; yearly and half-year trends
are.

**Q3. Prioritization** (deck, slide 3). **Repeat purchase**: new customers
already feed it (25% of returning revenue in September 2026, and 16–34% since
April, up from 7–13% between October 2025 and March 2026), yet most never buy
twice. Primary metric: 90-day churn of new customers;
secondary: returning share of revenue.

**Recommendations** (deck, slide 3):
1. **Improve repeat among newly acquired customers:** product recommendations
   based on the first order, then a time-limited second-order offer around day
   30–60, run as an A/B test with a holdout group.
2. **Shift part of paid spend to repeat efforts:** get the real cost per
   channel, then move part of the marginal paid budget (Facebook, Display,
   about 10% of new-customer revenue) to second-purchase actions.

## What I skipped / would do with more time

- **A dashboard in Looker Studio.** I started building the visuals there, but
  did not have time to finish. I chose to spend the time on validating the
  data and interpreting the results rather than on learning a visualization
  tool I have not used before (I know the concepts from other BI tools). The
  charts are built from the same reporting table
  (`mart_monthly_business_review`, persisted by Part 1), so a Looker Studio
  dashboard can be plugged on it directly.

## Part 3 – AI & analytics

### Part 3 – 3.1. Workflow idea: an internal "ask the metrics" space, rolled out in stages

A natural-language question interface over the governed marts, built like a
Databricks Genie space (which I used daily at Zillow), or its Google
equivalent: a BigQuery data agent / Conversational Analytics in Looker,
grounded in the semantic layer. It stays **internal**: a tool that can make
mistakes is never opened directly to clients. Rollout in stages, each one
gated on measured quality:
1. **Data analysts** first, as an accelerator: they know the right answers, so
   they validate how the agent behaves and feed corrections back.
2. **Product teams** next: comfortable with technical notions and able to
   spot an odd answer.
3. **Less technical stakeholders** last (Marketing, Finance, Customer
   Success), once accuracy is proven.

Brand partners benefit indirectly: analysts use partner-scoped spaces to
prepare monthly scorecards faster, and every output is reviewed before it is
sent.

**What data goes in, and what does not**
- In: the curated marts only (`mart_monthly_health`, `mart_customer_mix`,
  `mart_churn_90d`), their metric definitions, column descriptions and a set
  of verified example queries.
- Out, by construction (whatever is not added to the space does not exist for
  the agent):
  - raw tables (`order_items`, `events`…): the agent could recompute revenue
    its own way, and we would be back to "different teams, different numbers";
  - personal data (names, emails, addresses, IP, precise location): tables are
    exposed through column-restricted views;
  - in a partner-scoped space: other partners' data, and internal data such as
    cost and margin.

**Key system prompt (space instructions)**
> You answer questions about TheLook's business metrics using only the tables
> and metric definitions provided. Revenue means completed sales (status
> Complete, not returned); months are attributed by order date; churn uses
> the 90-day definition and only mature months. Use the verified queries for
> these metrics; never redefine them. Always state the period and show the
> query used. If a question cannot be answered from the data, say so instead
> of guessing. Describe what the data shows; never state a cause the data does
> not support, and label any possible explanation as a hypothesis.

**Guardrails**
- Wrong numbers: verified queries for key metrics; the generated SQL is always
  shown; a benchmark set of questions with known answers is re-run after every
  change to the space.
- Invented explanations: the agent reports facts ("revenue fell 8% MoM");
  causes are hypotheses or not given.
- Leakage between partners: partners never query the agent. To prepare a
  partner's scorecard, analysts use a space built on a view filtered on that
  partner's data only, so the output can never mix partners.
  At scale, a single space with row-level security based on the user's identity
  (Unity Catalog row filters, or BigQuery row-level security / Looker access
  filters), to keep one set of metric definitions. Market benchmarks only as
  aggregates over enough brands (e.g. 5+) that none is identifiable.

**Human in the loop**
- Users mark answers as correct or incorrect; flagged answers go to the space
  owner (data team), who fixes instructions, definitions or example queries.
  This is curation, not model retraining.
- Each rollout stage opens only after the previous one meets the quality bar.
- Nothing produced with the agent reaches a partner without an analyst's
  review.

**How I would measure it, and when I would shut it down**

| Area | Metric |
|---|---|
| Adoption | weekly active users per stage, questions per user, share of partner scorecards prepared with it |
| Output quality | share of answers marked correct; score on the benchmark set |
| Efficiency | fewer ad hoc requests to the data team; time to answer |
| Business impact | decisions traced to answers; faster partner scorecards |

Shut down (or roll back to analysts only) if: any data from one partner shows
up in another partner's output (immediate stop); benchmark accuracy falls below a threshold (e.g. 90%); or
adoption stays low after a pilot of a few weeks.

### Part 3 – 3.2. AI use in this challenge

- **Tool and role:** Claude (chat) as an accelerator and reviewer, not as the
  author. I set the approach (dbt-style layers, order of work, scope), the
  metric definitions and the recommendations; Claude drafted SQL on request,
  challenged definitions and built chart prototypes. Every query was run and
  checked in BigQuery before being kept.
- **Example prompt:** *"Show me a query on the order items dated in the
  future. What I want to show: less than 1% of item volume, X% of total revenue
  and Y% of monthly revenue, only the current month affected, easy to exclude
  by filtering up to the current date, and worth fixing at the source."*
  Running it led to the top finding: item dates do not match order dates.
- **Example prompt to validate an interpretation** (paraphrased): *"Returning
  revenue grows while churn stays at 95%. My reading: the growth comes from
  customers we just acquired, not from a loyal base. Write the query that
  would confirm or reject it."* The query split returning revenue by
  acquisition date: customers acquired in the previous 3 months went from
  7–13% of returning revenue (October 2025 to March 2026) to 16–34% since
  April, which confirmed the reading and became
  the storyline of slide 3 ("protect acquisition, and make it pay twice").
  The split was then reconciled with B1 (same returning share every month).
- **How I validated outputs:**
  - reconciled the monthly revenue of the mart with an independent query
    attributing items by order date (September 2026: $117,542.03 in both);
  - when a refresh changed the figures, checked the source tables' last
    rewrite time (`__TABLES__.last_modified_time`) to separate a data change
    from a code change;
  - recomputed the returning share of revenue from a separate query (recent vs
    established customers): it matches B1 to the decimal every month;
  - cross-source check: purchase sessions equal order items every month (on
    the October 24 run; see A1 for the frozen run);
  - spot-checked single rows end to end (one inventory item across
    `order_items` and `inventory_items`);
  - KPIs in the slides recomputed from the reporting table.
- **What the AI got wrong, and how I caught it:**
  - It repeatedly presented assumptions and estimates as facts, without saying
    they did not come from the data, which caused confusion several times. I
    caught each one by asking for the source, then checked it against the data:
    - schema: it wrote `inventory_items` columns from memory, then removed them
      when questioned; `INFORMATION_SCHEMA.COLUMNS` showed they did exist;
    - figures: customer base growth and the share of late returners were
      back-of-envelope estimates, later replaced by a real query;
    - recommendation: "improve repeat purchase" was pushed without weighing
      acquisition, until the revenue increment (80% from new customers) led to
      the final framing: protect acquisition and make it pay twice.
