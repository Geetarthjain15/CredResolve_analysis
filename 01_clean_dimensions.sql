-- ============================================================================
-- 01_clean_dimensions.sql
-- Cleans the dimension / master tables: borrowers, agents, vendor_telephony,
-- accounts, campaigns.
--
-- KEY FORENSIC FINDINGS THAT DRIVE THIS FILE (see reports/data_quality_report.md
-- for full evidence):
--
--   * raw_borrowers has 30,600 rows but only 11,015 distinct borrower_id.
--     For borrower_ids with >1 row, the *other* columns (name/phone/email/
--     city/state) frequently disagree across rows for the SAME borrower_id
--     (up to 11 conflicting variants for one id). This is not simple
--     duplication -- it is unresolved identity data. We cannot know which
--     variant is "true" from this data alone, so we pick the most-recently
--     UPDATED row per borrower_id as the working record and flag every
--     borrower_id that had conflicting variants with data_quality_flag =
--     'IDENTITY_CONFLICT' so downstream geography/demographic cuts can be
--     read with appropriate skepticism.
--
--   * raw_agents has 30,000 rows but only 1,000 distinct agent_id (the same
--     agent_id used consistently as the FK in calls/attempts/dispositions/
--     sessions/field_visits/ptp -- 0 orphan agent_ids in calls). The ~30
--     rows per agent_id are NOT a clean slowly-changing-dimension history:
--     employee_code, agent_name, vendor_id, team and status are scrambled
--     essentially at random across the rows for a single agent_id (e.g.
--     agent AGT0000367 shows 48 different employee_codes and 8 different
--     names). employee_code is *also* not a reliable alternate key: a
--     handful of employee_codes (e.g. EMP00900) fan out across 40+ distinct
--     agent_ids with different names. We therefore treat agent_id as the
--     only trustworthy grain (it is what operational events actually key
--     on) and derive a single "best guess" attribute row per agent_id using
--     the mode (most frequent value) of each attribute, with ties broken by
--     the most recently updated row. This is explicitly a low-confidence
--     reconstruction -- documented in the DQ report -- and any driver
--     analysis that depends on "team" or "vendor_id" per agent should be
--     read as directional only.
--
--   * vendor_telephony (15 rows) and campaigns (120 rows) are clean 1-row-
--     per-key tables with no duplication -- no special handling required
--     beyond a light rename/typing pass.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- BORROWERS: dedupe to one row per borrower_id, keep latest by updated_at.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_borrowers_conflict_flag AS
  SELECT borrower_id,
         COUNT(*)                                                            AS n_raw_rows,
         COUNT(DISTINCT (name, phone, email, city, state))                   AS n_distinct_identities
  FROM raw_borrowers
  GROUP BY 1;

CREATE OR REPLACE TABLE clean_borrowers AS
  WITH ranked AS (
    SELECT b.*,
           ROW_NUMBER() OVER (PARTITION BY borrower_id ORDER BY updated_at DESC, created_at DESC) AS rn
    FROM raw_borrowers b
  )
  SELECT r.borrower_id, r.name, r.phone, r.email, r.city, r.state,
         r.created_at, r.updated_at,
         f.n_raw_rows,
         f.n_distinct_identities,
         (f.n_distinct_identities > 1) AS identity_conflict_flag
  FROM ranked r
  JOIN stg_borrowers_conflict_flag f USING (borrower_id)
  WHERE r.rn = 1;

-- ---------------------------------------------------------------------------
-- AGENTS: agent_id is the only trustworthy key. Rebuild one attribute row
-- per agent_id using the mode of each column (ties -> most recent updated_at).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_agents_mode AS
  WITH counts AS (
    SELECT agent_id, employee_code, agent_name, vendor_id, team, status,
           COUNT(*) AS n,
           MAX(updated_at) AS max_updated_at
    FROM raw_agents
    GROUP BY 1,2,3,4,5,6
  ),
  ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY agent_id ORDER BY n DESC, max_updated_at DESC) AS rn
    FROM counts
  )
  SELECT * FROM ranked WHERE rn = 1;

CREATE OR REPLACE TABLE clean_agents AS
  SELECT m.agent_id, m.employee_code, m.agent_name, m.vendor_id, m.team, m.status,
         MIN(a.joined_at)  AS joined_at_earliest,
         MAX(a.updated_at) AS updated_at_latest,
         COUNT(*)          AS n_raw_rows,
         COUNT(DISTINCT a.employee_code) AS n_distinct_employee_codes,
         COUNT(DISTINCT a.agent_name)    AS n_distinct_names,
         TRUE AS attributes_low_confidence  -- see file header: agents dim is scrambled
  FROM raw_agents a
  JOIN stg_agents_mode m USING (agent_id)
  GROUP BY 1,2,3,4,5,6;

-- ---------------------------------------------------------------------------
-- VENDOR TELEPHONY: clean already (15 rows, 15 distinct vendor_id).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_vendor_telephony AS
  SELECT DISTINCT * FROM raw_vendor_telephony;

-- ---------------------------------------------------------------------------
-- CAMPAIGNS: clean already (120 rows, 120 distinct campaign_id).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_campaigns AS
  SELECT DISTINCT * FROM raw_campaigns;

-- ---------------------------------------------------------------------------
-- ACCOUNTS: 30,000 rows, 30,000 distinct account_id -- no row-level dedup
-- needed. However accounts.status disagrees with the latest event in
-- account_status_history for 85.7% of accounts with history (22,295 /
-- 25,999) -- see 02_clean_events.sql where account_status_history is
-- cleaned and reconciled. We carry accounts.status through as
-- "status_snapshot" (source: core dimension table) and separately compute
-- "status_from_history" (source: event log) downstream, rather than
-- silently picking a winner here.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE clean_accounts AS
  SELECT account_id, borrower_id, loan_type, principal_amount, outstanding_amount,
         dpd,
         CASE
           WHEN dpd = 0 THEN 'CURRENT'
           WHEN dpd BETWEEN 1 AND 30 THEN '1-30'
           WHEN dpd BETWEEN 31 AND 60 THEN '31-60'
           WHEN dpd BETWEEN 61 AND 90 THEN '61-90'
           ELSE '90+'
         END AS dpd_bucket,
         risk_segment, status AS status_snapshot, opened_at, timezone, schema_version
  FROM raw_accounts;
