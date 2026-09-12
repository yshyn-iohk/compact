// This file is part of Compact.
// Copyright (C) 2026 Midnight Foundation
// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//  	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//
// Codegen byte-parity regression guard.
//
// Iter 9 (commit 405be1c) restored the Scheme codegen build after Iters
// 4-6 had introduced phantom nanopass dispatches that prevented compactc
// from rebuilding. The e2e tests stayed green only because every
// fixture's `lib.rs` was hand-written / pre-generated and checked in.
// That allowed a real regression to hide in the IR-level emit logic.
//
// This test re-runs the locally-built `compactc --rust` over each
// example contract and asserts that the output is byte-identical to the
// committed `tests-e2e-rust/contracts/<dir>/lib.rs`. It is the regression
// guard that ensures future Scheme-side changes to rust-passes (or to
// the upstream nanopass IR they target) don't silently drift away from
// the checked-in expectation.
//
// Behaviour — the gate NEVER skips itself:
// - A missing compiler, an unlocatable repo root, or a FIXTURES entry
//   whose source or committed output is absent are all **hard failures**.
//   This test used to skip with a warning in each of those cases so that
//   `cargo test -p tests-e2e-rust` stayed green on a checkout that had
//   not run `nix build .#compactc`. The effect was a byte-parity gate
//   that reported success having regenerated nothing — which is what it
//   did in CI for the entire life of the branch. A gate that cannot run
//   must say so, not pass.
// - Callers that genuinely cannot supply a compiler exclude this test by
//   name (`-- --skip rust_codegen_byte_parity`) instead. That keeps the
//   exclusion visible at the call site and in libtest's "filtered out"
//   count, and it means any run that *does* execute this test is
//   guaranteed to have had a real compiler. `rust-runtime-test.yml`'s
//   bare Ubuntu/macOS runners do exactly that; MediaNoxLabs/compact#23
//   tracks giving CI a real compactc so the gate runs there too.
// - Resolution order: the repo root is the nearest ancestor of the test
//   crate holding both `examples/` and `Cargo.toml` (independent of any
//   nix build, so it works when the caller brings its own compiler).
//   The compiler is `$COMPACTC` if set, else `<root>/result/bin/compactc`
//   — the symlink `nix build .#compactc` produces.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

/// (source filename in examples/, contract dir under tests-e2e-rust/contracts/)
const FIXTURES: &[(&str, &str)] = &[
    ("aliases_fixture.compact", "aliases-fixture"),
    ("bounded_uint_fixture.compact", "bounded-uint-fixture"),
    ("bug11_fixture.compact", "bug11-fixture"),
    ("cross_circuit_fixture.compact", "cross-circuit-fixture"),
    ("election.compact", "election"),
    ("fold_fixture.compact", "fold-fixture"),
    ("for_iter_fixture.compact", "for-iter-fixture"),
    ("for_range_fixture.compact", "for-range-fixture"),
    ("hash_to_curve_fixture.compact", "hash-to-curve-fixture"),
    ("hmt_default_fixture.compact", "hmt-default-fixture"),
    ("if_stmt_fixture.compact", "if-stmt-fixture"),
    ("list_fixture.compact", "list-fixture"),
    ("map_fixture.compact", "map-fixture"),
    ("map_fn_fixture.compact", "map-fn-fixture"),
    ("map_lambda_fixture.compact", "map-lambda-fixture"),
    ("module_fixture.compact", "module-fixture"),
    ("multi_pl_call_fixture.compact", "multi-pl-call-fixture"),
    ("nested_map_fixture.compact", "nested-map-fixture"),
    ("pure_circuit_fixture.compact", "pure-circuit-fixture"),
    ("sealed_ledger_fixture.compact", "sealed-ledger-fixture"),
    ("set_fixture.compact", "set-fixture"),
    ("set_size_fixture.compact", "set-size-fixture"),
    (
        "struct_collision_fixture.compact",
        "struct-collision-fixture",
    ),
    ("tiny.compact", "tiny"),
    ("uints_fixture.compact", "uints-fixture"),
    ("vector_fixture.compact", "vector-fixture"),
    ("witnesses_fixture.compact", "witnesses-fixture"),
    ("zerocash.compact", "zerocash"),
    ("assert_parity_fixture.compact", "assert-parity-fixture"),
    // A29: >16 ledger fields — the front end chunks the state into a nested
    // shape (StateValue::Array caps at 16); locks the chunked initial-state
    // scaffold alongside the executing readback gate in
    // tests/chunked_ledger_fixture.rs.
    ("chunked_ledger_fixture.compact", "chunked-ledger-fixture"),
    // G1: struct-field projection as an operand of trapping unsigned
    // arithmetic (`currentTime - attestation.proof.createdAt <= policy.maxAge`),
    // inside and outside an `if` guard. The typer nests TWO levels of
    // let*-lifted assignment for that shape, and the emitter rendered only
    // the outer one; locks the nested-assignment rendering alongside the
    // executing assert gate in tests/guarded_assert_arith_fixture.rs.
    (
        "guarded_assert_arith_fixture.compact",
        "guarded-assert-arith-fixture",
    ),
    // Wide, structured state: 20 ledger fields (A29 chunked scaffold), a
    // `ContractAddress` cell written from `kernel.self()` whose read goes
    // through the alignment-aware `decode_via_field_repr` (A30/A31, incl.
    // the all-zero / empty-normalised-atom case), `Map`/`Set` values that
    // are structs, and a constructor that calls an impure circuit reading
    // its own writes (A28). Executing gate:
    // tests/asset_registry_fixture.rs.
    ("asset_registry_fixture.compact", "asset-registry-fixture"),
    // Schnorr-on-Jubjub routing: the emitter rewrites a call to the generic
    // `schnorrVerify<#n>` into `midnight_compact_runtime::schnorr_verify_jubjub` and
    // routes `SchnorrSignature` to the runtime's mirror type. Also the only
    // fixture with a generic circuit, a generic struct at two widths, and a
    // tuple-returning witness. Executing gate:
    // tests/schnorr_attest_fixture.rs.
    ("schnorr_attest_fixture.compact", "schnorr-attest-fixture"),
    // Mid-ladder widening casts in `mbits->rust-width`: the u16 and u32
    // rungs, which no other fixture reaches. The ladder was otherwise
    // exercised only at u64 (the same-width no-op, asset-registry /
    // guarded-assert-arith) and u128 (a real widening, map-lambda's
    // `x * 2` on Uint<64>) — so widening was covered but three rungs and
    // both interior boundaries were not. An off-by-one in a rung
    // comparison would pick a wrong width and, since `wrapping_*` cannot
    // overflow, yield a WRONG VALUE in code that still compiles.
    // Executing gate: tests/widening_arith_fixture.rs.
    ("widening_arith_fixture.compact", "widening-arith-fixture"),
    // Mixed-MINIMAL-width operands at comparison/equality boundaries: the
    // typer wraps the narrower operand of `q * 4 <= y` (product ranges to
    // u64, `y` is u32) in a `safe-cast`, which the emitter now materialises
    // as `((y) as u64)`. `widening_arith_fixture` covers the mbits ladder at
    // uniform declared widths; this one covers operands of ONE binary
    // operation whose minimal Rust widths differ, across all six comparison
    // operators, mixed-width `+ - *`, the guarded-subtraction route, an
    // impure inline equality, and the constructor. Executing gate:
    // tests/mixed_width_operand_fixture.rs.
    (
        "mixed_width_operand_fixture.compact",
        "mixed-width-operand-fixture",
    ),
    // Type-directed coercion of bare literals and Uint values: Field const
    // RHS, struct Field member, `some<Field>(0)`, `persistentHash([0])`,
    // native / pure-call argument, return tail, scalar and wide Uint→Field,
    // aggregate Field vector, and destination-typed ledger writes. Executing
    // gate: tests/literal_coercion.rs (state-byte parity + round-trips).
    (
        "literal_coercion_fixture.compact",
        "literal-coercion-fixture",
    ),
];

/// Walks up from `start` looking for the repository root: the nearest
/// ancestor holding both `examples/` (the fixture sources this test
/// compiles) and a `Cargo.toml`. Returns `None` if not found within 6
/// levels.
///
/// Deliberately independent of `result/bin/compactc`. Keying the root off
/// the nix symlink conflated two questions — "where is the checkout?" and
/// "is there a compiler?" — so a caller that set `COMPACTC` to its own
/// binary without ever running `nix build` resolved the root to the test
/// crate's own directory. Fixtures then failed to resolve and the gate
/// reported a missing-fixture error instead of the real problem.
fn find_repo_root(start: &Path) -> Option<PathBuf> {
    let mut cur = start.to_path_buf();
    for _ in 0..6 {
        if cur.join("examples").is_dir() && cur.join("Cargo.toml").is_file() {
            return Some(cur);
        }
        if !cur.pop() {
            break;
        }
    }
    None
}

#[test]
fn rust_codegen_byte_parity_against_committed_fixtures() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    // Locate the checkout first, independently of any compiler. Failing
    // here names the actual problem instead of letting every fixture
    // resolve against the wrong directory and reporting them as missing.
    let repo_root = find_repo_root(&manifest).unwrap_or_else(|| {
        panic!(
            "byte-parity gate cannot run: could not locate the repository root \
             (no ancestor of {} within 6 levels contains both examples/ and \
             Cargo.toml). The gate compiles fixture sources out of examples/, \
             so it needs the checkout, not just a compiler.",
            manifest.display()
        )
    });

    // A missing compiler must FAIL, not skip: this test previously
    // returned early here, so `cargo test -p tests-e2e-rust` without a
    // prior `nix build .#compactc` printed "SKIP" and passed in 0.00s — a
    // green byte-parity gate that compiled nothing. Callers that cannot
    // supply a compiler exclude the test by name instead (see the header).
    let (compactc, how) = match std::env::var_os("COMPACTC") {
        Some(p) => (PathBuf::from(p), "COMPACTC"),
        None => (repo_root.join("result/bin/compactc"), "default path"),
    };
    assert!(
        compactc.exists(),
        "byte-parity gate cannot run: no compactc at {} (from {}). \
         Run `nix build .#compactc`, or point COMPACTC at a real binary.",
        compactc.display(),
        how
    );

    let examples_dir = repo_root.join("examples");
    let contracts_dir = manifest.join("contracts");
    let mut drift = Vec::new();

    for (src_name, dir_name) in FIXTURES {
        let src = examples_dir.join(src_name);
        let committed = contracts_dir.join(dir_name).join("lib.rs");
        // Missing inputs are a broken FIXTURES table, not a reason to skip:
        // silently dropping an entry would quietly shrink the gate.
        assert!(
            src.exists(),
            "fixture {}: source {} is missing — fix or remove its FIXTURES entry",
            dir_name,
            src.display()
        );
        assert!(
            committed.exists(),
            "fixture {}: committed {} is missing — regenerate it or remove its FIXTURES entry",
            dir_name,
            committed.display()
        );

        let outdir = tempdir(&format!("codegen-regen-{}", dir_name));
        // `--target rust` selects the Rust backend only. This doubles as the
        // gate's coverage of the flag: nothing else in CI exercises `--target`,
        // and a regression in its parsing would show up here as every fixture
        // "drifting" (no lib.rs emitted at all) rather than as a flag bug — so
        // read a total wipeout as a flag problem before a codegen one.
        // Skipping TypeScript costs nothing; the gate reads only lib.rs.
        let status = Command::new(&compactc)
            .arg("--target")
            .arg("rust")
            .arg("--skip-zk")
            .arg(&src)
            .arg(&outdir)
            .status()
            .expect("failed to spawn compactc");
        assert!(
            status.success(),
            "compactc failed for {} (exit {:?})",
            src_name,
            status.code()
        );

        let regen = outdir.join("contract/lib.rs");
        let regen_bytes = std::fs::read(&regen)
            .unwrap_or_else(|e| panic!("read regen {}: {}", regen.display(), e));
        let committed_bytes = std::fs::read(&committed)
            .unwrap_or_else(|e| panic!("read committed {}: {}", committed.display(), e));

        if regen_bytes != committed_bytes {
            drift.push((dir_name.to_string(), regen.clone(), committed.clone()));
        }

        // Best-effort cleanup; ignore errors so a stale dir doesn't fail
        // the test.
        let _ = std::fs::remove_dir_all(&outdir);
    }

    if !drift.is_empty() {
        let summary: String = drift
            .iter()
            .map(|(name, regen, committed)| {
                format!(
                    "  - {}: regen={} vs committed={}",
                    name,
                    regen.display(),
                    committed.display()
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        panic!(
            "compactc --rust output drifted from committed fixtures \
             ({} drift{}):\n{}\n\n\
             To investigate: diff each pair above. If the regen is correct, \
             update the committed lib.rs. If the regen is wrong, fix the Scheme \
             rust-passes and rerun this test.",
            drift.len(),
            if drift.len() == 1 { "" } else { "s" },
            summary
        );
    }
}

/// Every `FIXTURES` row's generated crate MUST also be a dev-dependency of
/// `tests-e2e-rust`.
///
/// Workspace membership alone does not make `cargo build -p tests-e2e-rust
/// --tests` (the CI build gate) compile a crate — only a dependency edge
/// does. A registered fixture whose crate is not a dev-dependency is
/// therefore byte-compared by the gate above but never compiled, so a
/// codegen change that emits non-compiling Rust for it would pass CI. That
/// is exactly how `compact-contract-multi-pl-call-fixture` was invisible.
///
/// This test is deliberately compiler-free: it only reads the `FIXTURES`
/// table defined above and the crate manifest, so it also runs on the
/// bare no-Nix `test` matrix, where it is the only thing keeping the two
/// registrations in sync.
#[test]
fn every_fixture_crate_is_a_dev_dependency() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let cargo_toml_path = manifest_dir.join("Cargo.toml");
    let cargo_toml = std::fs::read_to_string(&cargo_toml_path)
        .unwrap_or_else(|e| panic!("read {}: {}", cargo_toml_path.display(), e));

    // Keys declared under `[dev-dependencies]`, which runs until the next
    // top-level `[section]` header. Fixture packages are named exactly
    // `compact-contract-<dir-name>`, so the `FIXTURES` dir-name is enough to
    // derive the expected key. (This mirrors the manifest's own convention;
    // the assertion below fails loudly if that convention ever drifts.)
    let mut dev_deps = BTreeSet::new();
    let mut in_dev_deps = false;
    for raw in cargo_toml.lines() {
        let line = raw.trim();
        if line.starts_with('[') {
            in_dev_deps = line == "[dev-dependencies]";
            continue;
        }
        if !in_dev_deps || line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, _)) = line.split_once('=') {
            dev_deps.insert(key.trim().to_string());
        }
    }
    assert!(
        !dev_deps.is_empty(),
        "parsed no [dev-dependencies] from {} — this test's parser no longer \
         matches the manifest layout",
        cargo_toml_path.display()
    );

    let missing: Vec<String> = FIXTURES
        .iter()
        .map(|(_, dir_name)| format!("compact-contract-{}", dir_name))
        .filter(|crate_name| !dev_deps.contains(crate_name))
        .collect();

    assert!(
        missing.is_empty(),
        "codegen_regression FIXTURES row(s) are not tests-e2e-rust dev-dependencies: {:?}\n\
         A workspace member in the root Cargo.toml does not make `cargo build \
         -p tests-e2e-rust --tests` compile the crate; only a dev-dependency edge does, \
         so these fixtures would be byte-compared but never compiled. Add each as \
         `compact-contract-<dir-name> = {{ path = \"contracts/<dir-name>\" }}` under \
         `[dev-dependencies]` in {} (and refresh Cargo.lock so every `--locked` gate \
         stays valid), then reference the crate from a `tests/<dir-name>.rs`.",
        missing,
        cargo_toml_path.display()
    );
}

/// Create a fresh temp dir under `$TMPDIR/<prefix>-<pid>-<nanos>`. Used
/// per-fixture so parallel test runs (or restarts after a panic) don't
/// collide. Kept dependency-free — `tempfile` isn't in the workspace.
fn tempdir(prefix: &str) -> PathBuf {
    use std::time::{SystemTime, UNIX_EPOCH};
    let base = std::env::temp_dir();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id();
    let dir = base.join(format!("{}-{}-{}", prefix, pid, nanos));
    std::fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("mkdir {}: {}", dir.display(), e));
    dir
}
