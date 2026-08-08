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
