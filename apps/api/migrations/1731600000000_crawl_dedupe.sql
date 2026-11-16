-- Up Migration
-- P2.6: near-duplicate detection (job-to-job only, never profile text: P2 plan H5), display names, apply links.
CREATE EXTENSION IF NOT EXISTS vector;
ALTER TABLE jobs
  ADD COLUMN apply_url text NOT NULL DEFAULT '',
  ADD COLUMN embedding vector(256),
  ADD COLUMN duplicate_of bigint REFERENCES jobs ON DELETE SET NULL;
-- Duplicate checks look within one company's visible rows.
CREATE INDEX jobs_company_live ON jobs (company, id) WHERE duplicate_of IS NULL;
-- The search order, over the rows search shows.
CREATE INDEX jobs_live ON jobs (posted_at DESC NULLS LAST, id DESC) WHERE duplicate_of IS NULL;
ALTER TABLE job_sources ADD COLUMN company_name text CHECK (length(company_name) BETWEEN 1 AND 200);

-- Down Migration
ALTER TABLE job_sources DROP COLUMN company_name;
DROP INDEX jobs_live;
DROP INDEX jobs_company_live;
ALTER TABLE jobs DROP COLUMN duplicate_of, DROP COLUMN embedding, DROP COLUMN apply_url;
DROP EXTENSION IF EXISTS vector;
