-- templates/idempotent-webhook/schema.sql — the ledger the idempotent-webhook template claims keys in.
--
-- Background and the whole pattern: docs/operations/idempotency.md
--
-- Apply it ONCE, from the repository root, with a password for the workflow's own role on stdin so it never
-- reaches a command line (every user on the host can read /proc/<pid>/cmdline):
--
--   read -rsp 'password for the n8n_idem role: ' pw && echo
--   { printf "\\set idem_password '%s'\n" "${pw}"; cat templates/idempotent-webhook/schema.sql; } \
--     | ( cd compose && docker compose --env-file versions.env --env-file .env \
--           exec -T postgres psql -U n8n -d n8n -v ON_ERROR_STOP=1 )
--   unset pw
--
-- Then create ONE Postgres credential in n8n with that password (host `postgres`, database `n8n`, user
-- `n8n_idem`, port 5432, SSL disabled — it never leaves the internal Docker network) and point the
-- template's two Postgres nodes at it.
--
-- Re-running this file is safe: the table and index are created only if missing, and the role's password is
-- set to whatever you pass in — which is also how you rotate it (rotate here, then update the credential).
--
-- The ledger lives in n8n's OWN database on purpose: it is then covered, with no extra work, by the backup,
-- the restore and the DR drill this kit already proves (docs/operations/backup-restore.md). The price is in
-- docs/operations/idempotency.md — a restore to an older point also rewinds the ledger.

BEGIN;

-- One row per intent. `key` is the caller's idempotency key, so the PRIMARY KEY is the whole mechanism:
-- Postgres, not the workflow, decides who claimed it first.
CREATE TABLE IF NOT EXISTS idempotency_keys (
  key        text        PRIMARY KEY,
  -- who holds the lease ("exec:<n8n execution id>"). Set on INSERT and never changed, which is how the
  -- claim query tells "I inserted this row" from "somebody else did" without relying on xmax folklore.
  owner      text        NOT NULL,
  state      text        NOT NULL DEFAULT 'in_progress' CHECK (state IN ('in_progress', 'done')),
  -- what the first execution answered. Every later delivery of the same key is answered with this, so keep
  -- it small and keep secrets out of it: it is as readable as the rest of the table.
  result     jsonb,
  claimed_at timestamptz NOT NULL DEFAULT now(),
  done_at    timestamptz
);

-- For the retention delete and for finding leases that never completed (both in the docs page).
CREATE INDEX IF NOT EXISTS idempotency_keys_claimed_at_idx ON idempotency_keys (claimed_at);

-- ---------------------------------------------------------------------------------------------------------
-- The role the WORKFLOW uses. Not the `n8n` role: that one is the database's bootstrap superuser (it is the
-- POSTGRES_USER the official image runs initdb with), and a credential holding it would let any workflow on
-- the instance — or anyone who can edit one — read every stored credential and drop n8n's own tables.
-- This role can claim and complete keys in this one table, and nothing else.
-- ---------------------------------------------------------------------------------------------------------
SELECT format('CREATE ROLE %I LOGIN', 'n8n_idem')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_idem')
\gexec

ALTER ROLE n8n_idem WITH LOGIN PASSWORD :'idem_password';

GRANT CONNECT ON DATABASE n8n TO n8n_idem;
GRANT USAGE ON SCHEMA public TO n8n_idem;
-- No DELETE on purpose: expiring old keys is a scheduled maintenance job run by the owner, not something a
-- webhook should be able to do. A workflow that can delete ledger rows can replay a payment.
GRANT SELECT, INSERT, UPDATE ON idempotency_keys TO n8n_idem;

COMMIT;

\echo 'idempotency_keys is ready, and the n8n_idem role can claim and complete keys in it.'
