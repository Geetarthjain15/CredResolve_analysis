-- ============================================================================
-- 03_golden_build.sql
-- Assembles the Golden analytical layer from the clean_* tables built in
-- 01_clean_dimensions.sql and 02_clean_events.sql.
--
-- Golden layer =  one row per real-world business event / entity, deduped,
-- with canonical codes, joined to enough dimension context to analyse
-- without re-deriving these decisions every time.
--
-- Exclusion rules applied (documented, not silent):
--   * Analysis window is capped at [2026-01-01, 2026-08-01) i.e. complete
--     calendar months only. 2025-12 has a single stray call row (pre-window
--     noise, excluded) and 2026-08 has only 8 days of data as of the
--     extract date -- included in golden tables for completeness but
--     EXCLUDED from all month-over-month trend comparisons because a
--     partial month will always look like a "decline" versus a full month
--     (in this data: -74% vs July) purely from missing days, not
--     performance. This is flagged explicitly wherever monthly trends are
--     computed (see 04_metrics.sql).
-- ============================================================================

CREATE OR REPLACE VIEW golden_accounts AS
  SELECT a.*,
         b.identity_conflict_flag AS borrower_identity_conflict_flag,
         h.status_from_history,
         h.status_from_history_at,
         (h.status_from_history IS NOT NULL AND a.status_snapshot IS DISTINCT FROM h.status_from_history) AS status_source_conflict_flag
  FROM clean_accounts a
  LEFT JOIN clean_borrowers b USING (borrower_id)
  LEFT JOIN stg_account_latest_status h USING (account_id);

CREATE OR REPLACE VIEW golden_payments AS
  SELECT p.*,
         date_trunc('month', p.event_at) AS event_month,
         a.risk_segment, a.loan_type, a.dpd_bucket
  FROM clean_payments p
  LEFT JOIN clean_accounts a USING (account_id)
  WHERE p.event_at >= DATE '2026-01-01';

CREATE OR REPLACE VIEW golden_calls AS
  SELECT c.*,
         date_trunc('month', c.event_at) AS event_month,
         camp.channel        AS campaign_channel,
         camp.strategy_version,
         camp.target_definition,
         v.vendor_name
  FROM clean_calls c
  LEFT JOIN clean_campaigns camp USING (campaign_id)
  LEFT JOIN clean_vendor_telephony v USING (vendor_id)
  WHERE c.event_at >= DATE '2026-01-01';

CREATE OR REPLACE VIEW golden_call_dispositions AS
  SELECT d.*, date_trunc('month', d.event_at) AS event_month
  FROM clean_call_dispositions d
  WHERE d.event_at >= DATE '2026-01-01';

CREATE OR REPLACE VIEW golden_promises_to_pay AS
  SELECT t.*, date_trunc('month', t.event_at) AS event_month
  FROM clean_promises_to_pay t
  WHERE t.event_at >= DATE '2026-01-01';

-- ---------------------------------------------------------------------------
-- Data-cleaning impact summary: Raw -> Rejected/Corrected -> Golden counts,
-- for the Part 1 deliverable ("quantify the impact of your cleaning
-- decisions").
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dq_cleaning_impact AS
  SELECT 'borrowers' AS table_name,
         (SELECT COUNT(*) FROM raw_borrowers) AS raw_rows,
         (SELECT COUNT(*) FROM raw_borrowers) - (SELECT COUNT(*) FROM clean_borrowers) AS rows_removed,
         (SELECT COUNT(*) FROM clean_borrowers) AS golden_rows,
         'Deduped to 1 row per borrower_id (latest updated_at). 8,518 of 11,015 borrower_ids (77%) had internally conflicting name/phone/email/city across raw rows -- flagged, not resolved.' AS note
  UNION ALL
  SELECT 'agents', (SELECT COUNT(*) FROM raw_agents),
         (SELECT COUNT(*) FROM raw_agents) - (SELECT COUNT(*) FROM clean_agents),
         (SELECT COUNT(*) FROM clean_agents),
         'Collapsed 30,000 scrambled rows to 1,000 agent_id via attribute mode. Team/vendor per agent are low-confidence reconstructions.'
  UNION ALL
  SELECT 'calls', (SELECT COUNT(*) FROM raw_calls),
         (SELECT COUNT(*) FROM raw_calls) - (SELECT COUNT(*) FROM clean_calls),
         (SELECT COUNT(*) FROM clean_calls),
         'Dropped 1,350 duplicate call_id rows (1,271 exact dupes + 79 conflicting copies resolved by rule).'
  UNION ALL
  SELECT 'whatsapp_events', (SELECT COUNT(*) FROM raw_whatsapp_events),
         (SELECT COUNT(*) FROM raw_whatsapp_events) - (SELECT COUNT(*) FROM clean_whatsapp_events),
         (SELECT COUNT(*) FROM clean_whatsapp_events),
         'Dropped 600 exact duplicate whatsapp_event_id rows.'
  UNION ALL
  SELECT 'payments', (SELECT COUNT(*) FROM raw_payments),
         (SELECT COUNT(*) FROM raw_payments) - (SELECT COUNT(*) FROM clean_payments),
         (SELECT COUNT(*) FROM clean_payments),
         'Dropped 500 duplicate payment_id rows. Removed Rs 2.59 Cr (1.93%) of double-counted SUCCESS amount. payment_reference NOT used as dedup key (legitimately reused across distinct payments).'
  UNION ALL
  SELECT 'call_dispositions', (SELECT COUNT(*) FROM raw_call_dispositions),
         0,
         (SELECT COUNT(*) FROM clean_call_dispositions),
         'No row-level dedup. Canonicalized PROMISE_TO_PAY -> PTP (same event, two labels, ~50/50 split every month).'
  UNION ALL
  SELECT 'account_status_history', (SELECT COUNT(*) FROM raw_account_status_history),
         0,
         (SELECT COUNT(*) FROM clean_account_status_history),
         'No row-level dedup. 85.7% of accounts disagree between accounts.status and latest history status -- flagged, both kept.';
