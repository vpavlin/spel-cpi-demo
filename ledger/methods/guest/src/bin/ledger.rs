#![no_main]

use spel_framework::prelude::*;
use nssa_core::account::Data;

risc0_zkvm::guest::entry!(main);

/// The ledger's running total, stored in the literal-seed `"log"` PDA.
///
/// `#[account_type]` registers this in the IDL so `spel inspect <PDA> --type LedgerLog`
/// can decode it — see docs/tutorial.md Step 2.
#[account_type]
#[derive(Debug, Clone, Default, BorshSerialize, BorshDeserialize)]
pub struct LedgerLog {
    pub total: u64,
}

// Use the shared `ledger_core::Instruction` enum instead of letting the macro
// generate its own, so `vault` (the caller) can construct the exact same type
// when building a `ChainedCall` into `record` below. See ledger_core/src/lib.rs
// for why.
#[lez_program(instruction = "ledger_core::Instruction")]
mod ledger {
    #[allow(unused_imports)]
    use super::*;

    /// Add `amount` to the running total in the `"log"` PDA.
    ///
    /// This is the only instruction ledger exposes: it doubles as "create" and
    /// "update". The docs only describe two fixed shapes for a PDA account —
    /// `#[account(init, pda = ...)]` (must not exist yet) or `#[account(mut,
    /// pda = ...)]` (must already exist, claim unchanged) — neither one alone
    /// allows the same instruction to both create the PDA on its first call
    /// and update it on every later call, which is what "record" needs to do
    /// since a single deposit path calls it repeatedly via chained calls.
    ///
    /// The fix (found by reading spel-framework-core/src/spel_output.rs —
    /// not documented in docs/reference/macros.md's Claims table, which only
    /// lists the constraint-driven AutoClaim mapping): bypass the idiomatic
    /// `SpelOutput::execute(...)` and call `execute_with_claims` directly with
    /// `AutoClaim::ClaimedIfDefault(Claim::Pda(seed))`. That claim helper
    /// checks the account's *current on-chain owner* at post-state-build time:
    /// if it's still `DEFAULT_PROGRAM_ID` (first call), it claims the PDA for
    /// this program; if this program already owns it (later calls), it claims
    /// nothing and the plain `mut` update goes through.
    #[instruction]
    pub fn record(
        #[account(mut, pda = literal("log"))]
        mut log: AccountWithMetadata,
        amount: u64,
    ) -> SpelResult {
        let data: Vec<u8> = log.account.data.clone().into();
        let mut state: LedgerLog = if data.is_empty() {
            LedgerLog::default()
        } else {
            borsh::from_slice(&data).map_err(|e| SpelError::DeserializationError {
                account_index: 0,
                message: e.to_string(),
            })?
        };

        state.total = state.total.checked_add(amount).ok_or(SpelError::Overflow {
            operation: "ledger record".to_string(),
        })?;

        let bytes = borsh::to_vec(&state).map_err(|e| SpelError::SerializationError {
            message: e.to_string(),
        })?;
        log.account.data = Data::try_from(bytes).map_err(|_| SpelError::custom(1, "log data too big"))?;

        let claim = claimed_if_default_pda(&[&seed_from_str("log")]);

        Ok(SpelOutput::execute_with_claims(
            &[log.account.clone()],
            &[claim],
            vec![],
        ))
    }
}

/// Build an `AutoClaim` that claims a PDA the first time it's touched (its
/// current on-chain owner is still `DEFAULT_PROGRAM_ID`) and leaves an
/// already-owned PDA's claim alone on every later call.
///
/// `AutoClaim::pda_from_seeds` (spel-framework-core) always returns
/// `AutoClaim::Claimed(..)`, which would make a *second* call to `record` fail
/// with `ClaimedNonDefaultAccount` (skills/spel/references/gotchas.md: "you
/// claimed an already-initialised account"). Reuse its seed-combination logic
/// (identical to the macro's own `[literal(...)]` derivation — SHA-256 for
/// multiple seeds, raw 32 bytes for one) and downgrade the result to
/// `ClaimedIfDefault`.
fn claimed_if_default_pda(seeds: &[&[u8; 32]]) -> AutoClaim {
    let refs: Vec<&[u8]> = seeds.iter().map(|s| s.as_slice()).collect();
    match AutoClaim::pda_from_seeds(&refs) {
        AutoClaim::Claimed(claim) => AutoClaim::ClaimedIfDefault(claim),
        other => other,
    }
}
