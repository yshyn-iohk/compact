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
// Mixed-width operand executing gate.
//
// mixed_width_operand_fixture.compact puts a range-widened operand
// (`q * 4` on `q: Uint<32>` — value range Uint<0..17179869180>, minimal
// Rust width u64) against a Uint<32>-ranged one in every comparison
// operator, in mixed-width `+ - *`, in the guarded-subtraction route, in
// an impure inline equality, and in the constructor.
//
// Ported from PR #70's fixture, minus its ternary-dependent
// `assertQuotientPinned`/`recordPinned` dogfood shape: ternary
// EXPRESSIONS are the sibling `fix-ternary-expression-codegen` change.
//
// Byte-parity (codegen_regression) locks the generated TEXT, but a
// widening cast can be truncating, dropped, or pointed the wrong way
// and still compile — and still byte-match a wrong emitter. Only values
// discriminate. Every "detector" case below is chosen so that the
// correct zero-extending cast and a truncating one DISAGREE: with
// `q = Uint<32>::MAX`, `q * 4 = 17179869180`, which truncated to u32 is
// `4294967292` — a different number that flips the affected comparison
// or sum. A correctly-widened `y` compared against the full-width
// product is the mirror image (e.g. `guarded_diff` at the top of the
// u32 range).
#![allow(clippy::unit_arg)]

use compact_contract_mixed_width_operand_fixture::{ledger, pure_circuits, Contract};
use midnight_compact_runtime::*;
use midnight_serialize::tagged_serialize;
use midnight_storage::storage::HashMap;
use tests_e2e_rust::SmallFixtureTsReference;

/// Constructor arguments used on BOTH sides of the byte-parity capture
/// (capture-mixed-width-operand-fixture.mjs must stay in sync):
/// `CAPTURE_BASE - CAPTURE_Q * 4 = 4294967295 - 4294967292 = 3`, with
/// the widened underflow guard comparing at the very top of the u32
/// range (`4294967295 >= 4294967292`).
const CAPTURE_BASE: u32 = u32::MAX;
const CAPTURE_Q: u32 = 1_073_741_823;

/// `q = Uint<32>::MAX`: `q * 4 = 17179869180` exceeds 2^32, and its
/// u32 truncation is `4294967292` — the value every detector case
/// pivots on.
const Q_MAX: u32 = u32::MAX;

fn fixture() -> SmallFixtureTsReference {
    SmallFixtureTsReference::load(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/fixtures/mixed-width-operand-fixture-ts-state.json"
    ))
}

fn ctor_ctx() -> ConstructorContext<()> {
    ConstructorContext {
        initial_private_state: (),
        empty_zswap_local_state: ZswapLocalState::default(),
        cost_model: INITIAL_COST_MODEL.clone(),
        gas_limit: None,
    }
}

/// Build a `ContractState` envelope around a freshly minted `ChargedState`.
/// The fixture exports two IMPURE circuits (`recordPinned`,
/// `recordMatching`); the operations map must register both to match the
/// TS-side `initialState()` output (the nine pure circuits live in
/// `pure_circuits` and are not part of the dispatch map).
fn make_envelope(
    data: ChargedState<midnight_storage::DefaultDB>,
) -> ContractState<midnight_storage::DefaultDB> {
    let mut operations: HashMap<EntryPointBuf, ContractOperation, midnight_storage::DefaultDB> =
        HashMap::new();
    for name in ["recordPinned", "recordMatching"] {
        operations = operations.insert(
            EntryPointBuf(name.as_bytes().to_vec()),
            ContractOperation::new(None),
        );
    }
    ContractState {
        data,
        operations,
        maintenance_authority: ContractMaintenanceAuthority::default(),
        balance: Default::default(),
    }
}

/// The constructor route's byte-parity gate: the TS backend's
/// `initialState(ctx, 4294967295n, 1073741823n)` and the Rust
/// `initial_state(ctx, ...)` must produce identical `ContractState`
/// bytes. The constructor body carries the mixed-width guarded
/// subtraction, so this pins that route's widened guard against the TS
/// reference, not just against yesterday's Rust.
#[test]
fn mixed_width_fixture_init_byte_parity() {
    let ts_ref = fixture();
    let contract: Contract<(), NoWitnesses> = Contract::new(NoWitnesses);
    let result = contract
        .initial_state(ctor_ctx(), CAPTURE_BASE, CAPTURE_Q)
        .expect("initial_state");

    let envelope = make_envelope(result.current_contract_state.clone());
    let mut buf = Vec::new();
    tagged_serialize(&envelope, &mut buf).expect("tagged_serialize");

    let ts_bytes = ts_ref.after_init.state_bytes();
    assert_eq!(
        buf,
        ts_bytes,
        "Rust state bytes differ from TS reference\n\nRust ({} B): {}\n\nTS   ({} B): {}",
        buf.len(),
        hex::encode(&buf),
        ts_bytes.len(),
        hex::encode(&ts_bytes),
    );
}

/// The constructor's guarded difference: `lastDiff` holds
/// `base - q * 4` computed through the widened guard, and `mixedOps`
/// keeps its zero seed.
#[test]
fn constructor_guarded_diff_writes_the_difference() {
    let contract: Contract<(), NoWitnesses> = Contract::new(NoWitnesses);
    let result = contract
        .initial_state(ctor_ctx(), CAPTURE_BASE, CAPTURE_Q)
        .expect("initial_state");
    let view = ledger(&result.current_contract_state);
    assert_eq!(view.last_diff().expect("last_diff"), 3);
    assert_eq!(view.mixed_ops().expect("mixed_ops"), 0);
}

/// `<=`: the pass side sits at the top of the range (product =
/// `2^32 - 4`); the fail side's product is `17179869180` (`4 * 2^32 -
/// 4`), which truncates to `2^32 - 4` under a u32 wrap — a
/// truncating cast would wrongly pass, so this fail side doubles as
/// the truncation detector.
#[test]
fn assert_product_le_both_sides() {
    pure_circuits::assert_product_l_e(CAPTURE_Q, u32::MAX)
        .expect("4294967292 <= 4294967295 must hold");
    let err = pure_circuits::assert_product_l_e(Q_MAX, u32::MAX)
        .expect_err("17179869180 <= 4294967295 must fail");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "product must not exceed the bound"),
        "expected the bound assert, got {err:?}"
    );
}

/// `<`: pass side three below the bound; fail side equal to it, plus
/// the truncation detector (`Q_MAX * 4` truncates to `2^32 - 4 <
/// u32::MAX`, so a u32-wrapping product would wrongly pass).
#[test]
fn assert_product_lt_both_sides() {
    pure_circuits::assert_product_l_t(CAPTURE_Q, u32::MAX)
        .expect("4294967292 < 4294967295 must hold");
    let err = pure_circuits::assert_product_l_t(CAPTURE_Q, 4_294_967_292)
        .expect_err("4294967292 < 4294967292 must fail");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "product must stay below the bound"),
        "expected the bound assert, got {err:?}"
    );
    let err = pure_circuits::assert_product_l_t(Q_MAX, u32::MAX)
        .expect_err("17179869180 < 4294967295 must fail (truncation detector)");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "product must stay below the bound"),
        "expected the bound assert, got {err:?}"
    );
}

/// `>` DETECTOR: with `q = Uint<32>::MAX` the true product
/// `17179869180 > 4294967295` holds, but the truncated product
/// `4294967292` would fail — only a correctly widened comparison passes.
/// The pass side at exactly `2^32` and a within-range fail side pin the
/// operator's boundaries. (A product past `2^32` can never FAIL `>`
/// against a u32 `y`, so the fail side stays in range.)
#[test]
fn assert_product_gt_detector_and_fail_side() {
    pure_circuits::assert_product_g_t(Q_MAX, u32::MAX)
        .expect("17179869180 > 4294967295 needs the widened product");
    pure_circuits::assert_product_g_t(1_073_741_824, u32::MAX)
        .expect("2^32 > 2^32 - 1 needs the widened product");
    let err = pure_circuits::assert_product_g_t(CAPTURE_Q, u32::MAX)
        .expect_err("4294967292 > 4294967295 must fail");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "product must exceed the bound"),
        "expected the bound assert, got {err:?}"
    );
}

/// `>=` DETECTOR: `y = 4294967293` — the true product `17179869180` is
/// above it, the truncated `4294967292` is not. The equality boundary
/// (`4294967292 >= 4294967292`) and a one-below fail side pin the
/// operator itself.
#[test]
fn assert_product_ge_detector_equality_and_fail() {
    pure_circuits::assert_product_g_e(Q_MAX, 4_294_967_293)
        .expect("17179869180 >= 4294967293 needs the widened product");
    pure_circuits::assert_product_g_e(CAPTURE_Q, 4_294_967_292)
        .expect("4294967292 >= 4294967292 must hold");
    let err = pure_circuits::assert_product_g_e(CAPTURE_Q, 4_294_967_293)
        .expect_err("4294967292 >= 4294967293 must fail");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "product must reach the bound"),
        "expected the bound assert, got {err:?}"
    );
}

/// `==` DETECTOR (fail side): the true product `17179869180` differs
/// from `4294967292`, so the assert must FAIL; a truncated product
/// would equal it and wrongly pass. The pass side pins a genuine
/// equality at a non-trivial product.
#[test]
fn assert_product_eq_detector_and_pass() {
    pure_circuits::assert_product_e_q(CAPTURE_Q, 4_294_967_292)
        .expect("4294967292 == 4294967292 must hold");
    let err = pure_circuits::assert_product_e_q(Q_MAX, 4_294_967_292)
        .expect_err("17179869180 == 4294967292 must fail");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "product must equal the bound"),
        "expected the bound assert, got {err:?}"
    );
}

/// `!=` DETECTOR (pass side): the true product differs from
/// `4294967292`, so the assert passes; a truncated product would equal
/// it and wrongly fail.
#[test]
fn assert_product_ne_detector() {
    pure_circuits::assert_product_n_e(Q_MAX, 4_294_967_292)
        .expect("17179869180 != 4294967292 needs the widened product");
    let err = pure_circuits::assert_product_n_e(CAPTURE_Q, 4_294_967_292)
        .expect_err("4294967292 != 4294967292 must fail");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "product must differ from the bound"),
        "expected the bound assert, got {err:?}"
    );
}

/// Mixed-width `+` crossing 2^32: `Uint<32>::MAX + 255 =
/// 4294967550`, which a truncating cast would wrap to `254`.
#[test]
fn sum_mixed_crosses_the_boundary() {
    assert_eq!(
        pure_circuits::sum_mixed(u32::MAX, u8::MAX).expect("sum must compute"),
        4_294_967_550u64
    );
    assert_eq!(pure_circuits::sum_mixed(0, 0).expect("zero sum"), 0u64);
}

/// Mixed-width `*` deep past 2^32: `Uint<32>::MAX * 255 =
/// 1095216660225`.
#[test]
fn product_mixed_crosses_the_boundary() {
    assert_eq!(
        pure_circuits::product_mixed(u32::MAX, u8::MAX).expect("product must compute"),
        1_095_216_660_225u64
    );
    assert_eq!(
        pure_circuits::product_mixed(1, 1).expect("unit product"),
        1u64
    );
}

/// The guarded-subtraction route: the widened guard admits the
/// top-of-range product and the same-width `wrapping_sub` yields the
/// difference; on the underflow side the guard must fire (not wrap).
#[test]
fn guarded_diff_computes_and_traps() {
    assert_eq!(
        pure_circuits::guarded_diff(u32::MAX, CAPTURE_Q).expect("top-of-range difference"),
        3u32
    );
    assert_eq!(
        pure_circuits::guarded_diff(1_000, 250).expect("small difference"),
        0u32
    );
    let err = pure_circuits::guarded_diff(0, 1)
        .expect_err("0 - 4 must trip the underflow guard, not wrap");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "result of subtraction would be negative"),
        "expected the underflow guard, got {err:?}"
    );

    // Truncation detector: `1_073_741_824 * 4 = 2^32` exactly, so the
    // true difference is negative and the guard must fire; a u32-
    // wrapping product would truncate to `0` and wrongly return 1000.
    let err = pure_circuits::guarded_diff(1_000, 1_073_741_824)
        .expect_err("1000 - 2^32 must trip the underflow guard, not truncate to 1000");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "result of subtraction would be negative"),
        "expected the underflow guard, got {err:?}"
    );
}

/// The impure routes. `recordPinned` forwards the mixed-width ordering
/// asserts to the pure callee and increments `mixedOps` only when they
/// hold; `recordMatching` carries an INLINE mixed-width equality
/// (`Uint<8> == Uint<32>`, the ctor-path widening) and proves the
/// zero-extension is exact (7u8 == 7u32 passes; 7 != 8 fails before any
/// write).
#[test]
fn impure_circuits_forward_and_write() {
    let contract: Contract<(), NoWitnesses> = Contract::new(NoWitnesses);
    let init = contract
        .initial_state(ctor_ctx(), CAPTURE_BASE, CAPTURE_Q)
        .expect("initial_state");

    let after_pin = contract
        .record_pinned(
            CircuitContext::new(init.current_contract_state.clone(), ()),
            CAPTURE_Q,
            u32::MAX,
        )
        .expect("4294967292 <= 4294967295 must commit");
    let view = ledger(&after_pin.context.current_query_context.state);
    assert_eq!(view.mixed_ops().expect("mixed_ops"), 1);

    // `CircuitResults<(), ()>` is not `Debug`, which `expect_err`'s
    // `T: Debug` bound requires, so go through `.err().expect(...)`.
    #[allow(clippy::err_expect)]
    let err = contract
        .record_pinned(
            CircuitContext::new(after_pin.context.current_query_context.state.clone(), ()),
            Q_MAX,
            u32::MAX,
        )
        .err()
        .expect("invalid bound must propagate the assert");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "product must not exceed the bound"),
        "expected the bound assert, got {err:?}"
    );

    let after_match = contract
        .record_matching(
            CircuitContext::new(after_pin.context.current_query_context.state, ()),
            7,
            7,
        )
        .expect("7u8 == 7u32 must pass through the widening");
    let view = ledger(&after_match.context.current_query_context.state);
    assert_eq!(view.mixed_ops().expect("mixed_ops"), 2);

    #[allow(clippy::err_expect)]
    let err = contract
        .record_matching(
            CircuitContext::new(after_match.context.current_query_context.state, ()),
            7,
            8,
        )
        .err()
        .expect("7u8 != 8u32 must fail");
    assert!(
        matches!(err, CompactError::AssertionFailed(ref m) if m == "values must match across widths"),
        "expected the match assert, got {err:?}"
    );
}
