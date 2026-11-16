# Sync crypto (v1)

D3: the server stores only ciphertext. Clients encrypt and decrypt; the server can't, and can't recover a lost key. That is the design.

## Keys
- **Account key (AK)**: 32 random bytes, made once per account on the first device. Never leaves a device unwrapped.
  Mac: Keychain generic password (data-protection Keychain once the Developer ID exists, P1.7 blocker). Web: IndexedDB as a non-extractable WebCrypto `CryptoKey`.
- **Key id**: 8 random bytes, hex (16 chars), made with the AK. Sent with every blob so a client knows which key to use. It says nothing about the key.
- **Recovery key (RK)**: 16 random bytes, shown once as base32 in groups of 4 (`ABCD-EFGH-…`), for the user to print or write down.
  KEK = HKDF-SHA256(ikm = RK, salt = UTF-8 userId, info = "offerlane-recovery-v1", 32 bytes). RK is random, so no password stretching is needed.
- **Keyring blob**: AK ‖ key id (ASCII) encrypted with KEK, so every device uses the AK's one key id (same blob format below, kind `keyring`, key id `rk-<n>` where n counts recovery-key resets), uploaded so a new device can fetch it and unwrap it with the RK.

## Blob format
`0x01 ‖ nonce (12 random bytes) ‖ AES-256-GCM ciphertext ‖ tag (16 bytes)`
- AAD = UTF-8 `offerlane-sync-v1|<userId>|<kind>|<version>|<keyId>`. `version` is the one being written: 1 on create, n+1 when replacing version n.
  The server can't move a blob to another user or kind, relabel an old blob as a newer version, or swap its key id, without decryption failing.
- Clients remember the highest version they have seen per kind and refuse a lower one (stops a rollback to an older genuine blob).
  Accepted risk (v1): a fresh device restoring with the RK has no such memory, so a malicious server could serve older genuine
  versions or withhold updates there. Confidentiality still holds. Upgrade path: a per-kind version manifest inside the keyring blob.
- Random nonces: rotate the AK long before 2^32 encryptions under one key (in practice: on every recovery-key reset).
- Ciphertext ≤ 8 MiB (server cap). Clients may gzip the plaintext before encrypting.

## Wire (`/v1/sync/{kind}`)
- `GET` → 200 `{version, keyId, ciphertext}` (base64) + `ETag: "v<n>"`, or 404.
- `PUT {keyId, ciphertext}` with `If-None-Match: *` (create) or `If-Match: "v<n>"` (replace). The server sets the new version.
  409 `{error: "conflict", version}` when the precondition is stale; 428 when it is missing; 413 over the cap; 400 for a bad kind/body.
- On 409 the client downloads, decrypts, merges, re-encrypts with the new version in the AAD, and retries.

## What the server can see
User id, kind names, versions, sizes, timestamps, key ids. Kind names are a fixed list with no personal data in them:
`keyring`, `profile`, `resumes`, `applications`, `contacts`, `settings` (the server and a DB CHECK reject any other). Key ids match `^[A-Za-z0-9_-]{1,64}$`.

## Rotation and loss
- Rotate: make a new AK + key id, re-encrypt every kind, re-wrap the keyring. Keep the old AK locally until every blob is moved.
- New RK: re-wrap the keyring with the new KEK (and rotate the AK, since the old RK may have leaked).
- Lost every device AND the RK: the synced data is gone. The UI must say so plainly when it shows the RK (P3/Mac wiring).

## Clients and merge (P4.4)
- Ports: web/Windows `libs/core/src/sync.ts` + `apps/web/src/sync.ts`; Mac `OfferlaneCore/Sync` (CryptoKit). `Fixtures/sync/{ts,swift}_sealed.json`: each port opens the other's blobs.
- Plaintext is JSON. Records (`applications`): union by id, newer ISO `updated` wins; on a tie the greater canonical JSON (sorted keys,
  JSON.stringify spelling) wins, so every device picks the same record. Whole kinds (`profile`, `resumes`): last writer wins, the replaced value is kept locally.
- The Mac syncs `profile`, its default resume as `resumes`, and acted-on jobs as `applications` (times in UTC on the wire); its own extra fields stay on the Mac.
