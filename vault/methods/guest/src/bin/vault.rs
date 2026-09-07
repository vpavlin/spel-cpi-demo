#![no_main]

use spel_framework::prelude::*;
use nssa_core::account::Data;

risc0_zkvm::guest::entry!(main);

/// The vault's global config, created once by `initialize` at a literal-seed
/// PDA. `#[account_type]` registers it in the IDL — docs/tutorial.md Step 2.
#[account_type]
#[derive(Debug, Clone, Default, BorshSerialize, BorshDeserialize)]
pub struct VaultConfig {
    pub admin: [u8; 32],
}

/// A single depositor's balance, stored at a per-owner PDA
/// (`literal("vault") + account("owner")`, docs/reference/macros.md "PDA Seeds").
#[account_type]
#[derive(Debug, Clone, Default, BorshSerialize, BorshDeserialize)]
pub struct VaultAccount {
    pub owner: [u8; 32],
    pub balance: u64,
}

#[lez_program]
mod vault {
    #[allow(unused_imports)]
    use super::*;

    /// Create the global config PDA (literal seed `"vault_config"`).
    #[instruction]
    pub fn initialize(
        #[account(init, pda = literal("vault_config"))]
        mut config: AccountWithMetadata,
        #[account(signer)]
        admin: AccountWithMetadata,
    ) -> SpelResult {
        let state = VaultConfig {
            admin: *admin.account_id.value(),
        };
        let bytes = borsh::to_vec(&state).map_err(|e| SpelError::SerializationError {
            message: e.to_string(),
        })?;
        config.account.data =
            Data::try_from(bytes).map_err(|_| SpelError::custom(1, "config data too big"))?;
        Ok(SpelOutput::execute(vec![config, admin], vec![]))
    }

    /// Deposit `amount` into the caller's per-owner vault PDA, then forward it
    /// to ledger's `record` instruction via a chained call so the ledger total
    /// reflects the deposit too.
    ///
    /// `log` is the address of ledger's `"log"` PDA. It is passed in as a
    /// plain account (no `#[account(...)]` attribute at all — this mirrors
    /// `tests/e2e/fixture_program`'s `delegate_to_program(... target:
    /// AccountWithMetadata ...)`, the only chained-call example anywhere in
    /// the spel repo) rather than derived with `pda = ...`, because the `pda`
    /// attribute always derives an address from *this* program's own id — it
    /// has no way to compute an address owned by a different program. The
    /// caller (the e2e script) computes it with
    /// `spel pda log --idl ledger-idl.json --program <ledger-hex>` and passes
    /// it with `--log`. `ledger_program_id` is filled in automatically by the
    /// CLI's `--bin-ledger <ledger.bin>` flag (docs/reference/cli.md
    /// "Additional program binaries").
    #[instruction]
    pub fn deposit(
        #[account(mut, pda = [literal("vault"), account("owner")])]
        mut vault_account: AccountWithMetadata,
        #[account(signer)]
        owner: AccountWithMetadata,
        log: AccountWithMetadata,
        ledger_program_id: ProgramId,
        amount: u64,
    ) -> SpelResult {
        // ── Update the caller's own per-owner balance ──────────────────
        let data: Vec<u8> = vault_account.account.data.clone().into();
        let mut state: VaultAccount = if data.is_empty() {
            VaultAccount {
                owner: *owner.account_id.value(),
                balance: 0,
            }
        } else {
            borsh::from_slice(&data).map_err(|e| SpelError::DeserializationError {
                account_index: 0,
                message: e.to_string(),
            })?
        };

        state.balance = state.balance.checked_add(amount).ok_or(SpelError::Overflow {
            operation: "vault deposit".to_string(),
        })?;

        let bytes = borsh::to_vec(&state).map_err(|e| SpelError::SerializationError {
            message: e.to_string(),
        })?;
        vault_account.account.data =
            Data::try_from(bytes).map_err(|_| SpelError::custom(1, "vault data too big"))?;

        // `deposit` must work identically on a brand-new per-owner PDA (first
        // deposit for this owner) and an existing one (later deposits) — see
        // `claimed_if_default_pda` below for why plain `#[account(init, ...)]`
        // / `#[account(mut, ...)]` can't express that by themselves, and why
        // we bypass `SpelOutput::execute(...)` for `execute_with_claims(...)`.
        let vault_claim = claimed_if_default_pda(&[&seed_from_str("vault"), owner.account_id.value()]);
        // Mirrors what the macro would auto-derive for `#[account(signer)]`
        // (docs/reference/macros.md Claims table) — we have to spell it out
        // by hand here since `execute_with_claims` doesn't run the macro's
        // per-parameter claim derivation.
        let owner_claim = AutoClaim::ClaimedIfDefault(Claim::Authorized);

        // ── Chained call into ledger::record ────────────────────────────
        // `ChainedCall::new` risc0-serializes `instruction` into the
        // `Vec<u32>` `instruction_data` format documented in
        // docs/reference/cli.md "Serialization (spel-cli internals)" — the
        // same format the CLI itself produces for a top-level instruction.
        // This constructor is not mentioned anywhere in docs/; found by
        // reading nssa_core::program (a dependency of spel-framework-core,
        // hence in scope per the escape-hatch rule) after macros.md's
        // "Chained calls" example left `instruction_data` as a bare
        // placeholder value with no construction shown.
        //
        // `vault_core::LedgerInstruction` is a vendored mirror of
        // `ledger_core::Instruction`, not a shared dependency on it — see
        // vault_core/src/lib.rs for why a cross-project path dependency
        // doesn't survive the guest's Docker build.
        let ix = vault_core::LedgerInstruction::Record { amount };
        let call = ChainedCall::new(ledger_program_id, vec![log.clone()], &ix);

        // Every account passed to the handler must appear once in the
        // returned post-states (skills/spel/references/gotchas.md) — `log`
        // is returned unchanged here; its real mutation happens inside the
        // chained call, executed with ledger as the owning program.
        Ok(SpelOutput::execute_with_claims(
            &[
                vault_account.account.clone(),
                owner.account.clone(),
                log.account.clone(),
            ],
            &[vault_claim, owner_claim, AutoClaim::None],
            vec![call],
        ))
    }
}

/// Build an `AutoClaim` that claims a PDA the first time it's touched (its
/// current on-chain owner is still `DEFAULT_PROGRAM_ID`) and leaves an
/// already-owned PDA's claim alone on every later call — see the longer
/// explanation in `methods/guest/src/bin/ledger.rs`, which needs the exact
/// same trick for its `"log"` PDA.
fn claimed_if_default_pda(seeds: &[&[u8; 32]]) -> AutoClaim {
    let refs: Vec<&[u8]> = seeds.iter().map(|s| s.as_slice()).collect();
    match AutoClaim::pda_from_seeds(&refs) {
        AutoClaim::Claimed(claim) => AutoClaim::ClaimedIfDefault(claim),
        other => other,
    }
}
