# review-queue

[![CI](https://github.com/njoroge-viktor/review-queue/actions/workflows/ci.yml/badge.svg)](https://github.com/njoroge-viktor/review-queue/actions/workflows/ci.yml)
[![Elixir](https://img.shields.io/badge/elixir-1.15%2B-purple)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A concurrent, lease-based review queue for annotation workforces. OTP
supervision, ETS-backed storage, HTTP via Plug and Bandit.

```bash
mix deps.get && mix run --no-halt
```

## Why a GenServer rather than bare ETS

Claiming a task is read-modify-write: find the highest-priority pending task,
then mark it leased. Two annotators racing through raw ETS can both read the
same task before either writes, and both get handed the same work.

Serialising writes through a single process makes that race **structurally
impossible** rather than merely unlikely. This is the BEAM's answer to a mutex,
and it costs less than one.

Reads that do not mutate — `fetch/2`, and the dashboard's polling — go straight
to ETS and skip the process entirely, so a status poll never queues behind a
claim:

```elixir
def fetch(queue \\ __MODULE__, id) do
  case :ets.lookup(table_for(queue), id) do   # no GenServer.call
    [{^id, task}] -> {:ok, task}
    [] -> :error
  end
end
```

The proof is a test, not a paragraph: 16 processes drain a 200-task queue and
assert every task was claimed exactly once.

## Leases

An annotator claims a task and closes the tab. Without leases that task is lost
forever; at scale a meaningful slice of the queue quietly evaporates.

A claim grants a time-limited lease. An expired lease returns its task to the
pool with `attempts` incremented:

```
claim   -> t1 leased to ann-a, expires in 5m, attempts: 1
  (ann-a disappears)
claim   -> t1 leased to ann-b,                attempts: 2
```

- **Only the holder may submit**, and only before expiry. Accepting a late
  submission would silently overwrite work already reassigned to someone else.
- **`extend/3`** renews a lease for a reviewer still working.
- **A task that defeats `max_attempts` annotators is dropped**, not recycled
  forever. A task nobody can complete is a data problem; cycling it hides that.

**Expiry sweeping is lazy.** Rather than a timer per task, expired leases are
reaped whenever the queue is next touched. A thousand tasks means one sweep,
not a thousand timers — this is the difference between a queue that scales and
one that drowns in its own scheduler messages.

## Two ETS tables

```elixir
:ets.new(:review_queue_tasks, [:set, :protected, :named_table, read_concurrency: true])
:ets.new(:review_queue_order, [:ordered_set, :protected, :named_table])
```

The order table is keyed by `{-priority, sequence}`, so "the next task to hand
out" is `:ets.first/1` — O(log n), no scan, no re-sorting on insert. Negating
priority makes the natural ascending order put urgent work first, and the
sequence keeps equal priorities strictly FIFO.

`read_concurrency` on the store because reads vastly outnumber writes and must
not contend with them.

## Supervision

```elixir
children = [{ReviewQueue.Queue, queue_opts()}, {Bandit, plug: ReviewQueue.Router, ...}]
Supervisor.start_link(children, strategy: :one_for_one, ...)
```

`:one_for_one` because the HTTP layer and the queue fail independently. A crash
while handling a request must not discard queue state, and a queue restart must
not drop every open connection.

If the queue does crash, in-flight leases are lost — which is correct. A lost
lease returns its task to the pool. Re-reviewing a task is cheap; losing one is
not.

## HTTP API

Every `/v1/` route requires an `X-Annotator-ID` header.

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/tasks` | Enqueue a task |
| `POST` | `/v1/tasks/claim` | Lease the highest-priority pending task |
| `POST` | `/v1/tasks/:id/submit` | Complete a leased task |
| `POST` | `/v1/tasks/:id/extend` | Renew a live lease |
| `POST` | `/v1/tasks/:id/release` | Hand a task back |
| `GET` | `/v1/tasks/:id` | Read a task |
| `GET` | `/healthz`, `/stats` | Liveness and queue depth |

Errors share one shape, so a client needs one code path:

```json
{ "error": "not_lease_holder", "message": "caller does not hold this lease" }
```

| Status | Error | Cause |
| --- | --- | --- |
| `401` | `unauthenticated` | Missing `X-Annotator-ID` |
| `403` | `not_lease_holder` | Submitting a task you do not hold |
| `409` | `lease_expired` / `already_exists` | Lease lapsed, or duplicate live id |

## Bandit, not Cowboy

`plug_cowboy` pulls in `cowlib`, which at the time of writing carries
[CVE-2026-43966](https://osv.dev/vulnerability/EEF-CVE-2026-43966) (MEDIUM) and
CVE-2026-43969. `mix deps.get` flagged it on the first install.

Rather than pin around it, this uses [Bandit](https://github.com/mtrudel/bandit)
— pure Elixir, now the Phoenix default, and with no `cowlib` in the dependency
tree at all. The advisory is designed out rather than suppressed.

## Telemetry

```elixir
:telemetry.attach("log-claims", [:review_queue, :task, :claimed], &handler/4, nil)
```

| Event | Measurement | Metadata |
| --- | --- | --- |
| `[:review_queue, :task, :claimed]` | `%{count: 1}` | `task_id`, `holder` |
| `[:review_queue, :task, :completed]` | `%{count: 1}` | `task_id`, `holder`, `attempts` |
| `[:review_queue, :task, :dropped]` | `%{count: 1}` | `task_id`, `attempts` |

## Testing

```bash
mix check   # format --check-formatted, credo --strict, test
mix test --cover
mix dialyzer
```

50 tests and 2 doctests, 93% coverage, `credo --strict` clean, Dialyzer clean.

Time is **injected**, not slept on. Lease-expiry tests that `Process.sleep/1`
are slow and flaky; a swappable clock makes them instant and deterministic:

```elixir
{:ok, clock} = TestClock.start_link()
{:ok, q} = Queue.start_link(clock: TestClock.fun(clock), lease_ttl: :timer.minutes(1))

Queue.claim(q, "ann-a")
TestClock.advance(clock, :timer.minutes(2))   # no sleep
assert {:ok, %{attempts: 2}} = Queue.claim(q, "ann-b")
```

## License

MIT — see [LICENSE](LICENSE).
