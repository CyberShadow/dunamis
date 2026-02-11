@README.md
@ARCHITECTURE.md
@HACKING.md

See also:

- TODO.md - what was implemented and what is still planned
- USAGE.md - full documentation (keep it up to date)

# Agentic Development Instructions

Run tests with a timeout to ensure they do not get stuck indefinitely (or become too slow):

```
timeout 180 nix flake check
```

This runs everything: unit tests plus PostgreSQL, SQLite, and MySQL integration tests.

For quick iteration during development, `dub test` runs only unit tests (faster but incomplete).
