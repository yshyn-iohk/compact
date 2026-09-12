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
// TS ⇄ Rust target parity gate (task 5.4).
//
// The Rust backend's acceptance criterion is TypeScript feature parity: any
// program `compactc --target ts` accepts MUST either compile under
// `--target rust` or be refused with a limitation documented in
// `docs/rust-backend-limitations.md`. A refusal at a position the TS target
// accepts and the docs do not explain is a defect.
//
// The gate compiles every top-level `examples/*.compact` with BOTH targets
// and asserts:
//   * Rust accepts ⇒ TS accepts (the Rust target is not more permissive
//     than the reference backend), and
//   * TS accepts ∧ Rust refuses ⇒ the refusal kind appears in
//     `docs/rust-backend-limitations.md`.
//
// The test is named with the `rust_backend_` prefix so the compiler-less CI
// lane (which excludes `--skip rust_backend_`) does not run it; the
// `compiler-backed` lane runs everything.

use std::path::{Path, PathBuf};
use std::process::Command;

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

fn compiler() -> PathBuf {
    let root = find_repo_root(Path::new(env!("CARGO_MANIFEST_DIR")))
        .expect("parity gate cannot run: no ancestor holds both examples/ and Cargo.toml");
    let (compactc, how) = match std::env::var_os("COMPACTC") {
        Some(p) => (PathBuf::from(p), "COMPACTC"),
        None => (root.join("result/bin/compactc"), "default path"),
    };
    assert!(
        compactc.exists(),
        "parity gate cannot run: no compactc at {} (from {}). \
         Run `nix build .#compactc`, or point COMPACTC at a real binary.",
        compactc.display(),
        how
    );
    compactc
}

/// Compile `src` with `target` into a fresh temp dir. Returns
/// `(exit code, combined output)`.
fn compile(compactc: &Path, target: &str, src: &Path, tag: &str) -> (Option<i32>, String) {
    let dir = std::env::temp_dir().join(format!(
        "compact-parity-{}-{}-{}",
        std::process::id(),
        target,
        tag
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create temp dir");

    let result = Command::new(compactc)
        .args(["--target", target, "--skip-zk"])
        .arg(src)
        .arg(dir.join("out"))
        .output()
        .expect("run compactc");

    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&result.stderr),
        String::from_utf8_lossy(&result.stdout)
    );
    let _ = std::fs::remove_dir_all(&dir);
    (result.status.code(), text)
}

/// The `(<kind>)` a `rust-feature-error` diagnostic names, or #f.
fn refusal_kind(text: &str) -> Option<&str> {
    let needle = "unsupported Compact construct (";
    let start = text.find(needle)? + needle.len();
    let rest = &text[start..];
    let end = rest.find(')')?;
    Some(&rest[..end])
}

#[test]
fn rust_backend_ts_target_parity() {
    let root = find_repo_root(Path::new(env!("CARGO_MANIFEST_DIR"))).expect("repo root");
    let compactc = compiler();
    let docs = std::fs::read_to_string(root.join("docs/rust-backend-limitations.md"))
        .expect("read rust-backend-limitations.md");

    let mut sources: Vec<PathBuf> = std::fs::read_dir(root.join("examples"))
        .expect("read examples/")
        .filter_map(|e| {
            let p = e.ok()?.path();
            (p.extension().and_then(|s| s.to_str()) == Some("compact")).then_some(p)
        })
        .collect();
    // The vendored dogfood contract is the oracle: TS accepts it, the pre-fix
    // Rust target refuses it (the ternary gap), so it exercises the
    // documented-refusal half of this gate. Compiling it in place resolves its
    // relative `include` directives.
    let dogfood = root.join(
        "examples/dogfood/digital-passport-credential/src/digital-passport-credential.compact",
    );
    if dogfood.exists() {
        sources.push(dogfood);
    }
    sources.sort();
    assert!(
        !sources.is_empty(),
        "parity gate found no examples/*.compact"
    );

    let mut undocumented = Vec::new();
    for src in &sources {
        let name = src.file_name().unwrap().to_string_lossy().to_string();
        let (ts_code, ts_text) = compile(&compactc, "ts", src, "ts");
        let (rust_code, rust_text) = compile(&compactc, "rust", src, "rust");

        let ts_ok = ts_code == Some(0);
        let rust_ok = rust_code == Some(0);

        // Rust is never more permissive than TS: a Rust acceptance must be a
        // TS acceptance too.
        assert!(
            !rust_ok || ts_ok,
            "{name}: the Rust target compiled a program the TS target refused. \
             The Rust target must not accept what the reference backend rejects.\n\
             --- TS output ---\n{ts_text}\n--- Rust output ---\n{rust_text}"
        );

        // TS-accepted but Rust-refused: the refusal must be documented.
        if ts_ok && !rust_ok {
            match refusal_kind(&rust_text) {
                Some(kind) if docs.contains(kind) => {}
                Some(kind) => undocumented.push(format!(
                    "{name}: Rust refused with undocumented kind `{kind}`"
                )),
                None => {
                    undocumented.push(format!("{name}: Rust refused with no attributable kind"))
                }
            }
        }
    }

    assert!(
        undocumented.is_empty(),
        "TS-accepted positions refused by the Rust target without a documented \
         limitation:\n  {}\n\nAdd each to docs/rust-backend-limitations.md (or fix the \
         lowering). A refusal at a position the TS target accepts is a defect.",
        undocumented.join("\n  ")
    );
}
