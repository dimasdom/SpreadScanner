# Investigation: ArbitrageScanner's 4-hour forced restart

**Status: inconclusive on root cause — a real correctness/hygiene issue was found and fixed, but it did not reproduce as an unbounded leak in isolation. The `timeout 14400` restart is still in place pending real evidence.**

## Symptom

`docker-compose.yml` runs the scanner worker as:

```
entrypoint: ["/bin/sh", "-c", "timeout 14400 dotnet ArbitrageScanner.Worker.dll; exit 0"]
```

paired with `restart: unless-stopped`, forcibly recycling the process every 4 hours. The README documented this as an intentional design choice ("prevents accumulation of stale data"), which is the tell of a leak papered over rather than fixed.

## Hypothesis

Code review of `ArbitrageScanner.Infrastructure/Services/ProxyService.cs` found a concrete candidate: `SetNextProxy()` constructed a **brand-new `HttpClientHandler` + `HttpClient` pair per exchange** (regular + observer service — 2× per exchange) on every proxy rotation, and disposed the *old* pair via a fire-and-forget `Task.Delay(30s).ContinueWith(...)`, with no bound on how many old clients could be queued for delayed disposal at once. Rotation happens every 200 symbols processed (`ArbitrageService.StartOperationParallel`), so if rotations ever outpaced the 30-second grace period, old clients could pile up faster than they were disposed.

## How this was actually measured

**This was not measured against the real production deployment.** No environment with real proxy credentials, real exchange connections, or hours of runtime was available in this session. Instead, the hypothesis was tested with an isolated, throwaway reproduction harness (not committed to the repo):

- A loopback `HttpListener` standing in for an exchange API, responding after a 300ms delay so requests are genuinely in-flight across rotations.
- A rotation loop replicating `SetNextProxy()`'s exact object-creation/delayed-dispose pattern, rotating once per second — far faster than production's real cadence — to make any overlap as obvious as possible.
- A second variant simulating heavy thread-pool pressure (400 background CPU-bound tasks), to test whether thread-pool contention could delay the `Task.Delay` continuations enough to make the backlog grow unboundedly.
- Instrumentation counting objects created vs. actually disposed, plus `GC.GetTotalMemory` and (separately) `lsof -p <pid>` for OS-level file-descriptor/socket counts.

## What was found

**The backlog is bounded, not unbounded — even under simulated heavy load:**

```
[..] created=6  disposed=0  pending_backlog=6  gcHeapMB=7
[..] created=16 disposed=0  pending_backlog=16 gcHeapMB=8
[..] created=26 disposed=0  pending_backlog=26 gcHeapMB=8
[..] created=31 disposed=1  pending_backlog=30 gcHeapMB=8   <- 30s mark: disposals start catching up
[..] created=46 disposed=16 pending_backlog=30 gcHeapMB=7
[..] created=66 disposed=36 pending_backlog=30 gcHeapMB=9
[..] created=90 disposed=61 pending_backlog=29 gcHeapMB=6   <- steady state, ~90s in
```

The backlog stabilizes at ~30 objects — exactly what `30s grace period ÷ 1s rotation interval` predicts — and stays flat. Managed heap stayed in the 2-9MB noise range throughout (GC-driven fluctuation, not growth). File-descriptor count under the non-load variant also stayed flat (118-128 range over 80s). `Task.Delay` timers fired reliably even under the simulated thread-pool pressure; disposal never fell meaningfully behind creation.

**Conclusion: this specific mechanism, as reproduced in isolation, does not explain an unbounded multi-hour leak.** It's architecturally wasteful (churning ~24+ handler/client pairs per rotation instead of reusing them) but self-correcting.

### A real bug found along the way

While designing the fix (reuse one handler per exchange, only rotate the proxy target), a second, separate issue was confirmed directly: **`HttpClientHandler` locks properties like `.Proxy`/`.UseProxy` after the first request is sent** — a naive "just reuse the handler and reassign `.Proxy` on each rotation" fix throws `InvalidOperationException: This instance has already started one or more requests` at runtime. This was verified with a standalone repro before writing the real fix, not assumed.

## Fix applied (regardless of unconfirmed root cause)

`ProxyService.SetNextProxy()` now creates one `HttpClientHandler`/`HttpClient` pair **per exchange, once**, and rotates only the proxy target on subsequent calls — via a new `RotatingWebProxy : IWebProxy` (`ArbitrageScanner.Infrastructure/Services/RotatingWebProxy.cs`) whose `GetProxy`/`Credentials`/`IsBypassed` delegate to a swappable inner `WebProxy`. The handler's own `.Proxy` reference never changes after construction (avoiding the lock), only the wrapper's internal target does. This eliminates the object churn and the delayed-dispose pattern entirely — there's nothing to dispose on rotation anymore.

This is a legitimate improvement independent of whether it was the actual cause of the 4-hour degradation: fewer allocations per rotation, no reliance on a 30-second timing assumption, and one less moving part. Verified with unit tests (`ArbitrageScanner.Tests/RotatingWebProxyTests.cs`) and a clean Docker build.

## What this doesn't tell us

The real 4-hour degradation that motivated the `timeout 14400` wrapper was never reproduced or measured in this investigation — only the one specific hypothesis about `ProxyService` was tested, and it came back negative. Other candidates that were *not* ruled out:

- ccxt's own internal state per `Exchange` instance (WebSocket ticker streams, rate-limiter bookkeeping) over real, sustained multi-hour exchange traffic — this needs real exchange connections to observe.
- The `ExchangeMarkets`/`ExchangeSpotMarkets` collections in `DataService`, which only ever grow (`TryAdd`) and are refreshed via `UpdatePairs()` every 10 batches — plausible if `UpdatePairs()` doesn't actually replace stale entries, though a first-pass read suggested this is bounded by the exchange's real market list.
- Anything specific to real proxy servers (vs. the direct, no-proxy connections used in the reproduction) — proxied connections can have very different connection-lifecycle behavior than direct ones.

## Recommendation

Do **not** remove the `timeout 14400` restart wrapper based on this investigation alone — the roadmap's own condition for removing it ("once proven fixed") isn't met. The fix applied here is worth keeping regardless, but the restart hack should stay in place until the actual degradation is measured directly — either with `dotnet-counters`/`dotnet-gcdump` against a real deployment over several hours, or by removing the timeout in a low-stakes environment and watching Grafana over a full unforced run.
