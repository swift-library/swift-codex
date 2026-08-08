# Documentation

The public documentation is organized by reader need:

- `Usage/` contains product guides and runnable examples.
- `Architecture/` states the current package and target boundaries.
- `Reference/` records pinned upstream contracts, provenance, and generated
  adoption inventories.

Start with the repository [README](../README.md), then open the relevant guide
under [Usage](Usage/README.md). Contributors changing target boundaries should
also update [Architecture](Architecture/README.md). Schema changes must update
the upstream lock, manifests, method adoption inventory, and API diff together.

Each of the eleven public libraries owns one module-level DocC catalog under
`Sources/<Target>/Documentation.docc/`. Generated DocC archives are build
artifacts and are never committed.
