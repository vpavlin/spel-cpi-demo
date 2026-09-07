/// Generate IDL JSON for the ledger program.
///
/// Usage:
///   cargo run --bin generate_idl > ledger-idl.json

spel_framework::generate_idl!("../methods/guest/src/bin/ledger.rs");
