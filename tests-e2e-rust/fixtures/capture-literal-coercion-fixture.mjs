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

// Capture the TS backend's `initialState()` for
// literal_coercion_fixture.compact so the Rust crate's constructor output
// can be byte-compared. Three ledger fields (Field, Uint<64>,
// Vector<2, Field>), all seeded by literal writes in the constructor.
//
// Usage:
//   compactc --target ts --skip-zk examples/literal_coercion_fixture.compact /tmp/literal-coercion-ts-driver/
//   echo '{"type":"module"}' > /tmp/literal-coercion-ts-driver/contract/package.json
//   ln -sfn "$PWD/node_modules" /tmp/literal-coercion-ts-driver/contract/node_modules
//   node tests-e2e-rust/fixtures/capture-literal-coercion-fixture.mjs \
//     > tests-e2e-rust/fixtures/literal-coercion-fixture-ts-state.json

import { Contract } from '/tmp/literal-coercion-ts-driver/contract/index.js';
import * as cr from '@midnight-ntwrk/compact-runtime';

const contract = new Contract({});
const emptyCpk = { bytes: new Uint8Array(32) };
const constructorCtx = {
  initialPrivateState: null,
  initialZswapLocalState: cr.emptyZswapLocalState(emptyCpk),
};

const initResult = contract.initialState(constructorCtx);
const afterInitHex = Buffer.from(initResult.currentContractState.serialize()).toString('hex');

process.stdout.write(JSON.stringify({ afterInit: { stateHex: afterInitHex } }, null, 2) + '\n');
