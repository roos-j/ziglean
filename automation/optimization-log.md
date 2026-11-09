# Verified optimization checkpoints

Only correctness-validated, paired measurements belong in this log. Experimental
results remain in ignored `reports/`. Speed is the primary objective; peak memory
is measured alongside it. Work continues from the best verified checkpoint.

## O1 — 2026-11-08 16:20 EST

Full Mathlib: 713,377 declarations, identical input and limits, 16 workers,
initial batch size 16,384. Three alternating complete-process runs on the same
Windows/i9-14900K machine. Both versions accepted every declaration in every run.

| Metric | Previous checker | O1 |
| --- | ---: | ---: |
| Median wall time | 20.195 s | 18.313 s |
| Median CPU time | 294.266 s | 250.750 s |
| Maximum peak working set | 3,960,643,584 bytes | 2,480,664,576 bytes |

This is 9.3% less wall time, 14.8% less CPU time, and 37.4% less peak memory.
The first O1 process took 26.645 s although its internal checking timer reported
17.413 s. That unexplained external-timing outlier remains in the recorded data;
it was not discarded. Later O1 processes took 18.313 s and 17.600 s.

Validation: 57/57 Debug unit tests, 208/208 Arena cases, and an x86_64 Linux
ReleaseFast cross-build. Linux runtime behavior was not tested.

Retained changes: 12-byte imported nodes and 16-byte temporary nodes with exact
overflow handling; immutable snapshot/vector and universe-list sharing; scoped
inference/conversion locals; selective delta unfolding; monomorphic fast paths;
batched dependent projection types; direct imported binary-node construction.

Baseline executable SHA-256:
`f8e034f6f6c12a277b960650d816d6ad38e3832884a7b1f627d5bbd348933d8e`.
O1 executable SHA-256:
`76495a1540408a9a6c33016fe8a4926171e4397a1ce4e484b08bdebf09ebfe23`.
The preserved O1 executable is `.tools/round2/verified-01.exe`.
Raw measurements and source fingerprints are in [measurements/O1.json](measurements/O1.json).

Further work: full-input profiling identifies import as the remaining bottleneck.
At batch size 4096, snapshot creation alone took 1.669 s and peak owned snapshot
tables were approximately 420 MB. Shared indexed name/string maps are being tested
to remove this copying and duplicate key storage.

## O2 — 2026-11-08 16:30 EST

Full Mathlib, three alternating runs against preserved O1, with the same input,
16 workers, batch size 16,384, and checking limits. All six runs accepted all
713,377 declarations.

| Metric | O1, remeasured | O2 |
| --- | ---: | ---: |
| Median wall time | 17.885 s | 15.912 s |
| Median CPU time | 232.344 s | 234.969 s |
| Maximum peak working set | 2,326,138,880 bytes | 1,912,619,008 bytes |

This is a further 11.0% reduction in wall time and 17.8% in peak memory. CPU time
was approximately unchanged (1.1% higher); the benefit is lower import overhead
and better overlap with checking. Candidate wall times were 15.912, 16.377, and
15.455 s. Every run is retained in [measurements/O2.json](measurements/O2.json).

Retained changes: append-only indexed name/string maps with atomic publication,
frozen-prefix lookup and reference-counted table generations; snapshots share
these tables instead of copying them. Expression-reference page descriptors now
occupy eight bytes instead of sixteen, preserving irregular mappings and full
32-bit wrapping offsets.

Validation: 60/60 Debug unit tests, 208/208 Arena cases, and the six complete
Mathlib checks above. Concurrent table insertion, resizing, hash collisions,
snapshot visibility, and clone independence have targeted regressions.

O2 executable SHA-256:
`f491e7a1687614f75af42797f2189b9225608e84d984e1ae1a6acedaf509908c`.
Executable and exact source snapshots are preserved as
`.tools/round2/verified-02.exe` and `.tools/round2/O2-source.zip`.

Further work: test shared declaration indices, then bounded producer-thread
parsing. The latter aims to overlap scanning and JSON parsing with validated
import, without increasing retained input size in proportion to Mathlib.

## O3 — 2026-11-08 16:54 EST

Full Mathlib, three alternating runs against preserved O2, identical input,
16 checking workers, batch size 16,384, and checking limits. O3 also uses one
producer thread to parse regular-file input. All six runs accepted all 713,377
declarations.

| Metric | O2, remeasured | O3 |
| --- | ---: | ---: |
| Median wall time | 15.653 s | 14.824 s |
| Median CPU time | 239.313 s | 240.734 s |
| Maximum peak working set | 2,028,089,344 bytes | 1,703,677,952 bytes |

This is a further 5.3% reduction in wall time and 16.0% in peak memory, with CPU
time approximately unchanged (0.6% higher). Candidate wall times were 15.121,
14.650, and 14.824 s. Raw runs and source fingerprints are in
[measurements/O3.json](measurements/O3.json).

Retained changes: shared atomic declaration indices with a cached visibility
bound; 10-byte imported nodes with exact overflow handling and a combined child
metadata fast path; universe-list memoization within individual substitutions;
bounded producer parsing with 48-byte queue entries. The parser owns three fixed
batch arenas, preserves input/error order, and falls back to synchronous parsing
for exceptional large records. Stdin and single-worker checking remain synchronous;
`--sync-import` also permits a direct comparison using the same executable.

Validation: 76/76 Debug unit tests, 208/208 Arena cases, and the six complete
Mathlib checks above. An x86_64 Linux ReleaseFast cross-build also passed;
Linux runtime behavior was not tested. No test failures were suppressed. One new parser test needed
a larger test arena to exercise JSON parsing rather than the correct raw-record
fallback; production limits were unchanged.

O3 executable SHA-256:
`331cc6829d4c2fe11109b72ce82948c2659f7e1d1d329dfd2fe919a6b55b0cc7`.
Executable and exact source snapshots are preserved as
`.tools/round2/verified-03.exe` and `.tools/round2/O3-source.zip`.

Further work: compare inference-cache lookup before node decoding, measure the
new pipeline's remaining waits, and investigate scheduling variability using
per-thread CPU time and sampled processor classes. Scheduling is currently only
a hypothesis; no affinity or system-wide scheduling changes have been made.

The subsequent inference-cache-before-decode experiment did not show a clear
gain: focused single-worker wall time was 3.462 versus 3.475 s, and parallel
results were mixed. Its code change was removed; the cache-lifetime/budget
regression test remains. The experimental executable and reports remain separate
from O3.

## O4 — 2026-11-08 17:18 EST

Full Mathlib, three alternating runs against preserved O3, identical input,
16 checking workers plus the parser thread, and initial batch size 16,384.
All six processes accepted all 713,377 declarations.

| Metric | O3, remeasured | O4 |
| --- | ---: | ---: |
| Median wall time | 14.745 s | 13.931 s |
| Median CPU time | 238.000 s | 219.344 s |
| Maximum peak working set | 1,703,071,744 bytes | 1,602,322,432 bytes |

This is a further 5.5% reduction in wall time, 7.8% in CPU time, and 5.9% in peak
memory. Candidate wall times were 13.718, 13.931, and 13.940 s. Raw runs are in
[measurements/O4.json](measurements/O4.json).

Only scheduling thresholds changed from O3: the adaptive batch ceiling is now
16,384 rather than 65,536, and at most two jobs remain active rather than four.
Explicit larger initial batch sizes still take precedence. The checker and
parser are identical to O3. Before full validation, paired measurements on a
2.48 GB prefix also improved both time and memory.
The exact preserved O4 source also passed all 76 Debug unit tests, including
parallel scope and forward-reference regressions.

O4 executable SHA-256:
`8aa94e006659bba0c6c898c9e6de72d84f5951ec85a91fed2c4af934b43730bf`.
Executable and exact source snapshots are preserved as
`.tools/round2/verified-04.exe` and `.tools/round2/O4-source.zip`.

Further work: evaluate FIFO dispatch and a bounded cache of repeated universe
instantiations. Diagnostic profiling observed 9.18 million repeated constant-type
substitutions generating 82.9 million temporary nodes; the bounded observation
table omitted additional keys, so this is not a complete reuse census.

FIFO dispatch was subsequently tested and removed: with two active jobs, the
moderate-input median was 5.008 s for the standard pool versus 4.994 s for FIFO,
with essentially identical CPU time. Four FIFO jobs improved that experiment's
wall time slightly but added about 40 MB. The production code retains the standard
pool and O4's two-job limit; FIFO artifacts remain separate for reproducibility.

The first bounded retained-type store also remains experimental. All 89 initial
regression tests passed, but its medium-input CPU time rose from 78.36 to 83.30 s.
Single-worker normalization, which does not retain types, slowed from 3.421 to
3.720 s. Explicit cold routing reduced that overhead but did not eliminate it
(3.504 versus 3.612 s in a separate paired comparison). The cache observed 1.60
million hits on the medium input, so reuse is real; handle access and admission
costs still need work. None of these measurements is recorded as an improvement.

An 8,192-declaration batch experiment had a slightly lower medium-input median
wall time (5.059 to 4.894 s), but CPU time increased and peak memory rose by
19.3 MB. O4's 16,384-declaration setting remains the accepted default.

Further isolated experiments remain outside the accepted checkpoint. A custom
universe-node hash was slower in all three paired medium-input runs. Moving
substitution memo lookups before decoding was approximately neutral. Packing
imported nodes into eight bytes passed 87 Debug tests and all 208 Arena cases;
full Mathlib peak memory fell from 1,600,942,080 to 1,448,574,976 bytes, but median
wall time increased from 14.107 to 14.257 s. That storage tradeoff is preserved
for further work rather than replacing the speed-prioritized checkpoint.

## O5 — 2026-11-08 18:21 EST

Full Mathlib, three alternating runs against preserved O4, identical input,
16 checking workers plus the parser thread, and batch size 16,384. All six
processes accepted all 713,377 declarations.

| Metric | O4, remeasured | O5 |
| --- | ---: | ---: |
| Median wall time | 13.754 s | 13.499 s |
| Median CPU time | 222.313 s | 220.125 s |
| Maximum peak working set | 1,597,014,016 bytes | 1,382,592,512 bytes |

This is a further 1.9% reduction in wall time, 1.0% in CPU time, and 13.4% in
peak memory. Each paired candidate run was faster: 13.536, 13.480, and 13.499 s
against 13.850, 13.570, and 13.754 s. The speed gain is modest; the memory gain
is substantial. Raw runs and exact source fingerprints are in
[measurements/O5.json](measurements/O5.json).

Retained changes: aligned eight-byte imported nodes with exact full-node escape
storage for wide ranges, third payloads, uncommon kinds, and large payloads;
56-byte declaration records with immutable rare metadata out of line; 24-byte
stored parser queue entries using batch-relative offsets; a lazily allocated
32K dense memo-cache window; and skipping impossible imported-leaf lookups for
worker-private universes. Ordinary declaration `all` lists are still validated,
then discarded because the kernel only uses those groups for inductives and
recursors. The combined storage savings more than offset the larger dense cache.

The packed representation preserves full-width IDs and payloads. References
above 134,217,727 use escape storage, so larger future exports can have a higher
escape rate and weaker compression; this is a performance tradeoff, not a
language restriction. No checking judgments persist between declarations.

Validation: 92/92 Debug tests, 208/208 Arena cases, all six complete Mathlib
checks, and an x86_64 Linux ReleaseFast cross-build. Linux runtime behavior was
not tested. The first declaration-layout experiment allocated rare metadata for
ordinary exported `all` fields and was rejected. Its replacement preserves
reference validation without those allocations; a newly added test fixture was
also corrected to supply required definition bodies, with production validation
unchanged.

O5 executable SHA-256:
`17fda1b51410d335f72842a9063a19ce5628b9e693a3edcf41190e8b4383aba2`.
The executable and exact source snapshot are preserved as
`.tools/round2/verified-05.exe` and `.tools/round2/O5-source.zip`; the working
source and installed executable now use this checkpoint. Obsolete experiment
compiler caches were removed, freeing another 742 MiB while preserving results.

Further work: test direct bound-variable and literal-type lookups, then evaluate
optional importer/parser ideal-processor hints on this hybrid-core Windows
machine. The retained-type cache variants and 64K dense window were not adopted:
their measured benefits did not justify their costs.

Post-O5 experiments: soft Windows ideal-processor hints were accepted by the OS
but produced mixed timing and higher CPU time, so they remain isolated. One
active checking job reduced memory but slowed the 16-worker comparison; tests
with 18, 20, and 24 workers did not establish a reliable overall improvement.
Both direct bound-variable cache variants were also left out after parallel
timing regressions. The benchmark reporter now records each variant's effective
worker count and batch size, including command-line overrides.

The combined exact stamped u32 memo entries and direct builtin literal lookup
passed 94 Debug tests, all 208 Arena cases, and a Linux cross-build. Its full
Mathlib comparison did not establish a speed gain: median wall time was
13.902 s versus O5's 13.569 s; CPU time was 221.61 s versus 224.22 s, and peak
working set was effectively unchanged (1,374,928,896 versus 1,375,997,952 bytes).
It was not adopted. Raw paired results and exact candidate source remain in
`reports/round2-stamped-literal-full.json` and
`.tools/round2/stamped-literal-source.zip`.

Further isolated candidates were left out: twelve-byte scratch nodes saved
about 10.6 MB on the focused input but increased median wall time from 5.051 s
to 5.196 s and CPU time from 79.28 s to 82.30 s. Generic memo fingerprints
gave no clear speed improvement. A twelve-byte equality cache had mixed
parallel results and slowed the serial comparison from 3.461 s to 3.511 s.
Exact sources and raw reports remain under `.tools/round2/` and `reports/`.

The comparison tool now supports explicit, equally applied `--warmup` runs,
recorded separately and excluded from measured summaries. Failed warmups
prevent successful timing summaries; the default remains zero for continuity
with earlier reports. No measured outliers are removed. The obsolete generated
`tests/local/scaling.ndjson` subset was deleted, freeing 1,064,862,790 bytes;
the active larger subset and full Mathlib input remain available.

Smaller reference pages and known-absent substitution-cache insertion each won
their three focused pairs, but their combination did not hold up on full
Mathlib. After equal warmups and four alternating measured pairs, O5 took
13.554 s median versus 13.742 s for the candidate. CPU time was 220.95 s versus
218.09 s; peak working sets were 1,379,770,368 and 1,378,811,904 bytes. All runs
accepted Mathlib. The candidate also passed 96 Debug tests, all 208 Arena cases,
and a Linux cross-build. It remains isolated, with exact source and raw results
in `.tools/round2/refs256-absent-source.zip` and
`reports/round2-refs256-absent-full.json`; O5 is still the retained checkpoint.
Other isolated range, cache, and reduction experiments continue. Another
1,383,669,089 bytes of obsolete compiler caches were removed without deleting
candidate source, executable, or report artifacts.

Concurrency was then tested without changing O5: 20 workers reduced focused
median time from 4.965 s to 4.493 s but raised peak memory from 668,520,448 to
705,490,944 bytes. Eighteen workers also improved time but increased peak
memory. These settings alone are not accepted as improvements under the memory
constraint. Name-reference compression and lower between-declaration cache
retention each saved about 7 MB in isolated focused comparisons with roughly
unchanged time. Their combination at 18 workers is undergoing full validation;
all reported configurations identify the actual worker count explicitly.

Full validation of that 18-worker candidate confirmed a latency improvement:
all four measured candidate runs beat their O5 pairs, with medians 12.516 s
versus 13.532 s (7.5% less elapsed time). It used 18 checking workers versus
16; this is not an equal-worker algorithmic speedup. Median CPU time increased
from 220.77 s to 227.93 s. Maximum peak memory was slightly higher:
1,379,983,360 versus 1,373,642,752 bytes (+0.46%). The latency gain is recorded,
but the candidate is not adopted yet because the measured peak did not fall.
It passed 97 Debug tests, all 208 Arena cases at 18 workers, a Linux cross-build,
and all full runs. Exact source and measurements are preserved in
`.tools/round2/names-trim64-source.zip` and
`reports/round2-names-trim64-j18-full.json`.

Worker-universe ownership diagnostics on the focused input found a largest
complete worker allocation estimate of 943,848 bytes and a largest batch's
sum of end-of-worker capacities of 11,564,500 bytes (not simultaneous peak).
Recycling universe IDs is therefore not justified by this evidence. The next
memory experiment lowers retained temporary expression storage between
declarations, using its existing reclamation path.

## O6 — 2026-11-08 20:08 EST

Adopted compressed external name references, 64K-slot retention limits for
judgment and transformation caches, and a 256K-node scratch-expression retention
limit. These limits reclaim oversized storage between declarations; proof-local
growth and checking budgets are unchanged. The memory savings permit 18 checking
workers within the previous 16-worker configuration's measured peak.

Four alternating full-Mathlib pairs after equal warmups gave median elapsed time
13.633 s for O5 at 16 workers and 12.440 s for O6 at 18 workers (8.7% less time).
All four candidate runs were faster. Maximum peak working set fell from
1,387,036,672 to 1,364,094,976 bytes (1.7%); median CPU time rose from 222.51 s
to 225.27 s (1.2%). Both used batch size 16,384. This includes a concurrency
change and is not an equal-worker algorithmic speedup. No outliers were removed.

Validation: 99 Debug tests, all 208 Arena cases at 18 workers, all measured and
warmup full-Mathlib runs, and an x86_64 Linux ReleaseFast cross-build (compile
only). Independent reviews covered reference semantics and cache reclamation.
Exact measurements are in `automation/measurements/O6.json`; preserved source
and executable are `.tools/round2/O6-source.zip` and
`.tools/round2/verified-06.exe`. Executable SHA-256:
`2beeddc45b2a233be4852ce1936eba5c626c0fa9f23c4d25974698ce0081a5e8`.

The next experiment lowers scratch retention to 128K nodes, comparing both
versions at 18 workers. Further conversion and pipeline opportunities are also
being investigated; O6 remains the checkpoint until a successor is verified.

The 128K scratch variant passed 99 Debug tests, 208 Arena cases, a Linux
cross-build, and all full runs. At equal 18-worker settings its four-pair full
comparison measured 12.872 s versus O6's 12.924 s, 218.68 versus 225.19 CPU
seconds, and 1,331,183,616 versus 1,350,713,344 bytes maximum peak memory.
Memory fell in every pair, but three of four elapsed-time pairs were slower;
the tiny median-time difference does not establish a speed improvement.
The variant remains isolated while testing whether its memory savings permit
more useful concurrency. Raw results: `reports/round2-scratch128-j18-full.json`;
exact source: `.tools/round2/names-trim64-scratch128-source.zip`.

The focused 128K/20-worker comparison against O6/18 workers did not establish
a speed gain (4.611 versus 4.576 s median), although maximum peak memory stayed
slightly lower. It was not adopted. A 64K variant subsequently won all four
equal-worker focused pairs and reduced peak memory by 22,630,400 bytes; full
validation is in progress.

A diagnostic build exposed a scheduling-dependent failure in the existing
snapshot-reader test: the reader signaled readiness before performing its first
lookup. The test now acknowledges its first completed read, also signaling on
early failure to prevent a deadlock. This changes test synchronization only.
The rebuilt interning diagnostic and weighted-batch candidate passed 101 and
104 Debug tests respectively.

Removed a further 927,305,004 bytes of obsolete compiler caches. Candidate
executables, exact source archives, and measurement reports were preserved.

## O7 — 2026-11-08 20:26 EST

Reduced scratch-expression retention from 256K to 64K nodes, using the existing
between-declaration reclamation path. Within a declaration, storage can still
grow to the configured checking budget. Included the test-only reader-start
synchronization fix described above.

Four alternating full-Mathlib pairs after equal warmups, both at 18 workers and
batch size 16,384, measured 12.719 s median for O6 and 12.027 s for O7 (5.4% less
elapsed time). Every candidate pair was faster. Median CPU time fell from
225.05 s to 218.08 s (3.1%); maximum peak working set fell from 1,363,255,296
to 1,321,406,464 bytes (3.1%). All runs and warmups accepted Mathlib; no timings
were discarded.

Validation: 99 Debug tests, all 208 Arena cases at 18 workers, and an x86_64
Linux ReleaseFast cross-build (compile only). Exact measurements are in
`automation/measurements/O7.json`; preserved source and executable are
`.tools/round2/O7-source.zip` and `.tools/round2/verified-07.exe`.
Executable SHA-256:
`f44c44d053a047821dee3d1bd1faa812387a8cd18bf1027da780312b099cdeba`.
Further work continues with deferred composite metadata, selective result-type
specialization, and expression-weight-based batch scheduling, rebased on O7.

## Wrap-up — 2026-11-08 20:36 EST

Stopped further optimization at the user's request. O7 remains the retained
implementation: later deferred-metadata, selective-tail, and weighted-batch
experiments showed small or mixed focused changes and were not adopted.
Their sources and reports remain isolated under ignored directories.

Moved all 13 test-only Zig files from `src/` to `tests/`, with the main suite
named `kernel_tests.zig`. Updated test imports, fixture paths, and both live
benchmark source-hash collectors. Implementation modules retain their inline
unit tests. The ignore rules expose the relocated Zig test sources, retain
ignored generated fixtures/datasets and external Arena files, and now ignore
`automation/measurements/`. Historical measurement/source fingerprints are
unchanged. The relocated suite passed all 99 Debug tests. No git commit was
created.

The final ReleaseFast build succeeded, and the remaining production source
files match O7 byte-for-byte. The source-layout cleanup did not change kernel
behavior; no further full-Mathlib benchmark was needed.
