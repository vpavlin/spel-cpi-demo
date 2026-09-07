# spel-cpi-demo

Two SPEL programs, three PDAs, one cross-program chained call — built to
exercise the SPEL docs end to end and to give the framework a reproducible
CPI test case.

```
vault.deposit(owner, amount)
  ├─ writes  vault PDA   [literal("vault"), account("owner")]   balance += amount
  ├─ writes  vault config PDA  [literal("vault_config")]        (created by initialize)
  └─ ChainedCall ──▶ ledger.record(amount)
                       └─ writes ledger PDA [literal("log")]    total += amount
```

The point of the demo is the last arrow: `vault` never touches ledger's PDA
itself. It hands `ledger.record` a `ChainedCall`, and the sequencer re-executes
that instruction with **ledger** as the owning program, which is the only way
LEZ rule 5 lets ledger's `"log"` account be mutated.

## Layout

| Path | What it is |
| --- | --- |
| `ledger/` | The callee. `record(amount)` accumulates into a `"log"` PDA. |
| `vault/` | The caller. `deposit` writes its own per-owner PDA *and* chains into ledger. |
| `ledger/ledger_core/` | Ledger's instruction enum, shared so a caller can build a typed call. |
| `vault/vault_core/` | A **vendored mirror** of that enum — see [NOTES.md](NOTES.md#3-a-caller-cannot-depend-on-the-callees-instruction-enum). |
| `scripts/e2e-test.sh` | Self-contained end-to-end test. Owns its own chain. |

## Running the e2e test

Prerequisites:

- A [logos-execution-zone](https://github.com/logos-blockchain/logos-execution-zone)
  checkout at **v0.2.4**, with `sequencer_service` and `wallet` built in
  release. The sequencer **must** be built with `--features standalone`:

  ```sh
  cargo build --release --features standalone -p sequencer_service
  cargo build --release -p wallet
  ```

  Without `standalone` the sequencer blocks on a Bedrock node at
  `localhost:18080` and never serves RPC — it looks like a hang, not an error.

- `spel` on `PATH`, built from a recent `main` (it needs the `program-id`
  subcommand and the v0.2.4 wallet storage schema):

  ```sh
  cargo install --path <spel-checkout>/spel-cli
  ```

- Docker, for the guest builds.

Then:

```sh
LSSA_DIR=/path/to/logos-execution-zone ./scripts/e2e-test.sh
```

The first run builds both guests in Docker (5–10 min each). After that,
`SKIP_BUILD=1` reuses them:

```sh
LSSA_DIR=/path/to/logos-execution-zone SKIP_BUILD=1 ./scripts/e2e-test.sh
```

### What it asserts

It does not grep for "success". It reads the ledger PDA back and compares its
`total` **by value** after each deposit:

```
Step 8: vault deposit 500 (fires the chained call)...
  ✓ after first deposit: ledger total = 500
Step 9: vault deposit 250 (must accumulate)...
  ✓ after second deposit: ledger total = 750
Step 10: checking the vault's per-owner PDA...
  ✓ vault balance = 750 (its own PDA, mutated directly)
```

If the chained call silently did nothing, the total would stay `0` and step 8
would fail.

### Reproducibility

Every run creates a **fresh sequencer home**, so the chain always starts from
genesis and re-deploying the same binaries never hits `ProgramAlreadyExists`.
The script refuses to start if something is already listening on its port,
rather than quietly attaching to a previous run's chain.

Environment knobs: `WORK_DIR` (or `$1`), `SKIP_BUILD`, `SEQUENCER_PORT`
(3040), `METRICS_PORT` (9000), `LEZ_REF` (`v0.2.4` — the git ref the sequencer
and wallet configs are read from; it must match the version the binaries were
built from).

## CI: testing new SPEL and LEZ versions

`.github/workflows/e2e.yml` runs everything above against a chosen SPEL commit
and a chosen LEZ node. SPEL's own `lez-compat` workflow only `cargo check`s, so
a change that compiles but breaks account claims, PDA derivation or
chained-call serialization passes it and fails here.

```sh
# SPEL main, node on the LEZ that commit pins (the default)
gh workflow run e2e.yml -R vpavlin/spel-cpi-demo

# same guests, newer chain — do today's programs still run on tomorrow's node?
gh workflow run e2e.yml -R vpavlin/spel-cpi-demo -f lez_ref=v0.2.5-rc1

# a SPEL branch (including SPEL's own `lez-bump/<sha>` branches)
gh workflow run e2e.yml -R vpavlin/spel-cpi-demo -f spel_ref=my-feature-branch

# from another repo's CI
gh api repos/vpavlin/spel-cpi-demo/dispatches \
  -f event_type=cpi-e2e -F 'client_payload[spel_ref]=my-branch'
```

It also runs on pushes to `main`, on pull requests, and twice every Monday —
07:00 UTC with the node on the LEZ SPEL pins (*did SPEL regress?*) and 08:00 UTC
with the node on LEZ `main` (*is LEZ about to break us?*).

### Two LEZ versions, only one of them a choice

The LEZ the guests are **compiled against** is whatever the SPEL commit pins,
and `lez_ref` cannot change it. Cargo unifies git dependencies by source
*string*, not by resolved commit, so pointing the guest at `rev = "47eba25…"`
while `spel-framework` says `tag = "v0.2.4"` puts two copies of `lee_core` in
the graph and the guest stops compiling:

```
expected `lee_core::account::data::Data`, found `lee_core::account::Data`
note: two different versions of crate `lee_core` are being used
```

`[patch]` is the only mechanism that would force one version across both, and
Cargo rejects a patch whose replacement is the same git source — including
`.git`-suffix variants, which it canonicalizes. So `scripts/pin-versions.sh`
copies SPEL's LEZ selector verbatim and then **asserts the lockfile contains
exactly one `lee_core`**, which turns a fifteen-minute Docker failure into an
immediate one.

The LEZ the **node runs** is a free choice, and that is the more interesting
axis anyway: `lez_ref` selects the sequencer, wallet and configs the programs
are deployed against. Guests built on SPEL's pinned LEZ running against a newer
node is a wire-and-validation-rule question that no `cargo check` can answer.
To compile against a different LEZ, point `spel_ref` at a SPEL branch that pins
it — SPEL's `lez-compat` workflow opens `lez-bump/<sha>` branches that do
exactly that.

### How it is put together

| Job | What it does | Cache key |
| --- | --- | --- |
| `resolve` | Resolves both refs to commits and prints them in the run summary | — |
| `lez` | Builds the node: `sequencer_service` (`--features standalone`) and `wallet` | node LEZ commit |
| `guests` | Re-pins both guests to the SPEL commit and builds them in Docker | SPEL + guest LEZ commit + guest sources |
| `e2e` | Builds the `spel` CLI at that SPEL commit and runs `scripts/e2e-test.sh` | SPEL commit |
| `report` | On a scheduled or dispatched failure, opens (or comments on) one issue per version pair | — |

The guests are **rebuilt against the SPEL commit under test**, not restored
from a stale binary, so a red run is a real incompatibility. Both helper
scripts run locally:

```sh
./scripts/resolve-ref.sh https://github.com/logos-co/spel.git main
./scripts/pin-versions.sh main
```

A fully cold run takes roughly an hour, most of it the two Docker guest builds
and the LEZ release build. With all three caches warm it is the `e2e` job only,
a few minutes.

## Notes

[NOTES.md](NOTES.md) records what had to be discovered outside the docs to get
this working. That is the actual deliverable of the exercise.
