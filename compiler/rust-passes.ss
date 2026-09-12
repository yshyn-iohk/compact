#!chezscheme

;;; This file is part of Compact.
;;; Copyright (C) 2025 Midnight Foundation
;;; SPDX-License-Identifier: Apache-2.0
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;; 	http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.

;;; Rust code generator — the entry point for the backend.
;;;
;;; Mirrors typescript-passes.ss in spirit: walks the
;;; post-prepare-for-typescript `Ltypescript` IR and emits a Rust crate
;;; (contract/lib.rs) depending on the `midnight-compact-runtime` crate.
;;; Running over the same IR as the TypeScript backend is what makes
;;; byte-parity between the two a checkable claim rather than an
;;; aspiration.
;;;
;;; The pass body below is `Program -> Program` identity; it exists for
;;; its effect, writing the crate through `out`. It is a leaf: nothing
;;; else in the compiler reads its output, and with `--target` absent it
;;; does not run.
;;;
;;; The eight included files are one `definitions` block, so every
;;; definition is visible to every other file — the split is for human
;;; navigation, not encapsulation. Include order matters for scope only.
;;;
;;; START HERE: compiler/README-rust-passes.md maps the modules, explains
;;; the walker/emit split and the three body routes, and states the
;;; rejection contract. docs/rust-backend-limitations.md lists what the
;;; backend refuses to lower and why.

(library (rust-passes)
  (export rust-passes)
  (import (except (chezscheme) errorf)
          (utils)
          (nanopass)
          (langs)
          (vm)
          (pass-helpers)
          (runtime-version))

  (define-pass print-rust : Ltypescript (ir) -> Ltypescript ()
    (definitions
      (include "rust-passes-helpers.ss")
      (include "rust-passes-types.ss")

      (include "rust-passes-prelude.ss")
      (include "rust-passes-decls.ss")

      (include "rust-passes-walker.ss")

      (include "rust-passes-streaming.ss")

      (include "rust-passes-emit.ss")

      (include "rust-passes-naming.ss"))

    (Program : Program (ir) -> Program ()
      [(program ,src ((,export-name* ,name*) ...) ,tdescs ,pelt* ...)
       (header)
       ;; M3.5-E4.4 Blocker 2: promote user types referenced ONLY by
       ;; non-exported pure circuits (e.g. zerocash's
       ;; `derive_nullifier(...): nullifier` — `nullifier` is mentioned
       ;; nowhere else on a publicly-reachable surface so the E2 walker
       ;; (analysis-passes) didn't promote it). We run a tiny scan here,
       ;; AFTER purity inference has set `id-pure?` correctly: collect
       ;; tstruct/tenum types referenced in non-exported user-pure
       ;; circuit sigs, then synthesise additional Ltypescript
       ;; export-typedef pelts and pass them to emit-type-decls.
       ;;
       ;; Bug-9: same scan also walks non-exported impure circuits whose
       ;; bodies are emitted as methods (per A18+A19), so user types in
       ;; their sigs (tiny.compact's `in_state(s: STATE)`) get a top-level
       ;; decl. The walkable check needs the id htables, so we build them
       ;; once up front and reuse them at the impure-emit site below.
       (let* ([all-tdefns (program-export-tdefns pelt*)]
              [native-id-ht (build-native-id-ht pelt*)]
              [witness-id-ht (build-witness-id-ht pelt*)]
              [circuit-id-ht (build-circuit-id-ht pelt*)]
              [extra-tdefns (collect-pure-circuit-tdefns
                              pelt* all-tdefns
                              native-id-ht witness-id-ht circuit-id-ht)]
              ;; Prefix-instantiation disambiguation tables (see
              ;; rust-passes-naming.ss). Built once from the export-name
              ;; alist + a full tstruct-node scan, then threaded via
              ;; current-id-rust-name-ht / current-struct-rust-name-ht so
              ;; every bare `(camel->snake (id-sym ...))` / struct-name
              ;; rendering site consults them. Non-colliding ids/structs
              ;; map to their bare names, so contracts without `import
              ;; M<...> prefix P_` collisions generate byte-identical
              ;; output.
              [circuit* (program-circuits pelt*)]
              [witness* (program-witnesses pelt*)]
              [native* (let loop ([ps pelt*] [acc '()])
                         (cond
                           [(null? ps) (reverse acc)]
                           [(native-pelt? (car ps)) (loop (cdr ps) (cons (car ps) acc))]
                           [else (loop (cdr ps) acc)]))]
              [ledger* (program-ledger-fields pelt*)]
              [export-alist (map cons export-name* name*)]
              [id-rust-name-ht (build-id-rust-name-ht export-alist circuit*)]
              ;; build-struct-rust-name-ht returns `(node-ht . fp-ht)`: the
              ;; eq?-node table for collected sig nodes and the fingerprint
              ;; table for body-site nodes. Both are installed so
              ;; struct-rust-name resolves either.
              [struct-rust-name-hts
                (build-struct-rust-name-ht
                  (append all-tdefns extra-tdefns)
                  circuit* witness* native* ledger*)])
         (parameterize ([current-id-rust-name-ht id-rust-name-ht]
                        [current-struct-rust-name-ht (car struct-rust-name-hts)]
                        [current-struct-rust-name-fp-ht (cdr struct-rust-name-hts)])
           (emit-type-decls (append all-tdefns extra-tdefns))
         (emit-witnesses (program-witnesses pelt*))
         (emit-contract-struct)
         ;; Iter 7: seed current-ledger-field-types from the program's
         ;; ledger fields once at the pass top so the constructor body and
         ;; every impure circuit body see the same path-idx → binding-type
         ;; map. emit-body-writes consults this to choose `new_cell_array`
         ;; vs `new_cell` for Vector<N,T> destinations.
         (parameterize ([current-ledger-field-types
                          (build-ledger-field-type-ht
                            (apply append
                              (map (lambda (lf)
                                     (nanopass-case (Ltypescript Program-Element) lf
                                       [(public-ledger-declaration ,pl-array ,lconstructor)
                                        (pl-array->public-bindings pl-array)]
                                       [else '()]))
                                   (program-ledger-fields pelt*))))])
           (emit-initial-state (program-ledger-fields pelt*)
                               (program-constructor-args pelt*)
                               pelt*)
           ;; Walk circuit declarations and split on purity. Impure circuits
           ;; become methods on the open Contract impl block; pure circuits are
           ;; collected for the pure_circuits module below.
           (let* ([circuit* (program-circuits pelt*)]
                  [pure-circuit*
                   (let loop ([c* circuit*] [acc '()])
                     (cond
                       [(null? c*) (reverse acc)]
                       [(id-pure? (circuit-function-name (car c*)))
                        (loop (cdr c*) (cons (car c*) acc))]
                       [else (loop (cdr c*) acc)]))])
             ;; Emit impure circuits as methods on the contract impl.
             ;;
             ;; EXPORTED impure circuits are part of the contract's public
             ;; surface and always emit (the emitter's per-circuit body
             ;; dispatch may still throw "no walker shape matched" if its
             ;; body shape isn't supported — that's the failure surface
             ;; users see as the codegen-rust frontier).
             ;;
             ;; NON-EXPORTED impure circuits are private helpers, e.g.
             ;; a `recordWrite` bookkeeping circuit or an
             ;; `assertWritable` guard. They emit ONLY if their body
             ;; is walkable in the current dispatcher — otherwise we skip
             ;; them silently (their callers inline them via the
             ;; assert-cond-rust inline-circuit-call path, or the caller's
             ;; body itself isn't walkable and the failure surfaces there).
             ;; This keeps non-exported helpers like tiny.compact's
             ;; `in_state` (non-unit single return-expression — not yet a
             ;; supported body shape) from forcing a hard error before
             ;; their callers ever invoke them.
             (for-each
               (lambda (c)
                 (when (and (not (id-pure? (circuit-function-name c)))
                            (or (id-exported? (circuit-function-name c))
                                (impure-circuit-body-walkable?
                                  c native-id-ht witness-id-ht circuit-id-ht)))
                   (emit-impure-circuit c native-id-ht witness-id-ht circuit-id-ht)))
               circuit*)
             (close-contract-struct)
             (emit-ledger-view (program-ledger-fields pelt*))
             (emit-pure-circuits pure-circuit* native-id-ht
                                  witness-id-ht circuit-id-ht))))
         ;; Task 4.1: everything has been buffered through `out`; refuse if a
         ;; spliced sentinel reached the text, else write lib.rs. A refusal
         ;; here leaves no lib.rs (the target-port exception handler deletes
         ;; the still-empty file).
         (flush-rust-output! src)
         (emit-cargo-toml))
       ir]))

  (define-passes rust-passes
    (print-rust          Ltypescript)))