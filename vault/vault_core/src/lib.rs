use borsh::{BorshDeserialize, BorshSerialize};
use serde::{Deserialize, Serialize};

/// Mirrors `ledger_core::Instruction` (in the sibling `ledger` project)
/// byte-for-byte: same variant name, same declaration order, same field
/// types.
///
/// This is a **vendored copy**, not a shared path dependency on ledger's own
/// `ledger_core` crate. That was the original design (matching
/// docs/tutorial.md's "External Instruction Enums" section), but it doesn't
/// survive the guest build: `cargo risczero build` compiles inside a Docker
/// container whose build context is scoped to `vault`'s own project
/// directory (`docker build ... /tmp/agentwork2/vault`), so a
/// `path = "../../../ledger/ledger_core"` dependency in
/// `methods/guest/Cargo.toml` resolves fine under a plain host-side
/// `cargo check` (no sandboxing) but fails inside the container with:
///
/// ```text
/// error: failed to load manifest for dependency `ledger_core`
/// Caused by: failed to read `/ledger/ledger_core/Cargo.toml`
/// ```
///
/// Nothing in docs/ or skills/spel/ mentions this scoping — the tutorial's
/// External Instruction Enum example is same-project (multisig_core lives
/// inside the multisig project), and cli.md / macros.md don't discuss
/// cross-project guest dependencies at all. Found by reading the Docker
/// build log after `make build` failed (`ledger-build.log` /
/// `vault-build.log` in this repo's e2e run).
///
/// Since `ChainedCall::new` serializes the instruction structurally via
/// `risc0_zkvm::serde::to_vec` (variant index + fields — see
/// docs/reference/cli.md "Serialization (spel-cli internals)"), a
/// byte-identical mirror type here produces the exact same `instruction_data`
/// ledger's own generated `Instruction` enum expects, as long as this stays
/// in sync with `ledger/ledger_core/src/lib.rs`.
#[derive(Debug, Clone, Serialize, Deserialize, BorshSerialize, BorshDeserialize)]
pub enum LedgerInstruction {
    /// Must match `ledger_core::Instruction::Record { amount: u64 }` exactly.
    Record { amount: u64 },
}
