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
// literal_coercion_fixture.compact executing gate.
//
// The fixture puts a bare literal (or a Uint value) in every position
// where the typechecker had to be honoured by the emitter — Field const
// RHS, struct Field member, `some<Field>(0)`, `persistentHash([0])`, a
// native argument, a pure-circuit argument, a return tail, a scalar
// Uint→Field, and an aggregate Field vector. Before the fix each such
// position emitted an un-typed Rust integer (`0`, ambiguous
// `AlignedValue::from(0)`, an `i32` where `Fr` was required) and the
// generated crate failed `cargo build`.
//
// Three assertions:
//   1. `initial_state()` serialised bytes match the TS reference — this
//      pins the destination-typed LEDGER writes (Field / Uint<64> /
//      `Vector<2, Field>` / `Bytes<32>` / `JubjubPoint`) including the
//      coerced hash and curve-point values.
//   2. each pure circuit returns the intended coerced value (the
//      round-trip), driven directly in Rust — the pure circuits have no
//      TS-side runtime entry point.

use compact_contract_literal_coercion_fixture::{ledger, pure_circuits, Contract};
use midnight_compact_runtime::*;
use midnight_serialize::tagged_serialize;
use midnight_storage::storage::HashMap;
use tests_e2e_rust::SmallFixtureTsReference;

fn fixture() -> SmallFixtureTsReference {
    SmallFixtureTsReference::load(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/fixtures/literal-coercion-fixture-ts-state.json"
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

/// The fixture has no impure circuits, so the operations map is empty; the
/// pure circuits live in `pure_circuits` and contribute nothing to the
/// on-chain state shape.
fn make_envelope(
    data: ChargedState<midnight_storage::DefaultDB>,
) -> ContractState<midnight_storage::DefaultDB> {
    ContractState {
        data,
        operations: HashMap::new(),
        maintenance_authority: ContractMaintenanceAuthority::default(),
        balance: Default::default(),
    }
}

/// The constructor seeds five destination-typed cells from literal / coerced
/// values; the serialised state must equal the TS backend's byte-for-byte.
#[test]
fn literal_coercion_init_byte_parity() {
    let ts_ref = fixture();
    let contract: Contract<(), NoWitnesses> = Contract::new(NoWitnesses);
    let result = contract.initial_state(ctor_ctx()).expect("initial_state");

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

/// Each ledger cell holds the value its coerced write produced — in
/// particular the `Uint<64>` cell commits a u64-aligned value, and the
/// `Vector<2, Field>` cell holds Field elements, not Bytes-aligned Uints.
#[test]
fn constructor_seeds_the_destination_typed_cells() {
    let contract: Contract<(), NoWitnesses> = Contract::new(NoWitnesses);
    let result = contract.initial_state(ctor_ctx()).expect("initial_state");
    let view = ledger(&result.current_contract_state);

    assert_eq!(view.field_cell().expect("field_cell"), Fr::from(0u64));
    assert_eq!(view.uint_cell().expect("uint_cell"), 0u64);
    assert_eq!(
        view.field_vec().expect("field_vec"),
        [Fr::from(0u64), Fr::from(0u64)]
    );
    assert_eq!(
        view.hash_cell().expect("hash_cell"),
        midnight_compact_runtime::std_lib::persistent_hash_aligned(&[
            AlignedValue::from(Fr::from(0u64)),
            AlignedValue::from(Fr::from(0u64)),
        ])
    );
    assert_eq!(
        view.point_cell().expect("point_cell"),
        midnight_compact_runtime::hash_to_curve(Fr::from(0u64))
    );
}

/// Every newly-covered value position round-trips: the emitted circuit
/// computes the intended Compact value, so the coercion produced the right
/// Rust type and value at each site.
#[test]
fn every_coerced_position_round_trips() {
    // Return-tail literal.
    assert_eq!(
        pure_circuits::ret_field_literal().expect("ret"),
        Fr::from(0u64)
    );
    // Field const RHS + pure-call argument literal.
    assert_eq!(
        pure_circuits::const_then_call().expect("const+call"),
        Fr::from(0u64)
    );
    // Struct Field-member literal.
    assert_eq!(
        pure_circuits::struct_literal().expect("struct").f,
        Fr::from(0u64)
    );
    // `some<Field>(0)`.
    assert_eq!(
        pure_circuits::some_field_literal().expect("some"),
        midnight_compact_runtime::std_lib::some(Fr::from(0u64))
    );
    // `persistentHash([0, 0])` — literal vector elements.
    assert_eq!(
        pure_circuits::hash_zero_literal().expect("hash"),
        midnight_compact_runtime::std_lib::persistent_hash_aligned(&[
            AlignedValue::from(Fr::from(0u64)),
            AlignedValue::from(Fr::from(0u64)),
        ])
    );
    // Native-argument literal.
    assert_eq!(
        pure_circuits::native_arg_literal().expect("native"),
        midnight_compact_runtime::hash_to_curve(Fr::from(0u64))
    );
    // Scalar Uint→Field (u64 rung).
    assert_eq!(
        pure_circuits::uint_to_field(200).expect("u8->field"),
        Fr::from(200u64)
    );
    // The wide Uint<128> rung is lossless (no reduction modulo the field).
    assert_eq!(
        pure_circuits::u128_rung(1u128 << 100).expect("u128->field"),
        Fr::from(1u128 << 100)
    );
    // Aggregate target: element-wise `Uint<32>` → `Field`.
    assert_eq!(
        pure_circuits::vector_elt_wise(7).expect("vector"),
        [Fr::from(7u64), Fr::from(7u64)]
    );
}

/// Field literals above `u64::MAX` are rendered at the Field width — the
/// `u128` rung, then the little-endian byte constructor above `u128::MAX` —
/// rather than a fixed `u64` literal that overflowed and failed
/// `cargo build` while `compactc` exited 0. Each literal-coercion call site
/// is exercised so no site can regress to the `u64`-only form.
#[test]
fn wide_field_literals_never_overflow_u64() {
    // `u128::MAX` — the top of the `u128` rung.
    assert_eq!(
        pure_circuits::ret_u128_field_literal().expect("u128 rung"),
        Fr::from(u128::MAX)
    );

    // 2^200 — above `u128::MAX`, so it takes the byte constructor. Pinning
    // the little-endian bytes proves the value is exactly the literal, not a
    // wrapped or truncated one.
    let huge = pure_circuits::ret_huge_field_literal().expect("huge literal");
    let mut expected = [0u8; 32];
    expected[25] = 1; // 2^200 = 0x01 << 200
    assert_eq!(huge.as_le_bytes(), expected.to_vec());

    // The remaining literal-coercion sites carry the same value.
    assert_eq!(
        pure_circuits::const_huge_field_literal().expect("const"),
        huge
    );
    assert_eq!(
        pure_circuits::call_arg_huge_field_literal().expect("call arg"),
        huge
    );
    assert_eq!(
        pure_circuits::struct_member_huge_field_literal()
            .expect("struct member")
            .f,
        huge
    );
    assert_eq!(
        pure_circuits::vector_elt_huge_field_literal().expect("vector elt"),
        [huge]
    );
    assert!(pure_circuits::cmp_huge_field_literal(huge).expect("cmp huge"));
    assert!(!pure_circuits::cmp_huge_field_literal(Fr::from(0u64)).expect("cmp zero"));
}
