use borsh::{BorshDeserialize, BorshSerialize};
use serde::{Deserialize, Serialize};

/// Shared instruction enum for the `ledger` program.
///
/// This is defined here (rather than letting `#[lez_program]` generate its own
/// private enum) so that another program's guest binary — `vault`, in this
/// project — can construct a well-typed `Instruction::Record { amount }` value
/// and hand it to `ChainedCall::new(program_id, pre_states, &instruction)`,
/// which borsh/risc0-serializes it the same way ledger's own dispatcher expects.
///
/// See docs/tutorial.md "External Instruction Enums" — that section frames this
/// mechanism as being for FFI client generation, but the same shared-type need
/// applies to a caller program building a chained call into this one; nothing
/// else in the docs describes how a caller should construct `instruction_data`.
#[derive(Debug, Clone, Serialize, Deserialize, BorshSerialize, BorshDeserialize)]
pub enum Instruction {
    /// Add `amount` to the running total held in the `"log"` PDA.
    Record { amount: u64 },
}
