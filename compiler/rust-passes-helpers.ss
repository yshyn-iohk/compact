;;; This file is part of Compact.
;;; Copyright (C) 2026 Midnight Foundation
;;; SPDX-License-Identifier: Apache-2.0
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;  	http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.

;;; Shared foundations for the Rust backend.
;;;
;;; Owns `out` (the emit port every renderer writes through) and
;;; `rust-feature-error` — the single mechanism by which an unsupported
;;; construct aborts the compile. There is no fallback path and there must
;;; not be one; see docs/rust-backend-limitations.md for what happens when
;;; that rule is broken. Also holds name mangling (`id->rust-name`,
;;; `struct-rust-name`) and small predicates shared across the passes.
;;;
;;; Included first, so everything here is in scope for every other file.
;;; See compiler/README-rust-passes.md for the module map.

      ;; current-rust-output: reverse-accumulated `lib.rs` fragments. `out`
      ;; buffers rather than writing straight through so the whole text can be
      ;; scanned for a spliced sentinel BEFORE it reaches the output port
      ;; (task 4.1). `flush-rust-output!` is called once at the end of
      ;; print-rust's Program clause; a sentinel hit raises a located
      ;; `rust-feature-error` and the target-port exception handler deletes the
      ;; (still-empty) file, so a broken render never leaves a lib.rs behind.
      (define current-rust-output
        (make-parameter '()))

      (define (out s)
        (current-rust-output (cons s (current-rust-output))))

      ;; rust-false-sentinel-index: the index of a spliced `#f` token in `s`,
      ;; or #f. The Scheme `#f` reaches the output only when a renderer that
      ;; could not lower an expression has its `#f` fed to `format`/string
      ;; concatenation by an unchecked caller — the silent-bad-output failure
      ;; this guard exists to stop. A `#f` that is part of a Rust string/char
      ;; literal or a comment is ignored, as is a raw identifier (`r#foo`,
      ;; which the emitter produces for keyword-named enum variants), so only
      ;; an actual spliced token is flagged.
      (define (rust-false-sentinel-index s)
        (let ([n (string-length s)])
          (define (id-char? c)
            (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))
          (define (at2? i a b)
            (and (fx<= (fx+ i 2) n)
                 (char=? (string-ref s i) a)
                 (char=? (string-ref s (fx+ i 1)) b)))
          (let loop ([i 0] [in-str? #f] [in-line-comment? #f] [block-depth 0])
            (cond
              [(fx>= i n) #f]
              [in-line-comment?
               (if (char=? (string-ref s i) #\newline)
                   (loop (fx+ i 1) #f #f 0)
                   (loop (fx+ i 1) #f #t 0))]
              [(fx> block-depth 0)
               (cond
                 [(at2? i #\* #\/) (loop (fx+ i 2) #f #f (fx- block-depth 1))]
                 [(at2? i #\/ #\*) (loop (fx+ i 2) #f #f (fx+ block-depth 1))]
                 [else (loop (fx+ i 1) #f #f block-depth)])]
              [in-str?
               (cond
                 [(char=? (string-ref s i) #\\) (loop (fx+ i 2) #t #f 0)]
                 [(char=? (string-ref s i) #\") (loop (fx+ i 1) #f #f 0)]
                 [else (loop (fx+ i 1) #t #f 0)])]
              [(char=? (string-ref s i) #\") (loop (fx+ i 1) #t #f 0)]
              [(at2? i #\/ #\/) (loop (fx+ i 2) #f #t 0)]
              [(at2? i #\/ #\*) (loop (fx+ i 2) #f #f 1)]
              [(and (char=? (string-ref s i) #\#)
                    (fx< (fx+ i 1) n)
                    (char=? (string-ref s (fx+ i 1)) #\f)
                    (or (fx= i 0)
                        (not (id-char? (string-ref s (fx- i 1)))))
                    (or (fx= (fx+ i 2) n)
                        (not (id-char? (string-ref s (fx+ i 2))))))
               i]
              [else (loop (fx+ i 1) #f #f 0)]))))

      ;; flush-rust-output!: scan the buffered lib.rs for a spliced sentinel
      ;; and either refuse (located at `src`) or write it out. Called once,
      ;; after every `out`.
      (define (flush-rust-output! src)
        (let ([text (apply string-append (reverse (current-rust-output)))])
          (let ([i (rust-false-sentinel-index text)])
            (when i
              (rust-feature-error src 'sentinel-splice
                "an expression reached a position the renderer could not lower; refused rather than emit a `#f` sentinel (near byte ~a)"
                i)))
          (display-string text (get-target-port 'contract.rs))))

      ;; rust-feature-error: raises a compactc error tagged with the
      ;; `--target rust:` prefix when the codegen hits an unsupported Compact
      ;; construct. Use this in place of emitting `unimplemented!()`
      ;; Rust into the output — contracts that would otherwise compile
      ;; but panic at runtime now fail at compile time with a clear
      ;; message.
      ;;
      ;; Prefer this over external-errorf when you have a source object
      ;; (most IR nodes carry `,src`); falls back to external-errorf
      ;; when src is #f.
      ;;
      ;; The `tag` argument is a short stable identifier (e.g.
      ;; 'struct-literal-mismatch, 'enum-ref-non-tenum, 'witness-inline)
      ;; — useful for users grepping the codegen to see what they hit
      ;; and for future cross-references in docs.
      ;; stmt-src: best-effort source location for a Statement.
      ;;
      ;; Most Ltypescript Statement productions carry `src` as their first
      ;; field, but there is no accessor for it — callers normally reach the
      ;; src through an expression they are already destructuring. A rejection
      ;; raised at statement granularity has no such expression in hand, so
      ;; this recovers the location for the diagnostic.
      ;;
      ;; Only forms confirmed to exist in Ltypescript are matched. The
      ;; productions change as the language chain extends and a pattern for a
      ;; form that no longer exists is a meta-parse failure at BUILD time, not
      ;; a runtime miss — `statement-expression`, notably, has no src by this
      ;; point. Anything unmatched yields #f and rust-feature-error reports
      ;; without a location, because a missing location must never turn a
      ;; clear rejection into a crash.
      (define (stmt-src stmt)
        (nanopass-case (Ltypescript Statement) stmt
          [(seq ,src ,stmt* ... ,stmt^) src]
          [(if ,src ,expr ,stmt1 ,stmt2) src]
          [(const ,src (,local* ...)) src]
          [else #f]))

      (define (rust-feature-error src tag msg . args)
        (let ([prefixed (format "compactc --target rust: unsupported Compact construct (~a): ~a"
                                tag (apply format msg args))])
          (if src
              (source-errorf src "~a" prefixed)
              (external-errorf "~a" prefixed))))

      ;; current-qctx-ref: Rust expression string referring to the
      ;; QueryContext that ledger-read sub-expressions should read from.
      ;; In circuit bodies this is `&ctx.current_query_context`; in the
      ;; constructor body it is `&qctx` (the local QueryContext we built
      ;; from the K1 seed). emit-body-or-fallback parameterizes this
      ;; before walking the body.
      (define current-qctx-ref
        (make-parameter "&ctx.current_query_context"))

      ;; current-witness-call-binds: alist of (witness-call-expr-node .
      ;; rust-name). Populated when the body walker hoists witness calls
      ;; out of an assert/condition expression to top-level `let`-bindings
      ;; (election.add_voter's `!path_of(pk).is_some` shape). Consulted by
      ;; ctor-call-rust before the "witness inline" TODO branch — when the
      ;; current call expression matches (by eq?-identity), we emit the
      ;; bound name instead of a TODO. Keys use eq? identity, so the same
      ;; IR node reference must flow from hoist to render.
      (define current-witness-call-binds
        (make-parameter '()))

      ;; current-impure-call-binds: A15 sibling of current-witness-call-binds
      ;; for non-pure user-circuit calls hoisted out of an assert/condition.
      ;; The canonical case is an assert whose condition negates a call to
      ;; an impure predicate circuit — `assert(!exists(id), ...)`. Each
      ;; entry is `(list function-name arg-expr*
      ;; rust-name)` mirroring the witness binds. Consulted by
      ;; ctor-call-rust's else branch BEFORE falling to call-rust (which
      ;; would error with "non-native-call"): on hit, the call renders as
      ;; `<rust-name>.result.clone()` referring to the hoisted
      ;; `let <rust-name> = self.<X>(ctx, args)?;` binding.
      (define current-impure-call-binds
        (make-parameter '()))

      ;; Module-1: when a generated `self.<cname>(ctx, args)?` call into
      ;; an impure circuit resolves to a stdlib-provided Rust impl,
      ;; redirect to that path so the caller never tries to look up a
      ;; method that doesn't exist on `Contract<PS, W>`. Currently
      ;; covers a Schnorr-on-Jubjub generic verifier — a circuit whose
      ;; snake-cased name is `schnorr_verify` (e.g. an imported
      ;; `schnorrVerify<#n>`), which doesn't appear in the generated
      ;; contract methods because the Compact body lowering for a
      ;; GENERIC impure circuit isn't supported; the defining module's
      ;; body would otherwise need to be lowered. Instead we reuse the
      ;; orphan-safe `midnight_compact_runtime::schnorr_verify_jubjub` wrapper
      ;; (see runtime-rs/src/std_lib/schnorr.rs) which calls the
      ;; off-circuit verifier. Covered by
      ;; examples/schnorr_attest_fixture.compact.
      (define (impure-call-target cname)
        (let ([cname-str
               (cond
                 [(string? cname) cname]
                 [(symbol? cname) (symbol->string cname)]
                 [else (format "~a" cname)])])
          (cond
            [(string=? cname-str "schnorr_verify")
             "midnight_compact_runtime::schnorr_verify_jubjub"]
            [else
             (format "self.~a" cname-str)])))

      ;; current-var-substitution: alist of (var-name . rust-rendered-string),
      ;; threaded dynamically by ctor-expr-rust so that downstream callees
      ;; reachable only through `expr-rust` (e.g. emit-ledger-read-expr →
      ;; expr->vm-value → expr-rust) can still resolve var-ref substitutions
      ;; that came from inline-circuit-call's formal-binds. Without this,
      ;; rendering `verificationMethodExists(disclosedMethodId)` inlined into
      ;; an assert leaks the inner formal `id` into the final Rust because
      ;; expr-rust's var-ref clause has no access to ctor-expr-rust's
      ;; explicit local-binds parameter. Default `'()` matches "no
      ;; substitution active" — expr-rust falls back to its plain snake-case
      ;; rendering. Bug-1 (post-A19 inventory).
      (define current-var-substitution
        (make-parameter '()))

      ;; current-circuit-id-ht: eq-hashtable mapping a circuit function-name
      ;; id to its circuit Program-Element, threaded dynamically by
      ;; emit-pure-circuit so that expr-rust/call-rust (which do NOT take
      ;; circuit-id-ht as an explicit argument) can still recognise a
      ;; call to a user-defined *pure* circuit and route it to
      ;; `pure_circuits::<snake>(...)`. Defaults to an empty hashtable so
      ;; the impure-walker path (which resolves pure-circuit calls via
      ;; ctor-call-rust's explicit circuit-id-ht argument before ever
      ;; reaching call-rust) is unaffected. Bug-1 companion to
      ;; current-var-substitution — closes the pure-circuit-body-emission
      ;; gap for contracts whose pure circuits call other user pure
      ;; circuits in tail/statement position (a validation circuit that
      ;; delegates to smaller `assertValid*` / `*Root` helpers, say).
      (define current-circuit-id-ht
        (make-parameter (make-eq-hashtable)))

      ;; current-witness-id-ht: companion to current-circuit-id-ht — the
      ;; witness-id-ht threaded by emit-pure-circuit so call-rust's
      ;; native/stdlib dispatch (and any future witness-aware path in the
      ;; pure walker) sees the real witness table. Defaults to an empty
      ;; hashtable.
      (define current-witness-id-ht
        (make-parameter (make-eq-hashtable)))

      ;; current-id-rust-name-ht: eq-hashtable mapping a circuit
      ;; function-name id to its disambiguated Rust name (a symbol).
      ;; Populated once in the Program pass from the export-name alist
      ;; plus an id-sym collision scan, then threaded dynamically so
      ;; every bare `(camel->snake (id-sym ...))` site (emit-pure-circuit
      ;; `pub fn`, emit-impure-circuit method name, call-rust / walker
      ;; `pure_circuits::<name>(...)` routing, hoisted-call `self.<name>`)
      ;; consults it via `id->rust-name`. Exported ids use the prefixed
      ;; export-name; non-exported ids whose id-sym collides with another
      ;; circuit id get a `_` + id-uniq suffix (mirroring the TS backend's
      ;; uniq-suffix disambiguation for `import M<...> prefix P_`
      ;; instantiations). Defaults to an empty hashtable so lookups miss
      ;; and `id->rust-name` falls back to `(camel->snake (id-sym id))` —
      ;; preserving pre-fix behaviour for code paths not under the
      ;; Program pass's parameterize.
      (define current-id-rust-name-ht
        (make-parameter (make-eq-hashtable)))

      ;; current-struct-rust-name-ht: eq-hashtable mapping a tstruct Type
      ;; NODE (eq? identity) to its disambiguated Rust struct name (a
      ;; symbol). Populated once in the Program pass by scanning every
      ;; tstruct type node in the program, fingerprinting it
      ;; (struct-name + rendered field types), and — for struct-names
      ;; shared by more than one distinct fingerprint — assigning
      ;; `Name`, `Name_1`, `Name_2`, ... so two `import M<...>`
      ;; instantiations that produce same-named but field-distinct
      ;; structs (two `RequestMessage`s from different instantiations of
      ;; the same generic module, say)
      ;; emit as distinct `pub struct`s and resolve consistently at every
      ;; type-rust rendering site. Defaults to an empty hashtable so
      ;; `struct-rust-name` falls back to the bare struct-name —
      ;; preserving byte-identical output for contracts with no struct-name
      ;; collisions (tiny / election / zerocash / pure_circuit_fixture).
      (define current-struct-rust-name-ht
        (make-parameter (make-eq-hashtable)))

      ;; current-struct-rust-name-fp-ht: equal?-hashtable mapping a struct
      ;; FINGERPRINT (see tstruct-fingerprint) to its disambiguated Rust
      ;; name. This is the resolution path for tstruct nodes that the
      ;; eq?-node table above never saw: struct literals, decoder turbofish,
      ;; and default expressions all appear in *statement bodies*, which
      ;; build-struct-rust-name-ht does not walk (it scans signatures /
      ;; typedefs / ledger only). A body-site node is a distinct IR object
      ;; from the sig node, so it misses the eq? table; keying on the
      ;; structural fingerprint instead lets it resolve to the same
      ;; disambiguated name. Defaults to empty so non-colliding structs fall
      ;; back to their bare name (byte-identical output for the common case).
      (define current-struct-rust-name-fp-ht
        (make-parameter (make-hashtable equal-hash equal?)))

      ;; id->rust-name: return the disambiguated Rust name symbol for a
      ;; circuit/witness/native function-name id. Consults
      ;; current-id-rust-name-ht; on a miss falls back to
      ;; `(camel->snake (id-sym id))` so non-parameterised call sites and
      ;; witness/native ids (which are never inserted into the table)
      ;; render exactly as before.
      (define (id->rust-name id)
        (let ([n (eq-hashtable-ref (current-id-rust-name-ht) id #f)])
          (if n n (camel->snake (id-sym id)))))

      ;; struct-rust-name: return the disambiguated Rust name symbol for a
      ;; tstruct Type node. Consults current-struct-rust-name-ht by eq?
      ;; on the node; on a miss falls back to the bare struct-name so
      ;; non-colliding structs (the common case) render unchanged.
      (define (struct-rust-name type)
        (nanopass-case (Ltypescript Type) type
          [(tstruct ,src ,struct-name (,elt-name* ,type*) ...)
           (let ([n (eq-hashtable-ref (current-struct-rust-name-ht) type #f)])
             (cond
               [n n]
               [else
                ;; eq? miss: a body-site node (struct literal / decoder /
                ;; default) that the sig scan never registered. Resolve by
                ;; structural fingerprint. Compute the fingerprint with the
                ;; disambiguation tables forced empty so nested user-struct
                ;; fields render as bare names — matching how the fp table
                ;; was built (build-struct-rust-name-ht runs before the
                ;; tables are installed), keeping the key stable regardless
                ;; of which table state is live at the call site.
                (let ([fp (parameterize ([current-struct-rust-name-ht (make-eq-hashtable)]
                                         [current-struct-rust-name-fp-ht (make-hashtable equal-hash equal?)])
                            (tstruct-fingerprint type))])
                  (or (hashtable-ref (current-struct-rust-name-fp-ht) fp #f)
                      struct-name))]))]
          [else
           (rust-feature-error #f 'struct-rust-name-non-tstruct
             "struct-rust-name called on non-tstruct type")]))

      ;; current-enum-ref-typed?: when #t, ctor-expr-rust renders an
      ;; `enum-ref` as `EnumName::r#variant` instead of the integer
      ;; discriminant. Used inside an `==` comparison whose other operand
      ;; renders as a typed enum value (e.g. a witness call returning a
      ;; tenum). The default #f preserves the existing integer rendering
      ;; against u8-decoded ledger reads — that path covers tiny.compact's
      ;; `state == STATE.unset` and election.commit/reveal's
      ;; `state.read() == PublicState.commit` where the ledger decoder
      ;; produces u8.
      (define current-enum-ref-typed?
        (make-parameter #f))

      ;; current-formal-arg-types: eq-hashtable mapping a var-name id-sym
      ;; → its declared Compact Type. Initialised from a circuit's formal
      ;; args by emit-impure-circuit / emit-pure-circuit before walking
      ;; the body. The body walker additionally mutates this table as it
      ;; processes const-bindings (so a const-bound witness result whose
      ;; declared return type is a tenum can flow into `==` rendering).
      ;;
      ;; Used by `==` rendering (via operand-typed-enum?) to detect when
      ;; a var-ref operand resolves to a tenum-typed name, so an
      ;; `enum-ref` on the other side renders as `EnumName::variant`
      ;; rather than the integer discriminant.
      (define current-formal-arg-types
        (make-parameter #f))

      ;; current-ledger-field-types: eqv-hashtable mapping a ledger
      ;; field's path-index (a non-negative integer) → its declared
      ;; binding Type (the tadt wrapper, e.g.
      ;; `(tadt Cell ([0 (tvector 3 (tunsigned ...))]) ...)`). Initialised
      ;; by `emit-initial-state` before walking the constructor body so
      ;; `emit-body-writes` can choose `new_cell_array(...)` vs
      ;; `new_cell(...)` based on the destination field's tvector-ness
      ;; (Iter 7). Defaults to #f when not parameterized — callers fall
      ;; back to the plain `new_cell(...)` shape, matching pre-Iter 7
      ;; behaviour.
      (define current-ledger-field-types
        (make-parameter #f))

      ;; current-arith-suffix: Rust unsigned-type suffix ("u8" / "u16" /
      ;; "u32" / "u64" / "u128") that wrapping_add / wrapping_sub /
      ;; wrapping_mul operands should carry on their integer-literal
      ;; receivers. Set by expr-rust's downcast-unsigned clause before
      ;; recursing into the wrapped arithmetic so Rust resolves the
      ;; inherent method on a concrete type rather than rejecting the
      ;; call as "ambiguous numeric type". `#f` outside arithmetic
      ;; contexts.
      ;;
      ;; Iter 7 follow-up: introduced to support non-identity lambdas
      ;; in `map()` (e.g. `(x * 2) as Uint<64>` lowering).
      (define current-arith-suffix
        (make-parameter #f))

      ;; current-expr-expected-type: the Compact Type that the expression
      ;; currently being rendered must produce, or #f when no use position
      ;; has declared one. Set by `expr-rust-typed` (and the constructor
      ;; walker's typed entry) so the renderers can materialise the
      ;; `safe-cast` the typechecker already inserted at every consequential
      ;; position, instead of discarding it. The default #f keeps the
      ;; no-expectation path byte-identical: every consult site only acts
      ;; when this is non-#f, so a boundary that has not opted in renders
      ;; exactly as before. See `materialize-at-type` below.
      (define current-expr-expected-type
        (make-parameter #f))

      ;; current-pure-return-type: the declared return Type of the pure
      ;; circuit whose body is being emitted, or #f outside a pure-circuit
      ;; body. The pure statement walker consults it in tail position so a
      ;; statement-lifted return tail (e.g. `return 0;` in a Field circuit)
      ;; materialises the typer's return-type `safe-cast` (task 2.2).
      (define current-pure-return-type
        (make-parameter #f))

      ;; A25: ctor-zswap-threaded? — set #t (within emit-ctor-body-or-fallback's
      ;; dynamic extent) once a constructor has threaded an impure-circuit call
      ;; through a local `_zswap` binding. impure-call-thread-lines flips it on
      ;; the first ctor impure call and seeds subsequent calls from `_zswap`;
      ;; the ConstructorResult emitters read it via `ctor-zswap-result-field` to
      ;; return the threaded `_zswap` instead of `ctx.empty_zswap_local_state`,
      ;; so zswap-local changes made by a constructor's impure calls survive.
      ;; Defaults #f, so every constructor without an impure call emits exactly
      ;; the pre-A25 `ctx.empty_zswap_local_state` (byte-parity preserved).
      (define ctor-zswap-threaded?
        (make-parameter #f))

      ;; A27: set #t within a non-streamed 'circuit body that contains an
      ;; impure-circuit call. When #t, impure-call-thread-lines accumulates each
      ;; callee's `gas_cost` into a `__gas_acc` local (declared at body start)
      ;; and the CircuitResults emitter returns `__gas_acc + results.gas_cost`
      ;; instead of only the terminal write's cost — so circuits like
      ;; rotateControllerKey / recoverControllerKey (which call assert helpers +
      ;; recordUpdate before the final write) do not under-report gas. Defaults
      ;; #f, so bodies without impure calls emit exactly the pre-A27 result
      ;; (byte-parity preserved). The streaming walker has its own `__gas_acc`.
      (define circuit-gas-acc?
        (make-parameter #f))

      ;; CircuitResults `gas_cost:` field for a non-streamed circuit. When the
      ;; body accumulated impure-helper gas (A27), return `__gas_acc +
      ;; results.gas_cost`; otherwise just the terminal write's cost.
      (define (circuit-gas-result-field)
        (if (circuit-gas-acc?)
            "            gas_cost: __gas_acc + results.gas_cost,\n"
            "            gas_cost: results.gas_cost,\n"))

      ;; ConstructorResult `current_zswap_local_state:` field line. Returns the
      ;; threaded `_zswap` local when a ctor impure call fed it (A25), else the
      ;; inbound `ctx.empty_zswap_local_state`.
      (define (ctor-zswap-result-field)
        (format "            current_zswap_local_state: ~a,\n"
                (if (ctor-zswap-threaded?) "_zswap" "ctx.empty_zswap_local_state")))

      ;; integer-literal-rendering?: returns #t when `s` is a string of
      ;; one or more decimal digits (with no suffix, no operator chars,
      ;; no parens). Used by arith-operand-rust to decide whether
      ;; appending a `u<width>` type suffix is safe — variable refs and
      ;; method-call expressions would be corrupted by suffix
      ;; concatenation, but a bare literal token can carry the suffix
      ;; directly (`1` + `u64` = `1u64`).
      (define (integer-literal-rendering? s)
        (and (string? s)
             (fx> (string-length s) 0)
             (let loop ([i 0])
               (cond
                 [(fx= i (string-length s)) #t]
                 [else
                  (let ([c (string-ref s i)])
                    (and (char>=? c #\0) (char<=? c #\9)
                         (loop (fx+ i 1))))]))))

      ;; build-ledger-field-type-ht: given the program's ledger-field*
      ;; Program-Element list, build an eqv-hashtable mapping each
      ;; binding's path-index (number) to its binding Type. Mirrors
      ;; `pl-array->public-bindings` + `binding-path-indices` /
      ;; `binding-type`, but those live in rust-passes-emit.ss; this
      ;; helper sits next to its parameter so the include order doesn't
      ;; matter.
      (define (build-ledger-field-type-ht public-bindings)
        (let ([ht (make-eqv-hashtable)])
          (for-each
            (lambda (pb)
              (nanopass-case (Ltypescript Public-Ledger-Binding) pb
                [(,src ,ledger-field-name (,path-index* ...) ,type)
                 (when (and (pair? path-index*) (number? (car path-index*)))
                   (hashtable-set! ht (car path-index*) type))]))
            public-bindings)
          ht))

      ;; build-formal-arg-type-ht: build an eq-hashtable seeded with a
      ;; circuit's (Argument*) list, mapping id-sym → Type. Always returns
      ;; a fresh table (even when arg* is empty) so the body walker has a
      ;; mutable home for const-binding types it discovers later.
      (define (build-formal-arg-type-ht arg*)
        (let ([ht (make-eq-hashtable)])
          (for-each
            (lambda (a)
              (nanopass-case (Ltypescript Argument) a
                [(,var-name ,type)
                 (eq-hashtable-set! ht (id-sym var-name) type)]))
            arg*)
          ht))

      ;; record-const-binding-type!: if rhs is a direct call into a
      ;; witness or pure circuit whose declared return type we know, add
      ;; `var-name → type` to current-formal-arg-types. Called from the
      ;; body walker on each const-binding so subsequent `==` rendering
      ;; can detect tenum-typed locals (e.g. election.vote$reveal's
      ;; `const vote = private$vote();` where private$vote returns
      ;; PermissibleVotes).
      (define (record-const-binding-type! var-name rhs
                                          witness-id-ht circuit-id-ht)
        (let ([ht (current-formal-arg-types)])
          (when ht
            (let ([t (infer-rhs-type rhs witness-id-ht circuit-id-ht)])
              (when t
                (eq-hashtable-set! ht (id-sym var-name) t))))))

      ;; infer-rhs-type: best-effort declared type of a const-binding RHS.
      ;; Currently recognises direct witness calls (the only shape we care
      ;; about for tenum detection); pure-circuit calls are handled too
      ;; for completeness. Strips talias / casts. Returns #f when the
      ;; shape isn't a recognised call.
      (define (infer-rhs-type rhs witness-id-ht circuit-id-ht)
        (let ([e (expr-strip-cast rhs)])
          (nanopass-case (Ltypescript Expression) e
            [(call ,src ,function-name ,expr* ...)
             (let ([w (eq-hashtable-ref witness-id-ht function-name #f)]
                   [c (eq-hashtable-ref circuit-id-ht function-name #f)])
               (cond
                 [w
                  (nanopass-case (Ltypescript Program-Element) w
                    [(witness ,src ,function-name (,arg* ...) ,type) type]
                    [else #f])]
                 [c (circuit-return-type c)]
                 [else #f]))]
            ;; `const tmp = default<T>;` — type is carried directly on
            ;; the node, so record it so arg-rust-clone-if-var can skip
            ;; redundant clones on Copy default values.
            [(default ,src ,type) type]
            [else #f])))

      ;; rust-keyword?: returns #t when the symbol matches a Rust reserved
      ;; keyword (strict + reserved). Enum variant names like
      ;; `final` (election.compact's PublicState.final) collide otherwise.
      ;; Callers escape such names with the `r#` raw-identifier prefix.
      (define rust-keyword?
        (let ([kws '(as async await break const continue crate do dyn
                     else enum extern false final fn for if impl in
                     let loop macro match mod move mut override priv
                     pub ref return self Self static struct super trait
                     true try type typeof unsafe unsized use virtual
                     where while yield abstract become box)])
          (lambda (sym) (and (memq sym kws) #t))))

      ;; rust-variant-name: render an enum variant name, escaping Rust
      ;; keywords via the raw-identifier `r#` prefix.
      (define (rust-variant-name sym)
        (if (rust-keyword? sym)
            (string-append "r#" (symbol->string sym))
            (symbol->string sym)))

      ;; camel->snake: convert a CamelCase / mixedCase identifier symbol
      ;; into snake_case. Used for witness method names. Also sanitises
      ;; Compact-allowed `$` characters (which Rust doesn't permit in
      ;; identifiers) by mapping them to `_`.
      (define (camel->snake s)
        (let* ([str (symbol->string s)]
               [chars (string->list str)])
          (string->symbol
            (apply string-append
              (let loop ([chars chars] [first? #t])
                (cond
                  [(null? chars) '()]
                  [(char-upper-case? (car chars))
                   (cons (if first? "" "_")
                         (cons (string (char-downcase (car chars)))
                               (loop (cdr chars) #f)))]
                  [(char=? (car chars) #\$)
                   (cons "_" (loop (cdr chars) #f))]
                  [else (cons (string (car chars)) (loop (cdr chars) #f))]))))))

      ;; uint-rust-width: given the declared max value `nat` of a
      ;; (tunsigned src nat) Compact type, pick the smallest Rust
      ;; unsigned integer type that fits. Compact's `tunsigned` stores
      ;; the maximum value (not bit width), e.g. `Uint<0..65535>` lowers
      ;; to (tunsigned src 65535). Mirrors the TS emitter's bigint
      ;; pattern but specializes to a sized Rust primitive.
      (define (uint-rust-width nat)
        (cond
          [(<= nat 255) "u8"]
          [(<= nat 65535) "u16"]
          [(<= nat 4294967295) "u32"]
          [(<= nat 18446744073709551615) "u64"]
          [else "u128"]))

      ;; uint-byte-length: number of bytes the on-state alignment uses to
      ;; hold values up to `nat`. ceil(bit_length / 8). Mirrors the TS
      ;; emitter's `(byte-length nat)` helper used by
      ;; `CompactTypeUnsignedInteger(maxValue, length)`. This is the
      ;; `AlignmentAtom::Bytes { length: ... }` parameter on the wire and
      ;; can differ from the Rust integer width's byte count for bounded
      ;; ranges (e.g. `Uint<0..70000>` is u32 in Rust but 3 bytes on state).
      (define (uint-byte-length nat)
        (let loop ([n nat] [bits 0])
          (if (= n 0)
              (if (= bits 0) 1 (div (+ bits 7) 8))
              (loop (div n 2) (+ bits 1)))))

      ;; uint-byte-length-matches-rust-width?: true when the on-state
      ;; byte-length equals the Rust integer width's byte count, i.e. the
      ;; fixed-width `Uint<N>` cases where N ∈ {8,16,32,64,128}. False for
      ;; bounded ranges with non-power-of-two byte-lengths (e.g. 3, 5, 6,
      ;; 7, 9..15). When false, codegen must route through
      ;; `new_cell_bounded_uint(value, byte_len)` to get TS-parity.
      (define (uint-byte-length-matches-rust-width? nat)
        (let ([bl (uint-byte-length nat)])
          (or (= bl 1) (= bl 2) (= bl 4) (= bl 8) (= bl 16))))

      ;; -----------------------------------------------------------------
      ;; Type-directed coercion (the single decision point).
      ;;
      ;; The typechecker already computes every coercion the language
      ;; requires and records it as a `(safe-cast <target> <src> expr)`
      ;; wrapper. `materialize-at-type` is the one place that turns an
      ;; expression plus an expected Compact type into correctly-typed Rust;
      ;; it returns #f when the un-ascribed rendering is already correct, so
      ;; neutral sites stay byte-identical. See the change design at
      ;; openspec/changes/type-directed-expression-coercion/.
      ;; -----------------------------------------------------------------

      ;; type-strip-alias: peel `talias` layers, returning the underlying
      ;; structural Type. The coercion decision recurses into aggregate
      ;; shapes (Vector<N, T>, tuples, and their nesting), so it needs
      ;; structural access rather than the scalar-only `type-is-tfield?`.
      (define (type-strip-alias type)
        (nanopass-case (Ltypescript Type) type
          [(talias ,src ,nominal? ,type-name ,type^) (type-strip-alias type^)]
          [else type]))

      ;; type-elt-types: when `type` is an aggregate of length `n` — a
      ;; `(tvector n T)` or a `(ttuple T ...)`, possibly reached through a
      ;; `talias` — return its element types in order; #f otherwise
      ;; (including a length mismatch). Bridges the IR's two aggregate
      ;; spellings: a `Vector<n, T>` target routinely arrives with a
      ;; `ttuple` source (the typer's element-wise join).
      (define (type-elt-types t n)
        (nanopass-case (Ltypescript Type) (type-strip-alias t)
          [(tvector ,src ,len ,type) (and (= len n) (make-list n type))]
          [(ttuple ,src ,type* ...) (and (= (length type*) n) type*)]
          [else #f]))

      ;; uint-coercion-cast-width: the Rust primitive that losslessly holds
      ;; every value of a `(tunsigned nat)` — "u64" through 2^64-1 (kept for
      ;; byte parity with the original scalar path), "u128" through 2^128-1,
      ;; #f above u128::MAX. `Uint<N>` stores its inclusive max
      ;; (`Uint<128>` -> 2^128-1), so the u128 rung covers every legal
      ;; Compact width: `impl From<u128> for Fr` exists upstream and the
      ;; field modulus is ~2^255, so `as u128` is a lossless zero-extension.
      (define (uint-coercion-cast-width nat)
        (cond
          [(<= nat 18446744073709551615) "u64"]
          [(<= nat 340282366920938463463374607431768211455) "u128"]
          [else #f]))

      ;; join-rendered: comma-separate rendered parts into a Rust array body.
      (define (join-rendered parts)
        (let loop ([xs parts] [acc ""])
          (cond
            [(null? xs) acc]
            [(null? (cdr xs)) (string-append acc (car xs))]
            [else (loop (cdr xs) (string-append acc (car xs) ", "))])))

      ;; field-uint-scalar: render a Uint->Field scalar coercion from an
      ;; already-rendered inner value (`inner-text`). The value is cast to
      ;; the width that losslessly holds the source range, then wrapped in
      ;; `Fr::from`. A range above u128::MAX has no lossless Rust cast and is
      ;; refused loudly rather than emitted as a bare (wrong-width) Uint.
      (define (field-uint-scalar src nat inner-text)
        (let ([w (uint-coercion-cast-width nat)])
          (if w
              (format "Fr::from((~a) as ~a)" inner-text w)
              (rust-feature-error src 'field-uint-coercion
                "a Uint source range up to ~a has no lossless coercion to Field (exceeds u128)"
                nat))))

      ;; field-literal-rust: render a compile-time Field literal `n` (a
      ;; non-negative exact integer) as a Rust `Fr` value. The lexer bounds
      ;; every numeric literal to `max-field` and Field arithmetic folds
      ;; modulo `max-field + 1`, so `n` is always a canonical field element.
      ;;
      ;; Small values go through the runtime's `u64` / `u128` `From` impls;
      ;; the `u64` rung keeps the pre-existing `Fr::from(<n>u64)` bytes for
      ;; the common small-literal case, so neutral output stays
      ;; byte-identical. A Field literal above `u128::MAX` (legal — `max-field`
      ;; is a ~2^255 value, well above `u128::MAX`) is rendered from its
      ;; little-endian bytes via `Fr::from_le_bytes`, whose canonical-range
      ;; check always succeeds for a lexer-admitted literal. Picking the
      ;; width from the Field domain — rather than a fixed `u64` — is what
      ;; stops `Fr::from(<n>u64)` from overflowing `u64` and failing
      ;; `cargo build` while `compactc` exits 0.
      (define (field-literal-rust n)
        (cond
          [(<= n 18446744073709551615) (format "Fr::from(~au64)" n)]
          [(<= n 340282366920938463463374607431768211455)
           (format "Fr::from(~au128)" n)]
          [else
           (format "Fr::from_le_bytes(&[~a]).expect(\"Field literal is canonical\")"
             (join-rendered
               (map (lambda (b)
                      (let ([s (number->string b 16)])
                        (format "0x~a"
                          (if (fx= (string-length s) 1)
                              (string-append "0" s)
                              s))))
                 (let loop ([n n] [i 0] [acc '()])
                   (if (fx= i 32)
                       (reverse acc)
                       (loop (ash n -8) (fx+ i 1)
                             (cons (bitwise-and n #xff) acc)))))))]))

      ;; render-inner-at: bind `expected` as the current expected type and
      ;; render a sub-expression. `materialize-at-type` owns the expected type
      ;; around every inner render: a scalar inner is rendered at its SOURCE
      ;; type (so any nested wrapper at that level still materialises), an
      ;; aggregate element at the ELEMENT type, and a bound aggregate value
      ;; with no expected type (it is coerced by index afterwards). The thunks
      ;; the callers pass are the raw renderers (`expr-rust` /
      ;; `ctor-expr-rust`); they never bind the parameter themselves.
      (define (render-inner-at expected render-inner expr)
        (parameterize ([current-expr-expected-type expected])
          (render-inner expr)))

      ;; materialize-scalar: the scalar coercion decision for `expr` of
      ;; `source-type` into `target-type`, with `render-inner` producing the
      ;; un-ascribed inner rendering. Returns the coerced Rust text, or #f
      ;; when no coercion is needed (same type / same Rust width / a literal
      ;; Rust can infer).
      (define (materialize-scalar src target-type source-type expr render-inner)
        (nanopass-case (Ltypescript Type) (type-strip-alias target-type)
          [(tfield ,src^)
           (let ([lit (literal-int-expr? expr)])
             (cond
               [lit (field-literal-rust lit)]
               [else
                (let ([nat (type-peel-tunsigned source-type)])
                  (and nat
                       (field-uint-scalar src nat
                         (render-inner-at source-type render-inner expr))))]))]
          [(tunsigned ,src^ ,nat)
           (let ([lit (literal-int-expr? expr)])
             (cond
               [lit (format "~a~a" lit (uint-rust-width nat))]
               [else
                (let ([nat-s (type-peel-tunsigned source-type)])
                  (and nat-s
                       (let ([wt (uint-rust-width nat)]
                             [ws (uint-rust-width nat-s)])
                         (and (not (equal? wt ws))
                              (format "((~a) as ~a)"
                                      (render-inner-at source-type render-inner expr)
                                      wt)))))]))]
          [else #f]))

      ;; materialize-element: coerce one aggregate element (a Tuple-Argument)
      ;; from `source-elt` to `target-elt`. A nested aggregate recurses; a
      ;; scalar materialises; an element that needs no conversion renders at
      ;; its own element type through `render-inner` so any wrapper already on
      ;; it still materialises.
      (define (materialize-element src target-elt source-elt tuple-arg render-inner)
        (nanopass-case (Ltypescript Tuple-Argument) tuple-arg
          [(single ,src^ ,expr)
           (or (materialize-at-type src^ target-elt source-elt expr render-inner)
               (render-inner-at target-elt render-inner expr))]
          [(spread ,src^ ,nat ,expr)
           (rust-feature-error src^ 'tuple-spread
             "tuple spread (`...expr`) not supported")]))

      ;; materialize-indexed-text: build the Rust array literal that coerces an
      ;; aggregate value already bound to `base-text` (a temp name) element by
      ;; element. Indexing recurses, so nested aggregates are coerced at every
      ;; depth. Returns #f when no element needs coercing.
      (define (materialize-indexed-text src target-elt* source-elt* base-text)
        (if (not (ormap (lambda (te se) (materialize-needed? te se))
                        target-elt* source-elt*))
            #f
            (string-append
              "["
              (join-rendered
                (let loop ([i 0] [te* target-elt*] [se* source-elt*] [acc '()])
                  (if (null? te*)
                      (reverse acc)
                      (let ([access (format "~a[~a]" base-text i)])
                        (loop (+ i 1) (cdr te*) (cdr se*)
                              (cons (or (materialize-at-type-text src (car te*) (car se*) access)
                                        access)
                                    acc))))))
              "]")))

      ;; materialize-at-type-text: coerce an already-rendered Rust value
      ;; (`base-text`) of `source-type` into `target-type`, returning the
      ;; coerced text or #f when no conversion is needed. Used for aggregate
      ;; values whose element boundaries are not syntactically visible (a
      ;; `default`, a var-ref, a seq-lifted const): the value is bound once
      ;; and coerced by index.
      (define (materialize-at-type-text src target-type source-type base-text)
        (nanopass-case (Ltypescript Type) (type-strip-alias target-type)
          [(tfield ,src^)
           (let ([nat (type-peel-tunsigned source-type)])
             (and nat (field-uint-scalar src nat base-text)))]
          [(tunsigned ,src^ ,nat)
           (let ([nat-s (type-peel-tunsigned source-type)])
             (and nat-s
                  (let ([wt (uint-rust-width nat)]
                        [ws (uint-rust-width nat-s)])
                    (and (not (equal? wt ws))
                         (format "((~a) as ~a)" base-text wt)))))]
          [(tvector ,src^ ,len ,type)
           (let ([se* (type-elt-types source-type len)])
             (and se* (materialize-indexed-text src (make-list len type) se* base-text)))]
          [(ttuple ,src^ ,type* ...)
           (let ([se* (type-elt-types source-type (length type*))])
             (and se* (materialize-indexed-text src type* se* base-text)))]
          [else #f]))

      ;; materialize-needed?: type-level predicate — would coercing a value of
      ;; `source-type` into `target-type` change its Rust rendering? Delegates
      ;; to the text renderer with a placeholder base, so the predicate and the
      ;; renderer cannot drift.
      (define (materialize-needed? target-type source-type)
        (materialize-at-type-text #f target-type source-type "__materialize_probe"))

      ;; materialize-aggregate: render an aggregate coercion. A `(tuple ...)`
      ;; literal is decomposed syntactically, so each element's own expression
      ;; (and any wrapper already on it) is preserved. Any OTHER aggregate
      ;; value — a `default`, a var-ref, a seq-lifted const — has no syntactic
      ;; element boundaries, so it is bound once to a temp and coerced by
      ;; index (`materialize-indexed-text`). Returns #f when no element needs
      ;; coercing.
      (define (materialize-aggregate src target-elt* source-elt* expr render-inner)
        (if (not (ormap (lambda (te se) (materialize-needed? te se))
                        target-elt* source-elt*))
            #f
            (nanopass-case (Ltypescript Expression) expr
              [(tuple ,src^ ,tuple-arg* ...)
               (if (= (length tuple-arg*) (length target-elt*))
                   (string-append
                     "["
                     (join-rendered
                       (map (lambda (ta te se)
                              (materialize-element src te se ta render-inner))
                            tuple-arg* target-elt* source-elt*))
                     "]")
                   (rust-feature-error src 'field-uint-coercion
                     "aggregate coercion arity mismatch"))]
              [else
               (let ([tmp "__compact_materialize"])
                 (format "{ let ~a = ~a; ~a }"
                         tmp (render-inner-at #f render-inner expr)
                         (materialize-indexed-text src target-elt* source-elt* tmp)))])))

      ;; materialize-at-type: the single type-directed coercion decision.
      ;; Render `expr` (an Expression) of `source-type` at `target-type`, with
      ;; `render-inner` the raw renderer of a sub-expression. Returns the
      ;; coerced Rust text, or #f when the inner rendering is already correct
      ;; so the caller falls back to it and byte parity holds. The expected
      ;; type around every inner render is bound here (see render-inner-at),
      ;; so the caller's thunk must not bind it.
      (define (materialize-at-type src target-type source-type expr render-inner)
        (nanopass-case (Ltypescript Type) (type-strip-alias target-type)
          [(tvector ,src^ ,len ,type)
           (let ([se* (type-elt-types source-type len)])
             (and se* (materialize-aggregate src (make-list len type) se* expr render-inner)))]
          [(ttuple ,src^ ,type* ...)
           (let ([se* (type-elt-types source-type (length type*))])
             (and se* (materialize-aggregate src type* se* expr render-inner)))]
          [else
           (materialize-scalar src target-type source-type expr render-inner)]))

      ;; expr-expected-type: the destination type a `safe-cast` wrapper
      ;; records for its inner expression — the typechecker's own judgment of
      ;; what the wrapped value must become at its use position. A boundary
      ;; threads this as `current-expr-expected-type` when the destination is
      ;; not otherwise known at the site (a call argument's formal type, a
      ;; comparison/equality operand's joined type, a ledger write's field
      ;; type): the typechecker wraps every such position with
      ;; `maybe-safecast`, so the wrapper's own target IS the destination.
      ;; Returns #f for an un-wrapped expression (no coercion was required).
      (define (expr-expected-type expr)
        (nanopass-case (Ltypescript Expression) expr
          [(safe-cast ,src ,type ,type^ ,expr^) type]
          [else #f]))

      ;; -----------------------------------------------------------------
      ;; Stdlib lookup tables.
      ;;
      ;; Two alists drive every place the emitter must special-case a
      ;; runtime-provided struct or stdlib pure circuit:
      ;;
      ;;   stdlib-struct-mappings  : struct-name → (type-rust-fn skip-decl?)
      ;;     - type-rust-fn (lambda elt-name* type*) → Rust type string,
      ;;       called from type-rust's tstruct branch.
      ;;     - skip-decl? boolean; when #t, emit-type-decls's tstruct branch
      ;;       skips per-contract emission (runtime provides the type).
      ;;
      ;;   stdlib-circuit-mappings : compact-name → (rust-path-fn)
      ;;     - rust-path-fn (lambda cdefn) → Rust callee path string,
      ;;       called from stdlib-circuit-rust-path. cdefn is the looked-up
      ;;       circuit pelt (or #f); the lambda may inspect its return type
      ;;       for turbofish ascription.
      ;;
      ;; Adding a new stdlib mapping is a single table-entry edit instead
      ;; of touching 3-5 scattered cond clauses.
      ;; -----------------------------------------------------------------

      (define stdlib-struct-mappings
        `((Maybe
            ,(lambda (elt-name* type*)
               (let loop ([names elt-name*] [types type*])
                 (cond
                   [(null? names) "Maybe</* L1: no value field */>"]
                   [(eq? (car names) 'value) (format "Maybe<~a>" (type-rust (car types)))]
                   [else (loop (cdr names) (cdr types))])))
            #t)
          (MerkleTreePath
            ,(lambda (elt-name* type*)
               (let loop ([names elt-name*] [types type*])
                 (cond
                   [(null? names) "midnight_compact_runtime::MerklePath</* no leaf field */>"]
                   [(eq? (car names) 'leaf)
                    (format "midnight_compact_runtime::MerklePath<~a>" (type-rust (car types)))]
                   [else (loop (cdr names) (cdr types))])))
            #t)
          (MerkleTreePathEntry
            ,(lambda (elt-name* type*) "midnight_compact_runtime::MerklePathEntry")
            #t)
          ;; Module-1: a Compact-side `SchnorrSignature` struct
          ;; (`announcement: JubjubPoint`, `response: Field`) comes from
          ;; whichever module defines the Schnorr verifier and is consumed
          ;; by `midnight_compact_runtime::schnorr_verify_jubjub`. To make the call
          ;; site type-check we elide the codegen-emitted struct + impls
          ;; entirely and route the type to the runtime's mirror
          ;; (`midnight_compact_runtime::SchnorrSignature`) which has the
          ;; matching layout.
          (SchnorrSignature
            ,(lambda (elt-name* type*) "midnight_compact_runtime::SchnorrSignature")
            #t)))

      (define stdlib-circuit-mappings
        `((some
            ,(lambda (cdefn)
               (let ([t (and cdefn (maybe-value-type (circuit-return-type cdefn)))])
                 (format "midnight_compact_runtime::std_lib::some~a"
                         (if t (format "::<~a>" (type-rust t)) "")))))
          (none
            ,(lambda (cdefn)
               (let ([t (and cdefn (maybe-value-type (circuit-return-type cdefn)))])
                 (format "midnight_compact_runtime::std_lib::none~a"
                         (if t (format "::<~a>" (type-rust t)) "")))))
          (merkleTreePathRoot
            ,(lambda (cdefn) "midnight_compact_runtime::std_lib::merkle_tree_path_root"))
          (merkleTreePathRootNoLeafHash
            ,(lambda (cdefn) "midnight_compact_runtime::std_lib::merkle_tree_path_root_no_leaf_hash"))))

      ;; lookup-stdlib-struct: return (type-rust-fn skip-decl?) list for a
      ;; struct-name, or #f if not a stdlib struct.
      (define (lookup-stdlib-struct struct-name)
        (let ([entry (assq struct-name stdlib-struct-mappings)])
          (and entry (cdr entry))))

      ;; lookup-stdlib-circuit: return (rust-path-fn) list for a Compact
      ;; stdlib circuit symbol, or #f if not a stdlib circuit.
      (define (lookup-stdlib-circuit sym)
        (let ([entry (assq sym stdlib-circuit-mappings)])
          (and entry (cdr entry))))

