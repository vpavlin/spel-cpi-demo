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

## Notes

[NOTES.md](NOTES.md) records what had to be discovered outside the docs to get
this working. That is the actual deliverable of the exercise.
