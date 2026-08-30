-- ============================================================================
-- 00_load_raw.sql
-- Loads all 17 source CSVs into raw_* tables, unmodified, in DuckDB.
-- These are the "Raw" layer: exact copies of source data, no cleaning.
-- Run from the repo root: duckdb analysis.duckdb -f sql/00_load_raw.sql
-- ============================================================================

CREATE OR REPLACE TABLE raw_borrowers AS
  SELECT * FROM read_csv_auto('dataset/borrowers.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_accounts AS
  SELECT * FROM read_csv_auto('dataset/accounts.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_agents AS
  SELECT * FROM read_csv_auto('dataset/agents.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_agent_sessions AS
  SELECT * FROM read_csv_auto('dataset/agent_sessions.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_campaigns AS
  SELECT * FROM read_csv_auto('dataset/campaigns.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_daily_targeting AS
  SELECT * FROM read_csv_auto('dataset/daily_targeting.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_calls AS
  SELECT * FROM read_csv_auto('dataset/calls.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_call_attempts AS
  SELECT * FROM read_csv_auto('dataset/call_attempts.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_call_dispositions AS
  SELECT * FROM read_csv_auto('dataset/call_dispositions.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_whatsapp_events AS
  SELECT * FROM read_csv_auto('dataset/whatsapp_events.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_sms_events AS
  SELECT * FROM read_csv_auto('dataset/sms_events.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_field_visits AS
  SELECT * FROM read_csv_auto('dataset/field_visits.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_promises_to_pay AS
  SELECT * FROM read_csv_auto('dataset/promises_to_pay.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_payments AS
  SELECT * FROM read_csv_auto('dataset/payments.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_vendor_telephony AS
  SELECT * FROM read_csv_auto('dataset/vendor_telephony.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_complaints AS
  SELECT * FROM read_csv_auto('dataset/complaints.csv', sample_size=-1);

CREATE OR REPLACE TABLE raw_account_status_history AS
  SELECT * FROM read_csv_auto('dataset/account_status_history.csv', sample_size=-1);
