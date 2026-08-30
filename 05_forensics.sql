-- ============================================================================
-- 05_forensics.sql
-- Reproducible queries behind Part 2 (Data Forensics), items A-G.
-- Each block is runnable standalone against analysis.duckdb after
-- 00-03 have been run. Findings and business impact are written up in
-- reports/data_quality_report.md; this file is the evidence trail.
-- ============================================================================

-- A. DUPLICATE PAYMENTS -- CONFIRMED, quantified, corrected.
--    500 of 25,500 payment rows are exact duplicates of another row's
--    payment_id. Naive SUM(amount WHERE status='SUCCESS') overstates
--    recovery by Rs 25,901,962 (1.93%). Fixed in clean_payments.
SELECT 'A_duplicate_payments' AS check_name,
       (SELECT SUM(amount) FROM raw_payments WHERE payment_status='SUCCESS')   AS naive_success_amount,
       (SELECT SUM(amount) FROM clean_payments WHERE payment_status='SUCCESS') AS golden_success_amount,
       (SELECT SUM(amount) FROM raw_payments WHERE payment_status='SUCCESS')
         - (SELECT SUM(amount) FROM clean_payments WHERE payment_status='SUCCESS') AS overstatement_rupees;

-- B. ATTRIBUTION ERRORS -- CONFIRMED as a methodology risk, not a data bug.
--    Payments carry NO campaign_id / call_id / channel of their own. Any
--    "recovery by campaign" or "recovery by channel" figure MUST be built
--    by attributing a payment to the nearest preceding touchpoint within a
--    chosen window -- there is no ground truth link. Below: how much the
--    attributed campaign for a payment changes if we use a 3-day vs 30-day
--    look-back window (the "wrong attribution window" failure mode named
--    in Part 3).
WITH touches AS (
  SELECT account_id, event_at, campaign_id FROM golden_calls WHERE campaign_id IS NOT NULL
),
pay AS (
  SELECT payment_id, account_id, event_at AS pay_at FROM golden_payments WHERE payment_status='SUCCESS'
),
attr_3d AS (
  SELECT p.payment_id,
         (SELECT t.campaign_id FROM touches t
          WHERE t.account_id = p.account_id AND t.event_at <= p.pay_at
            AND t.event_at >= p.pay_at - INTERVAL 3 DAY
          ORDER BY t.event_at DESC LIMIT 1) AS campaign_3d
  FROM pay p
),
attr_30d AS (
  SELECT p.payment_id,
         (SELECT t.campaign_id FROM touches t
          WHERE t.account_id = p.account_id AND t.event_at <= p.pay_at
            AND t.event_at >= p.pay_at - INTERVAL 30 DAY
          ORDER BY t.event_at DESC LIMIT 1) AS campaign_30d
  FROM pay p
)
SELECT 'B_attribution_window_sensitivity' AS check_name,
       COUNT(*) AS total_success_payments,
       COUNT(a3.campaign_3d)  AS attributable_within_3d,
       COUNT(a30.campaign_30d) AS attributable_within_30d,
       SUM(CASE WHEN a3.campaign_3d IS DISTINCT FROM a30.campaign_30d THEN 1 ELSE 0 END) AS payments_whose_attributed_campaign_changes
FROM pay p
JOIN attr_3d a3 USING (payment_id)
JOIN attr_30d a30 USING (payment_id);

-- C. TIMEZONE PROBLEMS -- CONFIRMED as a data-contract defect; immaterial
--    to the trend (event timing is ~uniform across hours regardless).
--    73.5% of accounts show calls tagged with MORE THAN ONE timezone label
--    across their own history -- timezone is being recorded per-event, not
--    as a stable property of the account/borrower.
SELECT 'C_timezone_inconsistency' AS check_name,
       (SELECT COUNT(*) FROM (
          SELECT account_id FROM raw_calls GROUP BY 1 HAVING COUNT(DISTINCT timezone) > 1
       )) AS accounts_with_multiple_tz_labels,
       (SELECT COUNT(DISTINCT account_id) FROM raw_calls) AS accounts_with_any_call,
       (SELECT COUNT(*) FROM raw_calls c JOIN raw_accounts a USING(account_id) WHERE c.timezone != a.timezone) AS calls_where_call_tz_ne_account_tz;

-- D. VENDOR MAPPING / DISPOSITION CODE CHANGES -- NOT CONFIRMED as a
--    material issue for call_status (vocabulary and rates are stable across
--    all 15 vendors and all 3 vendor schema_versions -- answer rate range
--    19.3%-20.1%, within sampling noise). The one genuine code-drift issue
--    found is the PTP/PROMISE_TO_PAY synonym pair in call_dispositions
--    (see A/B above and clean_call_dispositions) -- that is a disposition
--    labeling issue, not a vendor-mapping issue.
SELECT 'D_vendor_call_status_stability' AS check_name,
       vendor_id,
       COUNT(*) AS total_calls,
       ROUND(100.0*COUNT(*) FILTER (WHERE call_status='ANSWERED')/COUNT(*),1) AS answer_rate_pct
FROM raw_calls GROUP BY vendor_id ORDER BY 1;

-- E. AGENT IDENTITY PROBLEMS -- CONFIRMED, severe. See 01_clean_dimensions.sql
--    header. agent_id is the only usable key (0 orphans against calls);
--    employee_code/agent_name/team/vendor_id are scrambled at the row
--    level for the SAME agent_id.
SELECT 'E_agent_identity_chaos' AS check_name,
       COUNT(*) AS raw_agent_rows,
       COUNT(DISTINCT agent_id) AS distinct_agent_id,
       COUNT(DISTINCT employee_code) AS distinct_employee_code,
       COUNT(DISTINCT agent_name) AS distinct_agent_name_values
FROM raw_agents;

-- F. PORTFOLIO MIX CHANGES -- NOT CONFIRMED. risk_segment and loan_type
--    composition of accounts making successful payments is stable
--    (+/-3pp) across all 7 complete months -- no evidence of a
--    fundamentally different portfolio being acquired mid-year.
SELECT 'F_portfolio_mix_by_month' AS check_name,
       m, risk_segment, n_accounts,
       ROUND(100.0*n_accounts / SUM(n_accounts) OVER (PARTITION BY m), 1) AS pct_of_month
FROM (
  SELECT date_trunc('month', p.event_at) AS m, a.risk_segment,
         COUNT(DISTINCT p.account_id) AS n_accounts
  FROM raw_payments p JOIN raw_accounts a USING(account_id)
  WHERE p.payment_status='SUCCESS'
  GROUP BY 1,2
)
ORDER BY m, risk_segment;

-- G. DENOMINATOR MANIPULATION -- NOT CONFIRMED in daily_targeting (targeted
--    population is flat at ~6,150 accounts/month across statuses). This
--    does NOT rule out denominator games in the business's own (unseen)
--    reporting pipeline -- we flag the RISK and show, as a worked example,
--    how differently "contact rate" reads depending on whether the
--    denominator is (i) all accounts ever opened, (ii) accounts with any
--    call attempt this month, or (iii) accounts still ACTIVE this month.
WITH d1 AS (SELECT COUNT(*) n FROM raw_accounts),                                   -- whole portfolio
     d2 AS (SELECT COUNT(DISTINCT account_id) n FROM raw_calls WHERE event_at >= '2026-07-01' AND event_at < '2026-08-01'), -- worked in July
     d3 AS (SELECT COUNT(*) n FROM raw_accounts WHERE status='ACTIVE'),             -- active only
     num AS (SELECT COUNT(DISTINCT account_id) n FROM raw_calls WHERE call_status='ANSWERED' AND event_at >= '2026-07-01' AND event_at < '2026-08-01')
SELECT 'G_denominator_choice_sensitivity' AS check_name,
       (SELECT n FROM num) AS july_accounts_answered,
       (SELECT n FROM d1) AS denom_whole_portfolio,
       (SELECT n FROM d2) AS denom_worked_this_month,
       (SELECT n FROM d3) AS denom_active_only,
       ROUND(100.0*(SELECT n FROM num)/(SELECT n FROM d1),2) AS rate_vs_whole_portfolio_pct,
       ROUND(100.0*(SELECT n FROM num)/(SELECT n FROM d2),2) AS rate_vs_worked_this_month_pct,
       ROUND(100.0*(SELECT n FROM num)/(SELECT n FROM d3),2) AS rate_vs_active_only_pct;
