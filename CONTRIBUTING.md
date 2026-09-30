# Contributing

Keep changes small, boundary-first, and placed by role.

## Where To Change

- Package manifest and target graph: `Package.swift`
- Library implementation: `Sources/Codex/*`
- Package tests: `Tests/CodexTests/*`
- Route instructions: `AGENTS.md`
- Index and placement guidance: `README`-class files
- Current repository structure: `Documentation/Architecture/*`
- Product usage: `Documentation/Usage/*`
- Generated and supporting reference material: `Documentation/Reference/*`
- GitHub-facing governance and collaboration files: `.github/*`
- Repo-wide contributor policy: root governance files such as
  `CONTRIBUTING.md`

## Local Validation

- Run `Scripts/verify-public-repository.sh` and
  `Scripts/verify-schema-snapshot.sh`.
- Run strict `swift-format` lint for `Package.swift`, `Sources`, `Tests`, and
  `Plugins`.
- Run `swift build` and `swift test --no-parallel` for package changes.
- Review documentation placement against `Documentation/README.md` before
  opening a pull request.

## Change Hygiene

- Keep route instructions in `AGENTS.md`.
- Keep repository and subtree indexes in `README`-class files.
- Keep current structure in `Documentation/Architecture/*`.
- Keep task-specific plans and investigation notes outside the public tree.
- Keep GitHub-facing collaboration files in `.github/`.
- Use Conventional Commit subjects because local hooks and CI validate them.

## Work Ownership And Closeout

- Keep the default branch as the daily integration checkout. Use one task
  branch and an isolated worktree when existing work requires separation.
- Before starting, inspect the checkout's commit, tracked and untracked changes,
  active worktrees and ongoing work. Record task-specific ownership and recovery
  information under ignored `.agent/` paths.
- Preserve unrelated source and local metadata. Do not reset, clean, stash or
  overwrite someone else's changes to make a checkout usable.
- Commit coherent increments and bind validation records to their source commit.
  Account for pre-existing work within the task's scope before declaring it
  complete. A recovery snapshot preserves source; integration requires an
  implemented or explicitly superseded disposition.
- Merge through the repository's pull request checks. Record the accepted head,
  merged commit and whether the source was published. Fast-forward the daily
  default checkout only when it is clean.
- Retire owned temporary worktrees and generated outputs after preserving source,
  necessary evidence and any non-generated ignored files. Keep normal build
  caches separate from recovery archives and acceptance records.
- Remove a task branch only when it has no active worktree or open pull request
  and its work is accounted for. For squash merges, confirm the exact pull
  request head and reachable merged commit; ancestry alone is insufficient.
  Preserve a verified recovery bundle when deleting refs would discard needed
  source history. Retain explicitly owned recovery refs until their review ends.

## Dependency Maintenance

- Dependabot checks Swift packages and GitHub Actions weekly. Minor and patch
  version updates are grouped by ecosystem; major updates remain separate.
  Grouping does not replace compatibility review or required checks.
- For an accepted Swift dependency update, synchronize `Package.resolved` and
  `DEPENDENCIES.json` using `Scripts/verify-dependency-manifest.py --update`, then
  run the verifier and the applicable package gates. Review the resulting pins,
  licenses, dependency roles and public API before merging.
- Respect exact dependency pins and published release provenance. Changes to
  upstream schema inputs follow the vendored-protocol workflow rather than a
  dependency-bot proposal.
- Close a replaced proposal after its replacement is accepted. Delete obsolete
  bot branches only after checking that no open pull request still uses them.
