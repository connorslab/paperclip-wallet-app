## Before You Start

**Check the nix flake is loaded before writing any code.**

Run `which captaind` or `echo $IN_NIX_SHELL`. If the flake isn't loaded, remind the user:

> "Please restart in a shell with the nix flake loaded (`nix develop` or direnv)."

Do not write code until the environment is confirmed.

## Skills

Use the skills in `contrib/agents/skills/` extensively:

| Skill | When to use |
|-------|-------------|
| `running-and-debugging-tests.md` | Running tests and investigating failures |
| `writing-tests.md` | Test patterns and conventions |
| `review.md` | Reviewing branches (with or without fix-ups) |
| `changelog.md` | Writing changelog entries |
| `missing-changelogs.md` | Finding MRs without changelog entries |
| `protocol-encoding.md` | Working with ProtocolEncoding (backward compat, no panics, DoS protection) |
| `documentation.md` | Documentation conventions (vocabulary is in CONTRIBUTING/style_guide.md) |
| `database-schema.md` | Finding the full database DDL (use schema.sql, not migrations) |
| `prompts.md` | Managing prompts and research |
| `corrections.md` | When corrected, encode the fix into skill files |
| `debug-ci.md` | Debugging CI failures — `debug <url to failed pipeline>` |

## iOS and Android backend parity

For every iOS backend fix, implement the corresponding fix on
`feature/android-wallet` in `connorslab/paperclip-wallet-app` as part of the same
task. Check both branches before changing shared Rust engine code, JNI/FFI
contracts, payment validation, fee accounting, persistence, recovery, or network
behavior. Port equivalent behavior in platform-specific backend adapters where
needed; copying Swift files alone does not update Android's Kotlin/JNI backend.

Preserve each branch's unrelated changes. Run appropriate regression checks for
both platforms and report the branch/commit or patch containing each fix and what
was actually verified. If Android lacks the corresponding feature or validation
is blocked, state the gap explicitly rather than claiming parity. Keep platform
build, publication, and App Store submission actions within the user's authorized
scope.

## Testing

**Never run integration tests with `cargo test` directly.** They require environment variables set by `just`.

```bash
just checks      # Pre-commit: style checks + cargo check
just unit        # Unit tests
just unit <name> # Specific unit test
just int         # Integration tests (bitcoind backend)
just int <name>  # Specific integration test
```

## Code Style

Primary goal: **code that humans can understand**.
Correct but hard-to-understand code is worse than clear code with a bug (bugs get caught in review).

- **Tabs** for indentation
- **No strict rustfmt** - format for readability
- **No blind clippy fixes** - they can introduce bugs
- Follow bitcoin patterns and naming conventions
- Imports should be at the top of a module. Don't put imports inside a function.
- Look at surrounding code to match style

See `CONTRIBUTING/STYLE.md` for details on imports, serialization, etc.

## Writing Style and Vocabulary

Follow `CONTRIBUTING/style_guide.md` for vocabulary and writing style.
That guide applies to all text: documentation, comments, docstrings,
changelogs, commit messages, and user-facing strings.

## Commit Hygiene

- Prefix with subsystem: `bark:`, `server:`, `lib:`, `ci:`, `testing:`
- Focus on **why**, not what - help reviewers understand context
- Small, logical commits that individually compile (`just check`)
- Squash fixups into original commits (reviewers use `git range-diff`)

## Error Handling

- `ark-lib`: Use `thiserror` - errors are part of the API
- `bark`/`captaind`: Use `anyhow` - propagate errors upstream
- Use `thiserror` elsewhere when you need to handle errors differently
- Avoid creating too many error types - be pragmatic

## Database (Postgres)

See `CONTRIBUTING/postgres.md` for guidelines:

- Singular table names (`round` not `rounds`)
- Primary keys named `id`
- Store pubkeys/hashes as hex
- Avoid wildcards: `SELECT (id, created_at)` not `SELECT *`
- Use `RETURNING` on inserts/updates
