# CLAUDE.md

@AGENTS.md

AGENTS.md (imported above) is binding for Claude exactly as for every other agent: human-only files,
instruction records in `automation/instructions.md`, and the commit conventions. Claude-specific details:

- Commit only on an explicit instruction for that commit. Subject prefix `[claude]`, one subject line of at
  most 150 characters, no body, then a blank line and `Co-authored-by: Claude <noreply@anthropic.com>`.
- Mark instruction records written by Claude with `(Claude)` after the timestamp.
- `CLAUDE.md` is maintained by agents; keep it short and factual.

## The project

ziglean is a Lean 4 kernel checker in Zig 0.14.1 (`.zig-version`). It reads a `lean4export` 3.x NDJSON
stream and checks every declaration. README.md states what "good" means: never accept a proof of `False`,
accept as many valid proofs as possible, and be fast and memory-frugal consistently across practical inputs.
The reference yardstick is the [Lean Kernel Arena](https://arena.lean-lang.org), which runs

    ziglean -j 4 --max-steps 1000000000 --max-temporary-nodes 128000000 FILE

Exit codes: 0 accepted, 1 rejected, 2 declined (resource limit or unsupported), 3 I/O or usage error.

## Build and test

Zig is not on PATH on the development machine; a pinned copy lives in the ignored `.tools/zigpy/ziglang/`.

    zig build -Doptimize=ReleaseFast                      # zig-out/bin/ziglean(.exe)
    zig build test -Doptimize=ReleaseSafe --summary all   # unit tests (test.zig -> tests/unit/*.zig)
    zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu -p .zig-cache/linux-check   # compile-only Linux check
    python scripts/fetch_arena.py                         # downloads arena fixtures into ignored arena/
    python scripts/test_arena.py --threads 4 --stress     # arena good/bad fixtures, incl. perf

Unit tests embed fixtures from `arena/` and `tests/kernel/`; fetch the arena bundle first on a fresh checkout.
`scripts/compare_versions.py` runs alternating, complete-process A/B measurements (wall, CPU, peak memory).

## Layout

- `src/expr.zig` hash-consed expression pool (imported `global` store, per-declaration scratch store),
  substitution transforms; `src/level.zig` universe levels.
- `src/type_checker.zig` the `Checker` (caches, budgets, scoped binder variables); `src/inference.zig` type
  inference; `src/reduction.zig` weak-head reduction; `src/conversion.zig` definitional equality;
  `src/nbe.zig` evaluation machine for computation-heavy terms; `src/primitive.zig` literal arithmetic.
- `src/inductive.zig` inductive blocks (recursors and rules are regenerated, never trusted);
  `src/quotient.zig` quotient declarations.
- `src/import.zig`, `parsed_stream.zig`, `scan.zig`, `environment.zig`, `parallel.zig`, `main.zig` import
  pipeline, environment and parallel batches.
- `tests/unit/` Zig tests; `tests/kernel/{good,bad}` exported regression fixtures with `sources/` and
  `GENERATED.md` (provenance); `tests/kernel/good/large/` is ignored (local multi-GB exports).
- `automation/instructions.md` instruction records; `automation/optimization-log.md` verified checkpoints;
  `automation/measurements/` (ignored) raw data.
- Ignored working areas: `.tools/` (toolchains, comparator builds), `.upstream/` (reference sources:
  official Lean kernel, nano-lean, lean4export, microlean), `arena/`, `reports/`, `benchmarks/`, `claude/`
  (Claude's scratch: tools, baselines, results).

## Unfinished work to continue (run R15, see O10 in `automation/optimization-log.md`)

Three interrupted work streams live in the ignored, machine-local `claude/r15/work/` folder; a future agent
should finish, review and merge them rather than start over. Each has a `NOTES.md` to resume from;
`claude/r15/STATE.md` holds the overall plan and `claude/r15/BRIEF.md` the shared rules and gates.

- `work/eval` (base `claude/r15/base-src/wave1`): rewritten `nbe.zig`, large speedups on the magma tests and
  reachability; open memory growth, unit tests not adapted.
- `work/rules` (base `wave1`): `subject-reduction-redex`, structure eta before reducing the major, complete
  universe-level comparison; unit-like eta, function eta and the let-fold fast path not started.
- `work/t2b` (base `claude/r15/base-src/wave2`): syntactic matcher done; environment-based checked inference
  (app-lam, let-ladder) in progress.

Merge with `claude/r15/tools/merge3.py`, then run every gate in `BRIEF.md`. Still to do after that: primitive
validation (built-in `Nat`/`String` acceleration is keyed on names only), differential fuzzing against the
official kernel, and a review of the merged diff.

## Rules of thumb for kernel work

- Soundness first. A new reduction or conversion rule needs a justification from Lean's type theory or the
  official kernel, plus exported fixtures that must be accepted *and* near-miss fixtures that must be
  rejected. When in doubt, fail closed (reject or decline).
- Behaviour must never depend on input file names, test declaration names or expected verdicts.
- Validate kernel changes with: the unit tests; every arena group (all verdicts, `-j 1` and `-j 4`, ReleaseFast
  and ReleaseSafe); the real-world corpora (init, std, cedar, con-leche, cslib, navier-stokes-euler,
  reachability, mathlib); and the Linux cross-build.
- Performance claims need alternating paired runs reporting wall time, CPU time and peak memory; record only
  verified results in `automation/optimization-log.md`.
