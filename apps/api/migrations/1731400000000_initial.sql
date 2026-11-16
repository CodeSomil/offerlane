-- Up Migration
-- D3: no column here may hold readable resume/profile text. sync_blobs.ciphertext is client-encrypted.
CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  oidc_issuer text NOT NULL,
  oidc_sub text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (oidc_issuer, oidc_sub)
);

CREATE TABLE devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX devices_user ON devices (user_id);

CREATE TABLE sync_blobs (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind ~ '^[a-z][a-z0-9-]{0,31}$'),
  version bigint NOT NULL CHECK (version > 0),
  key_id text NOT NULL CHECK (length(key_id) BETWEEN 1 AND 64),
  ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) <= 8388608),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, kind)
);

CREATE TABLE job_sources (
  id serial PRIMARY KEY,
  ats text NOT NULL CHECK (ats IN ('greenhouse','lever','ashby','workable','smartrecruiters','workday')),
  company_slug text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  etag text,
  last_modified text,
  last_crawled_at timestamptz,
  UNIQUE (ats, company_slug)
);

CREATE TABLE jobs (
  id bigserial PRIMARY KEY,
  source_id int NOT NULL REFERENCES job_sources ON DELETE CASCADE,
  external_id text NOT NULL,
  title text NOT NULL,
  company text NOT NULL,
  location text NOT NULL DEFAULT '',
  remote boolean NOT NULL DEFAULT false,
  url text NOT NULL,
  description text NOT NULL DEFAULT '',
  posted_at timestamptz,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  dedupe_hash text NOT NULL,
  search tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('english', title), 'A') ||
    setweight(to_tsvector('english', company), 'B') ||
    setweight(to_tsvector('english', description), 'C')
  ) STORED,
  UNIQUE (source_id, external_id)
);
CREATE INDEX jobs_search ON jobs USING gin (search);
CREATE INDEX jobs_dedupe ON jobs (dedupe_hash);
CREATE INDEX jobs_posted ON jobs (posted_at DESC);

CREATE TABLE crawl_runs (
  id bigserial PRIMARY KEY,
  source_id int NOT NULL REFERENCES job_sources ON DELETE CASCADE,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running','ok','failed','refused')),
  found int,
  error text
);
CREATE INDEX crawl_runs_source ON crawl_runs (source_id, started_at DESC);

CREATE TABLE idempotency_keys (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  key text NOT NULL CHECK (length(key) BETWEEN 1 AND 255),
  request_hash text NOT NULL,
  status_code int,
  response bytea,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, key)
);
CREATE INDEX idempotency_keys_created ON idempotency_keys (created_at);

CREATE TABLE rate_buckets (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  bucket text NOT NULL,
  tokens double precision NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, bucket)
);

-- Down Migration
DROP TABLE rate_buckets;
DROP TABLE idempotency_keys;
DROP TABLE crawl_runs;
DROP TABLE jobs;
DROP TABLE job_sources;
DROP TABLE sync_blobs;
DROP TABLE devices;
DROP TABLE users;
