## Why

The Rust backend has no type-directed expression renderer. `expr-rust` (`rust-passes-emit.ss:1855`) and `ctor-expr-rust` (`rust-passes-walker.ss:218`) receive no expected type; the `(if …)` IR node carries no join type; and the typechecker's `(safe-cast <target> <src> …)` wrapper — which **does** encode the destination type at every consequential position — is peeled transparently (`rust-passes-emit.ss:1863`) or ignored. Consequently the same "what Rust type/width must this expression be emitted at" decision is re-derived independently at ≥8 use sites across four body routes. This is the structural cause of PR #70's ~10 compiler review-fix commits: each new ternary shape had to be patched at every site, and pre-existing sibling bugs (a bare `0` in a Field struct member, `some(0)`, `[0]` feeding a native) share the same root. Fixing the root once is cheaper and more stable than patching positions forever.

## What Changes

- Introduce a single type-directed coercion decision point: `materialize-at-type` (the one place that turns an expression plus an expected Compact type into correctly-typed Rust) and a typed entry `expr-rust-typed`, with the expected type carried by a dynamic parameter (`current-expr-expected-type`). `expr-rust` / `ctor-expr-rust` / streaming renderers delegate to it.
- Stop peeling `safe-cast`: materialise it as the appropriate lossless Rust coercion, choosing the destination width from the target type. `Uint → Field` selects `u64` for ≤ `u64::MAX` and `u128` for larger (the field modulus is ~2²⁵⁵, so `From<u128> for Fr` is lossless) and refuses (`field-uint-coercion`) only above `u128::MAX`; `Uint → wider Uint` widens losslessly (`(x) as u64`); aggregate targets are coerced element-wise, including nested aggregates. This **subsumes the separately-planned mixed-width operand fix**: the typer already wraps the narrower comparison/equality operand — and each ternary arm in a wider join — in `(safe-cast <wider> <own> …)`; materialising that wrapper once is the whole fix, so no `fix-mixed-width-operand` change is needed.
- Wire the expected type from the consuming boundary at every position: `const` RHS (declared type), return tail (declared return type), comparison operands, `assert` argument, call arguments (pure-circuit, witness, constructor, `some`/`none`, and native — from the argument's `safe-cast` target), struct-literal members (field type), vector/array elements and the persistentHash/transientHash tuple split (enclosing `safe-cast`'s element type), and ledger cell writes (destination field type).
- Guarantee no sentinel reaches emitted output: a post-emit assertion rejects `#f`/unsafe sentinel splices, replacing PR #70's weak `/* TODO` scan (`rendered-has-todo?`). Any unrenderable position refuses loudly with a source location.
- Fold in one pre-existing, coercion-independent walkability fix (kept explicit as task 3.1): the constructor walker must skip the declaration-only `const` statements the typechecker emits for lifted temps (`const-decl-only?`, `rust-passes-emit.ss:646`), matching the streaming walker — reachable at uniform widths and required by the constructor mixed-width fixture this change ports.
- Adopt TypeScript feature parity as the acceptance criterion: any program the TS target compiles, the Rust target MUST either compile or refuse with a documented, tracked limitation; a refusal at a position TS accepts is a defect.
- New neutral fixtures (`examples/literal_coercion_fixture.compact` + crate) covering the pre-existing bare-literal positions this closes, with executing tests; byte-stability sweep over the whole `FIXTURES` corpus.

## Capabilities

### New Capabilities

- `rust-codegen/type-directed-coercion`: the Rust backend renders every expression against its expected Compact type at a single decision point, materialising the typechecker's `safe-cast` losslessly in every position and body route, with no silent sentinel output.

### Modified Capabilities

(none)

## Impact

- `compiler/rust-passes-helpers.ss` (new `materialize-at-type`, `current-expr-expected-type`), `compiler/rust-passes-emit.ss` (typed entry; clause rewrites; boundary wiring), `compiler/rust-passes-walker.ss` (walker + ctor + streaming boundaries), `compiler/rust-passes-streaming.ss` (streaming boundaries), possibly `compiler/rust-passes-decls.ss`.
- New fixtures + registrations; `tests-e2e-rust/tests/*`; `docs/rust-backend-limitations.md` (recomputed counts); `compiler/compiler-version.ss` 0.31.116 → 0.31.117, `flake.nix`, `doc/ledger-adt.mdx`, `CHANGELOG.md`.
- Prerequisite for `fix-ternary-expression-codegen`; consumes the oracle probes from `vendor-digital-passport-harness` (including flipping the mixed-width operand probe, which this change owns). This change may alter emitted bytes only where output was previously wrong or ambiguous (bare literals in Field positions, mixed-minimal-width operands); AGENT.md §5.2 diff classification is mandatory.
- Byte-stability constraints are explicit: width comparison uses `uint-rust-width`, not `sametype?` (so `Uint<0..256> <= Uint<0..65535>`, both `u16`, gains no spurious cast); the bare-literal peel at comparison boundaries is preserved; and `+ - *` operands are **not** pushed an expected type (they are already same-width via `arith-binop-rust`'s `mbits` cast, and pushing one would double-cast).
