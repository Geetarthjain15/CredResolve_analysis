-- ============================================================================
-- 02_clean_events.sql
-- Cleans the event-level (fact) tables: calls, call_attempts,
-- call_dispositions, whatsapp_events, sms_events, field_visits,
-- promises_to_pay, payments, complaints, account_status_history,
-- daily_targeting.
--
-- Row-count audit (raw -> distinct primary key), used to decide where
-- de-duplication is actually required:
--   calls                    91,350 rows / 90,000 distinct call_id            -> DEDUPE
--   call_attempts            120,000 / 120,000                                 -> clean
--   call_dispositions        35,000 / 35,000 (but code synonyms) -> CANONICALIZE
--   whatsapp_events          60,600 / 60,000 distinct whatsapp_event_id        -> DEDUPE
--   sms_events                45,000 / 45,000                                  -> clean
--   field_visits              25,000 / 25,000                                  -> clean
--   promises_to_pay           18,000 / 18,000                                  -> clean
--   payments                  25,500 / 25,000 distinct payment_id             -> DEDUPE
--   complaints                 8,000 / 8,000                                   -> clean
--   account_status_history    60,000 / 60,000 (but conflicts w/ accounts.status) -> RECONCILE
--   daily_targeting           45,000 / 45,000                                  -> clean
-- ============================================================================

-- ---------------------------------------------------------------------------
-- CALLS: 1,350 call_ids appear >1 time (2,700 rows). Of those groups, 1,271
-- are byte-for-byte exact duplicates (drop straight away). The remaining 79
-- groups have the SAME call_id but disagree on one field:
--   (a) agent_id NULL in one copy, populated in the other  -> keep populated
--   (b) event_at differs by a few days, everything else identical -> keep
--       the EARLIEST event_at as canonical (treated as a re-ingested /
--       re-logged echo of the original call, not a second real call).
-- Net effect: 91,350 raw rows -> 90,000 golden rows (-1,350, -1.48%).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_calls AS
  WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
             PARTITION BY call_id
             ORDER BY (agent_id IS NOT NULL) DESC, event_at ASC
           ) AS rn
    FROM raw_calls
  )
  SELECT call_id, account_id, borrower_id, event_at, agent_id, campaign_id,
         direction, vendor_id, call_status, duration_sec, timezone
  FROM ranked
  WHERE rn = 1;

-- ---------------------------------------------------------------------------
-- CALL ATTEMPTS: no de-dup required (clean 1:1 on attempt_id).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_call_attempts AS
  SELECT * FROM raw_call_attempts;

-- ---------------------------------------------------------------------------
-- CALL DISPOSITIONS: no row-level duplication, but the disposition_code
-- vocabulary contains a synonym pair -- 'PTP' and 'PROMISE_TO_PAY' co-occur
-- in every version tag (legacy/v1/v2) at a near-identical ~50/50 split in
-- every month (e.g. Jan: PROMISE_TO_PAY=588 vs PTP=566). These are the same
-- business event under two different labels, not two different outcomes.
-- disposition_version itself does NOT correlate with calendar time (all
-- three tags span the full Jan-Aug window), so it is not usable as a
-- "before/after a schema migration" signal -- we keep it only as metadata.
-- We canonicalize to a single 8-value disposition taxonomy.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_call_dispositions AS
  SELECT disposition_id, account_id, borrower_id, event_at, call_id, agent_id,
         CASE WHEN disposition_code = 'PROMISE_TO_PAY' THEN 'PTP'
              ELSE disposition_code END AS disposition_code_canonical,
         disposition_code AS disposition_code_raw,
         disposition_version
  FROM raw_call_dispositions;

-- ---------------------------------------------------------------------------
-- WHATSAPP EVENTS: 600 exact duplicate whatsapp_event_id rows -> drop.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_whatsapp_events AS
  WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY whatsapp_event_id ORDER BY event_at) AS rn
    FROM raw_whatsapp_events
  )
  SELECT whatsapp_event_id, account_id, borrower_id, event_at, message_id,
         event_type, template_code, provider_id
  FROM ranked WHERE rn = 1;

-- ---------------------------------------------------------------------------
-- SMS EVENTS: no de-dup required.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_sms_events AS
  SELECT * FROM raw_sms_events;

-- ---------------------------------------------------------------------------
-- FIELD VISITS / PROMISES TO PAY / COMPLAINTS / DAILY TARGETING: clean.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_field_visits    AS SELECT * FROM raw_field_visits;
CREATE OR REPLACE TABLE clean_promises_to_pay AS SELECT * FROM raw_promises_to_pay;
CREATE OR REPLACE TABLE clean_complaints      AS SELECT * FROM raw_complaints;
CREATE OR REPLACE TABLE clean_daily_targeting AS SELECT * FROM raw_daily_targeting;

-- ---------------------------------------------------------------------------
-- PAYMENTS: 500 exact-duplicate payment_id rows (486 fully identical, 14
-- identical except payment_reference is NULL in one copy) -> drop, keeping
-- the row with a non-null payment_reference when one exists.
--
-- IMPORTANT -- what we did NOT do: we did NOT collapse rows by
-- payment_reference. payment_reference is reused across genuinely different
-- payments (different payment_id, different amount, different event_at) --
-- e.g. reference TXN0000050468 legitimately covers 3 distinct part-payments.
-- Collapsing by reference would have thrown away ~14% of real recovered
-- rupees. The correct grain for "one payment event" is payment_id, not
-- payment_reference.
--
-- Net effect on recognised recovery (status = SUCCESS):
--   naive SUM(amount)            : Rs 1,341,485,926  (all raw SUCCESS rows)
--   golden SUM(amount)           : Rs 1,315,583,965  (post de-dup)
--   overstatement removed        : Rs   25,901,962  (1.93%)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_payments AS
  WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
             PARTITION BY payment_id
             ORDER BY (payment_reference IS NOT NULL) DESC, event_at ASC
           ) AS rn
    FROM raw_payments
  )
  SELECT payment_id, account_id, borrower_id, event_at, payment_reference,
         amount, payment_status, payment_method, provider_id
  FROM ranked
  WHERE rn = 1;

-- ---------------------------------------------------------------------------
-- ACCOUNT STATUS HISTORY: no row-level duplication (60,000/60,000 distinct
-- history_id). But accounts.status (the dimension "snapshot") disagrees
-- with the LATEST status per account in this event log for 22,295 / 25,999
-- accounts that have any history (85.7%). We cannot tell from the data
-- which source is authoritative -- flagged as an open question for the
-- product/engineering team in the DQ report. For golden-dataset purposes we
-- treat the event log as the higher-fidelity source (it is timestamped and
-- traceable to a `source` system) and expose status_from_history as the
-- "best available" current status, while retaining accounts.status_snapshot
-- unchanged alongside it so nothing is silently overwritten.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_account_status_history AS
  SELECT * FROM raw_account_status_history;

CREATE OR REPLACE TABLE stg_account_latest_status AS
  WITH ranked AS (
    SELECT account_id, status, event_at, source,
           ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY event_at DESC) AS rn
    FROM clean_account_status_history
  )
  SELECT account_id, status AS status_from_history, event_at AS status_from_history_at, source AS status_from_history_source
  FROM ranked WHERE rn = 1;
