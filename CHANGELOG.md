# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Toolchain 0.31.117, language 0.23.103, runtime 0.16.100]

### Fixed

- **`--target rust` emitted un-typed Rust integers wherever a bare literal (or
  a `Uint` value) sat in a typed position**, so the generated crate failed
  `cargo build` while `compactc` exited 0. A `Field` const RHS (`const x: Field
  = 0;`), a struct `Field` member, `some<Field>(0)`, a `persistentHash([0])`
  element, a native argument, a return tail, and a destination-typed ledger
  write each emitted a bare `0`/`1`/ambiguous `AlignedValue::from(0)` instead of
  the destination type. Every expression is now rendered against the Compact
  type its use position requires, materialising the typechecker's `safe-cast`
  wrapper at a single decision point (`materialize-at-type`); a `Uint → Field`
  coercion zero-extends losslessly (`Fr::from((x) as u64)`, or `as u128` above
  `u64::MAX`) and refuses above `u128::MAX` rather than truncating.

- **A `Field` literal above `u64::MAX` emitted an out-of-range `u64` literal.**
  Every literal coerced into a `Field` position was rendered `Fr::from(<n>u64)`,
  so a legal `Field` literal past `u64::MAX` — a range that runs up to
  `max-field` (~2^255) — produced a `u64` literal that overflowed and failed
  `cargo build` while `compactc` exited 0. Literals now pick their width from
  the `Field` domain at one point (`field-literal-rust`): `u64`, then `u128`,
  then the little-endian `Fr::from_le_bytes` constructor for the range above
  `u128::MAX`. The `u64` rung keeps previously-correct output byte-identical.

- **Mixed minimal-width comparison operands were peeled instead of widened.**
  `q * 4` on `q: Uint<32>` range-types to `u64`; compared against a `Uint<32>`
  value, the typechecker wraps the narrower operand and the emitter peeled the
  wrapper, so the two sides met at different Rust widths (E0308 at `cargo
  build`, `compactc` exit 0). The narrower operand is now widened losslessly
  (`((x) as u64)`), on both the pure and constructor/impure routes; ranges that
  already share a Rust width gain no cast, and `+ - *` keep their existing
  same-width normalisation.

- **A constructor whose `const` RHS lifted a temp was unwalkable.** The
  declaration-only `const` the typer emits for a `maybe-bind`-lifted temp (e.g.
  `const diff = base - q * 4;`) was not skipped by the constructor walker, so a
  body like `constructor(q, y) { assert(q * 4 <= y, …); … }` fell outside every
  shape. The constructor walker now skips the declaration and renders the
  matching lifted assignment, mirroring the streaming walker.

- **A renderer that could not lower an expression could splice a `#f`
  sentinel into `lib.rs`.** The emitted text is now buffered and scanned before
  it is written; a `#f` outside a string/comment/raw-identifier aborts with a
  located `sentinel-splice` error and writes no `lib.rs`, replacing the weak
  `/* TODO` scan as the correctness guarantee.

## [Toolchain 0.31.116, language 0.23.103, runtime 0.16.100]

### Fixed

- **`--target rust` silently discarded every constructor write** when no walker
  shape matched the constructor body. `emit-initial-state` treated "there is no
  constructor" and "there is a constructor and we could not lower it" as the
  same state, and emitted the default scaffold for both. A contract whose
  constructor seeded a `Map` and looped over a ledger cell compiled with **exit
  0** and produced a contract that deployed with none of its initial state.

  This is a miscompiler, not a missing feature: the output was well-formed
  Rust that built and ran, so nothing downstream could notice. It is now a
  `ctor-body-emission` rejection.

  The discriminator is narrower than it looks. `ldecl-constructor-stmt` is
  non-`#f` even when the author wrote no constructor, because the front end
  synthesises one for any contract with ledger fields — so "a statement
  exists" does not mean "the author wrote a constructor". The guard tests
  whether the body flattens to anything; constructor-less contracts and
  explicitly empty constructors both still compile.

- **A ledger field with no decoder emitted `decode_u64`** behind a `TODO`
  comment, so a `Vector<3, Bytes<32>>` accessor declared
  `Result<[[u8; 32]; 3], _>` and returned a `u64` in tail position — E0308, in
  generated code, from a compile that exited 0. Reachable with the smallest
  possible contract: one ledger field, no circuits, no constructor. Now
  `ledger-read-decoder-missing`.

- **`Field as Uint<N>` emitted `(x) as uN` where `x: Fr`.** `Fr` is a struct,
  so that is E0605, a non-primitive cast — again from a compile that exited 0.
  Narrowing an `Fr` needs a range-checking runtime helper that does not exist
  yet; the cast is refused until it does. The walker keys on the
  `downcast-unsigned` source bound, which the typer guarantees is present
  exactly for a `Uint` source and absent exactly for a `Field` source.

  `docs/rust-backend-limitations.md` already documented this as a
  `cast-from-field` rejection. It was not one — the kind did not exist. It
  does now.

- **`default-value-rust` no longer has a catch-all.** An unrecognised type
  fell through to `Default::default()`, which either fails to compile (no
  `Default` impl — E0277, in generated code) or compiles and seeds a ledger
  cell with a value that is not the Compact default. The walker's
  `default-supported?` mirrors the handled arms and is meant to gate this, but
  it is consulted at one of the seven `default-value-rust` call sites.

  No contract reaches the arm today — every route probed was closed by the
  decoder gate or the body walker first, and the full suite is unchanged by
  the removal. That was defence by accident; it is now
  `default-value-unsupported-type`.

### Added

- `tests-e2e-rust/tests/rejection_corpus.rs` — the negative corpus. Every other
  test in that crate pins what the backend *emits*; this one pins what it must
  **refuse**, which is a distinct property and was untested. Byte parity
  structurally cannot cover it: a construct that emits bad Rust agrees with its
  own committed fixture perfectly, so the gate stays green forever. All three
  bugs above shipped behind a green byte-parity run.

  The corpus asserts on both sides — the constructs that must reject, and the
  neighbouring shapes that must still compile. The second half is not
  ceremony: the first version of the constructor guard keyed on the synthesised
  statement and rejected every constructor-less contract.

## [Toolchain 0.31.115, language 0.23.103, runtime 0.16.100] — Schnorr identity guard, Field-arithmetic port, print-rust coverage (2026-08-21)

### Security

- **The vendored Schnorr verifier accepted the identity element as a public
  key**, in `examples/schnorr_attest_fixture.compact`. With `pk = O`,
  `ecMul(pk, c)` is `O` for every `c`, so verification collapses to
  `response*G == announcement` — the challenge, and with it the message,
  drops out. An attacker picks any `s`, sets `response = s` and
  `announcement = s*G`, and the pair verifies for **every** message under
  that key, with no secret required.

  Reachable rather than theoretical: `default<JubjubPoint>` IS the identity
  and a ledger cell holds its type's default until written, so a contract
  verifying against a key cell that was never set fails **open**.

  The circuit now rejects an identity key or announcement. The off-circuit
  Rust verifier already did.

  Demonstrated rather than asserted: `identity_public_key_is_rejected`
  constructs exactly that forgery, and removing the Rust guard makes the
  test FAIL — the forged signature is accepted — which is what shows both
  that the attack works and that the test is not vacuous.

  Two scope notes worth keeping. This is a fixture, not the compiler's
  standard library: the stdlib `jubjubSchnorrVerify` and
  `secp256k1EcdsaVerify` arrived with 0.33 and exist only on the ledger-9
  line, where the same fix landed separately. And the new test exercises the
  RUST verifier's guard, not the circuit's — the emitter rewrites the
  generic `schnorrVerify` call into
  `midnight_compact_runtime::schnorr_verify_jubjub`, so the circuit body
  never runs on the Rust path. Adding a security guard to the circuit left
  byte-parity completely unchanged, which is the sharpest available
  demonstration of the divergence tracked in #26.

### Fixed

- **`Field` arithmetic emitted `wrapping_*` on `Fr`, which does not compile.**
  `arith-binop-rust`'s fallback branch was reached whenever the width ladder
  returned `#f` — which includes the typer's FIELD case (`mbits = #f`) — so
  `return a + b` on two `Field`s produced `Ok((a).wrapping_add(b))`. `Fr`
  implements `Add`/`Sub`/`Mul` but not the `wrapping_*` family, so `compactc`
  exited 0 and the failure surfaced at `cargo build`. Field arithmetic now
  lowers to plain `+`/`-`/`*`. An out-of-ladder result width — the *other*
  reason the helper returns `#f`, and distinguishing the two is the fix —
  raises `rust-feature-error` rather than emitting an operator the type may
  not have. Byte-parity neutral: no fixture reached the branch.

  This was fixed on the ledger-9 line only; the stable branch, which the CoIP
  cites as the reference implementation, still carried it.

### Testing

- **`print-rust` coverage in the compiler's own suite: 2 cases -> 12.**
  `compiler/test.ss` held two Rust snapshot tests against 711
  `print-typescript` cases, so from inside the compiler's corpus the backend
  looked untested — all of its real coverage lives in `tests-e2e-rust`. The
  new cases cover crate scaffolding and the runtime-version pin, ledger reads
  and initial-state seeding per ADT, `Vector<N,T>` seeding, all three body
  routes with the temp uniquifier, witness trait shape and call site, three
  rungs of the `mbits->rust-width` ladder, Field arithmetic, and a guard that
  no placeholder reaches the output. They assert on content rather than
  whole-file snapshots, and need no cargo, Rust toolchain or built compactc.

## [Toolchain 0.31.114, language 0.23.103, runtime 0.16.100] — unsupported constructs reject instead of emitting plausible output (2026-08-21)

### Fixed

- **Four emitter paths produced valid, compiling, WRONG Rust instead of
  failing the compile.** The backend's central safety property is that a
  construct it cannot lower raises `rust-feature-error`; these violated it:
  - a constructor `assert` whose condition was a non-inlinable circuit call
    emitted `/* TODO */ true`, lowering to `assert!(true)` — a precondition
    that silently never fired;
  - a constructor `if` in the same situation emitted `/* TODO */ true`,
    making the then-branch unconditional and the else-branch dead, so a
    conditional ledger write became unconditional;
  - three catch-all `(guard (c [#t "/* TODO … */"]) …)` handlers in the
    streaming pass matched *every* condition, so a deliberate
    `rust-feature-error` was replaced by a comment emitted where an
    expression belongs — and a genuine emitter bug became a comment instead
    of a stack trace;
  - four natives with no Rust binding (`keccak256`, `ownPublicKey`,
    `createZswapInput`, `createZswapOutput`) emitted `unimplemented!()`,
    so contracts calling them compiled cleanly and panicked at run time.

  All four now reject at compile time with located diagnostics naming the
  offending circuit or native. New rejection kinds:
  `ctor-assert-condition-inline`, `ctor-if-condition-inline`.

  The natives fix is structural rather than a special case: the `(rust …)`
  clause is optional and `native-call-site-rust` already rejects on a `#f`
  field, so dropping the clause makes absence representable as absence and
  the existing rejection fires. A future unbound native cannot emit a panic
  by accident.

  **Byte-parity neutral** — the committed corpus contained zero `TODO` and
  zero `unimplemented` across all generated `lib.rs`, so no fixture reached
  any of these paths. They were latent traps for the next contract shape.

### Documentation

- Added `docs/rust-backend-limitations.md`: what the backend refuses to
  lower and why, with the four fixed paths as worked examples of the
  rejection contract. 28 rejection sites, 24 distinct kinds.
- Every one of the 9 `rust-passes*.ss` files now carries a file-level
  header stating what it owns; eight had none.
- `compiler/README-rust-passes.md` gained the walker/emit split and its
  cost, the three body routes, and what each test layer can and cannot
  catch. Corrected a convention that said walkers should "bail to
  `unimplemented!()` rather than producing wrong code" — the same mistake
  this release removes — and stale facts ("seven Scheme files", every LOC
  figure, a missing table row).
- Removed dangling `docs/superpowers/**` pointers from everything that
  ships, including three in `runtime-rs` / `runtime-rs-macros` that would
  have shipped as broken links in published rustdoc.

## [Toolchain 0.31.113, language 0.23.103, runtime 0.16.100] — --target replaces --rust / --skip-ts (2026-08-20)

### Changed

- **`--target <language>` replaces `--rust` and `--skip-ts`** as the way to
  select a contract-code backend. It is repeatable; the valid targets are
  `ts` and `rust`:

  | Invocation | TS | Rust |
  |---|---|---|
  | `compactc c.compact out/` | yes (implied) | no |
  | `compactc --target rust c.compact out/` | no | yes |
  | `compactc --target rust --target ts c.compact out/` | yes | yes |

  TypeScript is emitted when `--target` is absent, so invocations that do not
  pass the flag are unaffected. Passing `--target` replaces that default with
  exactly the targets listed, which is what lets `--target rust` subsume
  `--rust --skip-ts` without any flag-combination validation while keeping
  "emit both" expressible for the parity harness. `--skip-zk` stays
  orthogonal.

  Adopts review feedback on LFDT-Minokawa/compact#730. The interface matters
  now rather than later because a boolean `--rust` assumes exactly two
  backends: a third language would make `--skip-ts` ambiguous and force a
  breaking rename. Neither flag exists upstream, so there are no invocations
  to preserve — the cost of fixing this is zero today and a deprecation cycle
  later.

  `--rust` and `--skip-ts` keep working as **undocumented aliases** so this
  fork's harness and MediaNoxLabs/midnight-identity (which invokes
  `compactc --rust --skip-ts`) do not break in the same change. They are
  dropped from `--help`. Mixing `--target` with either alias is an error
  rather than a silent precedence rule, so no invocation can be read two
  ways. The aliases are fork-transitional and must not be carried upstream.

  Implementation note: `third_party/compiler/command-line-parsing.ss` keeps
  only the *last* value of a repeated flag, so a plain value clause would
  have turned `--target rust --target ts` into `ts`. Accumulation therefore
  uses the grammar's per-occurrence `$ <action>` hook, and validation runs in
  the matched clause body rather than in the action — actions can fire while
  a clause is only being attempted, so erroring inside one could reject a
  value on a command line that never matched.

## [Toolchain 0.31.112, language 0.23.103, runtime 0.16.100] — Rust runtime crate renamed to midnight-compact-runtime (2026-08-20)

### Changed

- **Breaking (`--rust`): the Rust runtime crate is renamed
  `compact-runtime` → `midnight-compact-runtime`** (and
  `compact-runtime-macros` → `midnight-compact-runtime-macros`), with the
  library paths following as `midnight_compact_runtime` /
  `midnight_compact_runtime_macros`. Generated code now emits
  `use midnight_compact_runtime::*;` and fully-qualified
  `midnight_compact_runtime::…` paths.

  Rationale (review feedback on LFDT-Minokawa/compact#730): Midnight's Rust
  crates are uniformly `midnight-*` (`midnight-onchain-state`,
  `midnight-transient-crypto`, …), so the prefix does for Rust what the
  `@midnight-ntwrk` scope does for npm, and `compact-runtime` alone is
  generic on crates.io. Generated code names the crate in every `use`, which
  makes the choice effectively permanent once anything is published — cheap
  to fix now, expensive later. The crate is unpublished, so no consumer is
  affected and the runtime version stays 0.16.100 (generated contracts pin
  it via `check_runtime_version!`, which requires exact equality).

  The **TypeScript** package `@midnight-ntwrk/compact-runtime` shares the
  name and is deliberately untouched; only the Rust crate is renamed. The
  directory names `runtime-rs/` and `runtime-rs-macros/` are unchanged, and
  historical entries in this file keep the name the crate had at the time.

  All 34 byte-parity fixtures were regenerated: the diffs are the new crate
  paths plus rustfmt reflow, since `midnight_compact_runtime` is nine
  characters longer and pushes some lines past the 100-column limit. The
  compiler's own `print-rust` snapshots (`compiler/snapshots/`) and the
  TypeScript e2e man-page golden
  (`tests-e2e/src/resources/compiler_man_page.txt`, which asserts
  `compactc --help` verbatim) were updated to match.

## [Toolchain 0.31.111, language 0.23.103, runtime 0.16.100] — struct-field projections in trapping arithmetic (2026-08-10)

### Fixed

- **Struct-field projection as an operand of trapping arithmetic (G1)** —
  a pure circuit whose assert subtracted a struct-field projection failed to
  compile with `unsupported Compact construct (pure-circuit-body-emission): no
  walker shape matched pure circuit body`, e.g.
  `if (policy.enforceMaxAge) { assert(currentTime -
  attestation.proof.createdAt <= policy.maxAge, "..."); }`
  (MediaNoxLabs/compact#5). The typer wraps trapping unsigned arithmetic in an
  underflow guard `(seq (assert (>= a b)) (- a b))` and let\*-lifts any
  operand that isn't already a simple local into its own temp, so a projection
  operand nests TWO levels of lifted assignment:
  `(= %t.0 (seq (= %t.1 (elt-ref attestation.proof createdAt)) (seq (assert
  (>= currentTime %t.1) ...) (- currentTime %t.1))))`. `stmt-flatten`'s
  `lift-seq-prefix-exprs` hoists the OUTER level to a statement, where
  `stmt-pure-body-rust`'s `stmt->assignment` clause lowers it as
  `let <temp> = <rhs>;` — but the inner level stayed inside the RHS and reached
  `seq-stmt-rust`, which handled only `assert` and fell through to `expr-rust`,
  which has no `(=)` clause at all. Plain scalar operands need only one level,
  and the same projection under `==` rather than `<=` also stays single-level,
  which is why every ingredient compiled in isolation and the `if` guard turned
  out to be incidental (the unguarded assert failed identically).
  `seq-stmt-rust` (`compiler/rust-passes-emit.ss`) now renders a nested
  assignment through the same helpers the statement-level path uses —
  `uniquify-rust-name` over `current-var-substitution`, then `expr-rust` for
  the RHS — rather than gaining a second projection-aware renderer, and
  `expr-rust`'s `seq` clause folds its prefix statements instead of mapping
  them so a binding one introduces is in scope for the statements after it and
  for the tail. The two `let`-binding clauses in `stmt-pure-body-rust` reserve
  their own Rust name for the duration of the RHS render, so a temp lifted from
  inside it uniquifies instead of shadowing the binder. Unblocks
  midnight-verifiable-credentials' `status-proof-protocol.compact`
  (`assertAuthorityAttestedStatusProofFreshEnough`, reached through
  `revocation-registry.compact`) and `secret-birth-credential.compact`, both of
  which previously died at `status-proof-protocol.compact:522`. Every existing
  byte-parity fixture is UNCHANGED — bodies without a nested assignment take
  the identical code path, and the digital-passport fixture's single-level
  `let t = { assert!(...); ... }` block form is preserved. Guarded by the new
  `examples/guarded_assert_arith_fixture.compact` fixture (byte parity via
  `tests-e2e-rust/tests/codegen_regression.rs`) plus the executing assert gate
  `tests-e2e-rust/tests/guarded_assert_arith_fixture.rs`, which calls the
  generated pure circuits with values that satisfy and values that trip each
  assert — pinning the inclusive boundary, the underflow trap (a dropped guard
  would wrap on `u64` and silently pass), the skipped-guard path, and a
  two-projection subtraction whose returned difference proves the two lifted
  temps stayed distinct. Emitter-only fix: the runtime crate version stays
  0.16.100 because generated contracts pin it via `check_runtime_version!`,
  which requires exact equality — only the toolchain version advances.

## [Toolchain 0.31.110, language 0.23.103, runtime 0.16.100] — alignment-aware ledger-read decode (2026-08-10)

### Fixed

- **Field-repr-arity ledger-read decoding of alignment-encoded cells (A30)** —
  `compact_runtime::std_lib::decode_via_field_repr<T>` converted the
  `AlignedValue`'s atoms to `Fr`s 1:1 (one `Fr::try_from(atom)` per atom) and
  fed that to `T::from_field_repr`. But cells are ALIGNMENT-encoded — one atom
  per leaf value — and a single leaf may span multiple field-repr `Fr`s: a
  32-byte address cell is ONE atom but `[u8; 32]::FIELD_SIZE == 2` `Fr`s
  (1-byte stray chunk + 31-byte chunk, packed from the end per upstream
  `impl FieldRepr for [u8]`). Every `ContractAddress` read —
  did.compact 0.5.0's `ledger().id()` accessor and the constructor's
  `id = kernel.self()` readback — could therefore NEVER decode, and
  multi-leaf struct reads (did-05's `VerificationMethod` map lookups: 6 atoms
  vs `FIELD_SIZE` 3) hit the same arity mismatch. Found empirically in the
  MediaNoxLabs/midnight-identity port (the "second decode-path finding" in the
  MediaNoxLabs/compact#3 comment thread; MediaNoxLabs/compact#4 landed the
  did-05 readback gate `#[ignore]`d on exactly this bug). The decoder now
  walks `av.alignment` in lockstep with the atoms and expands each leaf into
  exactly the `Fr` chunks its field-repr occupies: `Field` atoms as one `Fr`;
  `Bytes { length }` atoms as `ceil(length/31)` 31-byte little-endian chunks
  in reverse chunk order, with leading zero-`Fr`s re-padding the trailing
  zero bytes stripped by `ValueAtom::normalize`; `Compress` atoms (opaque
  strings / `Vec<u8>`) as raw-byte chunks of the actual atom — `ceil(n/31)`
  `Fr`s, zero `Fr`s for the empty value — matching this runtime's
  `OpaqueString`/`Vec<u8>` `FieldRepr` convention.
  `OpaqueString::from_field_repr` now strips the 31-byte-chunk zero padding
  (on-chain `Compress` atoms are normal-form, so trailing NULs are
  unrepresentable — stripping is the faithful inverse). For fixed-size
  targets the expanded stream must match `T::FIELD_SIZE` exactly, so a
  NON-empty variable-length leaf inside a fixed-slicing struct fails loudly
  instead of silently mis-slicing every following field
  (`OpaqueString::FIELD_SIZE == 0` gives the generated `from_field_repr` no
  slot for the bytes; variable-length struct leaves round-trip only while
  empty — tracked as a codegen follow-up). Runtime-only fix: NO generated
  code changes and byte-parity fixtures untouched; the runtime crate version
  stays 0.16.100 because generated contracts pin it via
  `check_runtime_version!`, which requires exact equality — only the
  toolchain version advances. Guarded by round-trip unit tests in
  `runtime-rs/src/std_lib/adts.rs` (`new_cell(T)` →
  `decode_via_field_repr::<T>` for u8/u32/u64/bool/Fr, tuples,
  `ContractAddress` incl. the all-zero normalised-empty-atom edge,
  `[u8; 32]`, a `[u8; 32]`-bearing struct, a JWK-shaped struct with empty
  string leaves, plain enums, opaque strings empty/short/31-byte/multi-chunk,
  and the loud non-empty-string-leaf rejection) and by un-ignoring the
  did-05 executing readback gate
  (`tests-e2e-rust/tests/did05_constructor_scaffold.rs`), which now asserts
  the full `initial_state` → `ledger()` accessor readback INCLUDING `id`
  (the pre-A30 failure-mode pin test is removed).

## [Toolchain 0.31.109, language 0.23.103, runtime 0.16.100] — initial-state chunked scaffold (2026-08-07)

### Fixed

- **Flat initial-state scaffold for >16-field ledgers (A29)** — contracts with
  more than 16 ledger fields (did.compact 0.5.0 has 19) generated an
  `initial_state` that seeded a *flat* n-element `new_array(vec![...])`
  scaffold, while every read/write emission site — including the constructor's
  own writes — used the front end's chunked nested shape
  (`StateValue::Array` caps at 16; did-05 chunks as an outer 2-slot array of
  4 + 15 fields). Executing the Rust constructor therefore wrote nested
  `idx_at_index` paths into a flat scaffold, producing state the generated
  `ledger()` accessors (and the chain shape) could not read. The scaffold
  emission (`emit-scaffold-elements` in `compiler/rust-passes-emit.ss`) now
  walks the IR's `public-ledger-array` structure recursively — the SAME
  nested structure `binding-path-indices` and all read/write emitters derive
  their paths from, mirroring `typescript-passes.ss::ledger-initializers` —
  so the shapes cannot diverge. Contracts with <=16 fields have no nested
  pl-arrays and stay byte-identical. Found while building the
  indexer-backed snapshot decoder in midnight-identity (tracked in
  MediaNoxLabs/compact#3 comments). Guarded by a new EXECUTING constructor
  readback gate: `tests-e2e-rust/tests/chunked_ledger_fixture.rs` runs the
  new 18-field `examples/chunked_ledger_fixture.compact`'s `initial_state`
  and reads every field back via the generated `ledger()` accessors. The
  did-05 equivalent (`tests-e2e-rust/tests/did05_constructor_scaffold.rs`)
  pins the current failure mode and carries the full readback `#[ignore]`d —
  did-05's constructor does `id = kernel.self()`, whose generated
  `decode_via_field_repr::<ContractAddress>` read hits the separate
  field-repr-vs-alignment decode bug (also tracked in the #3 comment
  thread); un-ignore when that follow-up lands.

## [Toolchain 0.31.108, language 0.23.103, runtime 0.16.100] — constructor read-your-writes (2026-08-05)

### Fixed

- **Constructor read-before-write for impure-call reads (A28)** — a constructor
  that writes a ledger field and then calls an impure circuit reading that
  field (did.compact 0.5.0's `controllerPublicKey` / `recoveryAuthorityPublicKey`
  writes followed by `assertControllerPublicKeyDistinctFromRecoveryAuthority`,
  which reads both) generated the read against the *unmodified initial ledger*,
  because all writes were batched into a single `OpProgramVerify` applied at the
  end. Both the argument read and the callee's own ledger reads saw
  `JubjubPoint::default()`, silently defeating the distinctness invariant. The
  codegen now flushes the pending cell-writes/pl-calls to `qctx`
  (`ctor-write-flush-lines`) before an impure call in a constructor, giving
  read-your-writes; the impure call and its args then observe the witnessed
  values. Surfaced by Codex review (P1). Covered by a structural regression
  test (the write-flush must precede the distinctness assert) plus the did-05
  byte-parity lock; other constructors (no impure call) are byte-identical.

## [Toolchain 0.31.107, language 0.23.103, runtime 0.16.100] — impure-call gas accounting (2026-08-05)

### Fixed

- **Circuit gas under-reporting for impure-helper calls (A27)** — a circuit
  that calls an impure circuit (e.g. `recordUpdate()` after a mutation, or a
  cross-circuit helper) rebound `ctx` from the callee's result but discarded
  the callee's `gas_cost`, so the generated function returned only the terminal
  write's gas and under-reported successful transactions. Both walkers now
  accumulate callee gas: the streaming walker adds `__gas_acc += _cr.gas_cost`
  for bare/const impure calls, and non-streamed circuit bodies with impure
  calls seed a `__gas_acc` and return `__gas_acc + results.gas_cost`. Surfaced
  by Codex review of the did.compact 0.5.0 circuits (setVerificationMethod /
  rotateControllerKey / …); also corrected the latent same-shape gap in
  `cross-circuit-fixture`. Covered by a new semantic gas test
  (`reset_and_set` gas strictly exceeds `reset` gas) plus byte-parity locks.

## [Toolchain 0.31.106, language 0.23.103, runtime 0.16.100] — did.compact 0.5.0 codegen support (2026-08-05)

### Added

- **did.compact 0.5.0 codegen support** — the `compactc --rust` backend now
  generates and compiles the midnight-did 0.5.0 contract (controller-
  authorization + recovery). New closures: a JubjubPoint ledger-read decoder
  and typed initial-cell default; constructor-mode impure-circuit context
  threading (query, private, and zswap-local state); multi-assert if/else
  branches emitted in source order; and non-terminal branch calls threaded in
  source order with their returned context carried into the terminal op
  (A22–A26). Added the `did-05` regression fixture (vendored contract + its
  jubjub-schnorr dependency under `examples/did-05/`) to the
  `codegen_regression` byte-parity table and as a workspace compile gate. All
  pre-existing fixtures regenerate byte-identically.

## [Toolchain 0.31.105, language 0.23.103, runtime 0.16.100] — codegen correctness sweep + digital-passport (2026-07-10)

### Fixed

- **export-typedef promotion gated to `--rust`** — the M3.5-E2 pass that
  synthesises `export-typedef` entries for user structs/enums (so the Rust
  H5-H7 emitter can declare them) ran unconditionally and mutated the shared
  `Lexpanded` IR, drifting ~64 `compiler/test.ss` goldens across
  expand-modules-and-types / infer-types / reject-recursive-circuits /
  track-witness-data / combine-ledger-declarations. It is now
  `(when (emit-rust) …)`, so the TS-backend IR is unchanged and the Rust
  fixtures still get their typedefs. This let the CI drop all fork-scoped
  `if: github.repository != …` skips. See
  [ADR 0002](docs/adr/0002-gate-export-typedef-promotion-to-rust.md).

- **Struct-name disambiguation** — same-named structs from distinct module
  imports (e.g. a generic protocol module instantiated twice, or two modules
  each exporting `struct Rec`) are now resolved by structural fingerprint,
  keyed on field **names** as well as types, and the disambiguated name
  (`Name` / `Name_1`) is applied at **all** emission sites — struct
  literals, decoder turbofish, and default expressions — not only in type
  positions. Previously the fingerprint ignored field names (merging
  distinct structs → `E0609`) and value sites emitted the raw name
  (mismatch vs the disambiguated signature → `E0308`/`E0422`). Stdlib
  structs (`Maybe`, `MerkleTreePath*`, `ContractAddress`) are excluded from
  disambiguation. New `struct_collision_fixture` byte-parity gate; see
  [ADR 0001](docs/adr/0001-rust-struct-name-disambiguation.md).

- **A20** — read-no-arg adt-op vm-code lowering. `emit-ledger-read-expr`
  no-arg branch in `compiler/rust-passes-emit.ss` was hardcoded to emit
  `dup → idx → popeq` and silently discarded the adt-op's vm-code, so
  any contract calling `Set.size`, `Set.isEmpty`, `Map.size`, `Map.isEmpty`,
  `List.isEmpty`, `List.length`, or `HistoricMerkleTree.isFull` compiled
  to misencoded gather chains that decoded the container as a raw `Cell`.
  Fix routes these ops through `expand-vm-code` (same machinery as A8's
  read-with-arg path). New `set_size_fixture` byte-parity gate.
  Commits: [`0916b28`](../../commit/0916b28), [`c15af41`](../../commit/c15af41).

- **A21** — `HistoricMerkleTree.insertIndexDefault` circuit-body shape.
  Walker rejected the IR with `circuit-body-emission: no walker shape
  matched`. Added the body-shape and op-builder support
  (`lt`/`branch`/`jmp`/`swap`/`pop`). New `hmt_default_fixture`
  byte-parity gate. Commits: [`6aa3cdc`](../../commit/6aa3cdc), [`776d83e`](../../commit/776d83e).

- **Bug-8** — `==`/`!=` walker forced typed enum rendering when the
  comparison's IR `type` was a tenum (Bug-4's optimisation), but the IR
  type is the tenum even when one operand is a ledger-read decoded as
  `u8`. Election's `state.read() == PublicState.commit` generated
  invalid Rust `u8 == PublicState::commit`. Added `is-ledger-read-expr?`
  predicate; in `==`/`!=` clauses, short-circuit `typed?` to `#f` when
  either operand is a ledger-read. Commit: [`0fffe67`](../../commit/0fffe67).

- **Bug-9** — non-exported tenum decls referenced by emitted impure
  circuits. A18+A19 (`f9b509f`) taught the emitter to render
  non-exported impure circuits as inherent methods on `Contract<PS, W>`,
  but the type-declarations pass didn't follow the new type-reference
  graph. Tiny's `circuit in_state(s: STATE): Boolean` was emitted as a
  method, but the `STATE` enum was never declared. Extended
  `collect-pure-circuit-tdefns` in `compiler/rust-passes-decls.ss` to
  walk non-exported impure circuit signatures too. Commit:
  [`a45d68d`](../../commit/a45d68d).

- **Bug-10** — typed decoder for `tenum` ledger reads (Option A).
  Previously `decoder-for-type` lowered tenum-typed ledger fields via
  `decode_u8`, which broke `state == s` (where `s: STATE` is a
  tenum-typed formal arg) because `u8 == STATE` doesn't compile.
  Bug-8's `is-ledger-read-expr?` short-circuit fixed the case where the
  RHS is an `enum-ref` literal (drops to u8 via `enum-ref->u8`), but had
  no fallback for typed var-ref RHS. Option A's fix flips the LHS to
  decode as the typed enum (`decode_via_field_repr::<EnumName>`),
  eliminating the u8/tenum mismatch entirely. Bug-8's special-case
  becomes redundant for tenum-typed reads. Commit: [`62c81be`](../../commit/62c81be).

### Changed

- **Rust codegen: `assert` is now a handleable error, not a panic
  (parity with the TS backend).** `compactc --rust` now lowers every
  `assert(cond, "msg")` inside a pure circuit to the `compact_assert!`
  macro (returning `Err(CompactError::AssertionFailed(msg))`) and emits
  pure circuits with a `Result<T, CompactError>` signature, appending
  `?` at every pure-circuit call site so the error propagates through
  impure callers. Previously pure-circuit asserts lowered to a
  panicking `assert!`, aborting the host process — fundamentally
  different from the TS backend's catchable `CompactError` throw. The
  5 fixtures with pure circuits (tiny, zerocash, election,
  if-stmt-fixture, pure-circuit-fixture) were regenerated; the on-chain
  op-program/witness bytes are unchanged, so all 51 byte-parity tests
  stay green. A new dedicated `assert_parity` fixture + test proves a
  failing pure-circuit assert yields `Err(AssertionFailed)`, not a
  panic. Note: the hand-imported `digital-passport` crate (no `.compact`
  source in this repo) is not regenerated by the pipeline and keeps its
  123 panicking `assert!` until re-emitted from upstream.

- **24 fixture `lib.rs` files regenerated** against the post-Bug-10
  compactc (commit [`4e322bc`](../../commit/4e322bc)). Drift categories:
  `PS: Clone` widening (Bug-3, all 24); `.popeq(true)` → `.popeq(false)`
  honouring the vm-code's `cached` flag (election, tiny); `tiny.in_state`
  inherent method emission (Bug-9); typed tenum ledger decoders
  (Bug-10). All 47 byte-parity tests + `codegen_regression` green.

### Process notes

The 5-bug cascade was surfaced by manually running `codegen_regression`
against a fresh `compactc --rust` regen. The standing byte-parity test
corpus is structurally blind to source-level codegen drift — bugs that
change generated Rust without changing `ContractState::serialize()`
output (Bug-8's `u8 == EnumName::variant` compile error; Bug-9's missing
enum decl; Bug-10's wrong decoder) don't surface without an explicit
regen-and-diff step. Treating `codegen_regression` as a CI gate, not
just a test result, is now the standing policy.

## [Toolchain 0.31.104, language 0.23.103, runtime 0.16.100]

### Added

- Adds `--rust` to `compactc`: lowers a `.compact` contract to a native
  Rust crate (`contract/lib.rs`) that depends on the new `compact-runtime`
  crate. The Rust crate exposes `Contract::new(...)`, `initial_state(...)`,
  each impure circuit as a method on the contract, and a `Ledger<'a, D>`
  view for reading on-chain state — parallel to the TypeScript backend's
  surface, with byte-identical `ContractState.serialize()` output.
  - **Runtime crate** (`runtime-rs/`): curated prelude over the Midnight
    Rust crates (`midnight-base-crypto`, `midnight-transient-crypto`,
    `midnight-storage`, `midnight-onchain-state` / `-vm` / `-runtime`,
    `midnight-coin-structure`, `midnight-zswap`); facade aggregates
    (`ConstructorContext`, `CircuitContext`, `ConstructorResult`,
    `CircuitResults`, `WitnessContext`, `CompactError`); Compact stdlib
    helpers (`Counter`, `Maybe<T>`, `OpaqueString`, `pad`, `disclose`,
    `persistent_hash_aligned`, Jubjub/EC native shims, Merkle path
    helpers); `OpProgramVerify` / `OpProgramGather` builders.
  - **Codegen coverage**: scalars, ADTs as ledger fields
    (`Counter`/`Cell`/`Map`/`Set`/`MerkleTree`/`HistoricMerkleTree`/`List`),
    user structs and enums, transparent + nominal type aliases, witnesses,
    native hashes, `if`-statement bodies, ADT method calls (`insert` /
    `lookup` / `member` / `checkRoot`), cross-circuit calls, `for`-range
    and `for`-iterable loops with compile-time unrolling, basic `fold`
    with loop-var substitution, bounded `Uint<L..U>`, sealed ledger fields.
  - **Compile-time safety**: unsupported Compact constructs now produce a
    `compactc --rust: unsupported Compact construct (...)` error at
    codegen time rather than emitting `unimplemented!()` Rust that
    compiles but panics at runtime.
  - **Test coverage**: 32 cross-language byte-parity tests under
    `tests-e2e-rust/`, plus a codegen-regression guard asserting all
    committed `lib.rs` files regenerate byte-identical via
    `compactc --rust`.
  - **Docs**: an end-user guide at `doc/rust-codegen-user-guide.md`,
    contributor READMEs under `compiler/README-rust-passes.md`,
    `runtime-rs/README.md`, and `tests-e2e-rust/README.md`, plus a
    parity gap report under
    `docs/superpowers/research/2026-06-02-upstream-parity-gap-report.md`.

## [Toolchain 0.31.103, language 0.23.103, runtime 0.16.100]

### Added

- Adds `keccak256` to the standard library, with the same signature as
  `persistentHash`.  Adds `keccak256` to the Compact runtime with the same
  signature as `persistentHash`.  `keccak256` requires the experimental feature
  flag `--feature-zkir-v3` to work in a circuit that directly or indirectly uses
  the public ledger state.  It is a compiler error to use it in a such a circuit
  using the ZKIR v2 backend.

## [Toolchain 0.31.102, language 0.23.102, runtime 0.16.0]

### Added

- `eval` and `arguments` which are reserved words in strict mode of JavaScript are now
  added as future reserved words in Compact. Previously Compact accepted a contract using
  these as an identifier, resulting in producing an invalid JavaScript output.

### Fixed

- Lexer matches the convention used by
  ECMAScript (https://tc39.es/ecma262/#sec-names-and-keywords) and
  UAX #31 (https://www.unicode.org/reports/tr31/#Table_Lexical_Classes_for_Identifiers):
  the lexer accepts Unicode `ID_Start` (`Lu Ll Lt Lm Lo Nl`) plus `_` and `$`.
  Previously it accepted all alphabetic charactes which includes some non-`ID-Start`
  characters which are invalid in JavaScript.
  `identifier-subsequent?` now follows Unicode `ID_Continue` (`Lu Ll Lt Lm Lo Nl Mn Mc Nd Pc`).
  Previously it included som non-`ID-Continue` characters.

## [Toolchain 0.31.101, language 0.23.101, runtime 0.16.0]

### Added

Adds `event` and `log` as future keywords that are reserved.

## [Toolchain 0.31.0, language 0.23.0, runtime 0.16.0]

This release includes all changes for compiler versions in the range between
0.30.100 and 0.31.0; language versions in the range between 0.22.100 and 0.23.0;
and Compact runtime versions in the range between 0.15.100 and 0.16.0.

## [Toolchain 0.30.107, language 0.22.101, runtime 0.15.101]

### Fixed

Various zkir operators that can result in assertion failures and thus should
be executed conditionally do not have guards are thus actually executed
unconditionally.  This can result in proof failures for correct transactions.
For example, casting an unsigned integer value to a smaller unsigned type will
always cause the proof to fail when the value is too big for that type, even if
the cast occurs in a branch that is not taken in the Compact code.

The intent is to add guards to these operators in the next version of zkir.
In the meantime, the compiler implements workarounds that arrange to invoke
these operators with inputs that cannot cause assertion failures when the
guard would be false.

The downside of these workarounds is that they can increase the size of the
generated circuit.
The size increase arises from conditional use (i.e., use in the `then` or
`else` part of an `if` statement or expression) of:

- downcasts from Uint types to smaller Uint types,
- downcasts of Field to Uint types,
- conversions of byte vectors to and from fields or unsigned integers,
- conversions of vectors to byte vectors, and
- uses of relational comparison expressions (<, <=, >=, and >) with inputs
  that might be unknown.

If the increase in circuit size is problematic for a particular contract, developers
should consider moving downcasts, conversions, and relational comparisons outside
of `if` expressions where possible until zkir supports the required guards and the
compiler workarounds have been removed.

## [Toolchain 0.30.106, language 0.22.101, runtime 0.15.101]

### Added

- Adds a `ledger` key to `contract-info.json` listing the contract's
  ledger fields. Each entry contains the field name, path index,
  export status, storage kind (Cell, Counter, Map, Set, List,
  MerkleTree, HistoricMerkleTree), and fully-resolved type tree.
  This enables language-agnostic tooling to discover a contract's
  ledger layout from the compiler output alone. Both exported and
  non-exported fields are included since the full layout is required
  to navigate the on-chain state tree and construct initial states.

## [Toolchain 0.30.105, language 0.22.101, runtime 0.15.101]

### Added

- Adds `--line-length` flag to fixup.

### Fixed

- JubjubPoint equality is now component-wise; it previously was reference
  equality.

## [Toolchain 0.30.104, language 0.22.101, runtime 0.15.101]

### Changed

- Renames `doc/lang-ref.mdx` and `compiler/lang-ref-proto.mdx` to
  `doc/compact-reference.mdx` and `compiler/compact-reference-proto.mdx`,
  respectively.  It also adopts some changes from midnight-docs PR changes
  for lang-ref 1.0.

## [Toolchain 0.30.103, language 0.22.101, runtime 0.15.101]

### Changed

- The language reference `doc/lang-ref.mdx` is now been fully revised and
  is completely up-to-date with the Compact Version 1.0 language.  Grammar
  snippets are automatically inserted into the document directly from parser.ss,
  and several changes have been made to the presentation of the grammar to
  make it more readable.

## [Toolchain 0.30.102, language 0.22.101, runtime 0.15.101]

### Changed

- Extends the `for (const i of start..end) stmt` syntax to allow `start` and
  `end` to be references to generic parameters.

## [Toolchain 0.30.101, language 0.22.0, runtime 0.15.101]

- Changes the format of the first argument passed to `convertBytesToUint` in `print-typescript` 
- Improves format of error messages for `convertBytesToUint` and `convertBytesToField`
- Changes the type of `maxval` to `bigint` to avoid JavaScript silently losing precision
  when comparing `x > maxval` for larg `Uint`s

## [Toolchain 0.30.0, language 0.22.0, runtime 0.15.0]

This release includes all changes for compiler versions in the range between
0.29.100 and 0.30.0; language versions in the range between 0.21.100 and 0.22.0;
and Compact runtime versions in the range between 0.14.100 and 0.15.0.

## [Unreleased toolchain 0.29.114, language 0.21.101, runtime 0.14.102]

### Changed

- The language reference `doc/lang-ref.mdx` is now largely up-to-date with
  the Compact 0.21.0 language.
- The HTML version of the formal grammar in `doc/Compact.html` has been
  replaced with a markdown (mdx) version in `doc/compact-grammar.mdx`.

### Added

- A list of Compact's keywords and reserved words, including those reserved
  for future use, is given in `doc/compact-keywords.mdx`.

## [Unreleased toolchain 0.29.113, language 0.21.101, runtime 0.14.102]

### Changed

- It is now a compiler error to pass Compact values containing opaque JS values
  (`Opaque<'string'>` or `Opaque<'Uint8Array'>`) to the standard library
  circuits `persistentHash` and `persistentCommit`.  Hashing such values does
  not work in circuit due to the representation of these types.  Previously,
  such code would crash the `zkir` process if it tried to generate prover and
  verifier keys.  Now it is a compiler error instead.
  
  This also affects the standard library operation `merkleTreePathRoot` (because
  it calls `persistentHash` in its implementation), and ledger `MerkleTree`
  insertion operations, because they implicitly use `persistentHash`.
  
  This is a **breaking** change because the error is signaled early, and so it
  is now an error to use any of these circuits or ADT operations, even for
  circuits that don't need prover and verifier key generation which would
  compile successfully before.

## [Unreleased toolchain 0.29.112, language 0.21.101, runtime 0.14.102]

### Changed

- The fixup tool now replaces references to the old standard-library type names
  `CurvePoint` and `NativePoint` with `JubJubPoint`.  It also does a better job
  of renaming standard-library circuits when it is safe to do so and explaining
  why when it is not safe to do so.

### Internal notes

- The expand-modules-and-types code for function lookup is more modular and
  easier to read.

## [Unreleased toolchain 0.29.111, language 0.21.101, runtime 0.14.102]

### Fixed

- The `<=` and `>` operand evaluation order in the proof circuit is incorrect
  (right-to-left rather than left-to-right).  It also differs from the evaluation
  order in the generated JavaScript code, which can result in proof failures
  when the operands are non-trivial.  This fix modifies the common upstream path
  `infer-types` to enforce the correct evaluation order.

## [Unreleased toolchain 0.29.110, language 0.21.101, runtime 0.14.102]

### Fixed

- There was an unreleased bug in ZKIR circuits (not in JS) where the
  representation of the default `JubjubPoint` was wrong.  Fixing this entailed
  allowing `default` in compiler IR from `Lflattened` and downstream in both
  ZKIR v2 and v3 backends.

## [Unreleased toolchain 0.29.109, language 0.21.101, runtime 0.14.102]

### Changed

- The compiler binary can now report `--ledger-version` (and
  `--feature-zkir-v3 --ledger-version`).  This is the version of the ledger that
  is targeted by the generated code and used to produce the generated prover and
  verifier keys.

## [Unreleased toolchain 0.29.108, language 0.21.101, runtime 0.14.102]

### Fixed

- Type declarations of `Uint<n>` and `Uint<0..n>` where `n` is a free type variable
  are now accepted by the compiler.

## [Unreleased toolchain 0.29.107, language 0.21.101, runtime 0.14.102]

### Changed

- The ZKIR v3 format, behind the feature flag `--feature-zkir-v3`, has changed
  so that:
  - circuit inputs are correctly typed as either `Scalar<BLS12-381>` or
    `Point<Jubjub>` (before they were always scalars, with `encode` instructions
    for curve points), and
  - `private_input` and `public_input` instructions are typed (before they
    always read scalars, with `encode` instructions for curve points)

## [Unreleased toolchain 0.29.106, language 0.21.101, runtime 0.14.102]

### Changed

- The Compact compiler now targets `midnight-ledger` version 8.0.0.  The Compact
  runtime now imports `onchain-runtime-v3` (instead of `-v2`) at version
  compatible with 3.0.0-rc.2.

## [Unreleased toolchain 0.29.105, language 0.21.101, runtime 0.14.101]

### Fixed

- [Breaking Change] The search order for include and external module files
  specified with non-absolute paths has been fixed so that (a) the compiler looks
  first relative to the directory of the including or importing file, and (b)
  the compiler does not automatically look in the directory where the compiler
  was invoked.

### Added

- compactc and fixup-compact support two new options: --compact-path to
  set the compact path and --trace-search to cause the compiler to say where
  it looks for include and external module files.  If the `--compact-path`
  command-line option is present, the environment variable `COMPACT_PATH`
  is ignored.

## [Unreleased toolchain 0.29.104, language 0.21.101, runtime 0.14.101]

### Added

- The generated TypeScript now includes a `ProvableCircuits<PS>` type and a
  `provableCircuits` field on the `Contract` class.  `ProvableCircuits` contains
  only the circuits that have verifier keys (i.e., circuits that appear in the
  flattened circuit IR and produce ZKIR files).  This distinguishes them from
  impure circuits that only call witnesses without touching the ledger.

### Fixed

- `setOperation` is now emitted only for provable circuits (those in
  `proof-circuit-name*`) rather than for all impure circuits.  Previously,
  witness-only impure circuits caused the runtime to look
  for a verifier key that does not exist.

## [Unreleased toolchain 0.29.103, language 0.21.101, runtime 0.14.101]

### Changed

- The standard library type `NativePoint` has been removed.  The standard
  library type `JubjubPoint` is now a `new type` alias for
  `Opaque<'JubjubPoint'>`.  This way `Opaque<'JubjubPoint'>` isn't really
  hidden, but it's not shown in error messages.
- `NativePoint` circuits in the standard library and the corresponding
  same-named functions in the Compact runtime have been renamed, and they now
  take or produce `JubjubPoint` values.
  - `nativePointX` -> `jubjubPointX`
  - `nativePointY` -> `jubjubPointY`
  - `constructNativePoint` -> `constructJubjubPoint`
- Signatures of elliptic curve operations in the standard library now use
  `JubjubPoint` in place of `NativePoint`.

### Internal notes

- The `compact fixup` tool can do these renamings except it cannot currently
  rename types (e.g. `NativePoint` to `JubjubPoint`).

## [Unreleased toolchain 0.29.102, language 0.21.100, runtime 0.14.100]

### Added

- There is a new builtin type `Opaque<'JubjubPoint'>`.  Unlike the other opaque
  types, this is intended to be a crypto backend (ZKIR) native type (not a JS
  type).  The standard library exports the type `JubjubPoint` which is a
  (transparent) `type` alias for the opaque type.

### Changed

- The standard library's (opaque) `new type` alias `NativePoint` now has
  underlying type `Opaque<'JubjubPoint'>`.
- The Compact runtime's types `CompactTypeNativePoint` and `NativePoint` are
  renamed to `CompactTypeJubjubPoint` and `JubjubPoint`.
- The runtime has TS (instead of Compact) implementations of the now-builtin
  `NativePointX` and `NativePointY` circuits.
- The feature flag `--zkir-v3` is changed to `--feature-zkir-v3` to fit a
  proposed standard naming convention, and to make crystal clear that it is
  still an experimental feature.

### Internal notes

- When the flag `--feature-zkir-v3` is enabled, `Opaque<'JubjubPoint'>` is
  represented natively in ZKIR v3.  Without the flag, it is still represented as
  a pair of field elements in ZKIR v2.
- This is implemented as a "pseudo"-alignment tag after flattening.  The tag
  looks like `(anative "JubjubPoint")` and it's interpreted as a `midnight-zk`
  JubjubPoint for ZKIR operations, converted to a pair of field values for
  the Impact code embedded in the ZKIR circuit.
- ZKIR v3 has new `encode` and `decode` gates for converting from ZKIR
  representations to Impact representations and back.
- ZKIR v3's `ec_add` has been eliminated; regular `add` is polymorphic,
  operating on either a pair of scalars or a pair of Jubjub curve points.
- ZKIR v3 has type annotations on circuit inputs and on `decode` instructions.
- ZKIR v3 has two types: `Scalar<BLS12-381>` and `Point<Jubjub>`.
- For both ZKIR v3 and ZKIR v2 modes, the JS representation of is still as a pair
  of field elements.

## [Unreleased toolchain version 0.29.101, language version 0.21.0]

### Changed

- In the formal grammar, the `stmt0` grammar production for one-armed
  `if` expressions has been removed.  It was unnecessary and made the grammar
  ambiguous.

## [Unreleased toolchain 0.29.100, language 0.21.0]

### Changed

The compiler binary can now report `--runtime-version`, the version of the
Compact runtime JS package that it will import in generated contract code.

## [Toolchain version 0.29.0, language version 0.21.0]

This release includes all changes for compiler versions in the range
0.28.100 and 0.29.0; and language versions in the range 0.20.100 and
0.21.0.  It uses Compact runtime 0.14.0 and on-chain runtime
compatible with 2.0.0.

## [Unreleased compiler 0.28.109, language 0.20.102]

### Fixed

- The fixup tool fixup-compact.ss failed to look for include files and modules
  relative to the directory of the source pathname.

## [Unreleased compiler 0.28.108, language 0.20.102]

### Removed

- The syntax for external circuits, i.e., circuit definitions with no body,
  has been removed.  This syntax was used exclusively for declaring built-in
  natives and was not useful outside of the compiler.

### Internal notes

- The compiler now injects natives directly into the standard library module.
  This is simpler and gives us a single source of truth for natives.

## [Unreleased compiler 0.28.107, language 0.20.101]

### Fixed

- An issue that caused transactions involving `mintShieldedToken`, `sendShielded`, `mintUnshieldedToken`, or
  `sendUnshielded` to fail validation with `RealUnshieldedSpendsSubsetCheckFailure` when the caller was also the 
  recipient of the newly minted token.

## [Unreleased compiler 0.28.106, language 0.20.100]

### Fixed

- An issue that caused the compiler to take an excessive amount of time to compile
  certain `for` loops, `fold` expression, and `map` expressions.

- An bug that caused the compiler to miss some of certain repeated disclosures
  of a witness value and to overstate the nature of certain other disclosures.

### Changed

- Messages about undeclared witness-value disclosures are now produced in an order
  that attempts, for each disclosure point and witness value, to put the most severe
  disclosures along the shortest paths first, since understanding these is easier
  and properly declaring them often addresses the others.

### Internal notes

- The underlying issue was the representation and maintenance of paths in the
  witness-protection program, and this has been replaced by a simpler mechanism
  with some careful crafting of the code to reduce computational complexity and
  generally make the compiler more efficient.

## [Unreleased compiler 0.28.105, language 0.20.100]

### Added

- The file compiler/contract-info.json that compactc generates in the output
  directory now includes some extra information: (1) version strings for the
  compiler, language, and runtime, and (2) for each circuit, a flag saying whether
  the circuit requires a proof (and therefore whether compactc has produced zkir
  code and prooving keys for it in the zkir and keys subdirectories of the output
  directory).

- ARM Linux artifact is added.

### Internal notes

- Adding the proof flag involved moving the pass that saves the contract-info file
  later in the compiler.  This in turn uncovered a couple of bugs in the preliminary
  handling of (as yet unsupported) cross-contract calls.  These have been fixed,
  though the code remains largely untested.  The zkir passes now recognize
  cross-contract calls and explicitly reject them as unsupported.

## [Unreleased compiler 0.28.104, language 0.20.100]

### Fixed

- A bug reported in issue [#34](https://github.com/LFDT-Minokawa/compact/issues/34) in which 
  `ChargedState` was not properly copied resulting in junk metadata being passed to contract deployments.

## [Unreleased compiler 0.28.103, language 0.20.100]

### Fixed

- A bug in the experimental `--zkir-v3` feature.  The on-chain representation of
  coin commitments changed between ledger version 6.1 and 6.2.  The domain
  separator string is changed, and the inputs to `persistentHash` are in a
  different order.

  This was already implemented for the default ZKIR v2, but the corresponding
  change was not implemented in the ZKIR v3 compiler passes.

## [Unreleased compiler 0.28.102, language 0.20.100]

### Changed

- For any circuit that returns something other than `[]` and for which some path through
  the circuit does not end in `return` form or ends in a `return` form without
  a return-value expression, the resulting error message now clearly states that
  this is the problem.

## [Unreleased compiler 0.28.101, language 0.20.100]

### Added

- Added a constructor, `constructNativePoint`, for `NativePoint` values

### Changed

- Renamed the existing accessors `NativePointX` and `NativePointY` to `nativePointX`
  and `nativePointY` for consistency with our conventions for circuit names.

## [Unreleased compiler 0.28.100, language 0.20.0]

There are no user-visible changes.

### Internal notes

- Instead of pulling test contracts from the separate (private) repository
  `midnight-contracts`, they are added to this repository under
  `test-center/test-contracts`.
  
## [Unreleased compiler 0.28.100, language 0.20.0]

### Changed

- The informal parser rule that "else" clauses belong to the innermost "if"
  expression is now explicit in the grammar.  Previously, we were relying on a
  shaky assumption about how the parser generator treats grammar ambiguities.
  This change is reflected in the formal grammar specification in doc/Compact.html
  but has no impact on how programs are compiled.

## [Compiler version 0.28.0, language version 0.20.0]

This release includes all changes for compiler versions in the range 0.27.100
(inclusive) and 0.28.0 (exclusive); and language versions in the range 0.19.100
(inclusive) and 0.20.0.  It uses compact-runtime 0.14.0-rc.0 and 
on-chain runtime 2.0.0-alpha.1.

## [Unreleased compiler version 0.27.113, language version 0.19.103]

### Changed

- The formatter's handling of several forms has been improved:
  - When the signature of a function needs to be broken up into multiple lines,
    the parameter list is also broken up into multiple lines (even if it would itself
    fit on one line), and the return-type declaration appears on a line following
    the last parameter declaration. This change applies to circuit definitions,
    external declarations, witness declarations, the constructor, and anonymous
    circuit definitions.
  - When a call expression needs to be broken up into multiple lines, the argument
    list is also broken up into multiple lines (even if it would itself
    fit on one line), and the closing parenthesis of the call appears on a line
    following the last argument expression.
  - When an anonymous circuit needs to be broken up into multiple lines, the body
    of the circuit is indented a few spaces in from the start of the parameter
    list rather than all the way out beyond the circuit's signature.
  - When the "else" expression of an "if" expression is itself an "if" expression,
    the inner "if" expression begins on the same line as the "else" and appears at
    at the same level of indentation as the outer "if" expression, in a case-like
    structure.  This special treatment is inhibited by end-of-line comments between
    the outer "else" keyword and the inner "if" keyword.

- The formatter now accepts a --line-length <n> parameter that sets the target line
  length to <n>.  The default line length currently defaults to 100.  The target line
  length can be exceeded in cases where the formatter considers the portion of input
  to be fit on a line to be unbreakable.

### Internal notes

- Configuration parameters have been collected into a single new library, (config-params)

- The formatter line length is now a configuration parameter, set to 100 by default.

- compiler/go now catches keyboard interrupts while running the tests and aborts the tests.

- compiler.md now more accurately describes the composition of the token stream.

- The formatter improvements are supported by the following changes:
  - add-block (appropriately renamed make-Qblock, since it returns a block)
    has been simplified to take a header rather than a proc that produces a header
  - make-Qsep has been split into two routines, one that expects a closer and one
    that doesn't.
  - make-Qsep and make-Qconcat now take an inherit-break? flag whose value is
    recorded in the resulting Qconcat record.  Processing a Qconcat with this
    flag set in the context in which lines are being broken causes the contents
    of the Qconcat itself to be broken into multiple lines.  The contents of a
    Qconcat q with this flag set are still indented relative to q.
  - The code for handling function signatures is now commonized into a single
    constructor make-Qsignature.

## [Unreleased compiler version 0.27.112, language version 0.19.103]

### Changed

- The Compact standard library structure type NativePoint (nee CurvePoint)
  is now a nominal type alias for an unexported internal type.  The standard
  library also now exports two new circuits, NativePointX and NativePointY,
  that can be used to access the x and y coordinates of a native point as Fields.
  This is a breaking change because the internal representation of NativePoint
  is no longer exposed.

- In type errors produced by the Compact compiler, Nominal type aliases are
  now shown simply as TypeName rather than as TypeName=Type.

## [Unreleased compiler version 0.27.111, language version 0.19.102]

### Changed

- Changes `CurvePoint` to `NativePoint`

## [Unreleased compiler version 0.27.110, language version 0.19.101]

### Changed

- Fixes PM-19299 by having `createZswapInput` and `createZswapOutput` return
  an empty array to represent the `[]` type in Compact.

## [Unreleased compiler version 0.27.109, language version 0.19.101]

### Changed

- The compiler now targets ledger version 7.0 instead of 6.2.  There are no API
  changes between 6.2 and 7.0 so it is only necessary to pull in a new
  implementation of the on-chain runtime and bump version numbers.  This is
  **not** a breaking change.

## [Unreleased compiler version 0.27.108, language version 0.19.101]

### Added

- The reserved words from TypeScript and JavaScript are now included in our
  future reserved words.

## [Unreleased compiler version 0.27.107, language version 0.19.100]

### Changed

- The compiler now targets ledger version 6.2 instead of 6.1.  This ledger
  version has changes to Zswap hashing made in response to ledger audit
  feedback.

- There are standard library changes to **non-exported** structs and circuits,
  so this is **not** a breaking change.

## [Unreleased compiler version 0.27.106, language version 0.19.100]

### Fixed

- Bugs in unreleased code preventing proper behavior of type aliases for certain
  uses of ADT types, including ledger operations that treat parameters of type
  QualifiedCoinInfo differently and the += and -= operators for incrementing
  Counters.

## [Unreleased compiler version 0.27.105, language version 0.19.100]

### Changed

- The compiler no longer generates zkir code or proving keys for circuits that
  do not directly touch the ledger.  Previously, it generated zkir code and
  proving keys for all impure circuits, so merely calling a witness or invoking
  one of the witness-like external circuits (`ownPublicKey`, `createZswapInput`,
  `createZswapOutput`) would also trigger zkir and proving-key generation.

## [Unreleased compiler version 0.27.104, language version 0.19.100]

### Fixed

- The compiler now rejects programs whose constructors contain array-reference,
  and bytes-reference, and slice expressions with out-of-bounds indices.
  Previously, such errors could lead to these expressions producing undefined
  values at run time.

## [Unreleased compiler version 0.27.103 language version 0.19.100]

### Added

- Compact now supports the definition of type aliases:
  Structually typed aliases:
    `type Name = Type;` defines `Name` to be an alias for `Type`.  For example,
    `type U32 = Uint<32>` defines `U32` to be the equivalent of and interchangeable
    with `Uint<32>`.

  Nominally typed aliases:
    `new type Name = Type;` is similar, but `Name` is defined as a distinct type
    compatible with `Type` but neither a subtype of nor a supertype of `Type` or
    any other type.  It is compatible in the senses that (a) values of type `Name`
    can be used by primitive operations that require a value of type `Type`, and
    (b) values of type `Name` can be explicitly cast to and from type `Type`.
    For example, within the scope of `type V3U16 = Vector<3, Uint<16>>`, a value
    of type `V3U16` can be referenced or sliced just like a vector of type
    `Vector<3, Uint<16>>`, but it cannot, for example, be passed to a function
    that expects a value of type `Vector<3, Uint<16>>` without an explicit cast.

    When one operand of an arithmetic operations (e.g., `+`) receives a value
    of some nominally typed alias T, the other operand must also be of type T,
    and the result is cast to type T, which might cause a run-time error if the
    result cannot be represented by type T.

    Values of some nominally typed alias T cannot be directly compared (using,
    e.g., `<`, or `==`) with values of any other type without an explicit cast.

  Both types of aliases can take type parameters, e.g.:
  `type V3<T> = Vector<3, T>`
  `new type VField<#N> = Vector<N, Field>`

  This is a breaking change due to the reservation of the `new` and `type` keywords.

### Changed

- Out-of-range constant Bytes value indices are now detected earlier in the
  compiler, which means that additional such errors might be caught, specifically
  those in code that is later discarded.  This is a breaking change.

- Upward casts no longer prevent tuple references and slices from recognizing
  constant indices, which allows more programs with references to non-vector tuple
  types to pass type checking.

### Fixed

- A bug that caused a misleading source location to be reported for some type
  errors, e.g., for invalid arguments to some calls to `map` and `fold`.

### Internal notes

- The Public-ledger ADT (`public-adt`) form, which describes the type of a
  public-ledger ADT, has been replaced by a new Type `tadt` throughout the compiler.
  This simplifies and regularizes the representation of types and allows type
  aliases to be used for ADT types as well as for non-ADT types.

- Equality testing in the unit-test framework has been tightened up to avoid
  false positives when the expected output uses different symbols to represent
  what turns out to be the same id or gensym in the actual output.  This can
  occur when the expected output is wrong or the compiler actually generates
  code that uses the same id or gensym for different purposes.  Several instances
  of the first have been fixed in the unit tests.

- A new checker, `pass-returns`, as been added to the unit-test framework.  It
  is like `returns` but checks the output of a specific pass.  This is intended
  to allow us to move toward having a single occurrence with checks for multiple
  passes rather than having to put multiple copies of the same test in different
  test groups.

- A new form `(assertf expr format-string arg ...)` has been added to utils.ss.
  Like `(assert expr)`, it returns the value of `expr` if `expr` evaluates to a
  true value and raises an exception if `expr` evaluates to #f.  Its error message
  includes the source location of the `assertf` form, as with `assert`, and also
  the result of applying `format` to `format-string` and `arg ...`.  `assertf`
  is useful in preference to `assert` when the assertion expression does not
  already indicate the problem and the problem is not otherwise obvious from the
  context.

- internal-errorf now also includes the source location in the error message.

## [Unreleased compiler version 0.27.102, language version 0.19.0]

### Changed

- The unique variable names in the ZKIR v3 output are now produced in such a way
  that they are stable in the face of changes in the order or set of circuits
  generated.  That is, if the generated zkir for a circuit doesn't otherwise
  change, the variable names should also be identical.

### Internal notes

- Running the unit tests in test.ss now produces the file replacement-results.ss
  containing one entry for each result that differs from the expected result,
  e.g., each returns form when the returned result is different, each oops
  form when the condition is different, each output-file result with the
  output is different, etc.  No entry is included for unexpected exceptions,
  e.g., no entry is included for a return form if an exception occurs instead.
  If replacement-results.ss would be empty, it is deleted and not created.
  The new program compiler/update-test.ss takes as input the pathname of the
  test file (usually compiler/test.ss), the pathname of the replacements file
  (usually replacement-results.ss), and the pathname of an output file (e.g.,
  /tmp/test.ss).  Bad things will happen if the output pathname identifies that
  same file as the input pathname.  update-test.ss applies the replacements in
  the replacements file to the input file and puts the result in the output file.
  The output file can then be manually copied over the input file.  This is useful
  primarily when making cosmetic changes that affect a large number of tests and
  only after spot-checking to make sure that the cosmetic change is doing no harm.

## [Unreleased compiler version 0.27.101, language version 0.19.0]

### Changed

- The ZKIR v3 format (behind the feature flag --zkir-v3) is changed to coalesce
  an Impact instructions encoding into a guarded array.  Previously they were
  multiple unguarded instructions followed by a guarded "skip" instruction.

## [Unreleased compiler version 0.27.100, language version 0.19.0]

### Fixed

- Use of `return` statements among the statements comprising the body of a `for`
  loop are not supported.  Previously, such uses resulted in strange run-time
  behavior or confusing compile-time error messages.  The compiler now explicitly
  flags such uses as static errors with an appropriate error message.

## [Compiler version 0.27.0, language version 0.19.0] - Branched 2025-11-19

This release includes all changes for compiler versions in the range 0.26.100
(inclusive) and 0.27.0 (exclusive); and language versions in the range 0.18.100
(inclusive) and 0.19.0.

## [Unreleased compiler version 0.26.121 language version 0.18.103]

### Changed

- Changed the intermediate languages leading up to Lexpr to reflect that circuit
  and constructor bodies must be blocks rather than arbitrary statements.  reworked
  hoist-local-variables to avoid a dependency on a fluid variable.  These are not
  user-visible changes.

## [Unreleased compiler version 0.26.120 language version 0.18.103]

### Changed

- Changed the (experimental, not yet announced) ZKIR v3 format to use symbolic
  names instead of indexes for instruction inputs and ouputs.

## [Unreleased compiler version 0.26.119 language version 0.18.103]

### Fixed

- The type checker was not raising an exception for casts from Bytes<0> values
  to Field or Uint values and vice versa, which led to confusing downstream errors
  in some cases.

## [Unreleased compiler version 0.26.118 language version 0.18.103]

### Added

- Four new kernel operations, `mintUnshielded`, `claimUnshieldedCoinSpend`, `incUnshieldedOutputs`, and
  `incUnshieldedInputs`.
- Eight new standard library functions, `mintUnshieldedToken`, `sendUnshielded`, `receiveUnshielded`,
  `unshieldedBalance`, `unshieldedBalanceLt`, `unshieldedBalanceGte`, `unshieldedBalanceGt`, `unshieldedBalanceLte`.

### Changed

- Updates the repository to use ledger `6.1.0-alpha.5`, i.e., `@midnight-ntwrk/onchain-runtime-v1` version `1.0.0-alpha.5`.
- Changes names like `QualifiedCoinInfo` and `CoinInfo` to be `QualifiedShieldedCoinInfo` and `ShieldedCoinInfo` to
  match the names in the new on-chain runtime.
- Renames standard library functions to distinguish between shielded and unshielded token utilities.

## [Unreleased compiler version 0.26.117 language version 0.18.102]

### Fixed

- A bug in which types other than tuple, vector, and bytes do not result in an internal
  error when checking the bounds of an index.  This was an unreleased bug, that is,
  the bug was created in an unreleased version of the compiler.

## [Unreleased compiler version 0.26.116 language version 0.18.102]

### Fixed

- A bug in which unimported modules enclosed in unimported modules are not processed
  to detect and report certain errors, including type errors.  While it is
  essentially harmless not to process unimported modules since code in unimported
  modules is never run, this fix potentially allows some issues to be detected
  earlier in the application development process.

## [Unreleased compiler version 0.26.115 language version 0.18.102]

### Fixed

- A bug in which the compiler sometimes mentioned the same incompatible function
  more than once in the error message produced when no function with compatible
  generic or run-time parameters is found at a call site.

## [Unreleased compiler version 0.26.114 language version 0.18.102]

### Changed

- The maximum representable unsigned integer has been reduced from the maximum value
  that fits in the number of _bits_ in a field to the maximum value that fits in the
  number of _bytes_ in a field.  This change is necessary because values that do not
  fit in the number of bytes in a field do not have a valid representation in the
  ledger.  Given that the maximum field value at present is between 2^254 and 2^255,
  the number of whole bytes representable by a field is 31, and the maximum unsigned
  value is (2^8)^31-1 = 2^248-1.

  This is a breaking change because programs that used unsigned integers between
  2^248 (inclusive) and 2^254 (exclusive) will no longer compile.  Though while they
  would previously have compiled, they would not necessarily have worked properly.

## [Unreleased compiler version 0.26.113 language version 0.18.101]

### Fixed

- A bug in which some obviously unreachable statements were not being reported as such.
  This should be considered a breaking change since some programs that previously compiled
  will no longer compile due to this fix.

## [Unreleased compiler version 0.26.112 language version 0.18.101]

### Changed

- `Uint` range end points are now exclusive rather than inclusive to match the
  range syntax for `for` ranges.  That is, `Uint<0..n>` is now interpreted as the
  set of all unsigned integers in the range 0 through `n-1`, e.g., `Uint<0..3>`
  represents the set {0, 1, 2} rather than the set {0, 1, 2, 3}.

- The runtime version has been bumped to 0.10.2.

- when passed the `--update-Uint-ranges` flag, `fixup-compact` now adjusts the
  end point of each Uint whose size is given by a range with a constant end point
  and issues a warning for each Uint whose size is given by a range when the end
  point is a generic-variable reference.

## [Unreleased compiler version 0.26.111 language version 0.18.100]

### Fixed
- A bug in which Compact enums were generated as CJS enums instead of ESM enums. Previously, `index.js` might contain:

  ```javascript
  var Status;
  (function (Status) {
  Status[Status['Pending'] = 0] = 'Pending';
  // ...
  })(Status = exports.Status || (exports.Status = {}));
  ```

  for an enum `Status`. Now, `index.js` contains:

  ```javascript
  export var Status;
  (function (Status) {
    Status[Status['Pending'] = 0] = 'Pending';
    // ...
  })(Status || (Status = {}));
  ```

## [Unreleased compiler version 0.26.110 language version 0.18.100]

### Fixed
- An unreleased bug that was created during putting bounds on vectors/tuples/bytes

## [Unreleased compiler version 0.26.109 language version 0.18.100]

### Fixed

- A bug that could cause ledger operations or witness calls occurring
  in the test part of an `if` expresssion not to be reflected in the
  generated zkir circuit.

## [Unreleased compiler version 0.26.108 language version 0.18.100]

### Fixed

- A bug in unreleased code that caused an internal error message
  about an invalid source object.
- Internal language version is now properly bumped to 0.18.100.

## [Unreleased compiler version 0.26.107 language version 0.18.1]

### Fixed

- A bug that allowed const statements binding patterns or multiple variables
  to appear in a single-statement context, e.g., the consequent or alternative
  of an `if` statement.

## [Unreleased compiler version 0.26.106 language version 0.18.1]

### Added

- Selective module import and renaming, e.g.:
    `import { getMatch, putMatch as $putMatch } from Matching;`
      imports `getMatch` as `getMatch`, `putMatch` as `$putMatch`
    `import { getMatch, putMatch as originalPutMatch } from Matching prefix M$;`
      imports `getMatch` as `M$getMatch`, `putMatch` as `M$originalPutMatch`
  The original form of import is still supported:
    `import Matching;`
      imports everything from `Matching` under their unchanged export names
    `import Matching prefix M$;`
      imports everything from `Matching` with prefix M$

### Fixed

- A bug that sometimes caused impure circuits to be identified as pure
