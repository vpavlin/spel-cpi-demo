/// Generate IDL JSON for the vault program.
///
/// Usage:
///   cargo run --bin generate_idl > vault-idl.json

spel_framework::generate_idl!("../methods/guest/src/bin/vault.rs");
