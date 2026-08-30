-- ============================================================================
-- 04_metrics.sql
-- Independent metric definitions (Question 3) and the monthly performance
-- reconstruction (Question 1).
--
-- METRIC DEFINITIONS (and why):
--
--  contact_rate      = accounts with >=1 ANSWERED call in month / accounts
--                       with >=1 call attempt in month.
--                       (Denominator = accounts actually WORKED, not the
--                       whole portfolio -- see "denominator manipulation"
--                       discussion in the DQ report for why whole-portfolio
--                       denominators are dangerous here.)
--  RPC (Right-Party Contact) = we do not have an explicit "right party"
--                       flag in calls; call_status=ANSWERED is the closest
--                       proxy available and is what we report as RPC. This
--                       is a documented approximation, not a Fact.
--  PTP_rate          = accounts with >=1 canonical PTP disposition (or a
--                       row in promises_to_pay) in month / accounts with
--                       >=1 ANSWERED call in month.
--  PTP_kept_rate     = promises_to_pay with status='KEPT' / all promises_to_pay
--                       with status in ('KEPT','BROKEN') created in month
--                       (excludes OPEN/CANCELLED, which have not resolved
--                       yet and would bias the rate if included as failures).
--  recovery_$        = SUM(amount) for clean_payments WHERE payment_status
--                       = 'SUCCESS', grouped by event_month. This is the
--                       golden (de-duplicated) figure -- see 03_golden_build.
--  recovery_rate     = recovery_$ in month / SUM(outstanding_amount) for
--                       accounts with a payment in that month (an
--                       account-weighted proxy for "how much of what was
--                       owed came back", since we do not have a true
--                       month-opening-balance snapshot in this dataset).
--  recovery_per_account = recovery_$ / distinct accounts with a SUCCESS
--                       payment in the month.
--  recovery_per_agent_hour = recovery_$ / total agent-hours logged in the
--                       month (from agent_sessions login/logout).
--  cost_per_rupee_recovered = NOT COMPUTED. There is no cost/spend table in
--                       this dataset (no agent wages, telephony per-minute
--                       cost, WhatsApp/SMS per-message cost). Any figure
--                       would be invented. We say so explicitly rather than
--                       fabricate a number -- see Question 3 answer.
--  channel_conversion = accounts touched by a channel (via campaign) in
--                       month with a SUCCESS payment within 14 days of
--                       being touched / accounts touched by that channel.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Monthly headline recovery trend (Question 1 / Question 3 core table).
-- Restricted to complete months (2026-01 through 2026-07); 2026-08 is
-- reported separately and flagged as partial.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE metric_monthly_recovery AS
  SELECT event_month,
         SUM(amount)                          AS recovery_rupees,
         COUNT(*)                             AS n_success_payments,
         COUNT(DISTINCT account_id)           AS n_accounts_paid,
         ROUND(SUM(amount) / COUNT(DISTINCT account_id), 2) AS recovery_per_account
  FROM golden_payments
  WHERE payment_status = 'SUCCESS'
  GROUP BY 1
  ORDER BY 1;

CREATE OR REPLACE TABLE metric_monthly_recovery_mom AS
  SELECT event_month, recovery_rupees, n_success_payments, n_accounts_paid, recovery_per_account,
         LAG(recovery_rupees) OVER (ORDER BY event_month) AS prev_month_recovery,
         ROUND(100.0 * (recovery_rupees - LAG(recovery_rupees) OVER (ORDER BY event_month))
               / NULLIF(LAG(recovery_rupees) OVER (ORDER BY event_month), 0), 2) AS mom_pct_change
  FROM metric_monthly_recovery
  ORDER BY event_month;

-- ---------------------------------------------------------------------------
-- Contact rate / RPC / PTP rate / PTP kept rate, by month (complete months
-- only for trend reading; 2026-08 included but should be read as partial).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE metric_monthly_funnel AS
  WITH worked AS (
    SELECT event_month, account_id,
           MAX(CASE WHEN call_status = 'ANSWERED' THEN 1 ELSE 0 END) AS answered
    FROM golden_calls
    GROUP BY 1, 2
  ),
  ptp AS (
    SELECT event_month, account_id, COUNT(*) AS n_ptp
    FROM golden_call_dispositions
    WHERE disposition_code_canonical = 'PTP'
    GROUP BY 1, 2
  )
  SELECT w.event_month,
         COUNT(*)                                     AS accounts_worked,
         SUM(w.answered)                               AS accounts_answered,
         ROUND(100.0 * SUM(w.answered) / COUNT(*), 2)  AS contact_rate_pct,
         COUNT(DISTINCT p.account_id) FILTER (WHERE p.n_ptp > 0) AS accounts_with_ptp,
         ROUND(100.0 * COUNT(DISTINCT p.account_id) FILTER (WHERE p.n_ptp > 0)
               / NULLIF(SUM(w.answered), 0), 2)        AS ptp_rate_pct
  FROM worked w
  LEFT JOIN ptp p ON p.event_month = w.event_month AND p.account_id = w.account_id
  GROUP BY w.event_month
  ORDER BY 1;

CREATE OR REPLACE TABLE metric_monthly_ptp_kept AS
  SELECT event_month,
         COUNT(*) FILTER (WHERE status IN ('KEPT','BROKEN'))                     AS resolved_ptps,
         COUNT(*) FILTER (WHERE status = 'KEPT')                                 AS kept_ptps,
         ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'KEPT')
               / NULLIF(COUNT(*) FILTER (WHERE status IN ('KEPT','BROKEN')), 0), 2) AS ptp_kept_rate_pct
  FROM golden_promises_to_pay
  GROUP BY 1
  ORDER BY 1;

-- ---------------------------------------------------------------------------
-- Recovery per agent-hour.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE metric_monthly_agent_hours AS
  SELECT date_trunc('month', login_at) AS event_month,
         SUM(date_diff('minute', login_at, logout_at)) / 60.0 AS agent_hours
  FROM raw_agent_sessions
  WHERE login_at >= DATE '2026-01-01'
  GROUP BY 1;

CREATE OR REPLACE TABLE metric_monthly_recovery_per_agent_hour AS
  SELECT r.event_month, r.recovery_rupees, h.agent_hours,
         ROUND(r.recovery_rupees / NULLIF(h.agent_hours, 0), 2) AS recovery_per_agent_hour
  FROM metric_monthly_recovery r
  LEFT JOIN metric_monthly_agent_hours h USING (event_month)
  ORDER BY 1;

-- ---------------------------------------------------------------------------
-- Statistical trend test on the complete months (Jan-Jul) -- is there a
-- genuine linear trend in recovery_rupees, or is month-to-month movement
-- consistent with noise around a flat mean?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE metric_trend_test_input AS
  SELECT event_month, recovery_rupees,
         ROW_NUMBER() OVER (ORDER BY event_month) - 1 AS t
  FROM metric_monthly_recovery
  WHERE event_month < DATE '2026-08-01';
  -- Linear regression / significance computed in the analysis notebook
  -- (Python scipy.stats.linregress) -- see notebook/analysis.ipynb, Section 4.
