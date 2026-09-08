# Notes from building this against the SPEL docs

This demo was written by working from `docs/` and `skills/spel/` only. What
follows is what those docs did not cover, or covered in a way that sent the
build the wrong direction. Every item was reproduced against `spel` built from
`main` at `dc33f66` and LEZ `v0.2.4` — the commands to reproduce are inline.

Nothing here is a criticism of any one change; it is the list of things a
newcomer hits that a returning contributor already knows.

---

## 1. `spel program-id` prints a ProgramId form that `spel` itself rejects

The human-readable output offers three renderings:

```
$ spel program-id ledger.bin
📦 ledger.bin
   ProgramId (decimal): 1027299449,1398471968,…
   ProgramId (hex):     3d3b5879,535afd20,52eac201,81667011,e3ec8c64,32dc03aa,5be894bc,65540f1f
   ImageID (hex bytes): 79583b3d20fd5a5301c2ea5211706681648cece3aa03dc32bc94e85b1f0f5465
```

Feeding the line labelled **`ProgramId (hex)`** into an instruction argument of
IDL type `program_id` fails:

```
$ spel --idl vault-idl.json -p vault.bin -- deposit \
    --ledger-program-id "3d3b5879,535afd20,52eac201,81667011,e3ec8c64,32dc03aa,5be894bc,65540f1f" …
❌ --ledger-program-id: ProgramId[0] invalid u32 '3d3b5879': invalid digit found in string
```

`parse_program_id` (`spel-cli/src/parse.rs`) takes the comma branch, and in
that branch a word without a `0x` prefix is parsed as **decimal**. So the
comma-separated *hex* the tool just printed is the one form it will not accept.
The decimal line works, the ImageID line works, and `--format hex` emits the
ImageID directly (which is what this repo's script uses).

Options, roughly in order of how little they change: print the hex words with
`0x` prefixes; or accept bare hex in the comma branch; or drop the ambiguous
line. Any of the three makes copy-paste from the tool's own output work.

## 2. `ChainedCall` has a constructor, and the docs show a struct literal instead

`docs/reference/macros.md` → "Chained calls" is the only place a chained call
is built, and it builds one by hand:

```rust
vec![ChainedCall { program_id, instruction_data, pre_states: vec![target], pda_seeds: vec![] }]
```

`instruction_data` appears as a free identifier. Its type is `Vec<u32>` in the
risc0 wire format, and nothing in `docs/` or `skills/` says how to produce one:

```sh
$ grep -rn "ChainedCall::new" docs/ skills/
# (no matches)
```

`nssa_core::program::ChainedCall::new(program_id, pre_states, &instruction)`
does the serialization for you and is what a caller actually wants. Finding it
meant reading a transitive dependency of `spel-framework-core`. One line in
that section — the constructor, and the fact that `instruction` is any
`Serialize` value shaped like the callee's instruction enum — would remove the
whole detour.

While in that section: the example also leaves unexplained how a caller obtains
the *address* of a PDA owned by the callee. `#[account(pda = …)]` always
derives against the current program's id, so it cannot express it; the address
has to be computed off-chain (`spel pda log --idl ledger-idl.json`) and passed
in as a plain, unattributed account parameter. `vault::deposit`'s `log`
parameter in this repo is that pattern.

## 3. A caller cannot depend on the callee's instruction enum

The natural way to build a well-typed chained call is to depend on the callee's
`*_core` crate — which is exactly what `docs/tutorial.md` → "External
Instruction Enums" sets up, and why `ledger_core` exists here at all.

Across two projects it does not work. Guest binaries build inside Docker with
the **project directory as the context root**, so a path dependency containing
`..` escapes it:

```toml
# vault/methods/guest/Cargo.toml
ledger_core = { path = "../../../ledger/ledger_core" }
```

```
$ cd vault && make build
 > [build 4/5] RUN cargo +risc0 fetch --locked … --manifest-path methods/guest/Cargo.toml:
0.453 error: failed to load manifest for dependency `ledger_core`
0.453 Caused by:
0.453   failed to read `/ledger/ledger_core/Cargo.toml`
```

Note the path: `../../../ledger/…` resolved to `/ledger/…`. Host-side
`cargo check` passes, so this only shows up after the ~5-minute Docker build
starts.

**Git dependencies do survive it** — that is how the generated guest already
pulls `spel-framework` and `nssa_core` — so the shape that works is to publish
the callee's core crate and depend on it by git rev. Until then this repo
carries `vault_core::LedgerInstruction`, a hand-maintained mirror of
`ledger_core::Instruction`. It works because `ChainedCall::new` serializes
structurally, but it is a real hazard: reordering variants in `ledger_core`
silently changes the discriminant and the mirror keeps compiling.

Worth a sentence in the tutorial's External Instruction Enums section
distinguishing same-project (path is fine) from cross-project (git dep), and a
line in the CLI reference noting that guest builds are context-scoped.

## 4. Version skew fails with errors that don't mention versions

Three separate skews cost real time, each surfacing as a serde message:

| Skew | Symptom |
| --- | --- |
| `spel` older than the LEZ wallet that wrote `storage.json` | `Failed to read persistent storage … missing field 'accounts'` |
| Sequencer config from an older LEZ tag than the `sequencer_service` binary | `Error: missing field 'funding_key' at line 1 column 420` |
| Wallet config using the pre-v0.2.1 flat `sequencer_addr` | *no error at all* — the key is ignored and the wallet talks to the default port |

The first two are at least loud. The third is silent because the config struct
has no `deny_unknown_fields`, and it presents later as a transaction that never
confirms. A `deny_unknown_fields` on the wallet config, and a version string in
`spel --version` output that names the LEZ tag it was built against, would turn
all three into one-line diagnoses.

## 5. The e2e harness gotchas (for anyone writing one)

Not doc bugs — but every one of these cost a debugging cycle here, and
`scripts/e2e-test.sh` guards against all of them:

- **The sequencer must be built `--features standalone`.** Without it the
  service starts, logs nothing alarming, and blocks forever on a Bedrock node
  at `localhost:18080`. It reads as a hang.
- **`RISC0_DEV_MODE=1`** is required, or proving dominates the runtime.
- **Background the sequencer with `exec`.** `( … ) &` makes `$!` the subshell;
  killing it orphans the sequencer, which keeps the port. The next run's health
  check then passes against the *previous* run's chain and fails much later
  with `Transaction not found in preconfigured amount of blocks`. The script
  now refuses to start if its port is already occupied.
- **Use a fresh sequencer home per run**, otherwise re-deploying the same
  binaries hits `ProgramAlreadyExists`.
- **The risc0 toolchain is a *runtime* dependency of the sequencer**, not just
  a build one: it executes the genesis transaction through risc0 at startup.
  Miss it and the node dies instantly with
  `ProgramExecutionFailed("No such file or directory (os error 2)")`, which
  names neither risc0 nor the file it wanted. This one only shows up on a
  machine that has never built a guest — a fresh CI runner, or a new laptop.

## 6. What worked well

Worth saying, since the list above is all friction:

- `#[account(pda = [literal("vault"), account("owner")])]` derives the address,
  emits the claim, and appears in the IDL from the one attribute. The
  multi-part seed syntax needed no lookup.
- `spel generate-idl` + `spel pda <account>` meant the test script never
  hard-codes an address.
- `AutoClaim::ClaimedIfDefault` is documented in both `macros.md` and
  `gotchas.md` with the rule-7 reasoning spelled out, which is what made the
  "works on the first deposit and every later one" case solvable without
  reading the validator.
- The `❌ --arg: <reason>` argument diagnostics report *every* bad argument in
  one pass rather than stopping at the first.
