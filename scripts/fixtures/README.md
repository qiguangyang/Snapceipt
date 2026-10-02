# Authentic v1 workspace store

Run `python3 scripts/fixtures/generate-v1-workspace.py --simulator <UUID>` on this macOS/Xcode host
with the configured iPhone 16 simulator booted. The generator archives Git commit
`e22d9952a1c7eccdca08e2e70976ddee0a59ccb0` into a temporary directory, compiles its
unaltered production `@Model` files, `SnapceiptSchema` and supporting model sources
as the original module **Snapceipt**, targeting arm64 iOS 17 Simulator. It runs the
small data generator under the iOS simulator runtime, then SQLite-backups the
committed database (including WAL contents) into the bundled `.store` file.

`v1-workspace.provenance.json` records baseline, Xcode/runtime, original source
hashes and output hash. `v1-workspace-main.swift` is the maintained synthetic-data
recipe; all contact/financial values are fictional. Timestamps and SQLite metadata
may vary on regeneration; semantic IDs and asserted domain values are fixed.
No renamed/nested fake v1 model and no v2-created database participates.

The test copies the read-only bundled fixture into a fresh temporary directory,
opens it with the complete v2 schema through a **throwing** disk ModelContainer,
asserts disk configuration and every fixture record, then tests a v2 edit/reopen.
The app's nonthrowing launch helper and memory fallback are never used by this test.
