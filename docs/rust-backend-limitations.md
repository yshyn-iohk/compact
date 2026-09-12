# `compactc --target rust` — known limitations

What the Rust backend does *not* lower, and what happens when you hit it.

The TypeScript backend is the reference; the Rust backend targets the same
`ContractState` bytes but covers a subset of the language. This page exists
so that subset is discoverable before you write a contract, rather than at
`compactc` time — or, worse, at `cargo build` time.

## The contract: unsupported means a compile error, never bad output

Every construct the backend cannot lower raises a `rust-feature-error`,
which fails the compile with a named diagnostic and a source location.
This is the single most important property of the backend, and the one to
preserve when adding lowerings:

> A construct the emitter does not understand must **FAIL**, not emit
> something plausible.

That rule was not free, and it was not won in one pass. Every item below
is a place that used to violate it — each a different flavour of the same
mistake, and each found by hand rather than by a gate:

- **`Field as Uint<N>`** shared an emitter clause with the `Uint`-source
  cast, so it emitted `(x) as uN` where `x: Fr`. `Fr` is a struct, so that
  is a non-primitive cast (E0605): `compactc` exited 0, the fixture
  regenerated "fine", and the breakage appeared later at `cargo build`.
- **A constructor body that no walker shape matched** emitted the *default
  scaffold* — every ledger write in the constructor silently discarded,
  from a compile that exited 0. Not a build break at all: well-formed Rust
  that compiled, ran, and deployed a contract with none of its initial
  state. The worst of the set, and the last found.
- **A ledger field with no decoder** emitted `decode_u64` behind a `TODO`
  comment, so a `Vector<3, Bytes<32>>` accessor returned a `u64` in tail
  position of `Result<[[u8; 32]; 3], _>`. Reachable with one ledger field,
  no circuits, and no constructor.
- **A constructor `assert` whose condition was a non-inlinable circuit
  call** emitted `assert!(true)`. A precondition silently disappeared, in
  code that compiles and reads correctly.
- **A constructor `if` in the same situation** emitted `if true`, making
  the then-branch unconditional and the else-branch dead — so a
  conditional ledger write became unconditional.
- **Four natives with no Rust binding** (`keccak256`, `ownPublicKey`,
  `createZswapInput`, `createZswapOutput`) emitted `unimplemented!()` into
  the generated crate. Those compiled cleanly and panicked at run time.

All of them now reject at compile time, and
`tests-e2e-rust/tests/rejection_corpus.rs` keeps them rejecting. If you are
adding a lowering and find yourself unsure what the correct output is,
raise a `rust-feature-error` rather than emit a guess — the guess is much
more expensive to find later than the error is to hit now.

**Note how each was found: by reading the emitter, not by a failing
test.** Byte parity structurally cannot catch this class. It compares
committed output against regenerated output, so a construct that emits bad
Rust agrees with itself perfectly and the fixture stays green forever.
Every bug above shipped behind a green byte-parity run. That is what the
negative corpus exists to cover, and why a new lowering should add an entry
there rather than only a fixture.

Diagnostics carry the source location and a kind symbol:

```
probe.compact line 11 char 10:
  compactc --target rust: unsupported Compact construct (ctor-assert-condition-inline):
  cannot inline the call to `readFlag` used as an `assert` condition in a constructor
```

## Enumerating the current set

The authoritative list is the code, not this page — it moves as lowerings
land. To count the rejection sites the same way:

```bash
grep -rn "(rust-feature-error" compiler/rust-passes*.ss \
  | grep -v "define (rust-feature-error" | wc -l
```

At the time of writing that is **38 call sites** across 4 passes
(`rust-passes-emit.ss` 28, `rust-passes-walker.ss` 4,
`rust-passes-helpers.ss` 5, `rust-passes-prelude.ss` 1), spanning **30
distinct kinds**. (The `rust-passes-helpers.ss` count includes the
post-emit `sentinel-splice` guard added by
`type-directed-expression-coercion` — see below.)

One caveat when reading a diagnostic: several emitters probe alternative
shapes under a catch-all `(guard (c [#t #f]) …)`, which swallows a specific
`rust-feature-error` and reports the enclosing body's generic kind instead
(`pure-circuit-body-emission`, `ctor-body-emission`). The refusal is still
correct — nothing is emitted — but the message can be coarser than the
kind that actually fired. `Field as Uint<N>` is the current example: it
reports `pure-circuit-body-emission`, not `cast-from-field`.

## The limitations most likely to affect a contract

### Natives with no Rust binding

`native-binding-missing`. Four natives have no Rust implementation to bind
to, and calling any of them fails the compile:

| Native | Why |
|---|---|
| `keccak256` | no upstream Rust binding — midnight crypto exposes keccak only as a ZK circuit chip |
| `ownPublicKey` | host-side zswap witness; needs a `WitnessContext`-mediated binding |
| `createZswapInput` | as above |
| `createZswapOutput` | as above |

These are represented in `compiler/midnight-natives.ss` by the *absence*
of a `(rust …)` clause, which leaves the field `#f` and makes
`native-call-site-rust` reject. That is deliberate: the absence of a
binding is now representable as absence, rather than as a string that
happens to contain `unimplemented!()`.

Note `keccak256` is also gated earlier under ZKIR v2 — you will see the
ZKIR diagnostic first unless you pass `--feature-zkir-v3`.

### Constructor conditions that need inlining

`ctor-assert-condition-inline`, `ctor-if-condition-inline`. A constructor's
`assert` or `if` condition must be resolvable at emission time — either a
directly renderable expression, or a circuit call the emitter can inline.
An impure, non-exported circuit call generally cannot be inlined, and is
rejected:

```compact
circuit readFlag(): Boolean { return count.read() > 0; }

constructor() {
  assert(readFlag(), "flag must be set");   // rejected
}
```

**Workaround:** inline the condition yourself (`assert(count.read() > 0, …)`),
or move the check out of the constructor into an exported circuit.

Many conditions that *look* like this are fine, because the constructor
evaluates ledger reads against the known initial state and folds the
condition. Reach for the workaround only when you actually see the
diagnostic.

### Constructor bodies past the walker's shapes

`ctor-body-emission`. The constructor is lowered by shape-matching, not by
a general statement compiler, so a body that combines collection seeding
with control flow can fall outside every shape:

```compact
constructor() {
  names.insert(1, 100);
  for (const i of 0..3) { total = (total + 7) as Uint<64>; }   // rejected
}
```

**Workaround:** move the loop into an exported circuit called once after
deploy, or unroll it in the constructor.

This is the one limitation worth knowing about even if you never hit it,
because until recently it was not a limitation at all — it emitted the
default scaffold and threw the constructor away. If you are on an older
build, check that your deployed initial state is what you wrote.

### `Field as Uint<N>` — no lowering

`cast-from-field`. Narrowing a `Field` to a bounded unsigned integer needs
a runtime helper that range-checks an `Fr` and narrows it to `uN`; the TS
runtime does the equivalent with a bigint bounds check. Until that helper
exists, the cast is rejected.

**Workaround:** keep the value in `Field` where possible, or perform the
narrowing in a witness (off-circuit) and pass the `Uint<N>` in.

### Generic impure circuits — body not lowered

A generic *impure* circuit's body is not lowered. The case that matters in
practice — the Schnorr-on-Jubjub verifier — is handled by rewriting the
call to an orphan-safe runtime wrapper
(`midnight_compact_runtime::schnorr_verify_jubjub`) rather than by lowering
the generic body; see `runtime-rs/src/std_lib/schnorr.rs` and
`schnorr_attest_fixture`. Generic *pure* circuits are supported.

### Fixed-arity hash and commit natives

`transient-hash-arity`, `persistent-hash-arity`,
`persistent-commit-arity`. Lowered for the arities the corpus exercises;
other arities reject.

### Ledger-read shapes

`ledger-read-decoder-missing`, `ledger-read-non-index-path`,
`ledger-op-non-read`, `adt-read-with-arg-lowering`. Reads are lowered
per-ADT with alignment-aware decoding; an ADT or access path without a
decoder rejects rather than guessing a layout. This is the class most
likely to meet a new contract shape, and the cheapest to fix — usually a
new decoder arm plus a fixture.

### `Map` MVP shape

`map-mvp-shape`. `map()` is lowered for the shapes the fixtures cover
(identity body, non-identity lambda, named function); other shapes reject.

### `Uint` wider than `u128` into a `Field`

`field-uint-coercion`. A `Uint<N>` value flowing into a `Field` position is
zero-extended through the widest lossless Rust cast available — `Fr::from((x)
as u64)`, then `Fr::from((x) as u128)` once the range passes `u64::MAX`. A
source range that runs past `u128::MAX` (e.g. `Uint<248>`, Compact's maximum
width) has no lossless cast into `Fr`, so it rejects rather than truncate:

```compact
ledger f: Field;
constructor(x: Uint<248>) { f = disclose(x); }   // rejected (field-uint-coercion)
```

The `Uint<128>` boundary itself is accepted — its max is exactly `u128::MAX`,
so `From<u128> for Fr` is lossless.

### Sentinel splice

`sentinel-splice`. The emitted `lib.rs` is buffered and scanned before it is
written: a `#f` from a renderer that could not lower an expression — the
value that used to reach the output when an unchecked caller fed it to
`format` — aborts the compile with a location instead of producing Rust that
merely looks plausible. The scan ignores `#f` inside string/char literals,
comments, and raw identifiers (`r#foo`), so it only fires on an actual
splice. This is the backstop that replaced the old reliance on the
`rendered-has-todo?` `/* TODO` scan for correctness.

## Verifying a claim on this page

Every limitation above is a `rust-feature-error` site, so it can be
confirmed by compiling a contract that uses the construct:

```bash
nix build .#compactc
./result/bin/compactc --target rust --skip-zk path/to/probe.compact /tmp/out
```

A limitation that does *not* produce a diagnostic is itself a bug — that is
the silent-bad-output path this page's contract exists to forbid. If you
find one, it belongs in the same category as the four listed above, not in
a TODO comment.
