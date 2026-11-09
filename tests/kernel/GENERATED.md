# Locally generated regression exports

`conversion.ndjson` and `unit_like.ndjson` were generated from
`tests/kernel/sources/Conversion.lean` and `tests/kernel/sources/UnitLike.lean`, respectively, with
Lean **4.34.0-rc2** (`6a10ac8c22beadecabdbb0919c2b50214762f91d`) and lean4export
**3.1.0** (`df81913eee5519d5a88ae5b0fd701b5298cc29ab`). Their exported declarations
are the theorems in namespace `ZigleanRegression` in those source files.

Compile each source to a `.olean` in a temporary Lean project with that toolchain,
then use `scripts/export_lean.py` with the module and theorem names. The exports
include the declarations' transitive dependencies from Lean's `Init` library,
covered by `LICENSES/Lean-Apache-2.0.txt`.

SHA-256:

* `conversion.ndjson`: `604a667312eb453b151acfb6c10c2a140382def83fb52e3be61305eb94a2ad35`
* `unit_like.ndjson`: `d530ac02a742e30eb013f99b6e46dc95c3ec2ec84e482273252773115b6420b1`

The conversion fixture deliberately contains a reducible proof with one billion
recursive steps. Proof irrelevance makes checking it cheap; the unit test enforces
a 100,000-step budget. It also compares a projected symbolic subtraction whose
argument contains `n + 2^31`, which must stay symbolic during conversion.
An additional theorem checks a proof argument wrapped in Lean's `eagerReduce`.
The unit-like fixture covers proof irrelevance, zero-field
structure equality, structure eta, and function extensionality with released Lean
semantics.

`multifunctor.ndjson` exports
`CategoryTheory.Functor.LaxMonoidal.ofBifunctor.firstMap₁` from
`Mathlib.CategoryTheory.Monoidal.Multifunctor`, Mathlib revision
`be865aa50cc0364be66c3941a6dc0c845a2c2ceb`, with the same Lean and exporter versions.
It includes 657 declarations in 2.59 MB and tests application congruence under a
one-million-step budget. Its SHA-256 is
`6d5c551bfa5180ff49b2e7dabb0152a452500f387b44b965d2808b827e567dd0`.
Mathlib is distributed under Apache-2.0.

`signed_range.ndjson` exports
`_private.Init.Data.Range.Polymorphic.SInt.0.Int32.instRxcHasSize_eq`
from `Init.Data.Range.Polymorphic.SInt`, using the Lean and exporter versions above.
Its 2,089 declarations occupy 6.52 MB. It guards abbreviation unfolding priority
and projection reduction under a one-million-step budget. SHA-256:
`88fd7bd7c7a909012d34f867383f00fa63eef9e6f79a50a9c15cc8101ef9b991`.

`nested.ndjson` exports `NestedTree` from `tests/kernel/sources/Nested.lean`, using the
same Lean and exporter versions. Duplicate application records were inserted,
with expression references renumbered, to exercise noncanonical input DAGs.
It has ten declarations and is checked both sequentially and in parallel.
A separate unit test constructs duplicate raw nested parameters directly and
verifies structural target matching. SHA-256:
`e33362bd0de4bf2a2be18f747ac5cda48cf9b397e7e91d6aed1ebd7a2a025ff9`.

`proof_universes.ndjson` exports `ProofUniverses.collapsed` from
`tests/kernel/sources/ProofUniverses.lean`, with the same toolchain. Its 5.2 KB checks
proof irrelevance for opaque values whose polymorphic result universe is
instantiated to zero. SHA-256:
`bf4d245d0136b2cb38138d980532b43c58b2db01af0e63b2245c97193d4601d8`.
