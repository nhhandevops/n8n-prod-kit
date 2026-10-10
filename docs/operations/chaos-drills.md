# Chaos drills

`make chaos` breaks one part of a running stack on purpose and checks that what the kit promises actually
happens. Every claim on this page was measured on a real stack, not reasoned about; where the measurement
contradicted the original design notes, this page records the measurement and the design notes were corrected.

```bash
cd compose
make chaos SCENARIO=worker          # kill a worker mid-execution        (TC-008)
make chaos SCENARIO=redis           # take Valkey away for 60 seconds    (TC-009)
make chaos SCENARIO=main            # restart n8n-main under load        (TC-010)
```text

Options: `N=` inputs to fire (default 120), `P=` requests in flight (40), `OUTAGE=` seconds Valkey stays down
(60), `RECOVER_TIMEOUT=` seconds allowed for recovery (420), `YES=1` to skip the confirmation prompt.

Each drill publishes its own `kit-smoke-chaos-<run id>` workflow, uses it, and deletes it again. It never
touches your volumes, your database or your `.env`, and its exit trap brings every service back with
`docker compose up -d`. If an assertion fails it **keeps** the workflow (deactivated, so it is no longer
reachable) and the files it wrote, so you can look at them.

**Run these on a dev or staging stack.** They stop and kill containers; on a production instance the drill
causes real downtime and, in the `worker` case, real lost executions.

---

## What a killed worker really costs you

This is the most important thing on this page, because it contradicts what most n8n scaling guides say.

**When a worker dies without a graceful shutdown, the executions it had in flight are lost. They are not
retried and not re-queued.** They end up with status `crashed`. Work that was still *queued* is safe — another
worker picks it up — but work already running on the dead worker is gone.

Measured on the kit's own stack (n8n 2.42.4, 2 workers at concurrency 10, 120 inputs, `docker kill` during the
backlog): 110 inputs succeeded, **10 ended as `crashed`**, 0 as `error`, and they were still `crashed` half an
hour later. Ten is exactly one worker's concurrency.

### Why

n8n builds its Bull queue with retry switched off, in `packages/cli/src/scaling/scaling.service.ts`:

```js
const settings = { ...this.globalConfig.queue.bull.settings, maxStalledCount: 0 };
```text

Bull's stalled sweep runs `if (stalledCount > MAX_STALLED_JOB_COUNT)`. With the limit at `0` the **first**
stall takes the fail branch: the job is moved to `failed` with `job stalled more than allowable limit` and is
never pushed back to `wait`. The `else` branch — the only re-enqueue path in the stack — is dead code under
this configuration. No environment variable reaches it: n8n exposes only `QUEUE_WORKER_LOCK_DURATION`,
`QUEUE_WORKER_LOCK_RENEW_TIME` and `QUEUE_WORKER_STALLED_INTERVAL`.

This is deliberate. The [n8n 2.0 breaking changes](https://docs.n8n.io/changelog/v20-breaking-changes) say:

> The `QUEUE_WORKER_MAX_STALLED_COUNT` environment variable and the Bull retry mechanism for stalled jobs will
> be removed because they often caused confusion and didn't work reliably. … After upgrading, n8n will no
> longer automatically retry stalled jobs. If you need to handle stalled jobs, consider implementing your own
> retry logic or monitoring.

On n8n **1.x** the same kill would have re-run the job once. If you are migrating from 1.x, this changed under
you.

### The timing

The sweep runs on a *surviving* worker — Bull only sweeps inside a process that called `.process()`, so main
and the webhook processors never do it. A job is swept once its lock expires and the next sweep comes round:

```text
QUEUE_WORKER_LOCK_DURATION 60s  +  QUEUE_WORKER_STALLED_INTERVAL 30s  ≈ 90s
```text

That matches the measurement: the crashed executions stopped 97 seconds after the kill. So a drill needs to
wait about 90 seconds longer than a plain drain before the numbers settle — and **a single-worker instance has
nobody to run the sweep at all**, so its orphans sit until the much slower queue recovery notices them. Run at
least two workers.

### What to do about it

| | |
|---|---|
| **Drain instead of killing** | `docker stop` / SIGTERM runs n8n's `stopWorker()`: it pauses the queues, waits for in-flight jobs for 80% of `N8N_GRACEFUL_SHUTDOWN_TIMEOUT`, then cancels the stragglers deterministically. Set that timeout above your p99 execution time, and make your orchestrator's grace period longer again. `make upgrade` already drains this way. |
| **Give critical workflows an Error Workflow** | This is the only automatic hook that still fires on the stall path. Point the workflow's `errorWorkflow` setting at a workflow starting with an Error Trigger and re-submit the payload from there. Note it does **not** fire on the queue-recovery or startup-recovery paths — a crash transition runs no lifecycle hooks. |
| **Do not rely on node-level "Retry on Fail"** | `retryOnFail` / `maxTries` run *inside* the execution process. When that process is killed they die with it. "Retry execution" in the UI is a manual action, not a safety net. |
| **Make replays safe** | Keep the payload somewhere you can re-drive it from, and key the workflow so running it twice is harmless — the kit's own drill fixture writes one file per input id for exactly this reason. |

### A `crashed` execution is not proof that nothing happened

The drill measures this directly. In one run, 112 inputs succeeded, 8 crashed — and **114 files existed**. Two of
the crashed executions had already written their file before the kill landed: the write node finished, the
execution never got marked done.

So "crashed" means *n8n does not know whether the work completed*, not *the work did not happen*. If you
re-drive crashed inputs, a non-idempotent workflow will do the side effect twice. Key the effect on something
from the input — as the drill fixture does — so a replay overwrites instead of duplicating.
| **Alert on it** | The monitoring profile's `ExecutionFailureRate` covers failures; watch for `crashed` executions specifically if this matters to you. |

---

## `docker kill` does not test the restart policy

A second thing worth knowing, because it is easy to assume otherwise.

**Docker will not restart a container you killed yourself.** `docker kill` and `docker stop` both go through
`daemon.killWithSignal`, which cancels the container's restart manager and sets `HasBeenManuallyStopped`. With
`restart: unless-stopped` — what every service in this kit uses — the policy then deliberately stays out of
it. The same applies to `docker compose kill`, `docker compose stop`, `docker compose down` and `docker rm -f`.

Measured: after `docker kill n8n-worker-1`, the container stayed down for 14 minutes with `RestartCount=0` and
only came back when `docker compose up -d` ran. Docker's restart backoff caps at 60 seconds and resets after a
run of 10 seconds or more, so a 14-minute gap cannot be backoff — and during a backoff the container reports
state `restarting`, which it never did.

So the `worker` drill does **not** assert that the container restarts itself. It reports that the worker did
not come back on its own, brings it back with `compose up -d`, and asserts that *that* worked. If you want to
exercise the restart policy for real, kill the container's main process from the host, where the daemon is
never asked to stop anything:

```bash
sudo kill -9 "$(docker inspect -f '{{.State.Pid}}' n8nkit-n8n-worker-1-1)"
```text

`docker exec <container> kill -9 1` does **not** work: the kernel discards a SIGKILL sent to a PID-namespace
init from inside that namespace. Only an ancestor namespace — the host — can force it.

---

## The drills

### `worker` — kill a worker mid-execution (TC-008)

Fires `N` inputs through the webhook pool, waits for a backlog, then `docker kill`s the first worker while it
is executing. Asserts:

- every input reaches a terminal state — successes + crashed + errors accounts for all of them, nothing vanishes
- queued work survived: the remaining worker(s) completed it
- exactly one side effect per successful input — the fixture writes one file per input id, so a re-run
  overwrites rather than duplicating
- the surviving worker took the load over
- the killed worker is back and healthy after `compose up -d`

It warns if **no** execution ended as `crashed`, because then the kill caught nothing in flight and the run
proved nothing about the failure path — raise `N` or `P`.

### `redis` — take Valkey away (TC-009)

Fires `N` inputs, stops Valkey with a backlog still waiting, calls the webhook three times during the outage,
waits `OUTAGE` seconds, and starts it again. Asserts:

- webhooks fail loudly while the queue is unreachable — measured 502/503, never a silent 2xx
- every service reconnects by itself (a worker's readiness probe requires a live Redis connection, so "healthy
  again" *is* the reconnect signal)
- every job queued before the outage completes afterwards — AOF kept the queue

Measured: Valkey stopped with 321 jobs waiting; 337 completed after it came back; nothing lost.

Raise `N` if the drill warns that nothing was queued at the stop — on a fast host the workers drain the burst
before the stop lands, and then the outage has nothing to protect.

### `main` — restart n8n-main under load (TC-010)

Publishes a schedule trigger, waits for it to fire, then restarts `n8n-main` while a webhook is sent every
second. Asserts:

- every webhook answers 200 across the restart — `N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true` keeps main out of
  the production webhook path entirely, so the pool is unaffected
- `n8n-main` comes back healthy
- the schedule trigger resumes on its own, counted from *after* main recovered so a tick from the old process
  cannot satisfy it

Measured: 40/40 webhooks answered 200; the scheduler resumed without intervention.

This is the drill that shows the topology paying off: restarting the UI/scheduler does not interrupt inbound
traffic. Schedule triggers are the thing that pauses, and only for as long as main takes to come back.

---

## Reading a failure

A drill that fails keeps its evidence. The workflow is deactivated but not deleted, and its files stay under
`/home/node/.n8n-files/chaos-<run id>-*`:

```bash
make logs SERVICE=n8n-worker-1 | tail -50
docker compose -p n8nkit exec n8n-main ls -1 /home/node/.n8n-files/
make status && make doctor
```text

Clean up when you are done — `make smoke` removes any `kit-smoke-*` workflow, or delete it in the UI.
