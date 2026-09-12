## Context

Both backends consume the same `Ltypescript` IR. The typechecker already computes every required coercion and records it as a `(safe-cast <target> <src> expr)` wrapper:
- call arguments (including `some<T>`, `none`, and natives) are wrapped to the declared formal type via `maybe-safecast` (`analysis-passes.ss:2942-2949`);
- struct-literal initialisers are wrapped to the field's declared type (`analysis-passes.ss:3070`);
- ternary arms are wrapped to the inferred join type (`analysis-passes.ss:2589-2603`);
- return tails are wrapped to the return type (`analysis-passes.ss:1830`).

The Rust renderer discards this context: `expr-rust`'s `safe-cast` clause is transparent (`rust-passes-emit.ss:1863`), `call-rust` matches the bare `tuple` (`:2462`), struct rendering ignores field types (`render-struct-literal`, `:280`), and the pure call route does not ascribe (`:2414`). The TS backend, by contrast, emits `cond ? e1 : e2` with no ascription and no `expr-supported?` gate (`typescript-passes.ss:2850`), relying on dynamic typing — so TS accepts every one of these positions.

Evidence that the gap is real and pre-existing: `AlignedValue::from(0)` is ambiguous across the integer `From` impls (comment at `rust-passes-emit.ss:866-873`), and a bare literal in a Field struct member already emitted wrong Rust before any ternary work. The ternary change merely exposes the same gap for `c ? 1 : 0`, where two literal arms give Rust nothing to infer from.

## Goals / Non-Goals

**Goals:**
- One home for the "render this expression at this expected type" decision.
- Lossless materialisation of every `safe-cast` the typechecker emits, in every position and body route.
- TS feature parity, with any residual refusal documented and tracked.
- No sentinel can reach emitted Rust.

**Non-Goals:**
- No frontend/typechecker change; no TS backend change.
- No change to language version or runtime crates.
- Not a wholesale rewrite of the emitters — the dynamic-parameter wrapper avoids re-threading every renderer signature.

## Decisions

1. **A dynamic expected-type parameter plus two functions, not full signature threading.** `current-expr-expected-type` (parameterized in `rust-passes-helpers.ss`) carries the destination type; `expr-rust-typed expr expected` binds it and calls `expr-rust`; `materialize-at-type src target-ttype source-ttype rendered` is the single coercion decision. Full threading through every renderer would be a large mechanical change with a large blast radius; the parameter keeps the change local and lets each boundary opt in with a one-line swap. Default `#f` (no expectation) preserves byte-identical output for already-correct emissions.
2. **`safe-cast` is materialised, not peeled.** `materialize-at-type` returns the inner rendering unchanged when no coercion is required (same type / uniform width / literal Rust can infer), and otherwise emits the lossless cast. This both fixes wrong sites and keeps neutral sites byte-identical.
3. **Width selection is lossless by construction.** `uint-coercion-cast-width` picks `u64`, then `u128`; above `u128::MAX` it refuses. Aggregate targets recurse element-wise, decomposing syntactic tuples and temp-binding/indexing any other aggregate.
4. **No-sentinel post-emit guard.** Emitted text is scanned for the `#f`/unsafe sentinel before it is written; a hit raises a located `rust-feature-error`. This replaces `rendered-has-todo?` (a `/* TODO` scan), which PR #70 proved too weak when a `cond =>` fall-through spliced `#f` into an operand.
5. **Refuse only what cannot be losslessly rendered.** Per the parity criterion, every position the typechecker wraps must render; a refusal there is a bug. Refusal is reserved for genuinely unsupported constructs, which must appear in `docs/rust-backend-limitations.md`.
6. **Subsume the mixed-width operand fix; keep its byte-stability rules.** The typechecker wraps the narrower operand of a mixed-width relational/equality comparison in `(safe-cast <joined-wider> <own-narrower> …)` (`analysis-passes.ss:2182-2219`) and each ternary arm in a wider join (`:2597-2606`); materialising the wrapper from `<target>` produces exactly the `((x) as <wider>)` cast PR #70 added by hand. Three rules keep output byte-stable: (i) decide "needs a cast" by `uint-rust-width` (`helpers.ss:487`), not `sametype?`, so two ranges that are both `u16` do not gain a spurious cast; (ii) preserve the bare-literal peel at comparison boundaries (`literal-int-expr?`); (iii) do **not** thread an expected type into `+ - *`, whose operands `arith-binop-rust` already normalises via `mbits->rust-width` — pushing one would double-cast. The constructor path's comparison renderer (`coerce-cmp-operand-rust`, `rust-passes-walker.ss:209`) must be wired too, not only `expr-rust`.
7. **The constructor-walker declaration-only `const` skip is folded in but kept explicit.** `const-decl-only?` (`rust-passes-emit.ss:646`) matches the forward declaration emitted whenever a `const` RHS lifts temps via `maybe-bind` (`analysis-passes.ss:2092`) — reachable at uniform widths and independent of any coercion. The streaming walker already skips it (`rust-passes-streaming.ss:81,371`); the constructor walker (`emit-body-or-fallback`, `walker.ss:1906`) does not. It is a pre-existing walkability defect, so `materialize-at-type` cannot close it; it is included here (task 3.1) only because this change ports the constructor mixed-width fixture that exercises it, and its task text records that provenance so attribution is not lost.

## Risks / Trade-offs

- [Byte churn across existing fixtures] → expected only where output was wrong/ambiguous; run the §5.2 classification on `git diff tests-e2e-rust/contracts/` and STOP on any unexplained hunk.
- [A dynamic parameter is implicit state] → name it explicitly, default it to `#f`, and add a test that the no-expectation path is byte-identical for a set of neutral fixtures.
- [Materialising safe-casts that Rust could infer adds noise] → return the inner rendering unchanged when no coercion is needed; the byte-parity gate proves it.
- [Aggregate element-wise coercion is complex] → start with the syntactic tuple case (the one the dogfood and fixtures use), then temp-bind/index for other aggregates; cover nested aggregates with a fixture.
- [A too-eager widening cast churns byte-identical output] → the three byte-stability rules in Decision 6; the `mixed_width_operand_fixture` port and the full FIXTURES sweep prove it.

## Migration Plan

Single forward change; no data migration. Rollback = revert commit (fixtures regenerate from the prior compiler). Version 0.31.117.
