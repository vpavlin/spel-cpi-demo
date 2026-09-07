use borsh::{BorshDeserialize, BorshSerialize};
use serde::{Deserialize, Serialize};

/// Mirrors `ledger_core::Instruction` (in the sibling `ledger` project)
/// byte-for-byte: same variant name, same declaration order, same field types.
///
/// This is a **vendored copy**, not a shared dependency on ledger's own
/// `ledger_core` crate. Depending on it directly was the original design — it
/// is what `docs/tutorial.md`'s "External Instruction Enums" section sets up,
/// and why `ledger_core` exists at all — but a cross-project path dependency
/// does not survive the guest build. `cargo risczero build` compiles inside a
/// Docker container whose context root is the *project* directory, so a path
/// containing `..` escapes it:
///
/// ```text
/// # methods/guest/Cargo.toml: ledger_core = { path = "../../../ledger/ledger_core" }
/// error: failed to load manifest for dependency `ledger_core`
/// Caused by: failed to read `/ledger/ledger_core/Cargo.toml`
/// ```
///
/// Note where `../../../ledger/…` landed. A host-side `cargo check` resolves
/// it fine, so this only shows up minutes into a Docker build. Git
/// dependencies *do* survive — that is how the guest already pulls
/// `spel-framework` and `nssa_core` — so the shape that works across projects
/// is to depend on the callee's core crate by git rev.
///
/// A byte-identical mirror works in the meantime because `ChainedCall::new`
/// serializes the instruction structurally via `risc0_zkvm::serde::to_vec`
/// (variant index + fields), producing exactly the `instruction_data` ledger's
/// own dispatcher expects. The hazard is that nothing enforces it: reordering
/// variants in `ledger_core` changes the discriminant while this keeps
/// compiling. See NOTES.md §3.
#[derive(Debug, Clone, Serialize, Deserialize, BorshSerialize, BorshDeserialize)]
pub enum LedgerInstruction {
    /// Must match `ledger_core::Instruction::Record { amount: u64 }` exactly.
    Record { amount: u64 },
}
