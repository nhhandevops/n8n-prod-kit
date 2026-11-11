# Sizing

How big a host this kit needs, measured rather than estimated. Two host shapes, three worker counts, with and
without the monitoring profile — every configuration run at least twice, because one load number is noise.

This page is the numbers. [Scaling](operations/scaling.md) is the knobs: what `WORKER_REPLICAS` and
`WORKER_CONCURRENCY` do, what each worker costs, when to scale webhook processors instead, and how to run
`make loadtest` against your own workflows. Read this to choose a host; read that to tune one.

## The short answer

| Host | What it did with the test workflow | Pick it when |
|---|---|---|
| **2 vCPU / 8 GB** | 500-job burst cleared in **35–40 s** · **27–33 req/s** intake · **750–857 executions/min** | the core stack, no monitoring profile, and bursts you are happy to see drain over half a minute |
| **4 vCPU / 8 GB** | the same burst in **18–19 s** · **55 req/s** intake · **1578–1666 executions/min** | you want the monitoring profile (it needs the cores), or bursts to clear in seconds |

**Doubling the cores roughly doubles everything** — intake ×1.8, throughput and drain time ×2. That is a cleaner
result than it had any right to be, and it holds because this stack is CPU-bound on a trivial workflow: nothing
here waits on a network call or a disk.

!!! warning "Both sizes are far above the kit's own design intent, and that is the point"
    `n8n-kit-PLAN.md` §2.6 sizes 4 vCPU / 8 GB for roughly 100k executions a day, which averages **69 per
    minute**. The 4 vCPU host above cleared **1600 a minute**. So for a workflow shaped like the test fixture,
    request rate is not what will decide your host — **execution duration and data volume are**. A single
    HTTP Request node waiting 2 s on a third-party API changes executions-per-minute by an order of magnitude,
    and no amount of CPU fixes it; `WORKER_CONCURRENCY` does, because waiting is not working.

## What was measured, and on what

Both hosts are VMware Workstation guests on one Windows desktop (i5-12400F, 6 cores / 12 threads, 32 GB), and
**only one guest ran at a time** — the whole reason this page took until 2026-11-11 to exist is that the earlier
attempt, on 2026-10-13, shared a host with other projects and came out intake-bound at 8–10 req/s, which measures
the neighbours rather than the kit.

| | Host A | Host B |
|---|---|---|
| vCPU / RAM | 2 / 7.7 GB | 4 (1 socket × 4 cores) / 7.8 GB |
| OS | Ubuntu 24.04.4 (installer) | Ubuntu 24.04.5 (**cloud image**) |
| Docker / Compose | 29.9.0 / 5.6.0 | 29.9.3 / 5.7.0 |
| n8n | 2.46.7 | 2.46.7 |
| Stack | core only | core only, and again with `COMPOSE_PROFILES=monitoring` |

Driven by `make loadtest` (`MODE=async` unless stated), whose fixture is a webhook that answers on receipt feeding
one Code node — so every execution includes a round trip to the runner sidecar. `WORKER_CONCURRENCY=10` throughout.
Runs: **4 per configuration** on host A, **2** on host B.

!!! note "Two methodology notes, because they changed what the numbers mean"
    **Settle the host first — but it mattered less than expected.** Host A's first set began one minute after boot
    at load 5.5, which looked like it would read low. Re-measured after waiting for load below 1.0, it came out
    *identical* (28 vs 28 req/s) and the larger bursts were marginally slower. So the spread you see between
    repeats is run-to-run noise, not warm-up — which is exactly why every configuration is repeated, and why a
    single run should not be trusted to 10 %.

    **These supersede the figures recorded on 2026-10-10** (a 200-job burst in 14 s, 40 req/s, ~850/min on 2 vCPU).
    That measurement was taken the same day `loadtest.sh` and its fixture were last changed, so it may predate
    their final form, and it ran n8n 2.42.4 against 2.46.7 here. Today's 2 vCPU host is slower on intake
    (28 vs 40 req/s). **That difference is not attributed** — settling it would mean running 2.42.4 and 2.46.7 on
    the same host, which has not been done, so it is not a regression claim.

## Worker count: the curve has a maximum, and it is lower than you expect

All on host B (4 vCPU), core stack, `N=500 P=50 async`:

| `WORKER_REPLICAS` | Intake | End to end | Throughput | Peak backlog | Errors |
|---|---|---|---|---|---|
| 1 | 55 / 41 req/s | 29 s / 31 s | 1034 / 967 per min | 415 / 417 | — |
| **2** | 55 / 55 req/s | **18 s / 19 s** | **1578 / 1666 per min** | 352 / 341 | — |
| 4 | 41 / 38 req/s | 20 s / 22 s | 1360 / 1500 per min | 221 / 212 | **1 × HTTP 502** |

**Two workers is the peak on four cores.** One leaves about 40 % of the throughput unused. Four *costs* about 15 %
and starts refusing requests at the edge — the single non-200 in these runs was an **HTTP 502**, Caddy failing to
reach a webhook processor.

The per-worker split says why it is not a load-balancing problem: at two workers the jobs divided 245 / 256, at four
they divided 130 / 128 / 123 / 120. Every worker took its share both times. What changed is that four workers plus
four runner sidecars compete for the same four cores with `n8n-main` and the two webhook processors — the processes
that *accept* the work. Starve those and the backlog gets smaller while the job takes longer, which is the shape in
the table: peak backlog falls from 352 to 212 precisely because requests are arriving more slowly. Load average on
the host reached **18** during the four-worker runs.

**The rule:** add workers only when the queue is the bottleneck — a clean HTTP histogram with a high peak backlog and
a long drain. If intake is already falling, you need cores, not processes. `make loadtest`'s own output tells you
which it is; [Scaling](operations/scaling.md) has the table for reading it.

## What the monitoring profile costs

Host B, 2 workers, with `COMPOSE_PROFILES=monitoring` (17 containers instead of 11):

| Burst | Core only | With monitoring |
|---|---|---|
| N=200 | 8 s / 8 s · 1500 / 1500 per min | 11 s / 9 s · 1090 / 1333 per min |
| N=500 | 19 s / 18 s · 1578 / 1666 per min | 24 s / 18 s · 1250 / 1666 per min |

**0–20 %, and the spread between repeats of the same configuration is as large as the effect.** The best run with
monitoring on equalled the best run without it (1666/min both). Treat it as "visible but not disqualifying" and do
not plan capacity around a single number.

It is cheaper in memory than this kit has been claiming. The six added containers measured **≈ 440 MiB in total**:

| | Measured | Limit |
|---|---|---|
| `grafana` | 174–180 MiB | 768m |
| `loki` | 85–102 MiB | 512m |
| `alloy` | 68 MiB | 384m |
| `prometheus` | 35–62 MiB | 512m |
| `cadvisor` | 18 MiB | 256m |
| `node-exporter` | 5–8 MiB | 128m |

Host RAM in use rose by roughly 0.7 GB with the profile on. `make preflight` warns below 5 GB for this profile,
which these numbers say is a comfortable margin rather than a tight one.

## Memory: the limits are not the usage

The kit sets memory **limits** and no CPU limits. A limit is a ceiling whose job is to cap a runaway execution, not
a reservation — and the gap between the two is wide. Host B, core stack, immediately after a 500-job burst:

| Service | Measured | `MEM_LIMIT_*` |
|---|---|---|
| `n8n-main` | 397–408 MiB | 1g |
| each `n8n-webhook-N` | 254–341 MiB | 512m |
| each `n8n-worker-N` | 295–337 MiB | 1g |
| each `n8n-worker-N-runners` | 87–180 MiB | 512m |
| `postgres` | 104–157 MiB | 1g |
| `valkey` | 12–22 MiB | 384m |
| `caddy` | 18–65 MiB | 256m |
| `backup` (idle) | 7–18 MiB | 1536m |

**The whole 2-worker core stack ran in about 2.0 GB** against roughly 6.6 GB of configured limits. One worker came to
~1.7 GB, four to ~2.8 GB — so **each worker + runner pair costs about 400 MiB in practice**, not the 1.5 GiB its two
limits imply. Size the host on the measured column; keep the limits where they are, because their purpose is the
runaway case this test never produced.

## `MODE=sync` measures something else

Host B, 2 workers, `MODE=sync N=100 P=10`: 100 executions end to end in **3 s**, 33 req/s, peak backlog **0**.

That 0 is by construction, not a result: sync holds each response until its execution finishes, so at most `P` jobs
exist at once and none of them ever waits. It is the right mode for per-request latency and the wrong one for
capacity. Use `MODE=async` for anything on this page.

## Reading your own numbers against these

1. Run `make loadtest` on a **settled** host with nothing else on it, twice, and compare the pair before believing
   either.
2. Compare the *shape*, not the absolute number: your workflow is not one Code node. If your executions take 2 s
   each, four cores will not give you 1600 a minute, and that is not a fault in the host.
3. If intake (`send phase … req/s`) is what degrades, you need cores or fewer competing processes. If the backlog and
   drain are what grow, you need workers or concurrency.
4. Set `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` above the p99 execution duration you measure — `make doctor` reports that p99
   from the last 7 days, and a worker killed mid-execution loses that work
   ([Chaos drills](operations/chaos-drills.md)).

## What these numbers do not tell you

- **One workflow shape.** A webhook into a Code node, no external calls, no binary data, tiny payloads. This is the
  best case by a wide margin.
- **Two host shapes, one hypervisor.** Both guests ran on the same desktop under VMware Workstation. A VPS with
  different storage, a noisy neighbour, or burstable CPU credits will not reproduce these.
- **No ACME, no public traffic, no TLS from a real CA.** Both hosts served the kit's internal CA over loopback.
- **Bursts, not sustained load.** Every figure is a burst being absorbed and drained. Nothing here ran for an hour.
- **No data growth.** Execution history was a few thousand rows. Postgres sizing under months of retention is a
  different question — [Scaling](operations/scaling.md) has the pruning knobs that decide it.
