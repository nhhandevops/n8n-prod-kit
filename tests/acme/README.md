# `tests/acme` — does the kit's ACME path actually work?

```bash
make acme-test          # ~1 minute; KEEP=1 leaves the containers up for inspection
```

Every row in [`docs/compat.md`](../../docs/compat.md) was produced with an internal CA. The kit's headline
claim — a fresh host ends up with a **publicly trusted** certificate — therefore rested on configuration that
had never once completed an ACME order. This closes that gap without a public host, a public domain, or a
single unit of Let's Encrypt's rate limits, by issuing from **[Pebble](https://github.com/letsencrypt/pebble),
Let's Encrypt's own test CA**.

## What it proves

The **shipped** `compose/caddy/Caddyfile` — the file is compared byte for byte against the copy under test —
completes the whole flow: Caddy registers an ACME account, gets an order, is challenged over HTTP on its own
HTTP port, finalises, installs the certificate and serves it for `DOMAIN`, with the kit's security headers
still in place and the `Server` banner still removed. The CA's own log is read back as evidence: the
validation task for the identifier, the authorization going `VALID`, and the issued serial.

## What it cannot prove

Everything that needs the public internet, which is still ledger **D-9**:

- that `DOMAIN` resolves to your host, and that **port 80 is reachable** from outside;
- the **IPv6 preference** — Let's Encrypt validates over IPv6 first when an `AAAA` exists, which is what
  `make preflight` now checks ([the bug log](../../warning_bug_and_solutions.md) has the detail);
- Let's Encrypt's **rate limits**, and that the staging → production switch behaves;
- the certificate being trusted by a **real browser**.

So a green run here means "the configuration is right", not "the host is ready". `n8n-kit-PROD-PLAN.md` P3 is
still the sequence to follow on the night, staging first.

## How it is built

| | |
|---|---|
| `docker-compose.yml` | Pebble + the kit's own pinned Caddy image, on their own network and project name, ports **8080/8443** and publishings on 127.0.0.1 only — so it is safe to run beside a live stack |
| `pebble-config.json` | points Pebble's HTTP-01 validation at port 8080 instead of its default 5002 |
| `tls-acmetest.caddy` | the TLS policy for `TLS_MODE=acmetest`: the test CA's directory URL plus the root that signs its API certificate |
| `run.sh` | assembles the config, extracts Pebble's API root from the image, brings both up, and asserts |

**No shipped file changes to make this testable.** The Caddyfile already resolves its TLS policy as
`import /etc/caddy/tls-{$TLS_MODE}.caddy`, so supplying a file plus `TLS_MODE=acmetest` is the config's own
extension point.

## Four things that cost a round each, written down so they do not again

- **A file cannot be bind-mounted into a read-only bind mount.** Layering `tls-acmetest.caddy` over
  `compose/caddy:ro` fails with *"make mountpoint … read-only file system"*, because Docker has to create the
  mountpoint inside a mount that forbids writes. Hence the staged copy — and the `cmp` that proves the copy is
  the shipped file.
- **The Pebble image is distroless**: no shell, no `cat`, no `ls`. `docker run --entrypoint cat` fails with
  *"executable file not found in $PATH"*; `docker create` plus `docker cp` gets the file out without ever
  starting it.
- **A real CA issues an empty subject DN.** The name is in the `subjectAltName` extension only, so an
  assertion written as `CN=<domain>` passes against Caddy's internal CA and **fails against a real one**. That
  is exactly the class of difference this harness exists to find before a production host does.
- **Pebble never logs the string `http-01`.** It logs the validation task it pulled for the identifier, the
  authorization going `VALID`, and the serial it issued — and it starts **three** validations per challenge,
  imitating Let's Encrypt's multi-perspective validation.

Pebble is pinned by digest like everything else the kit pulls, which matters more here than usual: `latest` is
the only tag the project publishes.
