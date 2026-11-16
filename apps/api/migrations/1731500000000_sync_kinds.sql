-- Up Migration
-- P2.4 review: only the kinds in docs/v4/SYNC_CRYPTO.md (bounds storage per user), and key ids are opaque tokens.
ALTER TABLE sync_blobs DROP CONSTRAINT sync_blobs_kind_check;
ALTER TABLE sync_blobs ADD CONSTRAINT sync_blobs_kind_check
  CHECK (kind IN ('keyring', 'profile', 'resumes', 'applications', 'contacts', 'settings'));
ALTER TABLE sync_blobs DROP CONSTRAINT sync_blobs_key_id_check;
ALTER TABLE sync_blobs ADD CONSTRAINT sync_blobs_key_id_check CHECK (key_id ~ '^[A-Za-z0-9_-]{1,64}$');

-- Down Migration
ALTER TABLE sync_blobs DROP CONSTRAINT sync_blobs_key_id_check;
ALTER TABLE sync_blobs ADD CONSTRAINT sync_blobs_key_id_check CHECK (length(key_id) BETWEEN 1 AND 64);
ALTER TABLE sync_blobs DROP CONSTRAINT sync_blobs_kind_check;
ALTER TABLE sync_blobs ADD CONSTRAINT sync_blobs_kind_check CHECK (kind ~ '^[a-z][a-z0-9-]{0,31}$');
