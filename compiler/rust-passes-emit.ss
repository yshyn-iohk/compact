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

;;; The renderers — what the generated Rust actually looks like.
;;;
;;; The initial-state scaffold (including the >16-field chunked form),
;;; circuit signatures and bodies, expressions (`expr-rust`), conditions
;;; (`cond-rust`), and arithmetic (`arith-binop-rust`, whose width ladder
;;; is pinned by widening_arith_fixture).
;;;
;;; Emission is string building through `out`, not construction of a Rust
;;; AST. That is a deliberate trade: rustfmt as a post-pass plus
;;; byte-parity testing gives the same guarantees for far less surface
;;; area. It does mean renderers must produce text a formatter will accept.
;;;
;;; See compiler/README-rust-passes.md for the module map.

      ;; emit-scaffold-seed: emit one initial-state scaffold line for a
      ;; leaf public-binding at the given indentation. ADT-aware seeding
      ;; (R1 / K1.1): the Compact ADTs whose initial-value isn't a plain
      ;; Cell — Map, Set, MerkleTree, HistoricMerkleTree — have dedicated
      ;; builders in compact-runtime that produce the exact StateValue
      ;; shape declared in midnight-ledger.ss. Cell / Counter / anything
      ;; else with a read op keeps the K1 path — new_cell(<default>).
      ;; Special case: tvector defaults to [T; N] which doesn't impl
      ;; Into<AlignedValue> upstream — route through new_cell_array which
      ;; concatenates per-element AVs.
      ;; Special case: tunsigned with a byte-length that doesn't match the
      ;; Rust integer width's byte count (e.g. `Uint<0..70000>` is u32 in
      ;; Rust but uses 3 bytes on state) — route through
      ;; `new_cell_bounded_uint(0u128, N)` so the on-state
      ;; `AlignmentAtom::Bytes` width matches TS.
      (define (emit-scaffold-seed public-binding indent)
        (let ([t (binding-type public-binding)])
          (cond
            [(tadt-name=? t 'Set)
             (out (format "~anew_map(),\n" indent))]
            [(tadt-name=? t 'Map)
             (out (format "~anew_map(),\n" indent))]
            [(tadt-name=? t 'List)
             (out (format "~anew_list(),\n" indent))]
            [(tadt-name=? t 'MerkleTree)
             (out (format "~anew_merkle_tree(~a),\n"
                          indent (tadt-merkle-height t)))]
            [(tadt-name=? t 'HistoricMerkleTree)
             (out (format "~anew_historic_merkle_tree(~a),\n"
                          indent (tadt-merkle-height t)))]
            [else
             (let ([read-type (tadt-read-op-type t)])
               (cond
                 [(type-is-tvector? read-type)
                  (out (format "~anew_cell_array(~a),\n"
                               indent (default-value-rust read-type)))]
                 [(tunsigned-bounded? read-type)
                  (out (format "~anew_cell_bounded_uint(0u128, ~a),\n"
                               indent (tunsigned-byte-length read-type)))]
                 [else
                  (out (format "~anew_cell(~a),\n"
                               indent (default-value-rust read-type)))]))])))

      ;; emit-scaffold-elements: walk one level of a public-ledger-array,
      ;; emitting each element at `indent`. Leaves seed their default via
      ;; emit-scaffold-seed; nested pl-arrays — the >16-field chunking the
      ;; front end computes (StateValue::Array caps at 16), the SAME
      ;; structure `binding-path-indices` and every read/write emitter
      ;; derive their idx_at_index chains from — recurse as nested
      ;; `new_array(vec![...])` scaffolds (A29). Flat (<=16-field)
      ;; contracts have no nested pl-arrays, so their output is unchanged.
      ;; Mirrors typescript-passes.ss::ledger-initializers.
      (define (emit-scaffold-elements pl-array indent)
        (nanopass-case (Ltypescript Public-Ledger-Array) pl-array
          [(public-ledger-array ,pl-array-elt* ...)
           (for-each
             (lambda (pl-array-elt)
               (nanopass-case (Ltypescript Public-Ledger-Array-Element) pl-array-elt
                 [,pl-array
                  (out (format "~anew_array(vec![\n" indent))
                  (emit-scaffold-elements pl-array (string-append indent "    "))
                  (out (format "~a]),\n" indent))]
                 [,public-binding
                  (emit-scaffold-seed public-binding indent)]))
             pl-array-elt*)]))

      ;; emit-initial-state: emits the `initial_state` constructor method
      ;; inside the open Contract impl block. K1 seeds each ledger field
      ;; with its type's default value; J2 then walks the constructor body
      ;; and emits the witness / pure-circuit prelude + a single
      ;; OpProgramVerify chain that writes each field its source-declared
      ;; value. If the constructor body shape isn't one we recognise, we
      ;; fall back to the K1-only return.
      (define (emit-initial-state ledger-field* ctor-arg* all-pelt*)
        (out "    pub fn initial_state(\n")
        (out "        &self,\n")
        (out "        ctx: ConstructorContext<PS>")
        ;; Constructor parameters: one per (var-name type) pair, emitted
        ;; after ctx in the same multi-line shape used elsewhere. Names go
        ;; through camel->snake (handles `$` and CamelCase); types via
        ;; type-rust.
        (for-each
          (lambda (arg)
            (nanopass-case (Ltypescript Argument) arg
              [(,var-name ,type)
               (out (format ",\n        ~a: ~a"
                            (camel->snake (id-sym var-name))
                            (type-rust type)))]))
          ctor-arg*)
        (out ",\n    ) -> Result<ConstructorResult<PS>, CompactError> {\n")
        ;; K1: walk the pl-array structure (all fields, not just exported)
        ;; and emit one seed per leaf binding using the read-op's result
        ;; type as the source of truth for the default value. The walk
        ;; preserves the IR's nesting (A29): contracts with >16 ledger
        ;; fields get the front end's chunked pl-array shape, so the
        ;; scaffold's nested new_array structure matches the idx_at_index
        ;; paths every read/write emitter derives from the same IR.
        ;; J2 (constructor body emission) then overrides these defaults
        ;; with whatever the source constructor assigns.
        (out "        let sv = new_array(vec![\n")
        (let* ([_
                (begin
                  (for-each
                    (lambda (lf)
                      (nanopass-case (Ltypescript Program-Element) lf
                        [(public-ledger-declaration ,pl-array ,lconstructor)
                         (emit-scaffold-elements pl-array "            ")]
                        [else (void)]))
                    ledger-field*)
                  (out "        ]);\n")
                  (out "        let state = ChargedState::new(sv);\n")
                  ;; Bucket-1: fully-qualify ContractAddress so a user struct
                  ;; named `ContractAddress` does not
                  ;; shadow the upstream coin-structure type required by
                  ;; QueryContext::new.
                  (out "        let qctx = QueryContext::new(state, midnight_compact_runtime::ContractAddress::default());\n"))]
               ;; J2: emit the constructor body if we have one and its shape
               ;; matches. Fall back to the K1-only return otherwise (counter has
               ;; no constructor body, so it lands here naturally).
               [stmt (and (pair? ledger-field*)
                          (ldecl-constructor-stmt (car ledger-field*)))]
               [native-id-ht (build-native-id-ht all-pelt*)]
               [witness-id-ht (build-witness-id-ht all-pelt*)]
               [circuit-id-ht (build-circuit-id-ht all-pelt*)]
               [emitted?
                (and stmt
                     ;; Seed current-formal-arg-types with the
                     ;; constructor's args so var-ref-known-copy? can
                     ;; suppress redundant `.clone()` on primitive ctor
                     ;; parameters (`v: Field` in tiny.compact, etc.).
                     ;; The body walker mutates the same hashtable as it
                     ;; classifies const-bindings, so witness/pure-circuit
                     ;; results get their declared types recorded too.
                     ;;
                     ;; Iter 7: current-ledger-field-types is seeded by
                     ;; print-rust at the pass top (so impure circuits
                     ;; that write Vector<N,T> fields also see the map),
                     ;; not here.
                     (parameterize
                       ([current-formal-arg-types
                          (build-formal-arg-type-ht ctor-arg*)])
                       (emit-ctor-body-or-fallback stmt
                                                   native-id-ht witness-id-ht circuit-id-ht)))])
          ;; `emitted?` is #f for two very different reasons, and conflating
          ;; them was a MISCOMPILER (MediaNoxLabs/compact#45):
          ;;
          ;;   stmt = #f          there is no constructor at all. The bare
          ;;                      K1-only return below is correct — the state
          ;;                      really is just the seeded scaffold.
          ;;
          ;;   stmt present,      a constructor EXISTS and we failed to lower
          ;;   emitted? = #f      it. Emitting the same bare return silently
          ;;                      discards every write the author made, at
          ;;                      exit 0, with no diagnostic and no marker.
          ;;                      The contract then initialises to something
          ;;                      other than what the source says.
          ;;
          ;; The second case is strictly worse than emitting non-compiling
          ;; Rust: there is no signal at all, and byte-parity cannot catch it
          ;; either — a fixture of that shape just pins the wrong bytes as
          ;; expected. Refuse instead.
          ;; `stmt` is NOT a reliable "the author wrote a constructor" signal:
          ;; the front end synthesises a Ledger-Constructor for every contract
          ;; with ledger fields, so a contract with no constructor still has a
          ;; non-#f stmt — a bare unit `(tuple src)`. Testing `stmt` alone
          ;; therefore rejects every constructor-less contract, which an
          ;; earlier version of this fix did.
          ;;
          ;; `stmt-flatten` drops that bare unit, so a genuinely empty body
          ;; flattens to '() while a real one does not. Reject only when there
          ;; was something to lower and we failed to lower it.
          (when (and stmt (not emitted?) (pair? (stmt-flatten stmt)))
            (rust-feature-error (stmt-src stmt) 'ctor-body-emission
              "no walker shape matched the constructor body; ~a"
              "emitting the default scaffold here would silently discard every constructor write"))
          (unless emitted?
            (out "        Ok(ConstructorResult {\n")
            (out "            current_contract_state: qctx.state,\n")
            (out "            current_private_state: ctx.initial_private_state,\n")
            (out "            current_zswap_local_state: ctx.empty_zswap_local_state,\n")
            (out "        })\n")))
        (out "    }\n\n"))

      ;; emit-circuit-args: emit each Argument as ",\n        name: type"
      ;; after the leading `&self` / `ctx` params on an impure circuit method,
      ;; matching the existing multi-line method signature shape.
      (define (emit-circuit-args arg*)
        (for-each
          (lambda (arg)
            (nanopass-case (Ltypescript Argument) arg
              [(,var-name ,type)
               (out (format ",\n        ~a: ~a"
                            (camel->snake (id-sym var-name))
                            (type-rust type)))]))
          arg*))

      ;; unit-type?: returns #t if a Type IR node is the empty tuple `()`
      ;; (Compact's `Void` / Ltypescript `(ttuple src)` with no element
      ;; types). I3a only emits bodies for unit-returning circuits; richer
      ;; return shapes (e.g. tiny.compact's `get(): Maybe<Fr>`) keep the
      ;; `unimplemented!()` fallback until I3b.
      (define (unit-type? type)
        (nanopass-case (Ltypescript Type) type
          [(ttuple ,src ,type* ...) (null? type*)]
          [else #f]))

      ;; struct-of-type: if `type` is a tstruct (possibly through a talias
      ;; chain), return (list struct-name elt-name* type*); otherwise #f.
      ;; Used by F2.2's struct-literal emission to recover the field-name
      ;; list (the IR's `(new ...)` carries field initialisers in source
      ;; order but not the names — those come off the struct's type).
      (define (struct-of-type type)
        (nanopass-case (Ltypescript Type) type
          [(tstruct ,src ,struct-name (,elt-name* ,type*) ...)
           (list struct-name elt-name* type*)]
          [(talias ,src ,nominal? ,type-name ,type) (struct-of-type type)]
          [else #f]))

      ;; tstruct-node-of-type: peel talias chains and return the underlying
      ;; tstruct Type NODE (not its parts), or #f. Callers pass the result to
      ;; struct-rust-name so a colliding struct resolves to its disambiguated
      ;; name (Name / Name_1) at value / decode / default sites, not just in
      ;; type positions. Returning the node (rather than the bare name) lets
      ;; struct-rust-name key on eq? identity or structural fingerprint.
      (define (tstruct-node-of-type type)
        (nanopass-case (Ltypescript Type) type
          [(tstruct ,src ,struct-name (,elt-name* ,type*) ...) type]
          [(talias ,src ,nominal? ,type-name ,type) (tstruct-node-of-type type)]
          [else #f]))

      ;; struct-rust-name-of: the disambiguated Rust struct name string for a
      ;; (possibly alias-wrapped) struct type. Falls back to the bare
      ;; struct-name symbol when the type isn't a tstruct (defensive; callers
      ;; already know it is a struct).
      (define (struct-rust-name-of type fallback-name)
        (let ([node (tstruct-node-of-type type)])
          (if node
              (symbol->string (struct-rust-name node))
              (symbol->string fallback-name))))

      ;; render-struct-literal: F2.2 — emit a Rust struct construction
      ;; expression for an Ltypescript `(new src type expr*)`. The struct
      ;; name comes off the type (via struct-of-type); for Maybe<T> we emit
      ;; the L1 runtime alias `Maybe` (in scope via the contract module
      ;; preamble), for user structs the bare struct name (H5-H7 emit the
      ;; struct definition into the contract module).
      ;;
      ;; Field initialiser exprs are rendered through ctor-expr-rust so
      ;; var-refs resolve against the current local-binds and nested
      ;; ledger reads / calls / etc. lower correctly.
      (define (render-struct-literal src type expr* local-binds
                                     native-id-ht witness-id-ht circuit-id-ht)
        (let* ([st (struct-of-type type)]
               [struct-name (and st (car st))]
               [elt-name* (and st (cadr st))]
               [elt-type* (and st (caddr st))])
          (cond
            [(not st)
             (rust-feature-error src 'struct-literal-non-tstruct
               "struct-literal of non-tstruct type")]
            [(not (fx= (length expr*) (length elt-name*)))
             (rust-feature-error src 'struct-literal-field-count-mismatch
               "struct-literal field-count mismatch for ~a (expected ~a, got ~a)"
               struct-name (length elt-name*) (length expr*))]
            [else
             (let* ([rust-struct-name (struct-rust-name-of type struct-name)]
                    [field-strs
                     ;; Each initialiser renders at the member's declared
                     ;; type so a bare literal member (task 2.6) is coerced
                     ;; to it.
                     (map (lambda (name e mtype)
                            (format "~a: ~a"
                                    (symbol->string name)
                                    (parameterize ([current-expr-expected-type mtype])
                                      (ctor-expr-rust e local-binds
                                                      native-id-ht witness-id-ht circuit-id-ht))))
                          elt-name* expr* elt-type*)])
               (string-append
                 rust-struct-name
                 " { "
                 (let join ([xs field-strs] [acc ""])
                   (cond
                     [(null? xs) acc]
                     [(null? (cdr xs)) (string-append acc (car xs))]
                     [else (join (cdr xs)
                                 (string-append acc (car xs) ", "))]))
                 " }"))])))

      ;; maybe-value-type: if `type` is `Maybe<T>` (a tstruct named Maybe with
      ;; a `value` field), return T. Otherwise return #f. Used by the
      ;; I3b/4 if-expression emitter to render `some::<T>` / `none::<T>` with
      ;; an explicit generic argument so Rust's type inference doesn't need
      ;; help from surrounding context.
      (define (maybe-value-type type)
        (nanopass-case (Ltypescript Type) type
          [(tstruct ,src ,struct-name (,elt-name* ,type*) ...)
           (cond
             [(eq? struct-name 'Maybe)
              (let loop ([names elt-name*] [types type*])
                (cond
                  [(null? names) #f]
                  [(eq? (car names) 'value) (car types)]
                  [else (loop (cdr names) (cdr types))]))]
             [else #f])]
          [(talias ,src ,nominal? ,type-name ,type^) (maybe-value-type type^)]
          [else #f]))

      ;; stmt->if-expression-body: detect the I3b/4 "single if-expression body"
      ;; shape — a flat statement sequence whose only element is
      ;; `(if cond then-stmt else-stmt)`, where each branch is a
      ;; `(statement-expression expr)` carrying a single expression
      ;; representing the circuit's return value. Returns
      ;;   (list cond-expr then-expr else-expr)
      ;; on success, #f otherwise.
      (define (stmt->if-expression-body stmt)
        (let ([stmts (stmt-flatten stmt)])
          (cond
            [(or (null? stmts) (not (null? (cdr stmts)))) #f]
            [else
             (nanopass-case (Ltypescript Statement) (car stmts)
               [(if ,src ,expr0 ,stmt1 ,stmt2)
                (let ([then-expr (stmt->return-expr stmt1)]
                      [else-expr (stmt->return-expr stmt2)])
                  (and then-expr else-expr (list expr0 then-expr else-expr)))]
               [else #f])])))

      ;; stmt->if-chain-body: A19 generalisation of stmt->if-expression-body.
      ;; Admits non-unit-returning impure-circuit bodies of shape:
      ;;   (a) single statement-expression       — `return expr;`
      ;;       (verificationMethodExists)
      ;;   (b) if/else-if/.../else chain         — `if (..) return ... else if ... else return ...;`
      ;;       (tiny.get)
      ;;   (c) if/else-if/...; trailing return    — `if ... else if ...; return default;`
      ;;       (verificationMethodRelationMember)
      ;; Returns
      ;;   (list arms else-expr)
      ;; where arms = ((cond-expr then-expr) ...) (possibly empty) and
      ;; else-expr is always present. Caller dispatches via
      ;; emit-if-chain-body. Returns #f on structural mismatch.
      (define (stmt->if-chain-body stmt)
        (let ([stmts (stmt-flatten stmt)])
          (cond
            [(null? stmts) #f]
            [(null? (cdr stmts))
             ;; Single stmt: either a top-level if (recurse into chain) or
             ;; a statement-expression (no arms, just the expr).
             (nanopass-case (Ltypescript Statement) (car stmts)
               [(if ,src ,expr0 ,stmt1 ,stmt2)
                (collect-if-chain (car stmts) '())]
               [(statement-expression ,expr) (list '() expr)]
               [else #f])]
            [(and (pair? (cdr stmts))
                  (null? (cddr stmts)))
             ;; Two stmts: an if (without final else) plus a trailing
             ;; return-expression. The trailing expr becomes the chain's
             ;; else.
             (let ([trailing (stmt->return-expr (cadr stmts))])
               (and trailing
                    (nanopass-case (Ltypescript Statement) (car stmts)
                      [(if ,src ,expr0 ,stmt1 ,stmt2)
                       (collect-if-chain (car stmts) (list trailing))]
                      [else #f])))]
            [else #f])))

      ;; collect-if-chain: walk a (possibly nested) if-then-else statement,
      ;; collecting (cond, then-expr) pairs and unwinding into the final
      ;; else-expr. `trailing-else` is the override else-expr to use when
      ;; the innermost if has no else of its own (case (c) above).
      (define (collect-if-chain stmt trailing-else)
        (let loop ([s stmt] [arms '()])
          (nanopass-case (Ltypescript Statement) s
            [(if ,src ,expr0 ,stmt1 ,stmt2)
             (let ([then-expr (stmt->return-expr stmt1)])
               (and then-expr
                    (let ([else-stmts (stmt-flatten stmt2)])
                      (cond
                        ;; else is itself a nested if: extend the chain.
                        [(and (pair? else-stmts) (null? (cdr else-stmts))
                              (nanopass-case (Ltypescript Statement) (car else-stmts)
                                [(if ,src ,expr0 ,stmt1 ,stmt2) #t]
                                [else #f]))
                         (loop (car else-stmts) (cons (list expr0 then-expr) arms))]
                        ;; else is a no-op `(tuple)` AND we have a trailing
                        ;; override: use the trailing as else.
                        [(and (pair? trailing-else)
                              (null? else-stmts))
                         (list (reverse (cons (list expr0 then-expr) arms))
                               (car trailing-else))]
                        ;; otherwise else is a return-expr.
                        [else
                         (let ([else-expr (stmt->return-expr stmt2)])
                           (and else-expr
                                (list (reverse (cons (list expr0 then-expr) arms))
                                      else-expr)))]))))]
            [else #f])))

      ;; stmt->return-expr: pull the single return expression out of a
      ;; branch Statement. The branches of a return-value if-expression
      ;; come out of typescript-passes lowering as a single
      ;; `(statement-expression expr)` (possibly wrapped in a `seq` with
      ;; a trailing unit tuple, which stmt-flatten strips). Returns the
      ;; expression on success, #f otherwise.
      (define (stmt->return-expr stmt)
        (let ([stmts (stmt-flatten stmt)])
          (cond
            [(or (null? stmts) (not (null? (cdr stmts)))) #f]
            [else
             (nanopass-case (Ltypescript Statement) (car stmts)
               [(statement-expression ,expr) expr]
               [else #f])])))

      ;; stmt-flatten: collapse nested `seq`s and trailing-`(tuple)` unit
      ;; statements into a flat list of leaf Statements. The unit
      ;; `(statement-expression (tuple src))` at the end of a `seq` is
      ;; pure (returns ()), so dropping it preserves semantics for our
      ;; void-returning circuits. Any other shape is left alone — callers
      ;; treat unexpected leaves as a non-match and fall back.
      ;; lift-seq-prefix-exprs: walk an Expression, find any (seq es ... e)
      ;; nodes in interior positions, collect the prefix `es` as lifted
      ;; assignment-statements, and return two values:
      ;;   (values lifted-stmts cleaned-expr)
      ;; where cleaned-expr has every seq replaced by just its trailing
      ;; expression. Lifting is order-preserving (left-to-right traversal)
      ;; so dependent assignments stay in order.
      ;;
      ;; This is what enables the streaming walker to see `let %tmp = ...;`
      ;; lifted out of complex assert conditions and similar nested
      ;; expressions.
      (define (lift-seq-prefix-exprs expr)
        (define lifted '())
        (define (push-lifted! e)
          (set! lifted
                (cons (with-output-language (Ltypescript Statement)
                        `(statement-expression ,e))
                      lifted)))
        (define (walk e)
          (nanopass-case (Ltypescript Expression) e
            [(seq ,src ,expr* ... ,expr^)
             (for-each (lambda (ex) (push-lifted! (walk ex))) expr*)
             (walk expr^)]
            [(assert ,src ,expr^ ,mesg)
             (let ([new-cond (walk expr^)])
               (with-output-language (Ltypescript Expression)
                 `(assert ,src ,new-cond ,mesg)))]
            [(not ,src ,expr^)
             (let ([n (walk expr^)])
               (with-output-language (Ltypescript Expression)
                 `(not ,src ,n)))]
            [(and ,src ,expr1 ,expr2)
             (let ([a (walk expr1)]
                   [b (walk expr2)])
               (with-output-language (Ltypescript Expression)
                 `(and ,src ,a ,b)))]
            [(or ,src ,expr1 ,expr2)
             (let ([a (walk expr1)]
                   [b (walk expr2)])
               (with-output-language (Ltypescript Expression)
                 `(or ,src ,a ,b)))]
            [(== ,src ,type ,expr1 ,expr2)
             (let ([a (walk expr1)]
                   [b (walk expr2)])
               (with-output-language (Ltypescript Expression)
                 `(== ,src ,type ,a ,b)))]
            [else e]))
        (let ([cleaned (walk expr)])
          (values (reverse lifted) cleaned)))

      (define (stmt-flatten stmt)
        (nanopass-case (Ltypescript Statement) stmt
          [(seq ,src ,stmt* ... ,stmt^)
           (let ([all (append stmt* (list stmt^))])
             (apply append (map stmt-flatten all)))]
          [(statement-expression ,expr)
           ;; Drop a bare unit `(tuple src)` — common terminal of a `seq`
           ;; for void-returning circuits.
           ;;
           ;; Also lift a `(seq src expr* ... expr^)` Expression out into
           ;; separate statement-expressions, so the streaming walker can
           ;; see each assignment and the final body as flat siblings. This
           ;; is what typescript-passes produces for `let*` lifted out of
           ;; expression contexts (e.g. `disclose(merkleTreePathRoot<...>
           ;; (path))` introducing a temp variable for the inner call).
           (nanopass-case (Ltypescript Expression) expr
             [(tuple ,src ,tuple-arg* ...)
              (if (null? tuple-arg*) '() (list stmt))]
             [(seq ,src ,expr* ... ,expr^)
              (apply append
                (map (lambda (e)
                       (stmt-flatten
                         (with-output-language (Ltypescript Statement)
                           `(statement-expression ,e))))
                     (append expr* (list expr^))))]
             [else
              ;; Try lifting any inner seq-prefix assignments from a
              ;; structured expression (assert / and / or / not / ==). If
              ;; lifting produced any prefix statements, return them
              ;; followed by the cleaned statement; otherwise return the
              ;; original statement unchanged.
              (let-values ([(lifted cleaned) (lift-seq-prefix-exprs expr)])
                (cond
                  [(null? lifted) (list stmt)]
                  [else
                   (let ([new-stmt
                          (with-output-language (Ltypescript Statement)
                            `(statement-expression ,cleaned))])
                     (append
                       (apply append (map stmt-flatten lifted))
                       (list new-stmt)))]))])]
          [else (list stmt)]))

      ;; const-binding?: detect a `(const src local expr)` and pull out
      ;; the binder's var-name and the bound expression. Returns
      ;; (cons var-name expr) on a match, #f otherwise.
      (define (const-binding stmt)
        (nanopass-case (Ltypescript Statement) stmt
          [(const ,src ,local ,expr)
           (nanopass-case (Ltypescript Argument) local
             [(,var-name ,type) (cons var-name expr)])]
          [else #f]))

      ;; const-binding-decl-type: like const-binding, but returns the
      ;; binder's declared Type (or #f if `stmt` isn't a const-binding).
      ;; Used by Prod-9 to detect Field-typed integer literals at RHS
      ;; (e.g. `const tmp_0: Field = 42n;`) so the emitter can wrap them
      ;; in `Fr::from(<n>u64)` instead of leaving a bare i32 literal that
      ;; later fails the `Into<AlignedValue>` bound at the ledger-write
      ;; builder call site.
      (define (const-binding-decl-type stmt)
        (nanopass-case (Ltypescript Statement) stmt
          [(const ,src ,local ,expr)
           (nanopass-case (Ltypescript Argument) local
             [(,var-name ,type) type])]
          [else #f]))

      ;; literal-int-expr?: returns the integer datum when `expr` strips
      ;; (through safe-cast layers) down to a `(quote ... <int>)` literal,
      ;; or #f otherwise.
      (define (literal-int-expr? expr)
        (let ([e (expr-strip-cast expr)])
          (nanopass-case (Ltypescript Expression) e
            [(quote ,src ,datum)
             (and (integer? datum) (exact? datum) datum)]
            [else #f])))

      ;; type-is-tfield?: is `type` a (tfield ...)? Peels nominal/transparent
      ;; talias layers so `type Foo = Field;` also matches.
      (define (type-is-tfield? type)
        (and type
             (nanopass-case (Ltypescript Type) type
               [(tfield ,src) #t]
               [(talias ,src ,nominal? ,type-name ,type^)
                (type-is-tfield? type^)]
               [else #f])))

      ;; type-peel-tunsigned: if `type` is a (tunsigned src nat) (possibly
      ;; through a talias chain), return the `nat` upper bound; otherwise #f.
      ;; Companion to `type-is-tfield?` for Prod-13's Uint<N> literal path.
      (define (type-peel-tunsigned type)
        (and type
             (nanopass-case (Ltypescript Type) type
               [(tunsigned ,src ,nat) nat]
               [(talias ,src ,nominal? ,type-name ,type^)
                (type-peel-tunsigned type^)]
               [else #f])))

      ;; uniquify-rust-name: Prod-14 — Compact's frontend lowering produces
      ;; per-statement `const tmp = ...; <ledger> = tmp;` shapes, so a
      ;; constructor body like
      ;;     admin = 42;
      ;;     count = 7;
      ;; lowers into TWO const-bindings both named `tmp`. Each binding maps
      ;; to a distinct id (and `local-binds` keys are eq-compared), but the
      ;; emitted Rust shares the same `let tmp = ...` string and shadows.
      ;; By the time the OpProgram builder consumes each `new_cell(<rust-name>.
      ;; clone())`, only the LAST `let tmp = …` is in scope, so every cell
      ;; reads the wrong value.
      ;;
      ;; Suffix the proposed name with `_N` until it doesn't collide with
      ;; any prior `local-binds` entry's rust-name. First occurrence keeps
      ;; the unsuffixed form to preserve existing snapshots (most fixtures
      ;; have at most one literal-RHS slot per body).
      (define (uniquify-rust-name proposed local-binds)
        (let ([taken (map cdr local-binds)])
          (cond
            [(not (member proposed taken)) proposed]
            [else
             (let loop ([n 0])
               (let ([candidate (format "~a_~a" proposed n)])
                 (cond
                   [(member candidate taken) (loop (fx+ n 1))]
                   [else candidate])))])))

      ;; coerce-literal-rhs-rendered: Prod-9/Prod-13 — typed integer literals
      ;; need to be rendered with the correct Rust type so the ledger-write
      ;; builder's `Into<AlignedValue>` bound is satisfied.
      ;;   - `tfield`: materialise as an `Fr` (`field-literal-rust`).
      ;;   - `tunsigned`: append the width suffix (`<n>u8` .. `<n>u128`) so
      ;;     the literal types as the same Rust primitive the ledger field
      ;;     uses. Without this, `ledger v: Uint<64>; v = 42;` lowered into
      ;;     `let tmp = 42; new_cell(tmp.clone())` — the bare i32 fails the
      ;;     `Into<AlignedValue>` bound (Prod-13).
      ;; All other RHS shapes return #f so the caller falls back to its
      ;; existing rendering.
      (define (coerce-literal-rhs-rendered decl-type rhs)
        (cond
          [(type-is-tfield? decl-type)
           (let ([n (literal-int-expr? rhs)])
             (and n (field-literal-rust n)))]
          [(type-peel-tunsigned decl-type) =>
           (lambda (nat)
             (let ([n (literal-int-expr? rhs)])
               (and n (format "~a~a" n (uint-rust-width nat)))))]
          [else #f]))

      ;; const-decl-only?: detect a `(const ,src (,local* ...))` Statement —
      ;; the "forward declaration" form produced by typescript-passes when a
      ;; `let* ([%tmp ...])` is lifted out of an expression context. These
      ;; carry no initializer; the actual assignment lands later as a
      ;; `(statement-expression (= ,src ,var-name ,expr))`. In the Rust
      ;; emission this is a no-op — the eventual `(= ...)` becomes a
      ;; plain `let <name> = <expr>;`. Returns #t on match, #f otherwise.
      (define (const-decl-only? stmt)
        (nanopass-case (Ltypescript Statement) stmt
          [(const ,src (,local* ...)) #t]
          [else #f]))

      ;; stmt->assignment: detect a `(statement-expression (= src var-name
      ;; expr))` and return (cons var-name expr). The assignment Expression
      ;; is what typescript-passes emits for `<name> = <expr>` after lifting
      ;; a let* temp out of a containing expression — see lifted-temp
      ;; comments above. Returns #f for anything else.
      (define (stmt->assignment stmt)
        (nanopass-case (Ltypescript Statement) stmt
          [(statement-expression ,expr)
           (nanopass-case (Ltypescript Expression) expr
             [(= ,src ,var-name ,expr^) (cons var-name expr^)]
             [else #f])]
          [else #f]))

      ;; expr-strip-cast: peel safe-cast layers from an Expression. The
      ;; typechecker inserts `safe-cast` to widen the source literal
      ;; (e.g. `1: Uint<1>`) up to the ADT op's declared parameter type
      ;; (e.g. `Uint16` for `Counter.increment`). For literal-int
      ;; arguments the cast is value-preserving, so we look through it
      ;; before extracting the literal.
      (define (expr-strip-cast expr)
        (nanopass-case (Ltypescript Expression) expr
          [(safe-cast ,src ,type ,type^ ,expr^) (expr-strip-cast expr^)]
          [else expr]))

      ;; expr-resolve: chase a `var-ref` through the local-binding alist
      ;; built from preceding `const` statements, then strip any
      ;; cast layers. Returns the underlying Expression or #f if the
      ;; chain hits something we don't recognise.
      (define (expr-resolve expr binds)
        ;; Pass through unknown var-refs unchanged. Originally this
        ;; returned #f to signal "unresolvable", but that prevented
        ;; legitimate Iter 6 use cases (the fold loop variable is bound
        ;; outside `binds` and substituted per-iteration by
        ;; emit-for-iter-terminal). Downstream callers (e.g.
        ;; branch->single-pl-call, stmt->single-public-ledger-call)
        ;; still test for #f via `(memv #f resolved)`; with this change
        ;; that test never fires for var-refs alone. Other shapes (e.g.
        ;; an unsupported expression form via expr-strip-cast) still
        ;; fall through to the `[else e]` arm — they keep their original
        ;; representation, and downstream emission rejects them through
        ;; `expr-supported?` / vm-code expansion rather than via #f here.
        (let ([e (expr-strip-cast expr)])
          (nanopass-case (Ltypescript Expression) e
            [(var-ref ,src ,var-name)
             (cond
               [(assq var-name binds) =>
                (lambda (p) (expr-resolve (cdr p) binds))]
               [else e])]
            [else e])))

      ;; stmt->single-public-ledger-call: detect the narrow I3a shape —
      ;; a flat statement sequence consisting of zero or more `const`
      ;; bindings followed by exactly one `(public-ledger ...)` call
      ;; (e.g. counter.compact's `round.increment(1);` which the
      ;; frontend lowers to `const tmp = safe-cast 1; round.increment(tmp);`).
      ;; On a match returns
      ;;   (list path-elt* adt-op resolved-expr*)
      ;; where each resolved-expr has had var-refs chased through the
      ;; const-binding alist and surrounding safe-casts peeled. Returns
      ;; #f for anything we don't yet support.
      (define (stmt->single-public-ledger-call stmt)
        (let loop ([stmts (stmt-flatten stmt)] [binds '()])
          (cond
            [(null? stmts) #f]
            [(const-binding (car stmts)) =>
             (lambda (b) (loop (cdr stmts) (cons b binds)))]
            [else
             (and
               ;; Exactly one terminal statement-expression.
               (null? (cdr stmts))
               (nanopass-case (Ltypescript Statement) (car stmts)
                 [(statement-expression ,expr)
                  (nanopass-case (Ltypescript Expression) expr
                    [(public-ledger ,src ,ledger-field-name ,sugar? (,path-elt* ...) ,src^ ,adt-op ,expr* ...)
                     (let ([resolved (map (lambda (e) (expr-resolve e binds)) expr*)])
                       (if (memv #f resolved)
                           #f
                           (list path-elt* adt-op resolved)))]
                    [else #f])]
                 [else #f]))])))

      ;; path-elt->vm-value: turn a Path-Element into the VM value that
      ;; `expand-vm-code` expects to see in the `f` argument. For path
      ;; indices (constant nats locating a ledger field) we emit a
      ;; `(VMalign path-index 1)` exactly as typescript-passes.ss does
      ;; (see line 695). Typed path elements (`(src type expr)`) — used
      ;; when the path includes a runtime expression, e.g. a Map key —
      ;; are not part of the I3a wedge; we return #f so the caller falls
      ;; back to `unimplemented!()` for those.
      (define (path-elt->vm-value path-elt)
        (nanopass-case (Ltypescript Path-Element) path-elt
          [,path-index (VMalign path-index 1)]
          [else #f]))

      ;; vm-rust-expr is a thin carrier record used to ferry a pre-rendered
      ;; Rust expression string through `expand-vm-code`. It lets the I3a
      ;; entry collapse non-literal circuit arguments (e.g. a Bytes32 var-ref
      ;; like `pk` or a pure-circuit result like `cm`) into a single Scheme
      ;; value that survives macro expansion intact, then surfaces back out
      ;; at `vminstr->builder-call` time so the push for that arg lowers to
      ;; the right Rust expression. Counter's literal-int path is preserved
      ;; unchanged (integers are still plain Scheme numbers).
      (define-record-type vm-rust-expr
        (nongenerative)
        (fields text))

      ;; expr->vm-value: turn a circuit argument Expression into a value
      ;; that the VM code can consume. Counter's `round.increment(1)`
      ;; passes the constant `1`; the vm-code wraps that in
      ;; `(rt-value->int amount)`, producing `(VMvalue->int <int>)` after
      ;; expansion, which we unwrap in vminstr->builder-call. For E4 the
      ;; insert ops pass a non-literal (e.g. `pk` / `cm`), so we also
      ;; accept any expression `expr-rust` can render and lift it into a
      ;; `vm-rust-expr` carrier — vminstr->builder-call recognises the
      ;; carrier when surfacing the push value. Returns #f only when the
      ;; expression itself can't be rendered.
      ;;
      ;; `native-id-ht` lets us route var-refs to native bindings (e.g.
      ;; arg names that came in via emit-circuit-args) when needed; the
      ;; counter literal-only path doesn't need it (and historically
      ;; didn't take it), so it defaults to #f and we only invoke
      ;; expr-rust when the expression isn't a plain literal.
      (define (expr->vm-value expr . opt-native-ht)
        (nanopass-case (Ltypescript Expression) expr
          [(quote ,src ,datum)
           (if (and (integer? datum) (exact? datum)) datum #f)]
          [else
           (let ([native-ht (and (pair? opt-native-ht) (car opt-native-ht))])
             (and native-ht
                  (let ([rendered (guard (c [#t #f]) (expr-rust expr native-ht))])
                    (and rendered
                         (make-vm-rust-expr
                           (expr-rust-arg-cloned expr rendered))))))]))

      ;; expr-rust-arg-cloned: given the original expression and its
      ;; expr-rust-rendered text, suffix `.clone()` when the expression
      ;; is a var-ref / elt-ref to a non-Copy local. Mirrors
      ;; arg-rust-clone-if-var's predicate (without re-rendering, since
      ;; expr-rust has already produced the text). Used by the
      ;; assert-cond / read-with-arg path where `expr-rust` (not
      ;; `ctor-expr-rust`) produces the inner text.
      (define (expr-rust-arg-cloned expr rendered)
        (let ([stripped (expr-strip-cast expr)])
          (nanopass-case (Ltypescript Expression) stripped
            [(var-ref ,src ,var-name)
             (if (var-ref-known-copy? var-name)
                 rendered
                 (string-append rendered ".clone()"))]
            [(elt-ref ,src ,expr ,elt-name ,nat)
             (cond
               [(not (elt-ref-rooted-in-var? stripped)) rendered]
               [(elt-ref-known-copy? stripped) rendered]
               [else (string-append rendered ".clone()")])]
            [else rendered])))

      ;; vm-immediate->int: given the value the vm-code computed for an
      ;; `[immediate ...]` argument, unwrap a `(VMvalue->int n)` (the
      ;; standard wrap produced by `(rt-value->int amount)`) into the
      ;; underlying integer. Returns #f if the value isn't a plain
      ;; literal-flavoured immediate.
      (define (vm-immediate->int v)
        (cond
          [(and (integer? v) (exact? v)) v]
          [(VMop? v)
           (VMop-case v
             [(VMvalue->int x)
              (if (and (integer? x) (exact? x)) x #f)]
             [else #f])]
          [else #f]))

      ;; vm-path->indices: given the value bound to `path` (typically the
      ;; whole `f` list in the vm-code), return a list of integer indices
      ;; if every element is a `(VMalign nat 1)`. Returns #f otherwise so
      ;; richer paths fall back to `unimplemented!()`.
      (define (vm-path->indices v)
        (cond
          [(not (list? v)) #f]
          [else
           (let loop ([xs v] [acc '()])
             (cond
               [(null? xs) (reverse acc)]
               [(VMop? (car xs))
                (VMop-case (car xs)
                  [(VMalign value bytes)
                   (if (and (= bytes 1) (integer? value) (exact? value))
                       (loop (cdr xs) (cons value acc))
                       #f)]
                  [else #f])]
               [else #f]))]))

      ;; vm-cell-elem->rust: render the inner expression of a
      ;; (VMstate-value-cell <elem>) form as the Rust expression that
      ;; should be wrapped in `new_cell(...)`. Recognises:
      ;;   - a plain integer literal              → "<n>u8"  (counter-style)
      ;;   - a VMalign with bytes=1               → "<n>u8"
      ;;   - a vm-rust-expr carrier               → the carrier's text
      ;;   - a VMleaf-hash wrapping any of the above
      ;;       → "leaf_hash(&ValueReprAlignedValue(AlignedValue::from(<inner>)))"
      ;;     (matches midnight-onchain-runtime's program_fragments shape)
      ;; Returns #f for anything we don't yet know how to render so the
      ;; caller can fall back to `unimplemented!()`.
      (define (vm-cell-elem->rust elem)
        (cond
          [(and (integer? elem) (exact? elem))
           (format "~au8" elem)]
          [(vm-rust-expr? elem)
           (vm-rust-expr-text elem)]
          [(VMop? elem)
           (VMop-case elem
             [(VMalign value bytes)
              ;; A20: extend beyond bytes=1 (Counter / Cell.read literals)
              ;; to support the wider literals that read-no-arg vm-code
              ;; pushes — e.g. `Set.isEmpty` emits `(push align-0-8)` for a
              ;; u64 zero compared against `(size)`. The 1/2/4/8 widths
              ;; match the on-state alignment widths of Compact's
              ;; Uint8 / Uint16 / Uint32 / Uint64 cells and map 1:1 onto
              ;; Rust's primitive `From<…> for AlignedValue` impls.
              (cond
                [(not (and (integer? value) (exact? value))) #f]
                [(= bytes 1) (format "~au8" value)]
                [(= bytes 2) (format "~au16" value)]
                [(= bytes 4) (format "~au32" value)]
                [(= bytes 8) (format "~au64" value)]
                [else #f])]
             [(VMleaf-hash x)
              (let ([inner (vm-cell-elem->rust x)])
                (and inner
                     (format
                       "leaf_hash(&ValueReprAlignedValue(AlignedValue::from(~a)))"
                       inner)))]
             ;; A21: `(rt-null T)` lowers to `VMnull T` carrying the type
             ;; whose default value we need to materialise. Used by HMT
             ;; (and MerkleTree) `insertIndexDefault` to push a hash of the
             ;; default leaf — `(rt-leaf-hash (rt-null value_type))` — and
             ;; later by any vm-code that needs a typed zero. We route the
             ;; type through `default-value-rust` (the same renderer
             ;; `emit-initial-state` uses for the ledger field zero) so the
             ;; Rust literal matches the TS reference's
             ;; `default(value_type)` expression bit-for-bit.
             [(VMnull type)
              (default-value-rust type)]
             [else #f])]
          [else #f]))

      ;; ltypescript-type-is-tadt?: returns #t when an Ltypescript Type is a
      ;; tadt (public-adt) form, peeling talias layers. Used by
      ;; vm-value->rust-state-value below to decide whether a
      ;; `VMstate-value-ADT val type` form wraps its `val` in `new_cell(...)`
      ;; (the leaf path — value_type is a non-ADT like Field/Uint/Bytes) or
      ;; surfaces the ADT directly (the recursive path — value_type is a
      ;; nested Map/Set/MerkleTree). Mirrors typescript-passes.ss's
      ;; `public-adt?` branch for `VMstate-value-ADT`.
      (define (ltypescript-type-is-tadt? type)
        (nanopass-case (Ltypescript Type) type
          [(tadt ,src ,adt-name ([,adt-formal* ,adt-arg*] ...) ,vm-expr (,adt-op* ...) (,adt-rt-op* ...)) #t]
          [(talias ,src ,nominal? ,type-name ,type) (ltypescript-type-is-tadt? type)]
          [else #f]))

      ;; vm-value->rust-state-value: render a state-value form (the kind
      ;; that appears as the `value` arg of a `push` vm-instruction) as
      ;; a Rust expression of type `StateValue<DefaultDB>`. Returns #f if
      ;; the form isn't one we yet know how to translate.
      ;;
      ;; G: `VMstate-value-ADT val type` — Map.insert's value-side push uses
      ;; this form because `state-value 'ADT value value_type` carries the
      ;; declared value_type. For non-public-adt value types (Field, Uint*,
      ;; Bytes<N>, …) the runtime semantics are identical to a plain
      ;; `VMstate-value-cell val` (typescript-passes wraps with
      ;; `StateValue.newCell`); we mirror that here so Map<K, leaf> insert
      ;; lowers to the same `.push(true, new_cell(<v>))` shape Set.insert
      ;; uses with its `(state-value 'null)`. tadt-typed values aren't yet
      ;; needed (Map<K, Map<…>> etc.) — return #f for those so the caller
      ;; falls back to `unimplemented!()`.
      (define (vm-value->rust-state-value val)
        (cond
          [(VMop? val)
           (VMop-case val
             [(VMstate-value-null) "StateValue::Null"]
             [(VMstate-value-cell inner)
              (let ([rust-inner (vm-cell-elem->rust inner)])
                (and rust-inner (format "new_cell(~a)" rust-inner)))]
             [(VMstate-value-ADT inner adt-type)
              (cond
                [(ltypescript-type-is-tadt? adt-type) #f]
                [else
                 (let ([rust-inner (vm-cell-elem->rust inner)])
                   (and rust-inner (format "new_cell(~a)" rust-inner)))])]
             [else #f])]
          [else #f]))

      ;; vminstr->builder-call: render a single vminstr as one line of the
      ;; OpProgramVerify builder chain (already indented for inclusion
      ;; inside the `let ops = ...` block). Recognises the ops needed by
      ;; counter (`idx`, `addi`, `ins`) plus the vm-ops emitted by Set /
      ;; MerkleTree / HistoricMerkleTree `insert` vm-code (`push`, `dup`,
      ;; `root`). Anything else returns #f so the caller can bail out to
      ;; the `unimplemented!()` fallback rather than emit syntactically-
      ;; valid but semantically-wrong Rust.
      (define (vminstr->builder-call v)
        (let ([op (vminstr-op v)]
              [args (vminstr-arg* v)])
          (cond
            [(string=? op "idx")
             (let* ([cached-pair (assoc "cached" args)]
                    [push-pair (assoc "pushPath" args)]
                    [path-pair (assoc "path" args)])
               (cond
                 [(not (and cached-pair push-pair path-pair)) #f]
                 [else
                  (let* ([indices (vm-path->indices (cdr path-pair))]
                         [push-path (cdr push-pair)]
                         [path-val (cdr path-pair)]
                         [runtime-key
                          (and (list? path-val)
                               (pair? path-val)
                               (null? (cdr path-val))
                               (vm-rust-expr? (car path-val))
                               (car path-val))])
                    ;; A11: emit one `.idx_at_index(N, push)` per index.
                    ;; Single- and multi-index paths share the loop — the
                    ;; n=1 case (Counter et al. at top-level) is just the
                    ;; specialisation. A write under a nested ledger
                    ;; struct (path `(1 6)`, say) needs n>1; A8 already did
                    ;; this for vminstr->gather-builder-call,
                    ;; this mirrors it for the Verify pipeline.
                    ;;
                    ;; A16: handle runtime-keyed paths (single vm-rust-expr
                    ;; in a 1-element list) for Map.insert / Map.lookup
                    ;; key indexing.
                    (cond
                      [runtime-key
                       (format "            .idx(~a, ~a, vec![midnight_compact_runtime::Key::Value(midnight_compact_runtime::AlignedValue::from(~a))])\n"
                               (if (cdr cached-pair) "true" "false")
                               (if push-path "true" "false")
                               (vm-rust-expr-text runtime-key))]
                      [(and indices (pair? indices))
                       (let loop ([is indices] [acc ""])
                         (cond
                           [(null? is) acc]
                           [else
                            (loop (cdr is)
                                  (string-append
                                    acc
                                    (format "            .idx_at_index(~au8, ~a)\n"
                                            (car is)
                                            (if push-path "true" "false"))))]))]
                      [else #f]))]))]
            [(string=? op "addi")
             (let ([imm-pair (assoc "immediate" args)])
               (cond
                 [(not imm-pair) #f]
                 [else
                  (let* ([imm (cdr imm-pair)]
                         [n (vm-immediate->int imm)])
                    (cond
                      ;; Literal integer (counter's `round.increment(1)`
                      ;; lowers the `1` to a Scheme exact int that
                      ;; vm-immediate->int unwraps directly).
                      [n (format "            .addi(~a)\n" n)]
                      ;; A4: when a multi-stmt body lowers an integer
                      ;; literal arg through a const-binding (Prod-14's
                      ;; `let tmp = 1u16; ops.increment(tmp);` shape),
                      ;; the `addi` immediate carries a vm-rust-expr
                      ;; whose `.text` is the rendered Rust reference
                      ;; (e.g. "tmp.clone()"). Emit it as a Rust
                      ;; expression cast to u32 (the addi parameter
                      ;; width per runtime-rs/src/op_builder.rs:61).
                      ;; The const-binding's source type might be
                      ;; u8/u16/u32/u64 depending on the literal's
                      ;; declared Uint<N> bound; `as u32` is the
                      ;; conservative target. Counter.increment's amount
                      ;; is typed Uint<32> on the runtime side, so this
                      ;; cast never silently truncates valid inputs.
                      [(vm-rust-expr? imm)
                       (format "            .addi(~a as u32)\n"
                               (vm-rust-expr-text imm))]
                      ;; Some `(VMvalue->int <vm-rust-expr>)` wrapping is
                      ;; also possible if the immediate went through the
                      ;; full vm-value path. Unwrap once.
                      [(and (VMop? imm)
                            (VMop-case imm
                              [(VMvalue->int x) (vm-rust-expr? x)]
                              [else #f]))
                       (let ([inner
                              (VMop-case imm
                                [(VMvalue->int x) x]
                                [else #f])])
                         (format "            .addi(~a as u32)\n"
                                 (vm-rust-expr-text inner)))]
                      [else #f]))]))]
            [(string=? op "rem")
             ;; A13: Set.remove / Map.remove vm-code op. Renders as
             ;; `.rem(<cached>)` on OpProgramVerify; the runtime
             ;; builder method was added alongside this change.
             (let ([cached-pair (assoc "cached" args)])
               (cond
                 [(not cached-pair) #f]
                 [else
                  (format "            .rem(~a)\n"
                          (if (cdr cached-pair) "true" "false"))]))]
            [(string=? op "ins")
             (let ([cached-pair (assoc "cached" args)]
                   [n-pair (assoc "n" args)])
               (cond
                 [(not (and cached-pair n-pair)) #f]
                 [else
                  (let ([n (cdr n-pair)])
                    (and (integer? n) (exact? n)
                         (format "            .ins(~a, ~a)\n"
                                 (if (cdr cached-pair) "true" "false")
                                 n)))]))]
            [(string=? op "push")
             (let ([storage-pair (assoc "storage" args)]
                   [value-pair (assoc "value" args)])
               (cond
                 [(not (and storage-pair value-pair)) #f]
                 [else
                  (let ([rust-val (vm-value->rust-state-value (cdr value-pair))])
                    (and rust-val
                         (format "            .push(~a, ~a)\n"
                                 (if (cdr storage-pair) "true" "false")
                                 rust-val)))]))]
            [(string=? op "dup")
             (let ([n-pair (assoc "n" args)])
               (cond
                 [(not n-pair) #f]
                 [else
                  (let ([n (cdr n-pair)])
                    (and (integer? n) (exact? n)
                         (format "            .dup(~a)\n" n)))]))]
            [(string=? op "root")
             (cond
               [(null? args) "            .root()\n"]
               [else #f])]
            ;; A21: branching / stack-shuffling ops emitted by the
            ;; bounded-index MerkleTree / HistoricMerkleTree
            ;; `insert*Index*` vm-code. The sequence is a compile-time
            ;; `max(old_first_free, index + 1)` realised on the VM stack:
            ;;
            ;;     (dup 1) (dup 1) (lt) (branch 2) (pop) (jmp 2)
            ;;     (swap 0) (pop)
            ;;
            ;; — push two copies of the candidates, compare, then either
            ;; drop the old counter (taken branch) or swap-then-drop the
            ;; new one (fallthrough). The Rust builder mirrors the ops 1:1;
            ;; `query_for_verify` walks them with the same VM semantics as
            ;; the TS reference, so byte-parity is preserved without
            ;; recovering structured control flow.
            [(string=? op "lt")
             (cond
               [(null? args) "            .lt()\n"]
               [else #f])]
            [(string=? op "pop")
             (cond
               [(null? args) "            .pop()\n"]
               [else #f])]
            [(string=? op "branch")
             (let ([skip-pair (assoc "skip" args)])
               (cond
                 [(not skip-pair) #f]
                 [else
                  (let ([skip (cdr skip-pair)])
                    (and (integer? skip) (exact? skip)
                         (format "            .branch(~a)\n" skip)))]))]
            [(string=? op "jmp")
             (let ([skip-pair (assoc "skip" args)])
               (cond
                 [(not skip-pair) #f]
                 [else
                  (let ([skip (cdr skip-pair)])
                    (and (integer? skip) (exact? skip)
                         (format "            .jmp(~a)\n" skip)))]))]
            [(string=? op "swap")
             (let ([n-pair (assoc "n" args)])
               (cond
                 [(not n-pair) #f]
                 [else
                  (let ([n (cdr n-pair)])
                    (and (integer? n) (exact? n)
                         (format "            .swap(~a)\n" n)))]))]
            [else #f])))

      ;; vminstr->gather-builder-call: like vminstr->builder-call but for
      ;; OpProgramGather chains emitted inline by emit-ledger-read-expr
      ;; (ADT `read` ops with args, e.g. Set.member, HistoricMerkleTree
      ;; .checkRoot, Map.member). Uses 16-space indentation to match the
      ;; existing read-expr block template and emits the additional ops
      ;; that read vm-code uses but write vm-code doesn't: `popeq` (no
      ;; result value in Gather mode), `member`, and `eq`. The `popeq`
      ;; arg layout matches Op::Popeq's `(cached, ())` Gather signature
      ;; via OpProgramGather::popeq(cached). Returns #f for ops we don't
      ;; know how to render so the caller falls back to the no-arg
      ;; hardcoded template.
      (define (vminstr->gather-builder-call v)
        (let ([op (vminstr-op v)]
              [args (vminstr-arg* v)])
          (cond
            [(string=? op "idx")
             (let* ([cached-pair (assoc "cached" args)]
                    [push-pair (assoc "pushPath" args)]
                    [path-pair (assoc "path" args)])
               (cond
                 [(not (and cached-pair push-pair path-pair)) #f]
                 [else
                  (let* ([indices (vm-path->indices (cdr path-pair))]
                         [push-path (cdr push-pair)]
                         [path-val (cdr path-pair)]
                         ;; A16: runtime-keyed idx — path is a 1-element
                         ;; list containing a vm-rust-expr (Map.lookup's
                         ;; second idx with `disclosed_method_id.clone()`).
                         [runtime-key
                          (and (list? path-val)
                               (pair? path-val)
                               (null? (cdr path-val))
                               (vm-rust-expr? (car path-val))
                               (car path-val))])
                    ;; A8: emit one `.idx_at_index(N, push)` per index.
                    ;; Single- and multi-index paths share the loop; the
                    ;; one-index case is just the n=1 specialisation
                    ;; (Map<K,V>.member etc. need n>1).
                    ;;
                    ;; A16: also handle runtime-keyed paths — emit
                    ;; `.idx(cached, push, vec![Key::Value(AlignedValue::from(<expr>))])`.
                    (cond
                      [runtime-key
                       (format "                .idx(~a, ~a, vec![midnight_compact_runtime::Key::Value(midnight_compact_runtime::AlignedValue::from(~a))])\n"
                               (if (cdr cached-pair) "true" "false")
                               (if push-path "true" "false")
                               (vm-rust-expr-text runtime-key))]
                      [(and indices (pair? indices))
                       (let loop ([is indices] [acc ""])
                         (cond
                           [(null? is) acc]
                           [else
                            (loop (cdr is)
                                  (string-append
                                    acc
                                    (format "                .idx_at_index(~au8, ~a)\n"
                                            (car is)
                                            (if push-path "true" "false"))))]))]
                      [else #f]))]))]
            [(string=? op "dup")
             (let ([n-pair (assoc "n" args)])
               (cond
                 [(not n-pair) #f]
                 [else
                  (let ([n (cdr n-pair)])
                    (and (integer? n) (exact? n)
                         (format "                .dup(~a)\n" n)))]))]
            [(string=? op "push")
             (let ([storage-pair (assoc "storage" args)]
                   [value-pair (assoc "value" args)])
               (cond
                 [(not (and storage-pair value-pair)) #f]
                 [else
                  (let ([rust-val (vm-value->rust-state-value (cdr value-pair))])
                    (and rust-val
                         (format "                .push(~a, ~a)\n"
                                 (if (cdr storage-pair) "true" "false")
                                 rust-val)))]))]
            [(string=? op "member")
             (cond
               [(null? args) "                .member()\n"]
               [else #f])]
            [(string=? op "eq")
             (cond
               [(null? args) "                .eq()\n"]
               [else #f])]
            [(string=? op "root")
             (cond
               [(null? args) "                .root()\n"]
               [else #f])]
            [(string=? op "size")
             ;; A20: `size` replaces the top-of-stack container with a
             ;; Cell holding its element count. Emitted by Set.size /
             ;; Set.isEmpty / Map.size / Map.isEmpty.
             (cond
               [(null? args) "                .size()\n"]
               [else #f])]
            [(string=? op "type")
             ;; A20: `type` replaces the top-of-stack StateValue with a
             ;; Cell holding its shape tag. Emitted by List.isEmpty to
             ;; detect the Null sentinel at the head of an empty list.
             (cond
               [(null? args) "                .type_()\n"]
               [else #f])]
            [(string=? op "popeq")
             (let ([cached-pair (assoc "cached" args)])
               (cond
                 [(not cached-pair) #f]
                 [else
                  (format "                .popeq(~a)\n"
                          (if (cdr cached-pair) "true" "false"))]))]
            [else #f])))

      ;; emit-public-ledger-call-body: emit the I3a body — an
      ;; OpProgramVerify builder chain matching the adt-op's vm-code,
      ;; followed by the query_for_verify wrapper + Ok return. Returns #t
      ;; on success, #f if any step (path translation, vm-code expansion,
      ;; vminstr rendering) couldn't be handled — the caller falls back
      ;; to `unimplemented!()` in that case.
      (define (emit-public-ledger-call-body src adt-op path-elt* expr*)
        (nanopass-case (Ltypescript ADT-Op) adt-op
          [(,ledger-op ,op-class (,adt-name (,adt-formal* ,adt-arg*) ...) ((,var-name* ,type*) ...) ,type ,vm-code)
           (cond
             [(not (fx= (length expr*) (length var-name*))) #f]
             [else
              ;; Lift each path-elt + expr to a VM value (#f on anything
              ;; we don't yet know how to translate) before invoking
              ;; expand-vm-code. We bail out as soon as we hit something
              ;; unsupported so the placeholder is preserved.
              (let ([path-vals (map path-elt->vm-value path-elt*)]
                    [expr-vals (map expr->vm-value expr*)])
                (cond
                  [(memv #f path-vals) #f]
                  [(memv #f expr-vals) #f]
                  [else
                   (let* ([arg-alist
                           (append (map cons adt-formal* adt-arg*)
                                   (map (lambda (var-name v)
                                          (cons (id-sym var-name) v))
                                        var-name*
                                        expr-vals))]
                          [vminstr*
                           (expand-vm-code src path-vals #f arg-alist
                             (vm-code-code vm-code))]
                          [lines (map vminstr->builder-call vminstr*)])
                     (cond
                       [(memv #f lines) #f]
                       [else
                        (out "        let ops = OpProgramVerify::<DefaultDB>::new()\n")
                        (for-each out lines)
                        (out "            .build();\n")
                        (out "\n")
                        (out "        let results = query_for_verify(\n")
                        (out "            &ctx.current_query_context,\n")
                        (out "            &ops,\n")
                        (out "            ctx.gas_limit.clone(),\n")
                        (out "            &ctx.cost_model,\n")
                        (out "        )?;\n")
                        (out "\n")
                        (out "        Ok(CircuitResults {\n")
                        (out "            result: (),\n")
                        (out "            context: CircuitContext {\n")
                        (out "                current_query_context: results.context,\n")
                        (out "                ..ctx\n")
                        (out "            },\n")
                        (out "            gas_cost: results.gas_cost,\n")
                        (out "        })\n")
                        #t]))]))])]))

      ;; emit-if-expression-body: emit the I3b/4 body shape — a single
      ;; if-expression in statement position producing a non-unit value.
      ;; The cond / then / else are rendered via ctor-expr-rust so existing
      ;; logic for inlining `in_state`, ledger reads in expression position,
      ;; and `some` / `none` runtime mapping all apply uniformly.
      ;;
      ;; Returns #t on success, #f if any rendered sub-expression contains
      ;; an `unimplemented!()` marker (caller falls back to `unimplemented!()`).
      ;;
      ;; The wrap uses `RunningCost::default()` since there are no ledger
      ;; writes — pure read-only circuits don't run query_for_verify.
      (define (emit-if-expression-body return-type cond-expr then-expr else-expr
                                       native-id-ht witness-id-ht circuit-id-ht)
        (let* ([cond-str (cond-rust cond-expr '()
                                    native-id-ht witness-id-ht circuit-id-ht)]
               ;; Task 2.2: each return arm renders at the declared return
               ;; type so a widening arm coerces; a primitive literal is
               ;; peeled (see render-tail-at).
               [then-str (render-tail-at then-expr return-type
                           (lambda (exp)
                             (parameterize ([current-expr-expected-type exp])
                               (ctor-expr-rust then-expr '()
                                               native-id-ht witness-id-ht circuit-id-ht))))]
               [else-str (render-tail-at else-expr return-type
                           (lambda (exp)
                             (parameterize ([current-expr-expected-type exp])
                               (ctor-expr-rust else-expr '()
                                               native-id-ht witness-id-ht circuit-id-ht))))])
          (cond
            [(or (rendered-has-todo? cond-str)
                 (rendered-has-todo? then-str)
                 (rendered-has-todo? else-str))
             #f]
            [else
             (out (format "        let result = if ~a {\n" cond-str))
             (out (format "            ~a\n" then-str))
             (out "        } else {\n")
             (out (format "            ~a\n" else-str))
             (out "        };\n")
             (out "        Ok(CircuitResults {\n")
             (out "            result,\n")
             (out "            context: ctx,\n")
             (out "            gas_cost: midnight_compact_runtime::RunningCost::default(),\n")
             (out "        })\n")
             #t])))

      ;; emit-if-chain-body: A19 generalisation of emit-if-expression-body.
      ;; Renders a non-unit-returning impure circuit body composed of zero
      ;; or more if/else-if arms followed by a final else expression, then
      ;; wraps the value in CircuitResults. arms is a list of
      ;; (cond-expr then-expr) pairs (possibly empty for a single-return
      ;; body); else-expr is the final value.
      (define (emit-if-chain-body return-type arms else-expr
                                  native-id-ht witness-id-ht circuit-id-ht)
        (let* ([arm-strs
                (map (lambda (a)
                       (let ([c-str (cond-rust (car a) '()
                                               native-id-ht witness-id-ht
                                               circuit-id-ht)]
                             ;; Task 2.2: return arms render at the declared
                             ;; return type (literal peel via render-tail-at).
                             [t-str (render-tail-at (cadr a) return-type
                                      (lambda (exp)
                                        (parameterize ([current-expr-expected-type exp])
                                          (ctor-expr-rust (cadr a) '()
                                                          native-id-ht witness-id-ht
                                                          circuit-id-ht))))])
                         (list c-str t-str)))
                     arms)]
               [else-str (render-tail-at else-expr return-type
                           (lambda (exp)
                             (parameterize ([current-expr-expected-type exp])
                               (ctor-expr-rust else-expr '()
                                               native-id-ht witness-id-ht
                                               circuit-id-ht))))]
               [any-todo?
                (or (rendered-has-todo? else-str)
                    (let loop ([xs arm-strs])
                      (cond
                        [(null? xs) #f]
                        [(or (rendered-has-todo? (caar xs))
                             (rendered-has-todo? (cadar xs))) #t]
                        [else (loop (cdr xs))])))])
          (cond
            [any-todo? #f]
            [(null? arms)
             ;; No arms: body is just `return <expr>;`. Emit directly.
             (out (format "        let result = ~a;\n" else-str))
             (out "        Ok(CircuitResults {\n")
             (out "            result,\n")
             (out "            context: ctx,\n")
             (out "            gas_cost: midnight_compact_runtime::RunningCost::default(),\n")
             (out "        })\n")
             #t]
            [else
             (let loop ([xs arm-strs] [first? #t])
               (cond
                 [(null? xs)
                  (out " else {\n")
                  (out (format "            ~a\n" else-str))
                  (out "        };\n")]
                 [first?
                  (out (format "        let result = if ~a {\n" (caar xs)))
                  (out (format "            ~a\n" (cadar xs)))
                  (out "        }")
                  (loop (cdr xs) #f)]
                 [else
                  (out (format " else if ~a {\n" (caar xs)))
                  (out (format "            ~a\n" (cadar xs)))
                  (out "        }")
                  (loop (cdr xs) #f)]))
             (out "        Ok(CircuitResults {\n")
             (out "            result,\n")
             (out "            context: ctx,\n")
             (out "            gas_cost: midnight_compact_runtime::RunningCost::default(),\n")
             (out "        })\n")
             #t])))

      ;; rendered-has-todo?: returns #t if the rendered Rust string
      ;; contains a TODO marker (`/* TODO`). Used by body emitters to
      ;; bail out (fall through to the method-level rust-feature-error)
      ;; when a sub-render produced a partially-supported placeholder
      ;; like `/* TODO ... */ true` (still valid Rust, but not
      ;; production-ready). Sub-renders that hit truly-unsupported
      ;; paths now raise via rust-feature-error rather than emit an
      ;; `unimplemented!()` string, so the predicate only needs to
      ;; scan for the `/* TODO` form.
      (define (rendered-has-todo? s)
        (and (string? s)
             (substring? s "/* TODO")))

      ;; substring?: simple substring search. Returns #t if `needle` appears
      ;; anywhere in `haystack`.
      (define (substring? haystack needle)
        (let ([hl (string-length haystack)]
              [nl (string-length needle)])
          (and (fx>= hl nl)
               (let loop ([i 0])
                 (cond
                   [(fx> (fx+ i nl) hl) #f]
                   [(string=? (substring haystack i (fx+ i nl)) needle) #t]
                   [else (loop (fx+ i 1))])))))

      ;; hoist-ctx-args: for an impure-circuit call `self.<m>(ctx, <args>)`,
      ;; any argument whose rendered text references `ctx` — a ledger read
      ;; emits `&ctx.current_query_context` — must be bound to a temp BEFORE
      ;; the call moves `ctx`, or Rust rejects the borrow-after-move
      ;; (a circuit forwarding a JubjubPoint LEDGER READ into a signature-
      ;; verification helper — `verify(digest, sig, signerKey)` — is the
      ;; canonical case). Returns
      ;; (values hoist-lines arg-tail): `hoist-lines` are the `let _carg… = …;`
      ;; strings (the caller emits or prepends them), and `arg-tail` is the
      ;; ", "-prefixed argument list with hoisted args replaced by their temp
      ;; names. Non-ctx args stay inline, so contracts without ctx-reading
      ;; call arguments are byte-unchanged.
      ;;
      ;; Covered by (grep the corpus for `_carg_`):
      ;;   - schnorr_attest_fixture — a JubjubPoint ledger read forwarded
      ;;     into the Schnorr verifier, the canonical shape above;
      ;;   - asset_registry_fixture — a ledger read passed to an impure
      ;;     circuit from inside a CONSTRUCTOR, so the hoist coexists with
      ;;     the A28 write-flush and their ordering is pinned too.
      (define (hoist-ctx-args arg-strs step)
        (let hloop ([xs arg-strs] [i 0] [lines '()] [names '()])
          (cond
            [(null? xs)
             (values (reverse lines)
                     (let join ([ys (reverse names)] [s ""])
                       (cond
                         [(null? ys) s]
                         [else (join (cdr ys)
                                     (string-append s ", " (car ys)))])))]
            [(substring? (car xs) "ctx")
             (let ([n (format "_carg_~a_~a" step i)])
               (hloop (cdr xs) (fx+ i 1)
                      (cons (format "        let ~a = ~a;\n" n (car xs)) lines)
                      (cons n names)))]
            [else
             (hloop (cdr xs) (fx+ i 1) lines (cons (car xs) names))])))

      ;; A22: emit an impure-circuit call plus context threading.
      ;;
      ;; In 'circuit mode the inbound `ctx` is already a CircuitContext, so
      ;; we hand it straight to the callee and rebind `ctx` from the result:
      ;;     let _cr_N = <target>(ctx, args)?;
      ;;     let ctx = _cr_N.context;
      ;;
      ;; In 'ctor mode the inbound `ctx` is a ConstructorContext (fields
      ;; initial_private_state / empty_zswap_local_state / cost_model /
      ;; gas_limit) and the working query context lives in the local `qctx`.
      ;; A circuit callee needs a CircuitContext, so we build one from qctx +
      ;; the current private state, call, then re-extract qctx and the private
      ;; state. Crucially we do NOT shadow `ctx`: the constructor's final
      ;; ConstructorResult still reads ctx.empty_zswap_local_state /
      ;; ctx.initial_private_state, so those fields must survive. cost_model /
      ;; gas_limit / empty_zswap are cloned because ctx is used again later.
      ;; Returns lines in FORWARD (source) order.
      (define (impure-call-thread-lines cr-name target arg-tail step mode
                                        witness-emitted?)
        (if (eq? mode 'ctor)
            (let* ([cctx (format "_cctx_~a" step)]
                   [priv (if witness-emitted?
                             "current_private_state"
                             "ctx.initial_private_state")]
                   ;; A25: the first ctor impure call seeds the callee's
                   ;; zswap-local state from `ctx.empty_zswap_local_state`;
                   ;; subsequent calls chain off the `_zswap` the previous
                   ;; call extracted. Either way we re-extract the callee's
                   ;; returned zswap-local state so a zswap-affecting
                   ;; constructor circuit's changes survive into the
                   ;; ConstructorResult (see ctor-zswap-result-field).
                   [first? (not (ctor-zswap-threaded?))]
                   [zswap-in (if first?
                                 "ctx.empty_zswap_local_state.clone()"
                                 "_zswap")])
              (ctor-zswap-threaded? #t)
              (list
                (format "        let ~a = CircuitContext {\n" cctx)
                (format "            current_private_state: ~a,\n" priv)
                "            current_query_context: qctx,\n"
                (format "            current_zswap_local_state: ~a,\n" zswap-in)
                "            cost_model: ctx.cost_model.clone(),\n"
                "            gas_limit: ctx.gas_limit.clone(),\n"
                "        };\n"
                (format "        let ~a = ~a(~a~a)?;\n" cr-name target cctx arg-tail)
                (format "        let qctx = ~a.context.current_query_context;\n" cr-name)
                (format "        let current_private_state = ~a.context.current_private_state;\n"
                        cr-name)
                (format "        let _zswap = ~a.context.current_zswap_local_state;\n"
                        cr-name)))
            ;; 'circuit mode: ctx is a CircuitContext; hand it straight to the
            ;; callee and rebind. A27: when the body accumulates gas, add the
            ;; callee's cost so a pre-terminal helper (assert / recordUpdate)
            ;; does not drop its gas from the final CircuitResults.
            (if (circuit-gas-acc?)
                (list
                  (format "        let ~a = ~a(ctx~a)?;\n" cr-name target arg-tail)
                  (format "        let ctx = ~a.context;\n" cr-name)
                  (format "        __gas_acc += ~a.gas_cost.clone();\n" cr-name))
                (list
                  (format "        let ~a = ~a(ctx~a)?;\n" cr-name target arg-tail)
                  (format "        let ctx = ~a.context;\n" cr-name)))))

      ;; cond-rust: render a boolean condition expression. Like
      ;; ctor-expr-rust but for `(call ...)` of an impure circuit
      ;; (e.g. tiny.compact's `in_state`) we try inline-circuit-call
      ;; first, since impure circuits can't be a direct Rust call target.
      (define (cond-rust expr local-binds
                         native-id-ht witness-id-ht circuit-id-ht)
        ;; Task 2.4: an `if`/`assert` condition is Boolean. Clear any
        ;; inherited expression expectation so a destination type from the
        ;; enclosing position cannot leak into the condition's sub-renders.
        (parameterize ([current-expr-expected-type #f])
        (let ([e (expr-strip-cast expr)])
          (nanopass-case (Ltypescript Expression) e
            [(call ,src ,function-name ,expr* ...)
             (let ([ne (eq-hashtable-ref native-id-ht function-name #f)]
                   [w (eq-hashtable-ref witness-id-ht function-name #f)]
                   [c (eq-hashtable-ref circuit-id-ht function-name #f)])
               (cond
                 [(or ne w (and c (id-pure? function-name)))
                  (ctor-expr-rust e local-binds
                                  native-id-ht witness-id-ht circuit-id-ht)]
                 ;; A call we cannot inline used to emit `/* TODO */ true`
                 ;; here, which is the worst available outcome: the
                 ;; condition becomes unconditionally true, so the
                 ;; then-branch always runs and the else-branch is dead.
                 ;; That compiles, reads plausibly, and gives no runtime
                 ;; signal — any ledger write the author meant to be
                 ;; conditional silently becomes unconditional. Refuse
                 ;; instead; see docs/rust-backend-limitations.md.
                 [c
                  (or (inline-circuit-call c expr* local-binds
                                           native-id-ht witness-id-ht circuit-id-ht)
                      (rust-feature-error src 'ctor-if-condition-inline
                        "cannot inline the call to `~a` used as an `if` condition in a constructor"
                        (id-sym function-name)))]
                 [else
                  (rust-feature-error src 'ctor-if-condition-inline
                    "cannot inline the call to `~a` used as an `if` condition in a constructor"
                    (id-sym function-name))]))]
            [else
             (ctor-expr-rust e local-binds
                             native-id-ht witness-id-ht circuit-id-ht)]))))

      ;; emit-impure-circuit: emit an impure circuit as a method on
      ;; `impl<PS, W> Contract<PS, W>`. Takes `&self, ctx: CircuitContext<PS>`
      ;; plus the source-level args typed via type-rust, and returns
      ;; `Result<CircuitResults<PS, T>, CompactError>` for the declared T.
      ;;
      ;; I3a recognises the narrow shape — a single `(public-ledger ...)`
      ;; statement returning `()` (e.g. counter.compact's
      ;; `round.increment(1);`) — and emits the corresponding Op program
      ;; via `expand-vm-code`. Anything richer keeps the `unimplemented!()`
      ;; placeholder so I3b+ can take it on without losing the build.
      (define (emit-impure-circuit cdefn native-id-ht witness-id-ht circuit-id-ht)
        (nanopass-case (Ltypescript Program-Element) cdefn
          [(circuit ,src ,function-name (,arg* ...) ,type ,stmt)
           ;; Exported impure circuits land on the public Contract API.
           ;; Non-exported ones are private helpers callable from bare-call
           ;; statements in other circuit bodies — same emission shape, but
           ;; `pub(crate)` so downstream crates don't see them. Mirrors the
           ;; pure-circuit visibility convention in emit-pure-circuit.
           (out (format "    ~a fn ~a(\n"
                        (if (id-exported? function-name) "pub" "pub(crate)")
                        (id->rust-name function-name)))
           (out "        &self,\n")
           (out "        ctx: CircuitContext<PS>")
           (emit-circuit-args arg*)
           (out (format ",\n    ) -> Result<CircuitResults<PS, ~a>, CompactError> {\n"
                        (type-rust type)))
           (parameterize ([current-formal-arg-types (build-formal-arg-type-ht arg*)])
           (let ([emitted?
                  (or
                    ;; I3b/4: single if-expression body returning non-unit.
                    ;; tiny.compact's `get()` lowers to this shape. We dispatch
                    ;; before the unit-only paths so a non-unit if-body
                    ;; doesn't fall through to `unimplemented!()`.
                    (let ([parts (stmt->if-expression-body stmt)])
                      (and parts
                           (not (unit-type? type))
                           (emit-if-expression-body
                             type (car parts) (cadr parts) (caddr parts)
                             native-id-ht witness-id-ht circuit-id-ht)))
                    ;; A19: multi-arm if/else-if returning non-unit, or a
                    ;; single trailing return-expression body. Closes
                    ;; membership predicates (a single
                    ;; `return member(x) || member(y)`) and relation
                    ;; dispatchers (an n-arm if/else-if with a trailing
                    ;; `return false`).
                    (let ([chain (stmt->if-chain-body stmt)])
                      (and chain
                           (not (unit-type? type))
                           (emit-if-chain-body
                             type (car chain) (cadr chain)
                             native-id-ht witness-id-ht circuit-id-ht)))
                    (and (unit-type? type)
                         (or
                           ;; I3a: counter-style single public-ledger call.
                           (let ([call (stmt->single-public-ledger-call stmt)])
                             (and call
                                  (emit-public-ledger-call-body
                                    src
                                    (cadr call)        ; adt-op
                                    (car call)         ; path-elt*
                                    (caddr call))))    ; expr*
                           ;; I3b/2: tiny.compact `set`-style body — leading
                           ;; asserts + const bindings + ledger writes. We
                           ;; pre-validate via body-walkable? so partial /
                           ;; broken emissions (e.g. tiny's `clear`, which
                           ;; needs `==` and `default<T>`) fall back to
                           ;; `unimplemented!()` rather than producing
                           ;; uncompilable Rust.
                           (and (body-walkable? stmt
                                                native-id-ht witness-id-ht circuit-id-ht)
                                (emit-body-or-fallback stmt 'circuit
                                                       native-id-ht witness-id-ht circuit-id-ht))
                           ;; Streaming walker for richer multi-stage bodies
                           ;; (zerocash.spend, election.vote$commit /
                           ;; vote$reveal). Tried when emit-body-or-fallback
                           ;; bails — A18 dropped the body-needs-streaming?
                           ;; preference gate so terminal multi-arm if-chains
                           ;; (an n-arm dispatcher that inserts into or removes
                           ;; from one of several ledger sets) also
                           ;; route through streaming.
                           (and (body-streaming-walkable?
                                  stmt native-id-ht witness-id-ht circuit-id-ht)
                                (emit-streaming-body
                                  stmt native-id-ht witness-id-ht circuit-id-ht)))))])
             (unless emitted?
               (rust-feature-error src 'circuit-body-emission
                 "no walker shape matched circuit body for ~a"
                 (id-sym function-name))))
           (out "    }\n\n"))]))

      ;; bytevector->rust-array-literal: render a Scheme bytevector as a Rust
      ;; array literal `[N1u8, N2, ..., NK]`. The first element carries the
      ;; explicit `u8` suffix so the literal infers as `[u8; K]` without an
      ;; ascription. Used by expr-rust for `(quote src #vu8(...))`.
      (define (bytevector->rust-array-literal bv)
        (let* ([n (bytevector-length bv)]
               [parts
                (let loop ([i 0] [acc '()])
                  (cond
                    [(fx= i n) (reverse acc)]
                    [else
                     (let ([byte (bytevector-u8-ref bv i)])
                       (loop (fx+ i 1)
                             (cons
                               (if (fx= i 0)
                                   (format "~au8" byte)
                                   (format "~a" byte))
                               acc)))]))])
          (string-append
            "["
            (let join ([xs parts] [acc ""])
              (cond
                [(null? xs) acc]
                [(null? (cdr xs)) (string-append acc (car xs))]
                [else (join (cdr xs) (string-append acc (car xs) ", "))]))
            "]")))

      ;; arith-operand-rust: render an arithmetic operand and, when
      ;; `current-arith-suffix` is set and the rendered output is a
      ;; bare integer literal, append the suffix so Rust resolves the
      ;; surrounding wrapping_* inherent method against a concrete
      ;; integer type. Non-literal operands (var-refs, method calls,
      ;; nested arithmetic with their own suffix) are returned unmodified
      ;; — they already carry typing information through the enclosing
      ;; `as u<width>` cast emitted by the downcast-unsigned clause.
      ;;
      ;; Iter 7 follow-up: introduced to support non-identity lambdas
      ;; in `map()` (`x * 2 as Uint<64>` and friends).
      (define (arith-operand-rust expr native-id-ht)
        (let ([rendered (expr-rust expr native-id-ht)]
              [s (current-arith-suffix)])
          (cond
            [(and s (integer-literal-rendering? rendered))
             (string-append rendered s)]
            [else rendered])))

      ;; mbits->rust-width: map a `(+/−/* ,src ,mbits ...)` result bit-width
      ;; (the typer's `(integer-length result-nat)`, analysis-passes.ss:2113)
      ;; to the smallest Rust unsigned int type that holds it. Returns #f for
      ;; #f (maybe-bits) or out-of-ladder widths so the caller falls back to
      ;; the operand-native width. Used to cast both operands to the result
      ;; width so e.g. `ageThresholdYears: Uint<8> * 365` (mbits=17) renders
      ;; as `((...) as u32).wrapping_mul((...) as u32)` — without the cast
      ;; `wrapping_mul` runs at the u8 receiver width and the u32 comparison
      ;; side mismatches (an age-predicate circuit, say).
      (define (mbits->rust-width mbits)
        (cond
          [(not (and (integer? mbits) (exact? mbits) (positive? mbits))) #f]
          [(<= mbits 8) "u8"]
          [(<= mbits 16) "u16"]
          [(<= mbits 32) "u32"]
          [(<= mbits 64) "u64"]
          [(<= mbits 128) "u128"]
          [else #f]))

      ;; arith-binop-rust: render a `(+/−/* ,src ,mbits ,e1 ,e2)` node,
      ;; casting both operands to the result width (from mbits) when it
      ;; maps to a Rust unsigned type. The cast is a no-op when the
      ;; operands are already that width (e.g. Uint<32> - Uint<32>,
      ;; mbits=32) and a widening cast when an operand is narrower
      ;; (Uint<8> * literal). Only reached by pure circuits that use
      ;; wrapping arithmetic.
      ;;
      ;; Ladder coverage in the fixture corpus:
      ;;   u16, u32 — widening_arith_fixture (both interior boundaries,
      ;;              incl. the `Uint<8> * 365` shape cited above)
      ;;   u64      — asset_registry_fixture / guarded_assert_arith_fixture
      ;;              (the same-width no-op case)
      ;;   u128     — map_lambda_fixture (`x * 2` on Uint<64>, mbits=65)
      ;; A wrong rung cannot fault: `wrapping_*` truncates silently, so it
      ;; yields a wrong VALUE in code that still compiles. That is why the
      ;; widening fixture has an executing test and not only byte-parity.
      ;; field-arith-rust-operator: Rust operator for FIELD arithmetic.
      ;; Field arithmetic is modular in the field's own characteristic, so the
      ;; plain operators are the correct lowering — `Fr` implements Add/Sub/Mul
      ;; and NOT the `wrapping_*` family, which exists only on Rust's
      ;; fixed-width integers.
      (define (field-arith-rust-operator op)
        (cond
          [(string=? op "add") "+"]
          [(string=? op "sub") "-"]
          [(string=? op "mul") "*"]
          [else #f]))

      (define (arith-binop-rust src op mbits expr1 expr2 native-id-ht)
        ;; Operands are NOT type-directed: the typer wraps both in
        ;; safe-casts to the result width, but `arith-binop-rust` already
        ;; casts each operand to the `mbits`-derived width. Materialising the
        ;; operand wrappers too would double-cast (`((x) as u64) as u64`),
        ;; so the expected type is cleared for the operand renders.
        (parameterize ([current-expr-expected-type #f])
        (let ([e1 (arith-operand-rust expr1 native-id-ht)]
              [e2 (arith-operand-rust expr2 native-id-ht)]
              [w (mbits->rust-width mbits)])
          (cond
            [w
             (format "((~a) as ~a).wrapping_~a((~a) as ~a)" e1 w op e2 w)]
            ;; FIELD arithmetic. The typer emits `mbits = #f` for its FIELD
            ;; branch, and this used to fall through to
            ;; `(~a).wrapping_~a(~a)` — emitting e.g. `(a).wrapping_add(b)` on
            ;; two `Fr`s, which does not compile because `Fr` has no
            ;; `wrapping_add`. compactc exited 0 and the failure surfaced only
            ;; at `cargo build`, from Compact as ordinary as
            ;;     export pure circuit addF(a: Field, b: Field): Field {
            ;;       return a + b;
            ;;     }
            ;; No fixture exercised the shape, so nothing caught it: the corpus
            ;; only ever reached the `w` branch above.
            ;;
            ;; Note `mbits->rust-width` also returns #f for an out-of-ladder
            ;; width (>128 bits), so the two cases MUST be distinguished here —
            ;; conflating them is what let the field case ride the fallback.
            [(not mbits)
             (let ([rust-op (field-arith-rust-operator op)])
               (unless rust-op
                 (rust-feature-error src 'field-arith-operator
                   "field arithmetic operator `~a` has no Rust lowering" op))
               (format "(~a) ~a (~a)" e1 rust-op e2))]
            ;; A width the ladder does not cover: refuse rather than emit
            ;; `wrapping_*` against a type that may not have it. A guess here
            ;; is exactly the silent-bad-output path the field case above spent
            ;; a release demonstrating.
            [else
             (rust-feature-error src 'arith-result-width
               "unsigned arithmetic with a ~a-bit result has no Rust lowering" mbits)]))))

      ;; expr-rust: emit a Rust expression string for an Ltypescript
      ;; Expression. I3b/1 covers the variants needed by tiny.compact's
      ;; public_key body — bytevector literal, var-ref, tuple (array
      ;; literal), and call. Unknown variants emit a TODO placeholder so
      ;; the gap is visible in the generated code rather than crashing.
      ;;
      ;; `native-id-ht` is the eq-hashtable built by build-native-id-ht;
      ;; consulted at every `call` site to resolve the function-name id
      ;; back to its native-entry (and thus its Rust binding name).
      ;; seq-stmt-rust: render one effect statement of a `(seq ...)`
      ;; expression block (the guard asserts the typer wraps around
      ;; trapping unsigned arithmetic). Used by expr-rust's `seq` case.
      ;; Asserts render via cond-rust (with current-var-substitution +
      ;; current-witness/circuit-id-ht) so user pure-circuit calls and
      ;; field accesses in the guard lower correctly; other expressions
      ;; render via expr-rust as `<expr>;`.
      ;;
      ;; Returns two values: the rendered statement string and either #f
      ;; or a `(var-name . rust-name)` pair naming a binding the statement
      ;; introduced, so expr-rust's `seq` clause can thread it into
      ;; current-var-substitution for the statements that follow.
      (define (seq-stmt-rust e native-id-ht)
        (nanopass-case (Ltypescript Expression) e
          [(assert ,src ,expr0 ,mesg)
           (let ([cstr (guard (c [#t #f])
                         (cond-rust expr0 (current-var-substitution)
                                    native-id-ht
                                    (current-witness-id-ht)
                                    (current-circuit-id-ht)))])
             (cond
               [(or (not cstr) (rendered-has-todo? cstr))
                (rust-feature-error src 'pure-circuit-body-emission
                  "seq guard assert unrenderable")]
               [else (values (format "compact_assert!(~a, ~s);" cstr
                                     (if (string? mesg) mesg ""))
                             #f)]))]
          [(= ,src ,var-name ,expr^)
           ;; G1: a let*-lifted temp assignment nested inside a `seq`
           ;; block. The statement-level renderer already lowers these —
           ;; see stmt-pure-body-rust's stmt->assignment clause — but a
           ;; `seq` prefix reached this renderer and fell through to
           ;; expr-rust, which has no `(=)` clause, so the whole body
           ;; bailed with `no walker shape matched`.
           ;;
           ;; The shape arises whenever a trapping arithmetic operand is
           ;; itself let*-lifted, which the typer does for struct-field
           ;; projections: `now - att.createdAt <= policy.maxAge`
           ;; lowers to `(= %t.6 (seq (= %t.7 (elt-ref att createdAt))
           ;; (seq (assert (>= now %t.7) ...) (- now %t.7))))` — two
           ;; nested assignment levels, where a plain scalar operand
           ;; produces only one. Plain `-`/`+`/`*` on locals, and the
           ;; same projection under `==`, only ever hit the outer level,
           ;; which is why every ingredient compiled in isolation.
           ;;
           ;; Rendering reuses the same helpers as the statement-level
           ;; path (uniquify-rust-name over current-var-substitution, then
           ;; expr-rust for the RHS) rather than introducing a second
           ;; projection-aware renderer. The RHS renders under the
           ;; pre-binding substitution — a lifted temp never references
           ;; itself.
           (let* ([binds (current-var-substitution)]
                  [proposed (symbol->string (camel->snake (id-sym var-name)))]
                  [rust-name (uniquify-rust-name proposed binds)]
                  ;; Render at the RHS wrapper's own target — the lifted
                  ;; temp's declared type — so a bare literal / widening
                  ;; materialises (task 2.1, assignment route).
                  [rhs (expr-rust-typed expr^ (expr-expected-type expr^) native-id-ht)])
             (values (format "let ~a = ~a;" rust-name rhs)
                     (cons var-name rust-name)))]
          [else
           (values (string-append (expr-rust e native-id-ht) ";") #f)]))

      ;; expr-rust-typed: render `expr` against the Compact type expected by
      ;; its use position. Binds `current-expr-expected-type` for the dynamic
      ;; extent of the render so the safe-cast / literal clauses below can
      ;; materialise the typechecker's coercion. Every boundary that knows its
      ;; destination type calls this instead of `expr-rust`; with the default
      ;; #f (any un-wired caller) rendering is byte-identical to before.
      (define (expr-rust-typed expr expected native-id-ht)
        ;; Always bind, even to #f: a boundary that renders a sub-expression
        ;; at a DIFFERENT destination than its enclosing one (a call argument
        ;; under a const RHS, an arithmetic operand) must be able to clear an
        ;; inherited expectation as well as set one. Binding #f where the
        ;; enclosing extent already has #f is byte-identical to not binding.
        (parameterize ([current-expr-expected-type expected])
          (expr-rust expr native-id-ht)))

      ;; cmp-operand-rust: render one ordering/equality comparison operand at
      ;; the joined operand type `joined-type`. The typechecker wraps a
      ;; narrower operand in `(safe-cast <joined> <own> ...)`
      ;; (analysis-passes.ss relational-/equality-operator), so rendering at
      ;; `joined-type` materialises exactly the lossless zero-extension a
      ;; mixed-width site needs and leaves the wider side (un-wrapped) at its
      ;; own minimal Rust width. A bare integer literal is peeled (rendered
      ;; un-suffixed) so it unifies with the other operand through Rust
      ;; inference — EXCEPT when the join is Field, where an integer literal
      ;; can never unify with the `Fr` struct and must be materialised as an
      ;; `Fr` (`field-literal-rust`, which picks the lossless width).
      ;; `joined-type` is the comparison node's own type
      ;; for `==`/`!=`; for ordering nodes (which carry only `bits`) it is
      ;; recovered from whichever operand the typer wrapped.
      (define (cmp-operand-rust expr joined-type native-id-ht)
        (cond
          [(literal-int-expr? expr)
           (if (type-is-tfield? joined-type)
               (field-literal-rust (literal-int-expr? expr))
               (expr-rust-typed expr #f native-id-ht))]
          [else (expr-rust-typed expr joined-type native-id-ht)]))

      ;; cmp-join-type: the joined operand type of an ordering (`< <= > >=`)
      ;; node, which carries only `bits`. Both operands were `maybe-safecast`ed
      ;; to the same join by the typer, so the first operand that carries a
      ;; `safe-cast` wrapper names it; when neither does, the operands already
      ;; share a type and no coercion is needed (#f).
      (define (cmp-join-type expr1 expr2)
        (or (expr-expected-type expr1) (expr-expected-type expr2)))

      ;; render-tail-at: render a return-value expression at the declared
      ;; return type, preserving the bare-literal peel for primitive (Uint)
      ;; returns — Rust infers the literal from the function's return type,
      ;; so suffixing would churn a both-literal ternary's arms — while a
      ;; Field return materialises the literal as an `Fr` (`field-literal-rust`;
      ;; an integer can never unify with the `Fr` struct). `render-at` is a one-argument
      ;; thunk taking the expected type so this composes over either the
      ;; expression (`expr-rust`) or constructor (`ctor-expr-rust`) renderer.
      (define (render-tail-at expr return-type render-at)
        (cond
          [(literal-int-expr? expr)
           (if (type-is-tfield? return-type)
               (field-literal-rust (literal-int-expr? expr))
               (render-at #f))]
          [else (render-at return-type)]))

      (define (expr-rust expr native-id-ht)
        (nanopass-case (Ltypescript Expression) expr
          [(safe-cast ,src ,type ,type^ ,expr^)
           ;; Materialise the typer's coercion when a use position has
           ;; declared an expected type; otherwise peel, byte-identical to the
           ;; pre-change behaviour. `materialize-at-type` returns #f when the
           ;; wrapper is one the inner rendering already satisfies (same type
           ;; / same Rust width / a literal Rust can infer), so the peel path
           ;; still runs. `materialize-at-type` binds the inner render's
           ;; expected type itself, so a nested value is never coerced twice.
           (let ([expected (current-expr-expected-type)])
             (if expected
                 (or (materialize-at-type src expected type^ expr^
                       (lambda (e) (expr-rust e native-id-ht)))
                     (expr-rust expr^ native-id-ht))
                 (expr-rust expr^ native-id-ht)))]
          [(quote ,src ,datum)
           (cond
             [(bytevector? datum) (bytevector->rust-array-literal datum)]
             [(boolean? datum) (if datum "true" "false")]
             [(and (integer? datum) (exact? datum))
              ;; A bare literal in a typed position (e.g. the RHS of
              ;; `const x: Field = 0;` or a Field struct-member initialiser)
              ;; must carry the destination's Rust type: `Fr::from(0u64)` for
              ;; Field, the width suffix for a `Uint<N>`. With no expectation
              ;; the literal stays bare (byte-identical).
              (let ([expected (current-expr-expected-type)])
                (cond
                  [(and expected (type-is-tfield? expected))
                   (field-literal-rust datum)]
                  [(and expected (type-peel-tunsigned expected)) =>
                   (lambda (nat) (format "~a~a" datum (uint-rust-width nat)))]
                  [else (format "~a" datum)]))]
             [else (rust-feature-error src 'quote-variant
                     "unsupported quote datum: ~s" datum)])]
          [(var-ref ,src ,var-name)
           ;; Bug-1 fix: consult current-var-substitution before falling
           ;; back to the default snake-case rendering. ctor-expr-rust
           ;; dynamically binds the parameter from its local-binds so
           ;; inlined sub-expressions reaching this path (via
           ;; emit-ledger-read-expr → expr->vm-value → expr-rust) still
           ;; resolve formal→actual substitutions from inline-circuit-call.
           (cond
             [(assq var-name (current-var-substitution)) => cdr]
             [else (symbol->string (camel->snake (id-sym var-name)))])]
          [(tuple ,src ,tuple-arg* ...)
           ;; Compact's `Vector<N, T>` lowers to a Rust `[T; N]`. The IR
           ;; uses `tuple` for both tuples and vectors at the value level;
           ;; the immediate caller (e.g. a native taking a Vector) knows
           ;; which form is wanted. For I3b/1 we render every `tuple` as a
           ;; Rust array literal — the only consumer is persistent_hash,
           ;; where the elements have identical type ([u8; 32]).
           ;;
           ;; When the enclosing position declared an aggregate expected
           ;; type (a `safe-cast` to `Vector<N, T>` recovered by the
           ;; caller), each element renders at the element type so a bare
           ;; literal element is coerced (`[0]` -> `[Fr::from(0u64)]`).
           (let* ([n (length tuple-arg*)]
                  [elt-types (expected-elt-types n)]
                  [parts
                   (map (lambda (ta et) (tuple-arg-rust ta native-id-ht et))
                        tuple-arg*
                        (or elt-types (make-list n #f)))])
             (string-append
               "["
               (let join ([xs parts] [acc ""])
                 (cond
                   [(null? xs) acc]
                   [(null? (cdr xs)) (string-append acc (car xs))]
                   [else (join (cdr xs) (string-append acc (car xs) ", "))]))
               "]"))]
          [(call ,src ,function-name ,expr* ...)
           (call-rust src function-name expr* native-id-ht)]
          [(default ,src ,type)
           ;; I3b/3: `default<T>` lowers to the type's zero value. Reuses
           ;; the K1 helper so tunsigned/tfield/tbytes/tenum/talias are
           ;; handled consistently with initial_state's per-field seed.
           (default-value-rust type)]
          [(== ,src ,type ,expr1 ,expr2)
           ;; I3b/3: equality comparison. Parenthesised so it composes
           ;; safely inside larger expressions (e.g. inside a Rust assert
           ;; macro call without surrounding parens being implicit).
           ;; Operands render at the comparison's own (joined) type so a
           ;; mixed-width operand widens losslessly and a Field literal
           ;; becomes `Fr::from(<n>u64)`.
           (format "(~a == ~a)"
                   (cmp-operand-rust expr1 type native-id-ht)
                   (cmp-operand-rust expr2 type native-id-ht))]
          [(not ,src ,expr)
           ;; F1.2: Boolean negation.
           (format "(!(~a))" (expr-rust expr native-id-ht))]
          [(and ,src ,expr1 ,expr2)
           ;; F1.2: short-circuit Boolean AND.
           (format "(~a && ~a)"
                   (expr-rust expr1 native-id-ht)
                   (expr-rust expr2 native-id-ht))]
          [(or ,src ,expr1 ,expr2)
           ;; F1.2: short-circuit Boolean OR.
           (format "(~a || ~a)"
                   (expr-rust expr1 native-id-ht)
                   (expr-rust expr2 native-id-ht))]
          [(elt-ref ,src ,expr ,elt-name ,nat)
           ;; F1.2: struct field access.
           (format "~a.~a"
                   (expr-rust expr native-id-ht)
                   (symbol->string elt-name))]
          [(public-ledger ,src ,ledger-field-name ,sugar? (,path-elt* ...) ,src^ ,adt-op ,expr* ...)
           ;; I3b/3: ledger read in expression position (e.g. inside an
           ;; `(==)` or as the RHS of a const-binding). Emits an inline
           ;; gather query against (current-qctx-ref) and decodes the
           ;; resulting AlignedValue using the same decoder table the
           ;; Ledger view uses. F1.2/2: passes expr* + native-id-ht to
           ;; cover ADT read-with-arg (Set.member etc).
           (emit-ledger-read-expr path-elt* adt-op expr* native-id-ht)]
          [(enum-ref ,src ,type ,elt-name)
           ;; E6: enum variant in expression position (pure circuit body).
           ;; Render as `EnumName::variant` (with Rust keyword escaping
           ;; via rust-variant-name). Used by election.successor — the
           ;; declared return type is the enum itself, so we must emit
           ;; typed variants rather than the bare u8 discriminant.
           (nanopass-case (Ltypescript Type) type
             [(tenum ,src^ ,enum-name ,elt-name^ ,elt-name* ...)
              (format "~a::~a"
                      (symbol->string enum-name)
                      (rust-variant-name elt-name))]
             [else
              (rust-feature-error src 'enum-ref-non-tenum
                "enum-ref ~a on non-tenum type"
                elt-name)])]
          [(+ ,src ,mbits ,expr1 ,expr2)
           ;; Iter 7 follow-up: unsigned addition. Renders via Rust's
           ;; `wrapping_add` so the bounded-Uint contract holds even if
           ;; the operation would overflow at the inferred Rust width —
           ;; Compact's typer requires an explicit `downcast-unsigned`
           ;; or wider target type around any expression that could
           ;; produce a value outside the source-side type's range, so
           ;; the wrap matches the post-downcast semantics. Both operands
           ;; are cast to the result width (mbits) via arith-binop-rust.
           (arith-binop-rust src "add" mbits expr1 expr2 native-id-ht)]
          [(- ,src ,mbits ,expr1 ,expr2)
           ;; Iter 7 follow-up: unsigned subtraction. See `+` clause.
           (arith-binop-rust src "sub" mbits expr1 expr2 native-id-ht)]
          [(* ,src ,mbits ,expr1 ,expr2)
           ;; Iter 7 follow-up: unsigned multiplication. See `+` clause.
           (arith-binop-rust src "mul" mbits expr1 expr2 native-id-ht)]
          [(downcast-unsigned ,src ,nat? ,nat ,expr)
           ;; Iter 7 follow-up: cast the inner expression to the Rust
           ;; unsigned type whose upper bound is `nat`. The downcast
           ;; appears around arithmetic whose declared output type is
           ;; narrower than its operands' inferred type (Compact's typer
           ;; inserts it for `(x * 2) as Uint<64>` and similar). The
           ;; expr-supported? gate already rejected non-ladder widths.
           ;;
           ;; The target width is also pushed down via `current-arith-suffix`
           ;; so nested arithmetic operands can apply a type suffix to
           ;; integer literals — Rust's `wrapping_mul` etc. are inherent
           ;; methods on `uN`, so the receiver must be a concrete `uN`
           ;; type (an unsuffixed `1.wrapping_mul(2)` would be rejected
           ;; with "can't call method on ambiguous numeric type").
           ;; Bug-11 (2026-06-29): pick the smallest Rust unsigned width
           ;; that can hold `nat`, mirroring uint-rust-width and the
           ;; generalised tunsigned-rust-suffix-for-bound. Pre-Bug-11
           ;; this rejected anything off the power-of-2-minus-1 ladder
           ;; (255/65535/u32::MAX/u64::MAX/u128::MAX), which surfaced as
           ;; `downcast-unsigned: unsupported target width` for any
           ;; `Uint<L..U>` arithmetic with a non-power-of-2 upper bound.
           ;; The on-state byte-width still tracks `uint-byte-length`,
           ;; so the cell-builder path (new_cell vs new_cell_bounded_uint)
           ;; routes the value through the right alignment descriptor.
           (let ([w (cond
                      [(or (not (integer? nat)) (not (exact? nat)) (negative? nat)) #f]
                      [(<= nat 255) "u8"]
                      [(<= nat 65535) "u16"]
                      [(<= nat 4294967295) "u32"]
                      [(<= nat 18446744073709551615) "u64"]
                      [(<= nat 340282366920938463463374607431768211455) "u128"]
                      [else #f])])
             (cond
               ;; `nat?` is the SOURCE bound, and the typer guarantees
               ;; (circuit-passes.ss `downcast-unsigned` typing rule) that it
               ;; is present exactly when the source is a `Uint`, and #f
               ;; exactly when the source is a `Field`. So #f here means
               ;; `Field as Uint<N>`.
               ;;
               ;; `Fr` is a struct (a re-export of
               ;; midnight_transient_crypto::curve::Fr), so the `(x) as uN`
               ;; below is a non-primitive cast — E0605. We were emitting it
               ;; from a compile that exited 0, so the break landed at
               ;; `cargo build` with no pointer back to the Compact source.
               ;; Narrowing an Fr needs a range-checking runtime helper that
               ;; does not exist yet; until it does, refuse.
               [(not nat?)
                (rust-feature-error src 'cast-from-field
                  "`Field as Uint<~s>`: ~a" nat
                  "narrowing a Field needs a range-checking runtime helper")]
               [(not w)
                (rust-feature-error src 'downcast-unsigned-width
                  "downcast-unsigned: unsupported target width ~s" nat)]
               [else
                (format "(~a) as ~a"
                        (parameterize ([current-arith-suffix w]
                                       [current-expr-expected-type #f])
                          (expr-rust expr native-id-ht))
                        w)]))]
          [(new ,src ,type ,expr* ...)
           ;; F2.2: struct-literal in pure-expression context (e.g. nested
           ;; inside a quote/tuple consumer). Renders each field via the
           ;; raw expr-rust path; for the body-walker context the
           ;; corresponding case in ctor-expr-rust is used instead.
           (let* ([st (struct-of-type type)]
                  [struct-name (and st (car st))]
                  [elt-name* (and st (cadr st))]
                  [elt-type* (and st (caddr st))])
             (cond
               [(or (not st)
                    (not (fx= (length expr*) (length elt-name*))))
                (rust-feature-error src 'struct-literal-mismatch
                  "struct-literal mismatch (st=~s, expected=~a, got=~a)"
                  (and st (car st))
                  (and st (length elt-name*))
                  (length expr*))]
               [else
                (let* ([field-strs
                        (map (lambda (name e mtype)
                               (format "~a: ~a"
                                       (symbol->string name)
                                       (expr-rust-typed e mtype native-id-ht)))
                             elt-name* expr* elt-type*)])
                  (string-append
                    (struct-rust-name-of type struct-name)
                    " { "
                    (let join ([xs field-strs] [acc ""])
                      (cond
                        [(null? xs) acc]
                        [(null? (cdr xs)) (string-append acc (car xs))]
                        [else (join (cdr xs)
                                    (string-append acc (car xs) ", "))]))
                    " }"))]))]
          [(!= ,src ,type ,expr1 ,expr2)
           ;; F1.3: inequality. Parenthesised so it composes safely inside
           ;; larger expressions (assert macro args, && operands). Mirrors
           ;; the `==` rendering; structs derive PartialEq/Eq so `!=` is
           ;; structural for user types just as `==` is.
           (format "(~a != ~a)"
                   (cmp-operand-rust expr1 type native-id-ht)
                   (cmp-operand-rust expr2 type native-id-ht))]
          [(< ,src ,bits ,expr1 ,expr2)
           ;; F1.3: ordering comparisons on Uint<N> (Rust unsigned ints).
           ;; Operands render at the typer's joined operand type (recovered
           ;; from whichever side it wrapped) so a mixed-width comparison
           ;; widens the narrower side; bare literals are peeled. The `bits`
           ;; field records only the width, so it cannot name the join.
           (let ([jt (cmp-join-type expr1 expr2)])
             (format "(~a < ~a)"
                     (cmp-operand-rust expr1 jt native-id-ht)
                     (cmp-operand-rust expr2 jt native-id-ht)))]
          [(<= ,src ,bits ,expr1 ,expr2)
           (let ([jt (cmp-join-type expr1 expr2)])
             (format "(~a <= ~a)"
                     (cmp-operand-rust expr1 jt native-id-ht)
                     (cmp-operand-rust expr2 jt native-id-ht)))]
          [(> ,src ,bits ,expr1 ,expr2)
           (let ([jt (cmp-join-type expr1 expr2)])
             (format "(~a > ~a)"
                     (cmp-operand-rust expr1 jt native-id-ht)
                     (cmp-operand-rust expr2 jt native-id-ht)))]
          [(>= ,src ,bits ,expr1 ,expr2)
           (let ([jt (cmp-join-type expr1 expr2)])
             (format "(~a >= ~a)"
                     (cmp-operand-rust expr1 jt native-id-ht)
                     (cmp-operand-rust expr2 jt native-id-ht)))]
          [(seq ,src ,expr* ... ,expr)
           ;; F1.4: a guarded expression block. The Compact typer wraps
           ;; trapping unsigned arithmetic (e.g. `currentDay - dateOfBirthDays`
           ;; whose result must be non-negative) in
           ;; `(seq (assert <underflow-guard> ...) <expr>)` and let*-lifts
           ;; it into a const temp. Render as a Rust block
           ;; `{ <guards>; <expr> }` so the assert fires before the value
           ;; is produced, matching Compact's trap-on-underflow semantics
           ;; (Rust's `wrapping_sub` would otherwise silently wrap). The
           ;; guard assert's condition renders via cond-rust using the
           ;; current var-substitution + circuit/witness id hashtables so
           ;; calls to user pure circuits / field accesses lower correctly.
           ;;
           ;; G1: the prefix statements are folded rather than mapped so a
           ;; binding one of them introduces (seq-stmt-rust's `(=)` clause)
           ;; is in scope for the statements after it and for the tail —
           ;; the same left-to-right substitution threading
           ;; stmt-pure-body-rust does at statement level. Prefixes that
           ;; bind nothing leave the substitution untouched, so bodies
           ;; without a nested assignment render exactly as before.
           (let loop ([xs expr*] [binds (current-var-substitution)] [rev-pre '()])
             (cond
               [(pair? xs)
                (let-values ([(line bind)
                              (parameterize ([current-var-substitution binds])
                                (seq-stmt-rust (car xs) native-id-ht))])
                  (loop (cdr xs)
                        (if bind (cons bind binds) binds)
                        (cons line rev-pre)))]
               [else
                (let ([pre (reverse rev-pre)]
                      [tail (guard (c [#t #f])
                              (parameterize ([current-var-substitution binds])
                                (expr-rust expr native-id-ht)))])
                  (cond
                    [(or (not tail) (rendered-has-todo? tail))
                     (rust-feature-error src 'pure-circuit-body-emission
                       "seq tail expression unrenderable")]
                    [else
                     (string-append
                       "{ "
                       (let join ([xs pre] [acc ""])
                         (cond
                           [(null? xs) acc]
                           [(null? (cdr xs)) (string-append acc (car xs))]
                           [else (join (cdr xs) (string-append acc (car xs) " "))]))
                       (if (pair? pre) " " "")
                       tail
                       " }")]))]))]
          [else
           (rust-feature-error #f 'expr-variant
             "unhandled Expression variant in expr-rust")]))

      ;; emit-ledger-read-expr: render a `(public-ledger ... read)` IR
      ;; node as a Rust block expression that runs a gather query and
      ;; decodes the result. Used by expr-rust / ctor-expr-rust when the
      ;; read appears in expression position (clear()'s `apk == authority`,
      ;; in_state's inlined `state == s`, zerocash.spend's
      ;; `nullifiers.member(old)` and `commitments.checkRoot(...)`).
      ;;
      ;; The qctx source comes from the (current-qctx-ref) dynamic
      ;; parameter so circuit-body emissions read from
      ;; `&ctx.current_query_context` while constructor-body emissions
      ;; would read from `&qctx`.
      ;;
      ;; Optional `expr*` carries the ADT-read's runtime arguments (the
      ;; element for Set.member, the candidate root for
      ;; HistoricMerkleTree.checkRoot, the key for Map.member / lookup).
      ;; When present, we route through expand-vm-code + the gather
      ;; vminstr renderer so the resulting OpProgramGather chain mirrors
      ;; the adt-op's vm-code (including the additional push and
      ;; member / eq / root steps).
      ;;
      ;; A20: the no-arg branch (expr* empty) also routes through
      ;; expand-vm-code first so reads whose vm-code does more than
      ;; `(dup) (idx ...) (popeq)` — Set.size, Set.isEmpty, Map.size,
      ;; Map.isEmpty, List.isEmpty, List.length — render the correct
      ;; OpProgramGather chain rather than silently miscompiling to
      ;; the hardcoded template. Cell.read and Counter.read also flow
      ;; through expand-vm-code and produce the same shape as before.
      ;; The hardcoded template survives as a last-resort fallback for
      ;; any read whose vm-code instructions vminstr->gather-builder-call
      ;; doesn't yet recognise.
      ;; emit-struct-field-zero-read: F2.2 — emit a gather block for
      ;; reading a ledger cell whose value is a tstruct, decoding only
      ;; the leading (field-0) atom with the provided decoder. The
      ;; AlignedValue layout for a tstruct prepends field-0's atoms,
      ;; so `decoder(_av)` reads exactly the projected field's bytes.
      ;; Mirrors the no-arg branch of emit-ledger-read-expr but skips
      ;; the whole-struct decoder check.
      (define (emit-struct-field-zero-read path-elt* decoder)
        (let* ([path-idx*
                (map (lambda (pe)
                       (nanopass-case (Ltypescript Path-Element) pe
                         [,path-index path-index]
                         [else #f]))
                     path-elt*)]
               [idx-lines
                (let join ([xs path-idx*] [acc ""])
                  (cond
                    [(null? xs) acc]
                    [else
                     (join (cdr xs)
                           (string-append
                             acc
                             (format "                .idx_at_index(~au8, false)\n" (car xs))))]))])
          (string-append
            "{\n"
            "            let _gather_ops = OpProgramGather::<DefaultDB>::new()\n"
            "                .dup(0)\n"
            idx-lines
            "                .popeq(true)\n"
            "                .build();\n"
            "            let _gather_results = query_for_read(\n"
            "                " (current-qctx-ref) ",\n"
            "                &_gather_ops,\n"
            "                None,\n"
            "                &initial_cost_model(),\n"
            "            )\n"
            "            .map_err(|e| CompactError::AssertionFailed(format!(\"ledger query failed: {:?}\", e)))?;\n"
            "            let _av = match _gather_results.events.last() {\n"
            "                Some(midnight_compact_runtime::onchain_vm::result_mode::GatherEvent::Read(av)) => av,\n"
            "                _ => return Err(CompactError::AssertionFailed(\"ledger: expected Read event\".into())),\n"
            "            };\n"
            "            " decoder "(_av)?\n"
            "        }")))

      (define (emit-ledger-read-expr path-elt* adt-op . opt-args)
        (let* ([expr* (if (pair? opt-args) (car opt-args) '())]
               [native-ht (and (pair? opt-args) (pair? (cdr opt-args)) (cadr opt-args))])
          (nanopass-case (Ltypescript ADT-Op) adt-op
            [(,ledger-op ,op-class (,adt-name (,adt-formal* ,adt-arg*) ...) ((,var-name* ,type*) ...) ,type ,vm-code)
             (cond
               [(not (eq? op-class 'read))
                (rust-feature-error #f 'ledger-op-non-read
                  "non-read public-ledger op in expression position (op-class=~a)"
                  op-class)]
               [else
                (let* ([path-idx*
                        (map (lambda (pe)
                               (nanopass-case (Ltypescript Path-Element) pe
                                 [,path-index path-index]
                                 [else #f]))
                             path-elt*)]
                       [decoder (decoder-for-type type)])
                  (cond
                    [(memv #f path-idx*)
                     (rust-feature-error #f 'ledger-read-non-index-path
                       "ledger read with non-index path element")]
                    [(not decoder)
                     (rust-feature-error #f 'ledger-read-decoder-missing
                       "no decoder available for ledger read type")]
                    [(not (null? expr*))
                     ;; F1.2/2: ADT read-with-arg path. Run the adt-op's
                     ;; vm-code through expand-vm-code with the concrete
                     ;; path + lifted-arg substitutions, then render each
                     ;; vminstr as one line of the OpProgramGather chain.
                     ;; Falls back to `unimplemented!()` if any step is
                     ;; unsupported (e.g. an arg shape vm-value->rust
                     ;; doesn't yet handle).
                     (or
                       (emit-ledger-read-expr-with-args
                         path-elt* adt-op expr* native-ht decoder)
                       (rust-feature-error #f 'adt-read-with-arg-lowering
                         "ADT read-with-arg lowering failed for ledger op"))]
                    [else
                     ;; A20: route no-arg adt-op reads through the same
                     ;; expand-vm-code machinery as the with-arg path so
                     ;; the gather chain mirrors the actual vm-code
                     ;; (e.g. Set.size's `(size)`, Set.isEmpty's
                     ;; `(push align-0-8) (eq)`, List.isEmpty's `(type)`).
                     ;; The previous hardcoded `dup → idx → popeq`
                     ;; template happened to match Cell.read and
                     ;; Counter.read but silently miscompiled any read
                     ;; whose vm-code contained additional instructions.
                     ;; Fall back to that template only when expansion
                     ;; itself fails (so existing Cell/Counter coverage
                     ;; is preserved even for adt-ops whose vm-code
                     ;; touches instructions vminstr->gather-builder-call
                     ;; doesn't yet recognise).
                     (or
                       (emit-ledger-read-expr-with-args
                         path-elt* adt-op '() native-ht decoder)
                       (let ([idx-lines
                              (let join ([xs path-idx*] [acc ""])
                                (cond
                                  [(null? xs) acc]
                                  [else
                                   (join (cdr xs)
                                         (string-append
                                           acc
                                           (format "                .idx_at_index(~au8, false)\n" (car xs))))]))])
                         (string-append
                           "{\n"
                           "            let _gather_ops = OpProgramGather::<DefaultDB>::new()\n"
                           "                .dup(0)\n"
                           idx-lines
                           "                .popeq(true)\n"
                           "                .build();\n"
                           "            let _gather_results = query_for_read(\n"
                           "                " (current-qctx-ref) ",\n"
                           "                &_gather_ops,\n"
                           "                None,\n"
                           "                &initial_cost_model(),\n"
                           "            )\n"
                           "            .map_err(|e| CompactError::AssertionFailed(format!(\"ledger query failed: {:?}\", e)))?;\n"
                           "            let _av = match _gather_results.events.last() {\n"
                           "                Some(midnight_compact_runtime::onchain_vm::result_mode::GatherEvent::Read(av)) => av,\n"
                           "                _ => return Err(CompactError::AssertionFailed(\"ledger: expected Read event\".into())),\n"
                           "            };\n"
                           "            " decoder "(_av)?\n"
                           "        }")))]))])])))

      ;; emit-ledger-read-expr-with-args: F1.2/2 — render the ADT read
      ;; via expand-vm-code, producing a Rust block expression. Returns
      ;; #f if the path / args / vminstrs can't be lowered, so the
      ;; caller can fall back to the placeholder. `native-ht` may be #f
      ;; for cases where the caller didn't supply one — we then can't
      ;; render non-literal args and bail out.
      (define (emit-ledger-read-expr-with-args path-elt* adt-op expr* native-ht decoder)
        (nanopass-case (Ltypescript ADT-Op) adt-op
          [(,ledger-op ,op-class (,adt-name (,adt-formal* ,adt-arg*) ...) ((,var-name* ,type*) ...) ,type ,vm-code)
           (cond
             [(not (fx= (length expr*) (length var-name*))) #f]
             [else
              (let ([path-vals (map path-elt->vm-value path-elt*)]
                    [expr-vals
                     (map (lambda (e)
                            (if native-ht
                                (expr->vm-value e native-ht)
                                (expr->vm-value e)))
                          expr*)])
                (cond
                  [(memv #f path-vals) #f]
                  [(memv #f expr-vals) #f]
                  [else
                   (let* ([arg-alist
                           (append (map cons adt-formal* adt-arg*)
                                   (map (lambda (vn v)
                                          (cons (id-sym vn) v))
                                        var-name* expr-vals))]
                          [vminstr*
                           (guard (c [#t #f])
                             (expand-vm-code #f path-vals #f arg-alist
                               (vm-code-code vm-code)))]
                          [lines (and vminstr*
                                      (map vminstr->gather-builder-call vminstr*))])
                     (cond
                       [(or (not lines) (memv #f lines)) #f]
                       [else
                        (string-append
                          "{\n"
                          "            let _gather_ops = OpProgramGather::<DefaultDB>::new()\n"
                          (apply string-append lines)
                          "                .build();\n"
                          "            let _gather_results = query_for_read(\n"
                          "                " (current-qctx-ref) ",\n"
                          "                &_gather_ops,\n"
                          "                None,\n"
                          "                &initial_cost_model(),\n"
                          "            )\n"
                          "            .map_err(|e| CompactError::AssertionFailed(format!(\"ledger query failed: {:?}\", e)))?;\n"
                          "            let _av = match _gather_results.events.last() {\n"
                          "                Some(midnight_compact_runtime::onchain_vm::result_mode::GatherEvent::Read(av)) => av,\n"
                          "                _ => return Err(CompactError::AssertionFailed(\"ledger: expected Read event\".into())),\n"
                          "            };\n"
                          "            " decoder "(_av)?\n"
                          "        }")]))]))])]))

      ;; tuple-arg-rust: emit a Rust expression for a Tuple-Argument
      ;; (`single` or `spread`). I3b/1 only needs `single`; `spread` emits a
      ;; TODO placeholder.
      (define (tuple-arg-rust ta native-id-ht . maybe-expected)
        (let ([expected (and (pair? maybe-expected) (car maybe-expected))])
        (nanopass-case (Ltypescript Tuple-Argument) ta
          [(single ,src ,expr)
           ;; `expected` (when supplied) is the element type the enclosing
           ;; aggregate/vector declares, so a bare literal element is
           ;; coerced (`[0]` feeding `Vector<1, Field>` -> `Fr::from(0u64)`).
           ;; Unsullied callers pass #f and keep the bare rendering.
           (expr-rust-typed expr expected native-id-ht)]
          [(spread ,src ,nat ,expr)
           (rust-feature-error src 'tuple-spread
             "tuple spread (`...expr`) not supported")])))

      ;; expected-elt-types: element types of the current expected type when
      ;; it is an aggregate of arity `n` (a `Vector<n, T>` or `Tuple<...>`),
      ;; else #f. Lets the `tuple`/aggregate clauses render every element at
      ;; the element type the enclosing wrapper declares (task 2.7).
      (define (expected-elt-types n)
        (let ([t (current-expr-expected-type)])
          (and t (type-elt-types t n))))

      ;; call-rust: emit a Rust call expression for `(call src function-name
      ;; expr* ...)`. Resolves the function-name id to a native binding via
      ;; native-id-ht. For native calls whose Rust signature doesn't line up
      ;; 1:1 with Compact's (e.g. persistent_hash takes `&[u8]` whereas
      ;; Compact's persistentHash takes a typed value), emit a specialised
      ;; form. For natives with a clean 1:1 mapping (none yet exercised by
      ;; tiny.compact), emit a vanilla `<rust-name>(<arg>, ...)`. For
      ;; non-native (user-defined) circuit calls, fall back to the
      ;; snake-cased local name — a follow-up wedge will resolve these
      ;; properly.
      ;; pure-call-arg-rust: render a call argument via expr-rust, then
      ;; suffix `.clone()` when the argument is a var-ref or a
      ;; var-rooted field access whose type is not Rust `Copy`. Pure
      ;; circuits are free functions taking args by value, so a non-Copy
      ;; struct passed as `foo(x)` would move `x` and break later reads
      ;; of `x` in the same body (a validation circuit that passes the
      ;; same record to several helpers in sequence). `.clone()` borrows, so the owner
      ;; stays usable. Mirrors arg-rust-clone-if-var's decision logic but
      ;; renders via expr-rust (the pure walker's renderer) and consults
      ;; current-formal-arg-types (seeded by emit-pure-circuit) for the
      ;; Copy check. Also used for by-value native args (jubjub_point_x
      ;; takes `JubjubPoint` by value and is invoked twice on the same
      ;; field in a && expression).
      (define (pure-call-arg-rust e native-id-ht)
        ;; Render at the argument's own `safe-cast` target (the callee's
        ;; declared formal type) so a bare literal / mixed-width / aggregate
        ;; argument is materialised; see task 2.5.
        (let ([rendered (expr-rust-typed e (expr-expected-type e) native-id-ht)]
              [stripped (expr-strip-cast e)])
          (nanopass-case (Ltypescript Expression) stripped
            [(var-ref ,src ,var-name)
             (if (var-ref-known-copy? var-name)
                 rendered
                 (string-append rendered ".clone()"))]
            [(elt-ref ,src ,expr ,elt-name ,nat)
             (cond
               [(not (elt-ref-rooted-in-var? stripped)) rendered]
               [(elt-ref-known-copy? stripped) rendered]
               [else (string-append rendered ".clone()")])]
            [else rendered])))

      ;; native-vector-elem-strs: render a vector-typed native argument
      ;; (persistentHash / transientHash) as a list of
      ;; `AlignedValue::from(<elem>)` atoms. The argument is a `(tuple ...)`
      ;; typically wrapped in `(safe-cast <Vector<N,T>> ...)`; peeling the
      ;; cast exposes the tuple and the wrapper's target supplies the
      ;; element type, so a bare literal element is coerced
      ;; (`[0]` -> `AlignedValue::from(Fr::from(0u64))`). A non-tuple
      ;; argument renders whole at its own expected type.
      (define (native-vector-elem-strs arg native-id-ht)
        (let ([t (expr-expected-type arg)])
          (nanopass-case (Ltypescript Expression) (expr-strip-cast arg)
            [(tuple ,src ,tuple-arg* ...)
             (let* ([n (length tuple-arg*)]
                    [elt-types (and t (type-elt-types t n))])
               (map (lambda (ta et)
                      (format "midnight_compact_runtime::AlignedValue::from(~a)"
                              (tuple-arg-rust ta native-id-ht et)))
                    tuple-arg*
                    (or elt-types (make-list n #f))))]
            [else
             (list (format "midnight_compact_runtime::AlignedValue::from(~a)"
                           (expr-rust-typed arg t native-id-ht)))])))

      (define (call-rust src function-name expr* native-id-ht)
        (let ([ne (eq-hashtable-ref native-id-ht function-name #f)]
              [sym (id-sym function-name)])
          (cond
            [(or (eq? sym 'some) (eq? sym 'none))
             ;; I3b/4: stdlib circuits with no native binding — go through
             ;; the runtime-side `std_lib` path. Without the circuit pelt
             ;; here we can't inject `::<T>`, but tiny.compact's get()
             ;; reaches this through ctor-call-rust which does have the
             ;; pelt and ascribes the generic — this branch is a safety
             ;; net for any future ascription-free use site.
             (let ([args
                    (map (lambda (e)
                           (expr-rust-typed e (expr-expected-type e) native-id-ht))
                         expr*)])
               (format "midnight_compact_runtime::std_lib::~a(~a)"
                       sym
                       (let join ([xs args] [acc ""])
                         (cond
                           [(null? xs) acc]
                           [(null? (cdr xs)) (string-append acc (car xs))]
                           [else (join (cdr xs)
                                       (string-append acc (car xs) ", "))]))))]
            [(and ne (equal? (native-entry-rust-function ne)
                             "midnight_compact_runtime::persistent_hash"))
             ;; R3: alignment-aware lowering of Compact's
             ;; `persistentHash<T>(value)`. The TS path constructs an
             ;; `AlignedValue` from `value` (via the runtime type
             ;; descriptor) and feeds the alignment-framed byte stream to
             ;; SHA-256; see `node_modules/@midnight-ntwrk/compact-runtime/
             ;; src/built-ins.ts::persistentHash` and the wasm-side
             ;; `onchain-runtime-wasm/src/primitives.rs::persistent_hash`.
             ;;
             ;; We mirror that by converting each constituent of the
             ;; argument to an `AlignedValue` and calling
             ;; `persistent_hash_aligned`, which delegates to
             ;; `ValueReprAlignedValue::binary_repr` + the upstream SHA-256
             ;; persistent hash. When the argument is a `Vector<N, T>` the
             ;; IR represents it as a `(tuple ...)` and we lift each
             ;; element separately so each gets its own alignment atom; for
             ;; any other shape we wrap the single argument in a one-element
             ;; slice.
             ;;
             ;; Previous emit (I3b/1):
             ;;   `persistent_hash(&[a, b, ...].concat()).0`
             ;; produces byte-identical output for uniform `Bytes<N>` inputs
             ;; (tiny.compact's `public_key`), but diverges for mixed-type,
             ;; `Field`-, or `Compress`-bearing inputs because raw byte
             ;; concat skips the per-atom framing (Bytes<n> zero-padding,
             ;; Fr little-endian normalisation, Compress hashing).
             (cond
               [(fx= (length expr*) 1)
                (let ([arg (car expr*)])
                  (let ([elt-strs
                         ;; If the single argument is a `tuple` IR node
                         ;; (Compact-level Vector), break it apart so each
                         ;; element becomes its own AlignedValue. Otherwise,
                         ;; emit a one-element slice.
                         (native-vector-elem-strs arg native-id-ht)])
                    (string-append
                      "midnight_compact_runtime::std_lib::persistent_hash_aligned(&["
                      (let join ([xs elt-strs] [acc ""])
                        (cond
                          [(null? xs) acc]
                          [(null? (cdr xs)) (string-append acc (car xs))]
                          [else (join (cdr xs)
                                      (string-append acc (car xs) ", "))]))
                      "])")))]
               [else
                (rust-feature-error src 'persistent-hash-arity
                  "persistentHash arity ~a not yet supported (expected 1)"
                  (length expr*))])]
            [(and ne (equal? (native-entry-rust-function ne)
                             "midnight_compact_runtime::transient_hash"))
             ;; R5: alignment-aware lowering of Compact's
             ;; `transientHash<A>(value): Field`. The upstream
             ;; `transient_hash(elems: &[Fr]) -> Fr` takes a field-element
             ;; slice, but Compact surfaces a single typed value. Mirror
             ;; persistent_hash's R3 path: convert each constituent to an
             ;; `AlignedValue` and call `transient_hash_aligned`, which
             ;; field-reprs the concatenated alignment into a `Vec<Fr>`
             ;; preimage (via `ValueReprAlignedValue: FieldRepr`) and
             ;; Poseidon-hashes it — matching the TS runtime's
             ;; `transientHash(alignment, toValue(value))`. A `Vector<N,T>`
             ;; arg lowers to a `(tuple ...)` and is broken apart so each
             ;; element gets its own alignment atom; any other shape wraps
             ;; the single argument in a one-element slice.
             (cond
               [(fx= (length expr*) 1)
                (let ([arg (car expr*)])
                  (let ([elt-strs
                         (native-vector-elem-strs arg native-id-ht)])
                    (string-append
                      "midnight_compact_runtime::std_lib::transient_hash_aligned(&["
                      (let join ([xs elt-strs] [acc ""])
                        (cond
                          [(null? xs) acc]
                          [(null? (cdr xs)) (string-append acc (car xs))]
                          [else (join (cdr xs) (string-append acc (car xs) ", "))]))
                      "])")))]
               [else
                (rust-feature-error src 'transient-hash-arity
                  "transientHash arity ~a not yet supported (expected 1)"
                  (length expr*))])]
            [(and ne (equal? (native-entry-rust-function ne)
                             "midnight_compact_runtime::persistent_commit"))
             ;; R4: lowering of Compact's
             ;; `persistentCommit<T>(value, opening)`. The upstream
             ;; `persistent_commit<T: BinaryHashRepr + ?Sized>(value: &T,
             ;; opening: HashOutput)` takes `value` by reference and
             ;; `opening` (`Bytes<32>` = `[u8;32]`, Copy) by value. We
             ;; render `persistent_commit(&<value>, <opening>)`. The
             ;; borrow is non-moving so `value` remains usable in the
             ;; surrounding body. `BinaryHashRepr` is impl'd for `[u8;N]`,
             ;; all unsigned/signed ints, bool, tuples, and user structs
             ;; (via the H6 `Aligned` + `From<S> for Value` blanket that
             ;; gives `AlignedValue: From<S>`, whose `BinaryHashRepr`
             ;; delegates through `ValueReprAlignedValue`) — so
             ;; `Bytes<N>`, `Uint<N>`, and struct-typed values all
             ;; type-check. Mirrors the TS runtime's `persistentCommit`
             ;; (alignment-framed SHA-256 commit).
             (cond
               [(fx= (length expr*) 2)
                ;; `persistent_commit<T: BinaryHashRepr>(&T, HashOutput) ->
                ;; HashOutput`. The Compact `persistentCommit<A>(v, o):
                ;; Bytes<32>` surfaces `[u8; 32]`, so wrap the opening in
                ;; `HashOutput(...)` and extract `.0` from the result.
                ;; `HashOutput` isn't in midnight_compact_runtime's curated prelude
                ;; but is reachable as
                ;; `midnight_compact_runtime::base_crypto::hash::HashOutput`
                ;; (midnight-base-crypto re-exports the crate as
                ;; `base_crypto` and `hash` is a pub module).
                (string-append
                  "midnight_compact_runtime::persistent_commit(&"
                  (expr-rust (car expr*) native-id-ht)
                  ", midnight_compact_runtime::base_crypto::hash::HashOutput("
                  (expr-rust (cadr expr*) native-id-ht)
                  ")).0")]
               [else
                (rust-feature-error src 'persistent-commit-arity
                  "persistentCommit arity ~a not yet supported (expected 2)"
                  (length expr*))])]
            [ne
             ;; A native with a 1:1 binding. Emit `<rust-name>(<arg>, ...)`.
             ;; Args render via pure-call-arg-rust so by-value natives
             ;; that take a non-Copy struct / JubjubPoint (jubjub_point_x,
             ;; jubjub_point_y) get a defensive `.clone()` when the same
             ;; value is read again later in the body — a key-comparison
             ;; circuit calls
             ;; jubjubPointX then jubjubPointY on the same public key
             ;; inside a `&&` expression; without the clone the first
             ;; call moves the field and the second fails to borrow.
             (let ([rust-name (native-call-site-rust ne)]
                   [args
                    (map (lambda (e) (pure-call-arg-rust e native-id-ht)) expr*)])
               (string-append
                 rust-name
                 "("
                 (let join ([xs args] [acc ""])
                   (cond
                     [(null? xs) acc]
                     [(null? (cdr xs)) (string-append acc (car xs))]
                     [else (join (cdr xs) (string-append acc (car xs) ", "))]))
                 ")"))]
            [else
             ;; A user-defined circuit call. Resolve via
             ;; current-circuit-id-ht (threaded by emit-pure-circuit): if
             ;; the callee is a user pure circuit, route to
             ;; `pure_circuits::<snake>(...)` — both exported (`pub fn`)
             ;; and non-exported (`pub(crate) fn`) pure circuits land in
             ;; the `pure_circuits` module. Args use pure-call-arg-rust so
             ;; non-Copy struct args are cloned (the callee takes them by
             ;; value). Impure circuits and unknown callees keep the
             ;; existing non-native-call error — the impure walker
             ;; resolves pure-circuit calls earlier via ctor-call-rust, so
             ;; this else is only reached during pure-circuit emission
             ;; where current-circuit-id-ht is populated.
             (let ([c (eq-hashtable-ref (current-circuit-id-ht) function-name #f)])
               (cond
                 [(and c (id-pure? function-name))
                  (let ([rust-name (id->rust-name function-name)]
                        [args (map (lambda (e) (pure-call-arg-rust e native-id-ht)) expr*)])
                    ;; Append `?` so the `Result<T, CompactError>` a pure
                    ;; circuit returns is unwrapped at the call site. Every
                    ;; generated position that calls a pure circuit (pure-
                    ;; circuit bodies, impure circuit bodies, constructors,
                    ;; conditions) lives inside a function returning
                    ;; `Result<_, CompactError>`, so `?` is valid. The
                    ;; `Ok(...)` tail-wrap (Phase 5) wraps the already-`?`-ed
                    ;; call as `Ok(pure_circuits::foo(...)?)` — a single `?`.
                    (string-append
                      "pure_circuits::"
                      (symbol->string rust-name)
                      "("
                      (let join ([xs args] [acc ""])
                        (cond
                          [(null? xs) acc]
                          [(null? (cdr xs)) (string-append acc (car xs))]
                          [else (join (cdr xs) (string-append acc (car xs) ", "))]))
                      ")?"))]
                 [else
                  (rust-feature-error src 'non-native-call
                    "call to non-native circuit ~a not supported in this position"
                    (id-sym function-name))]))])))

      ;; stmt-pure-body-rust: render the body of a pure circuit as a Rust
      ;; block (a sequence of `let`-bindings / statements terminated by a
      ;; tail expression, or a single expression in tail position).
      ;;   - `(const src local expr)` and lifted `(statement-expression
      ;;     (= src var expr))` bindings become `let <name> = <rhs>;` and
      ;;     thread into `local-binds` so later references resolve.
      ;;   - `(const src (local* ...))` forward declarations are no-ops
      ;;     (the assignment lands later as a `(=)`).
      ;;   - `if/else`, `assert`, and tail `statement-expression` forms
      ;;     render via pure-stmt-rust.
      ;; `local-binds` is an alist `(var-name . rust-name)` threaded
      ;; through the statement walk and bound to `current-var-substitution`
      ;; around expression rendering so expr-rust resolves locals.
      ;; `witness-id-ht` / `circuit-id-ht` are passed to cond-rust so
      ;; if/assert conditions that call user pure circuits route to
      ;; `pure_circuits::...` (and witness calls, if any, resolve).
      ;; Returns the Rust source string, or #f to signal the caller
      ;; should fall back to `unimplemented!()`.
      ;;
      ;; pure-stmt-rust: render one VALUE-producing statement of a pure
      ;; circuit body (if / assert / tail expression). Const-bindings and
      ;; lifted assignments are intercepted by stmt-pure-body-rust's loop
      ;; before reaching here. Returns a Rust source string (terminated by
      ;; `;` for non-tail statements, no terminator for a tail
      ;; expression), or #f on unsupported shapes.
      (define (pure-stmt-rust stmt native-id-ht witness-id-ht circuit-id-ht
                               local-binds last?)
        (parameterize ([current-var-substitution local-binds])
        (nanopass-case (Ltypescript Statement) stmt
          [(if ,src ,expr0 ,stmt1 ,stmt2)
           (let ([cond-str (guard (c [#t #f])
                             (cond-rust expr0 local-binds
                                        native-id-ht
                                        witness-id-ht
                                        circuit-id-ht))]
                 [then-str (stmt-pure-body-rust stmt1 native-id-ht
                                                witness-id-ht circuit-id-ht
                                                local-binds #f)]
                 [else-str (stmt-pure-body-rust stmt2 native-id-ht
                                                witness-id-ht circuit-id-ht
                                                local-binds #f)])
             (cond
               [(or (not cond-str) (not then-str) (not else-str)) #f]
               [(or (rendered-has-todo? cond-str)
                    (rendered-has-todo? then-str)
                    (rendered-has-todo? else-str)) #f]
               [else
                (format "if ~a {\n            ~a\n        } else {\n            ~a\n        }"
                        cond-str then-str else-str)]))]
          [(if ,src ,expr0 ,stmt1)
           (let ([cond-str (guard (c [#t #f])
                             (cond-rust expr0 local-binds
                                        native-id-ht
                                        witness-id-ht
                                        circuit-id-ht))]
                 [then-str (stmt-pure-body-rust stmt1 native-id-ht
                                                witness-id-ht circuit-id-ht
                                                local-binds #f)])
             (cond
               [(or (not cond-str) (not then-str)) #f]
               [(or (rendered-has-todo? cond-str)
                    (rendered-has-todo? then-str)) #f]
               [else
                (format "if ~a {\n            ~a\n        }"
                        cond-str then-str)]))]
          [(statement-expression ,expr)
           (nanopass-case (Ltypescript Expression) expr
             [(assert ,src ,expr0 ,mesg)
              (let ([cond-str
                     (guard (c [#t #f])
                       (cond-rust expr0 local-binds
                                  native-id-ht
                                  witness-id-ht
                                  circuit-id-ht))])
                (cond
                  [(or (not cond-str) (rendered-has-todo? cond-str)) #f]
                  [else
                   (format "compact_assert!(~a, ~s);" cond-str
                           (if (string? mesg) mesg ""))]))]
             [else
              ;; In tail position render at the declared return type so a
              ;; statement-lifted `return <literal>` coerces (task 2.2);
              ;; non-tail statements keep the un-ascribed rendering. A
              ;; primitive literal is peeled so a both-literal ternary's
              ;; arms stay byte-identical.
              (let ([s (guard (c [#t #f])
                         (if last?
                             (render-tail-at expr (current-pure-return-type)
                                             (lambda (exp)
                                               (expr-rust-typed expr exp native-id-ht)))
                             (expr-rust-typed expr #f native-id-ht)))])

                (cond
                  [(or (not s) (rendered-has-todo? s)) #f]
                  [last? s]
                  [else (string-append s ";")]))])]
          [else #f])))

      ;; wrap-ok?: when #t (the default, used by emit-pure-circuit) the
      ;; rendered body's tail is wrapped as `Ok(...)` so the block is a
      ;; `Result<_, CompactError>`; assert-only / unit bodies end with
      ;; `Ok(())`. Recursion into if-branches (pure-stmt-rust's if arms)
      ;; passes #f so the branches are bare expressions — the enclosing
      ;; `if` expression is then wrapped by the top-level call.
      (define (stmt-pure-body-rust stmt native-id-ht witness-id-ht circuit-id-ht
                                   local-binds . maybe-wrap-ok?)
        (let ([wrap-ok? (or (null? maybe-wrap-ok?) (car maybe-wrap-ok?))])
          (let ([stmts (stmt-flatten stmt)])
          (let loop ([xs stmts] [binds local-binds] [acc '()])
            (cond
              [(null? xs)
               ;; A body of only declarations (no value-statement) — either
               ;; a truly empty body (assertValidSchemaCapabilities: a
               ;; placeholder pure circuit with only comments) or a
               ;; unit-returning circuit whose every stmt is a const /
               ;; assignment / decl-only. Emit the accumulated `let;` lines
               ;; and a trailing `()` so the block type-checks as `()`; a
               ;; truly empty body emits just `()`.
               (let ([joined
                      (let join ([rs (reverse acc)] [out ""])
                        (cond
                          [(null? rs) out]
                          [(null? (cdr rs)) (string-append out (car rs))]
                          [else (join (cdr rs) (string-append out (car rs) "\n        "))]))])
                 (let ([unit-tail (if wrap-ok? "Ok(())" "()")])
                   (cond
                     [(string=? joined "") unit-tail]
                     [else (string-append joined "\n        " unit-tail)])))]
              [(const-binding (car xs))
               =>
               (lambda (b)
                 (let* ([var-name (car b)]
                        [rhs (cdr b)]
                        [proposed (symbol->string (camel->snake (id-sym var-name)))]
                        [rust-name (uniquify-rust-name proposed binds)]
                        ;; G1: reserve rust-name while rendering the RHS so a
                        ;; temp lifted from inside it (seq-stmt-rust's `(=)`
                        ;; clause) uniquifies instead of shadowing this
                        ;; binder. The RHS can't reference var-name itself, so
                        ;; adding the entry early only affects name selection.
                        [rhs-binds (cons (cons var-name rust-name) binds)])
                   ;; Render the RHS at the binding's declared type (task
                   ;; 2.1, pure route). The typer wraps a consequential RHS
                   ;; in `safe-cast` to the declared type; a bare literal
                   ;; therefore becomes `Fr::from(<n>u64)` / `<n>u64` and a
                   ;; widening materialises.
                   (let ([s (guard (c [#t #f])
                              (parameterize ([current-var-substitution rhs-binds]
                                             [current-expr-expected-type
                                              (or (const-binding-decl-type (car xs))
                                                  (expr-expected-type rhs))])
                                (expr-rust rhs native-id-ht)))])
                     (cond
                       [(or (not s) (rendered-has-todo? s)) #f]
                       [else
                        (loop (cdr xs)
                              (cons (cons var-name rust-name) binds)
                              (cons (format "let ~a = ~a;" rust-name s) acc))]))))]
              [(const-decl-only? (car xs))
               ;; Forward declaration `(const src (local* ...))` — no-op;
               ;; the assignment lands later as a `(statement-expression
               ;; (= ...))` which the next clause renders as `let`.
               (loop (cdr xs) binds acc)]
              [(stmt->assignment (car xs))
               =>
               (lambda (a)
                 (let* ([var-name (car a)]
                        [rhs (cdr a)]
                        [proposed (symbol->string (camel->snake (id-sym var-name)))]
                        [rust-name (uniquify-rust-name proposed binds)]
                        ;; G1: see the const-binding clause above — reserve
                        ;; rust-name for the duration of the RHS render.
                        [rhs-binds (cons (cons var-name rust-name) binds)])
                   (let ([s (guard (c [#t #f])
                              (parameterize ([current-var-substitution rhs-binds]
                                             [current-expr-expected-type (expr-expected-type rhs)])
                                (expr-rust rhs native-id-ht)))])
                     (cond
                       [(or (not s) (rendered-has-todo? s)) #f]
                       [else
                        (loop (cdr xs)
                              (cons (cons var-name rust-name) binds)
                              (cons (format "let ~a = ~a;" rust-name s) acc))]))))]
              [else
               ;; A value-producing statement. The last one renders as a
               ;; tail expression (no `;`); earlier ones as `<expr>;`.
               (let ([last? (null? (cdr xs))])
                 (let ([s (pure-stmt-rust (car xs) native-id-ht
                                           witness-id-ht circuit-id-ht
                                           binds last?)])
                   (cond
                     [(not s) #f]
                     [last?
                      ;; tail element. `s` is either a value expression
                      ;; (rendered without `;`) or an assert statement
                      ;; (`compact_assert!(...);`, ends with `;`). When
                      ;; wrap-ok?: wrap a value tail in `Ok(...)`, and
                      ;; follow an assert tail with `Ok(())` so the block
                      ;; yields `Result<_, CompactError>`.
                      (let* ([n (string-length s)]
                             [value-tail?
                              (or (= n 0)
                                  (not (char=? (string-ref s (- n 1)) #\;)))])
                        (let ([acc
                               (cond
                                 [(and wrap-ok? value-tail?)
                                  (cons (format "Ok(~a)" s) acc)]
                                 [(and wrap-ok? (not value-tail?))
                                  (cons "Ok(())" (cons s acc))]
                                 [else (cons s acc)])])
                          (let join ([rs (reverse acc)] [out ""])
                            (cond
                              [(null? rs) out]
                              [(null? (cdr rs)) (string-append out (car rs))]
                              [else (join (cdr rs) (string-append out (car rs) "\n        "))]))))]
                     [else (loop (cdr xs) binds (cons s acc))])))])))))

      ;; emit-pure-circuit: emit a pure circuit as a free function inside
      ;; `mod pure_circuits`. No ctx — just the declared args and a direct
      ;; return type. For the narrow tiny.compact-style shape (a single
      ;; expression in statement position) we render the expression
      ;; directly; richer bodies (sequenced asserts / tail calls to other
      ;; user pure circuits / if-guarded asserts / const bindings) are
      ;; walked by stmt-pure-body-rust. Anything the walker can't handle
      ;; keeps an `unimplemented!()` placeholder via rust-feature-error.
      ;;
      ;; Exported circuits become `pub fn` (part of the crate's public
      ;; surface). Non-exported user pure circuits (e.g. zerocash's
      ;; `commitment_from_coin_info`, `derive_nullifier`) become
      ;; `pub(crate) fn` — callable from anywhere in the generated
      ;; contract crate (notably impure-circuit bodies via
      ;; `pure_circuits::foo(...)`) but not part of the contract's
      ;; downstream API.
      ;;
      ;; current-circuit-id-ht / current-witness-id-ht are parameterised
      ;; around the body so expr-rust/call-rust (which don't take the id
      ;; hashtables explicitly) can route calls to user pure circuits as
      ;; `pure_circuits::<snake>(...)`.
      (define (emit-pure-circuit cdefn native-id-ht witness-id-ht circuit-id-ht)
        (nanopass-case (Ltypescript Program-Element) cdefn
          [(circuit ,src ,function-name (,arg* ...) ,type ,stmt)
           (out (format "    ~a fn ~a("
                        (if (id-exported? function-name) "pub" "pub(crate)")
                        (id->rust-name function-name)))
           (let loop ([arg* arg*] [first? #t])
             (cond
               [(null? arg*) (void)]
               [else
                (nanopass-case (Ltypescript Argument) (car arg*)
                  [(,var-name ,type)
                   (out (format "~a~a: ~a"
                                (if first? "" ", ")
                                (camel->snake (id-sym var-name))
                                (type-rust type)))])
                (loop (cdr arg*) #f)]))
           (out (format ") -> Result<~a, CompactError> {\n" (type-rust type)))
           (parameterize ([current-formal-arg-types (build-formal-arg-type-ht arg*)]
                          [current-circuit-id-ht circuit-id-ht]
                          [current-witness-id-ht witness-id-ht]
                          ;; Task 2.2: the pure walker threads the declared
                          ;; return type into tail position so a
                          ;; statement-lifted return tail coerces.
                          [current-pure-return-type type])
             (let ([body (stmt-pure-body-rust stmt native-id-ht
                                              witness-id-ht circuit-id-ht '()
                                              #t)])
               (cond
                 [body (out (format "        ~a\n" body))]
                 [else
                  (rust-feature-error src 'pure-circuit-body-emission
                    "no walker shape matched pure circuit body for ~a"
                    (id-sym function-name))])))
           (out "    }\n\n")]))

      ;; pl-array->public-bindings: flatten a `public-ledger-array` IR node
      ;; into a list of `public-binding`s. Ported from
      ;; typescript-passes.ss::pl-array->public-bindings — nested arrays are
      ;; walked recursively; leaves (`public-binding`) accumulate.
      (define (pl-array->public-bindings pl-array)
        (let f ([pl-array pl-array] [pb* '()])
          (nanopass-case (Ltypescript Public-Ledger-Array) pl-array
            [(public-ledger-array ,pl-array-elt* ...)
             (fold-right
               (lambda (pl-array-elt pb*)
                 (nanopass-case (Ltypescript Public-Ledger-Array-Element) pl-array-elt
                   [,pl-array (f pl-array pb*)]
                   [,public-binding (cons public-binding pb*)]))
               pb*
               pl-array-elt*)])))

      ;; exported-public-binding?: #t if the binding's field-name id is
      ;; marked `id-exported?`. Mirrors typescript-passes.ss's predicate of
      ;; the same name. Non-exported ledger fields (e.g. tiny.compact's
      ;; `authority`, `state`) are dropped from the Rust public surface.
      (define (exported-public-binding? public-binding)
        (nanopass-case (Ltypescript Public-Ledger-Binding) public-binding
          [(,src ,ledger-field-name (,path-index* ...) ,type)
           (id-exported? ledger-field-name)]))

      ;; binding-field-name: extract the (snake-cased) Rust identifier for a
      ;; reader method from a public-binding.
      (define (binding-field-name public-binding)
        (nanopass-case (Ltypescript Public-Ledger-Binding) public-binding
          [(,src ,ledger-field-name (,path-index* ...) ,type)
           (camel->snake (id-sym ledger-field-name))]))

      ;; binding-path-indices: extract the list of path indices (integers)
      ;; that locate this field inside the on-chain state.
      (define (binding-path-indices public-binding)
        (nanopass-case (Ltypescript Public-Ledger-Binding) public-binding
          [(,src ,ledger-field-name (,path-index* ...) ,type) path-index*]))

      ;; binding-type: extract the binding's declared type (the ADT, e.g.
      ;; `(tadt Counter ...)` or `(tadt Cell ...)`).
      (define (binding-type public-binding)
        (nanopass-case (Ltypescript Public-Ledger-Binding) public-binding
          [(,src ,ledger-field-name (,path-index* ...) ,type) type]))

      ;; tadt-name=?: returns #t when `type` is a tadt with the given
      ;; adt-name (symbol). Used by emit-initial-state's R1/K1.1 dispatch
      ;; to pick the right per-ADT builder (new_map / new_merkle_tree /
      ;; new_historic_merkle_tree) instead of new_cell(Default::default()).
      (define (tadt-name=? type name)
        (nanopass-case (Ltypescript Type) type
          [(tadt ,src ,adt-name ([,adt-formal* ,adt-arg*] ...) ,vm-expr (,adt-op* ...) (,adt-rt-op* ...))
           (eq? adt-name name)]
          [(talias ,src ,nominal? ,type-name ,type) (tadt-name=? type name)]
          [else #f]))

      ;; type-is-tvector?: returns #t when `type` is a tvector (after
      ;; de-aliasing). Used by emit-initial-state to route vector ledger
      ;; field seeds through new_cell_array (since `[T; N]: Into<AlignedValue>`
      ;; isn't impl'd upstream).
      (define (type-is-tvector? type)
        (nanopass-case (Ltypescript Type) type
          [(tvector ,src ,len ,type) #t]
          [(talias ,src ,nominal? ,type-name ,type) (type-is-tvector? type)]
          [else #f]))

      ;; tunsigned-bounded?: returns #t when `type` is a `tunsigned` whose
      ;; byte-length doesn't match the underlying Rust integer width's byte
      ;; count — i.e. a `Uint<L..U>` with a non-power-of-two byte-length.
      ;; Used by emit-initial-state to route those seeds through
      ;; `new_cell_bounded_uint(0u128, N)` so the on-state alignment
      ;; descriptor matches TS. Fixed-width `Uint<N>` (N ∈ {8,16,32,64,128})
      ;; stays on the `new_cell(0uN)` path.
      (define (tunsigned-bounded? type)
        (nanopass-case (Ltypescript Type) type
          [(tunsigned ,src ,nat) (not (uint-byte-length-matches-rust-width? nat))]
          [(talias ,src ,nominal? ,type-name ,type) (tunsigned-bounded? type)]
          [else #f]))

      ;; tunsigned-byte-length: byte-length of the `AlignmentAtom::Bytes`
      ;; descriptor for a `tunsigned` type. Mirrors TS's `byte-length` —
      ;; ceil(bit_length(max_value) / 8). Used by tunsigned-bounded? routing.
      (define (tunsigned-byte-length type)
        (nanopass-case (Ltypescript Type) type
          [(tunsigned ,src ,nat) (number->string (uint-byte-length nat))]
          [(talias ,src ,nominal? ,type-name ,type) (tunsigned-byte-length type)]
          [else "0"]))

      ;; tadt-merkle-height: given a MerkleTree / HistoricMerkleTree tadt,
      ;; extract the Nat height argument (the first adt-arg). The Public-
      ;; Ledger-ADT-Arg grammar permits either a nat or a type; for the
      ;; height position we expect a nat literal (see midnight-ledger.ss
      ;; declarations — `[Nat nat]` formal). Falls back to "32" if the
      ;; shape is unexpected so the emitter never crashes.
      (define (tadt-merkle-height type)
        (nanopass-case (Ltypescript Type) type
          [(tadt ,src ,adt-name ([,adt-formal* ,adt-arg*] ...) ,vm-expr (,adt-op* ...) (,adt-rt-op* ...))
           (cond
             [(and (pair? adt-arg*) (number? (car adt-arg*)))
              (number->string (car adt-arg*))]
             [else "32"])]
          [(talias ,src ,nominal? ,type-name ,type) (tadt-merkle-height type)]
          [else "32"]))

      ;; tadt-read-op-type: given a binding's tadt, find the ADT operation
      ;; with op-class `read` and return its result type. Falls back to the
      ;; binding type itself if no read op is present (shouldn't happen for
      ;; ledger fields, but keep us robust).
      (define (tadt-read-op-type type)
        (nanopass-case (Ltypescript Type) type
          [(tadt ,src ,adt-name ([,adt-formal* ,adt-arg*] ...) ,vm-expr (,adt-op* ...) (,adt-rt-op* ...))
           (let loop ([ops adt-op*])
             (cond
               [(null? ops) type]
               [else
                (let ([result
                       (nanopass-case (Ltypescript ADT-Op) (car ops)
                         [(,ledger-op ,op-class (,adt-name (,adt-formal* ,adt-arg*) ...) ((,var-name* ,type*) ...) ,type ,vm-code)
                          (if (eq? op-class 'read) type #f)])])
                  (or result (loop (cdr ops))))]))]
          [else type]))

      ;; decoder-for-type: pick the `midnight_compact_runtime::std_lib::decode_*`
      ;; helper that turns an AlignedValue back into the Rust type returned
      ;; by `type-rust`. Mirrors `uint-rust-width` for the integer cases.
      (define (decoder-for-type type)
        (nanopass-case (Ltypescript Type) type
          [(tunsigned ,src ,nat)
           (cond
             [(<= nat 255) "midnight_compact_runtime::std_lib::decode_u8"]
             [(<= nat 65535) "midnight_compact_runtime::std_lib::decode_u16"]
             [(<= nat 4294967295) "midnight_compact_runtime::std_lib::decode_u32"]
             [(<= nat 18446744073709551615) "midnight_compact_runtime::std_lib::decode_u64"]
             [else "midnight_compact_runtime::std_lib::decode_u128"])]
          [(tfield ,src) "midnight_compact_runtime::std_lib::decode_fr"]
          [(tboolean ,src) "midnight_compact_runtime::std_lib::decode_bool"]
          [(tenum ,src ,enum-name ,elt-name ,elt-name* ...)
           ;; Bug-10 (2026-06-29): decode tenum-typed ledger reads as the
           ;; typed enum rather than as the raw u8 discriminant. Going
           ;; through `decode_via_field_repr::<EnumName>` (the user enum
           ;; derives FromFieldRepr via the H4 emission in
           ;; rust-passes-decls.ss) keeps both sides of an `==`/`!=`
           ;; comparison in the same Rust type. tiny's
           ;; `in_state(s: STATE)` body is `return state == s;` — the
           ;; LHS is this ledger read, the RHS is a STATE-typed formal,
           ;; and `decode_u8(_av)? == s` fails to compile (E0308). By
           ;; making the LHS a typed STATE, the walker's existing
           ;; tenum-name-of-type check on the `==` IR drives the RHS
           ;; enum-ref to render as `EnumName::variant`, eliminating
           ;; Bug-8's integer-coercion special case for tenum reads.
           ;; Boolean and Uint ledger reads still flow through their
           ;; integer decoders (decode_bool, decode_u8/u16/u32/u64/u128),
           ;; so Bug-8's short-circuit remains in force for those.
           (format "midnight_compact_runtime::std_lib::decode_via_field_repr::<~a>"
                   (symbol->string enum-name))]
          [(tbytes ,src ,len)
           (format "midnight_compact_runtime::std_lib::decode_bytes::<~a>" len)]
          [(tvector ,src ,len ,type)
           ;; Vector<N, T>: dispatch on element type. For Vector<N, Field>
           ;; and Vector<N, Uint<64>> we have dedicated decoders. Other
           ;; element types (Bytes<M>, user structs, nested vectors) need
           ;; their own helpers — leave them flagged so the gap is visible.
           (nanopass-case (Ltypescript Type) type
             [(tfield ,src)
              (format "midnight_compact_runtime::std_lib::decode_vector_fr::<~a>" len)]
             [(tunsigned ,src ,nat)
              ;; Iter 7: Uint<64> element → decode_vector_u64<N>. Wider
              ;; widths (u128) and narrower (u8/u16/u32) would each need
              ;; their own per-element decoder; ship only the common case.
              (cond
                [(and (> nat 4294967295)
                      (<= nat 18446744073709551615))
                 (format "midnight_compact_runtime::std_lib::decode_vector_u64::<~a>" len)]
                [else #f])]
             [else #f])]
          [(talias ,src ,nominal? ,type-name ,type) (decoder-for-type type)]
          [(topaque ,src ,opaque-type)
           ;; JubjubPoint (EmbeddedGroupAffine) has no FromFieldRepr impl —
           ;; orphan rules forbid one downstream — so a JubjubPoint-typed
           ;; ledger read (a `ledger signerKey: JubjubPoint` cell,
           ;; say) cannot go through
           ;; decode_via_field_repr. Route it to the orphan-safe
           ;; decode_jubjub_point helper. Other opaque tags stay flagged.
           (if (equal? opaque-type "JubjubPoint")
               "midnight_compact_runtime::std_lib::decode_jubjub_point"
               #f)]
          ;; A5: struct types (user-defined or stdlib like
          ;; `ContractAddress`) decode via the FromFieldRepr trait —
          ;; the H6/H7 emitter derives it for user structs, and
          ;; upstream stdlib structs in midnight-coin-structure /
          ;; midnight-base-crypto derive it natively. The Rust type
          ;; name comes through unqualified — it must already be in
          ;; scope at the call site (the codegen's `use
          ;; midnight_compact_runtime::*` import covers re-exported stdlib
          ;; types; user structs are emitted at module scope).
          [(tstruct ,src ,struct-name (,elt-name* ,type*) ...)
           (format "midnight_compact_runtime::std_lib::decode_via_field_repr::<~a>"
                   (struct-rust-name-of type struct-name))]
          [else #f]))

      ;; adt-is-collection?: ADTs whose `read` op-class is a per-element
      ;; presence/lookup check rather than a value extractor. For these,
      ;; the ledger view method (which currently decodes a single
      ;; AlignedValue → T) has incoherent semantics. Skip view emission
      ;; for collection-shaped ADTs; users access them through the typed
      ;; wrapper (E3 territory) or via direct StateValue inspection.
      (define (adt-is-collection? type)
        (nanopass-case (Ltypescript Type) type
          [(tadt ,src ,adt-name ([,adt-formal* ,adt-arg*] ...) ,vm-expr (,adt-op* ...) (,adt-rt-op* ...))
           (memq adt-name '(Map Set MerkleTree HistoricMerkleTree List))]
          [else #f]))

      ;; default-value-rust: emit the Rust expression for a type's default
      ;; (zero) value. Used by emit-initial-state to seed each ledger field
      ;; before the constructor body runs. Mirrors `type-rust`'s structure.
      ;; - tunsigned → `0u<width>` matching uint-rust-width
      ;; - tfield → `Fr::default()` (Fr derives Default = zero)
      ;; - tboolean → `false`
      ;; - tbytes N → `[0u8; N]`
      ;; - tenum → `0u8` (the first variant's discriminant; works whether
      ;;   the enum is exported as a Rust type or not, since the on-chain
      ;;   FieldRepr is u8 regardless)
      ;; - else → `Default::default()` as a best-effort fallback.
      (define (default-value-rust type)
        (nanopass-case (Ltypescript Type) type
          [(tunsigned ,src ,nat) (format "0~a" (uint-rust-width nat))]
          [(tfield ,src) "Fr::default()"]
          [(tboolean ,src) "false"]
          [(tbytes ,src ,len) (format "[0u8; ~a]" len)]
          [(tenum ,src ,enum-name ,elt-name ,elt-name* ...) "0u8"]
          [(tvector ,src ,len ,type)
           ;; Vector<N, T> defaults to an N-element array of T's default.
           ;; Requires T's default expression to be Copy (true for the
           ;; common primitives Fr/u*/bool/Bytes<M>).
           (format "[~a; ~a]" (default-value-rust type) len)]
          [(talias ,src ,nominal? ,type-name ,type) (default-value-rust type)]
          [(topaque ,src ,opaque-type)
           ;; Cat 4: give Opaque<"X"> a typed default so `new_cell(...)`
           ;; doesn't need explicit turbofish at the call site.
           ;; "string" goes through the OpaqueString newtype (orphan-rule
           ;; workaround for Aligned/FieldRepr on bare String); other
           ;; opaques stay as their direct mapping.
           (cond
             [(equal? opaque-type "string") "midnight_compact_runtime::std_lib::OpaqueString::default()"]
             [(equal? opaque-type "Uint8Array") "Vec::<u8>::new()"]
             ;; A23: JubjubPoint (EmbeddedGroupAffine) derives Default but the
             ;; generic `new_cell(Default::default())` can't infer the element
             ;; type, so seed the initial cell with a concrete typed default.
             [(equal? opaque-type "JubjubPoint") "midnight_compact_runtime::JubjubPoint::default()"]
             [else "Default::default()"])]
          [(tstruct ,src ,struct-name (,elt-name* ,type*) ...)
           ;; Maybe<T> needs an explicit type parameter so `Default::default()`
           ;; can infer the payload. Other named structs derive Default
           ;; (H5 emits `#[derive(... Default)]`), so the bare struct name works.
           (cond
             [(eq? struct-name 'Maybe)
              (let loop ([names elt-name*] [types type*])
                (cond
                  [(null? names) "Maybe::<()>::default()"]
                  [(eq? (car names) 'value)
                   (format "Maybe::<~a>::default()" (type-rust (car types)))]
                  [else (loop (cdr names) (cdr types))]))]
             [else (format "~a::default()" (struct-rust-name-of type struct-name))])]
          ;; No catch-all. `Default::default()` here would be a guess about a
          ;; type we did not recognise: it either fails to compile (no Default
          ;; impl — E0277, in generated code) or compiles and seeds a cell with
          ;; a value that is not the Compact default. The second is the #45
          ;; failure mode, so refuse instead.
          ;;
          ;; `default-supported?` in the walker mirrors the arms above and is
          ;; meant to gate this, but it is consulted at one of the seven
          ;; `default-value-rust` call sites. Nothing reaches this arm today —
          ;; every route probed was closed by the decoder gate or the body
          ;; walker first — but that is defence by accident. This makes it
          ;; defence by construction.
          [else
           (rust-feature-error #f 'default-value-unsupported-type
             "no Rust default for this type; ~a"
             "seeding it with `Default::default()` would guess at the initial state")]))

      ;; emit-ledger-view: emits the module-level `ledger()` factory and the
      ;; `Ledger<'a, D>` view struct with one accessor method per *exported*
      ;; ledger field. Each method reads its field via a dup + N idx_at_index
      ;; ops + popeq Op program, then decodes the resulting AlignedValue
      ;; through the appropriate `decode_*` helper based on the binding's
      ;; ADT `read` op result type. The popeq uses ResultModeGather so the
      ;; read value is captured as a GatherEvent::Read(AlignedValue).
      (define (emit-ledger-view ledger-field*)
        (out "pub struct Ledger<'a, D: DB = DefaultDB> {\n")
        (out "    state: &'a ChargedState<D>,\n")
        (out "}\n\n")
        (out "pub fn ledger<D: DB>(state: &ChargedState<D>) -> Ledger<'_, D> {\n")
        (out "    Ledger { state }\n")
        (out "}\n\n")
        (out "impl<'a, D: DB> Ledger<'a, D> {\n")
        ;; Flatten ledger-declaration -> bindings, keep only exported ones.
        (let* ([all-bindings
                (apply append
                  (map (lambda (ldecl)
                         (nanopass-case (Ltypescript Program-Element) ldecl
                           [(public-ledger-declaration ,pl-array ,lconstructor)
                            (pl-array->public-bindings pl-array)]
                           [else '()]))
                       ledger-field*))]
               [exported-bindings
                (filter exported-public-binding? all-bindings)])
          (for-each
            (lambda (pb)
              ;; R4: skip collection-shaped ADTs (Map/Set/MerkleTree/HMT/List).
              ;; Their `read` op returns Boolean (presence check), not a value
              ;; extractor — emitting a `fn name(&self) -> Result<bool, ...>`
              ;; that ignores the key/element being checked produces a
              ;; nonsensical API. Direct StateValue inspection or the typed
              ;; wrapper (E3) is the right access path for these.
              (unless (adt-is-collection? (binding-type pb))
              (let* ([name (binding-field-name pb)]
                     [path* (binding-path-indices pb)]
                     [read-type (tadt-read-op-type (binding-type pb))]
                     [rust-ret (type-rust read-type)]
                     ;; A missing decoder used to fall back to `decode_u64`
                     ;; behind a TODO comment (MediaNoxLabs/compact#45). That
                     ;; emits a call whose return type cannot match the
                     ;; declared one — e.g. a `Vector<3, Bytes<32>>` field
                     ;; produced `decode_u64` in tail position of
                     ;; `Result<[[u8; 32]; 3], _>`, an E0308 — from a compile
                     ;; that exited 0. Reachable with the smallest possible
                     ;; contract: one ledger field, no circuits, no
                     ;; constructor. Refuse instead of guessing a decoder.
                     [decoder (or (decoder-for-type read-type)
                                  (rust-feature-error #f 'ledger-read-decoder-missing
                                    "no ledger-read decoder for `~a`; ~a"
                                    rust-ret
                                    "the accessor cannot be emitted without one"))])
                (out (format "    pub fn ~a(&self) -> Result<~a, CompactError> {\n" name rust-ret))
                ;; Bucket-1: see note in J2 emitter — fully-qualify the
                ;; upstream ContractAddress so user-defined shadow types
                ;; don't break QueryContext::new.
                (out "        let qctx = QueryContext::new(self.state.clone(), midnight_compact_runtime::ContractAddress::default());\n")
                (out "        let ops = OpProgramGather::<D>::new()\n")
                (out "            .dup(0)\n")
                (for-each
                  (lambda (idx)
                    (out (format "            .idx_at_index(~au8, false)\n" idx)))
                  path*)
                (out "            .popeq(true)\n")
                (out "            .build();\n")
                (out "        let results = query_for_read(&qctx, &ops, None, &initial_cost_model())\n")
                (out "            .map_err(|e| CompactError::AssertionFailed(format!(\"ledger query failed: {:?}\", e)))?;\n")
                (out "        let av = match results.events.last() {\n")
                (out "            Some(midnight_compact_runtime::onchain_vm::result_mode::GatherEvent::Read(av)) => av,\n")
                (out "            _ => return Err(CompactError::AssertionFailed(\"ledger: expected Read event\".into())),\n")
                (out "        };\n")
                (out (format "        ~a(av)\n" decoder))
                (out "    }\n"))))
            exported-bindings))
        (out "}\n\n"))

      ;; emit-pure-circuits: emits the `pure_circuits` module containing one
      ;; free function per pure circuit declaration. Contracts with no pure
      ;; circuits (e.g. counter.compact) get an empty module.
      ;;
      ;; When any pure circuit is present, inject `use super::*;` at the
      ;; top so the function bodies (and the `Result<T, CompactError>`
      ;; signatures, which reference `CompactError`) see crate-level
      ;; types — `CompactError`, `Maybe<T>`, user structs emitted by H5-H7,
      ;; the `compact_assert!` macro, etc. — without qualification.
      ;; `use super::*;` reaches the parent's `use midnight_compact_runtime::*;`
      ;; glob, so `CompactError` / `compact_assert!` resolve. Contracts
      ;; with no pure circuits (e.g. counter.compact) get an empty
      ;; module with no `use`.
      (define (emit-pure-circuits pure-circuit* native-id-ht
                                   witness-id-ht circuit-id-ht)
        (out "pub mod pure_circuits {\n")
        (let ([has-any? (not (null? pure-circuit*))])
          (when has-any?
            (out "    use super::*;\n\n")))
        (for-each (lambda (c) (emit-pure-circuit c native-id-ht
                                                       witness-id-ht circuit-id-ht))
                  pure-circuit*)
        (out "}\n"))

      ;; emit-cargo-toml: emits a Cargo.toml alongside lib.rs so users can
      ;; `cargo build` the emitted contract directly. The compact-runtime
      ;; dep is pinned to the same version the lib.rs embeds via
      ;; check_runtime_version!.
      (define (emit-cargo-toml)
        (let ([port (get-target-port 'contract-cargo.toml)])
          (display-string
            (format
              "[package]
name = \"compact-contract\"
version = \"0.1.0\"
edition = \"2021\"

[lib]
path = \"lib.rs\"

[dependencies]
compact-runtime = \"~a\"
"
              runtime-version-string)
            port)))
