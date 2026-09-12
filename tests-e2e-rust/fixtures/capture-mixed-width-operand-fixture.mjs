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

// SPDX-License-Identifier: Apache-2.0
//
// Capture TS reference state for mixed_width_operand_fixture.compact's
// initial_state(). Two ledger fields (`lastDiff: Uint<32>`,
// `mixedOps: Counter`), nine exported pure circuits covering every
// comparison operator with a range-widened operand plus mixed-width
// arithmetic, two exported impure circuits (`recordPinned`,
// `recordMatching`), and a constructor whose body computes a
// mixed-width guarded subtraction (`base - q * 4`) and writes the
// result to `lastDiff` — the state captured here pins the constructor
// route (including its widened underflow guard) against the Rust side
// (tests/mixed_width_operand_fixture.rs).
//
// The constructor arguments are 4294967295n (Uint<32> max) and
// 1073741823n: the product q * 4 = 4294967292 sits 3 below the 2^32
// boundary, so the guard's widened `base >= q * 4` comparison operates
// at the very top of the u32 range where a mis-directed cast would
// flip its outcome, and `lastDiff` initialises to 3.
// (CAPTURE_BASE / CAPTURE_Q in tests/mixed_width_operand_fixture.rs
// must stay in sync.)
//
// Products that exceed 2^32 outright cannot appear in a PASSING
// constructor here (`q * 4 <= base <= Uint<32>::MAX` is the guard), so
// the true crossings live in the pure circuits — the executing test
// drives assertProductGT/GE/NE and sumMixed/productMixed with q near
// Uint<32>::MAX, where a truncating cast changes the answer.
//
// Usage:
//   compactc --target ts --skip-zk examples/mixed_width_operand_fixture.compact /tmp/mixed-width-ts-driver/
//   echo '{"type":"module"}' > /tmp/mixed-width-ts-driver/contract/package.json
//   ln -sfn "$PWD/node_modules" /tmp/mixed-width-ts-driver/contract/node_modules
//   node tests-e2e-rust/fixtures/capture-mixed-width-operand-fixture.mjs \
//     > tests-e2e-rust/fixtures/mixed-width-operand-fixture-ts-state.json

import { Contract } from '/tmp/mixed-width-ts-driver/contract/index.js';
import * as cr from '@midnight-ntwrk/compact-runtime';

const witnesses = {};
const contract = new Contract(witnesses);

const emptyCpk = { bytes: new Uint8Array(32) };
const constructorCtx = {
  initialPrivateState: null,
  initialZswapLocalState: cr.emptyZswapLocalState(emptyCpk),
};

const initResult = contract.initialState(constructorCtx, 4294967295n, 1073741823n);
const afterInitContractState = initResult.currentContractState;

const afterInitHex = Buffer.from(afterInitContractState.serialize()).toString('hex');

const fixture = {
  afterInit: { stateHex: afterInitHex },
};

process.stdout.write(JSON.stringify(fixture, null, 2) + '\n');
