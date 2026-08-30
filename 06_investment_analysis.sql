-- ============================================================================
-- 06_investment_analysis.sql
-- Supporting queries for reports/investment_recommendation.md (Question 4).
-- ============================================================================

-- Current human-calling capacity & cost anchors.
CREATE OR REPLACE TABLE inv_capacity_anchors AS
  WITH attempts AS (
    SELECT AVG(n) AS avg_attempts_per_month FROM (
      SELECT date_trunc('month', event_at) m, COUNT(*) n
      FROM raw_call_attempts WHERE event_at < DATE '2026-08-01' GROUP BY 1
    )
  ),
  hours AS (
    SELECT AVG(agent_hours) AS avg_agent_hours_per_month
    FROM metric_monthly_agent_hours WHERE event_month < DATE '2026-08-01'
  ),
  recov AS (
    SELECT AVG(recovery_rupees) AS avg_monthly_recovery,
           AVG(recovery_per_agent_hour) AS avg_recovery_per_agent_hour
    FROM metric_monthly_recovery_per_agent_hour WHERE event_month < DATE '2026-08-01'
  )
  SELECT a.avg_attempts_per_month, h.avg_agent_hours_per_month,
         ROUND(a.avg_attempts_per_month / h.avg_agent_hours_per_month, 2) AS attempts_per_agent_hour,
         r.avg_monthly_recovery, r.avg_recovery_per_agent_hour
  FROM attempts a, hours h, recov r;

-- Attempt-frequency dose-response (why "more calling" is not the recommendation).
CREATE OR REPLACE TABLE inv_attempt_frequency_doseresponse AS
  WITH monthly_attempts AS (
    SELECT account_id, date_trunc('month', event_at) m, COUNT(*) n_attempts
    FROM raw_call_attempts GROUP BY 1,2
  ),
  paid AS (
    SELECT DISTINCT account_id, date_trunc('month', event_at) m FROM raw_payments WHERE payment_status='SUCCESS'
  )
  SELECT CASE WHEN n_attempts=1 THEN '1' WHEN n_attempts BETWEEN 2 AND 3 THEN '2-3'
              WHEN n_attempts BETWEEN 4 AND 6 THEN '4-6' ELSE '7+' END AS bucket,
         COUNT(*) AS n_acct_months, COUNT(p.account_id) AS n_paid,
         ROUND(100.0*COUNT(p.account_id)/COUNT(*),2) AS pay_rate_pct
  FROM monthly_attempts ma
  LEFT JOIN paid p ON p.account_id = ma.account_id AND p.m = ma.m
  GROUP BY 1 ORDER BY 1;

-- WhatsApp dose-response (why digital is the recommendation).
CREATE OR REPLACE TABLE inv_whatsapp_doseresponse AS
  WITH wa AS (
    SELECT account_id, date_trunc('month', event_at) m, COUNT(*) n_wa
    FROM clean_whatsapp_events GROUP BY 1,2
  ),
  paid AS (
    SELECT DISTINCT account_id, date_trunc('month', event_at) m FROM raw_payments WHERE payment_status='SUCCESS'
  )
  SELECT CASE WHEN n_wa=1 THEN '1' WHEN n_wa=2 THEN '2' WHEN n_wa BETWEEN 3 AND 4 THEN '3-4' ELSE '5+' END AS bucket,
         COUNT(*) AS n, COUNT(p.account_id) AS n_paid,
         ROUND(100.0*COUNT(p.account_id)/COUNT(*),2) AS pay_rate_pct
  FROM wa LEFT JOIN paid p ON p.account_id = wa.account_id AND p.m = wa.m
  GROUP BY 1 ORDER BY 1;

-- WhatsApp reach & headroom.
CREATE OR REPLACE TABLE inv_whatsapp_reach AS
  SELECT
    (SELECT COUNT(DISTINCT account_id) FROM clean_whatsapp_events) AS accounts_ever_touched,
    (SELECT COUNT(*) FROM raw_accounts) AS total_accounts,
    (SELECT COUNT(*) FROM raw_accounts WHERE account_id NOT IN (SELECT account_id FROM clean_whatsapp_events)) AS accounts_never_touched,
    (SELECT COUNT(*)*1.0/COUNT(DISTINCT account_id) FROM clean_whatsapp_events) AS avg_events_per_touched_account;

-- daily_targeting.priority vs pay rate (targeting-lever check).
CREATE OR REPLACE TABLE inv_priority_doseresponse AS
  WITH dt AS (SELECT account_id, target_date, priority FROM raw_daily_targeting),
  paidmonth AS (SELECT DISTINCT account_id, date_trunc('month', event_at) m FROM raw_payments WHERE payment_status='SUCCESS')
  SELECT dt.priority, COUNT(*) AS n, COUNT(p.account_id) AS n_paid,
         ROUND(100.0*COUNT(p.account_id)/COUNT(*),2) AS pay_rate_pct
  FROM dt LEFT JOIN paidmonth p ON p.account_id = dt.account_id AND p.m = date_trunc('month', dt.target_date)
  GROUP BY 1 ORDER BY 1;
