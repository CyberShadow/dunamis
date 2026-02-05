@README.md

# Agentic Development Instructions

Run tests with a timeout to ensure they do not get stuck indefinitely (or become too slow):

```
timeout 120 nix flake check
```

This runs everything: unit tests plus PostgreSQL, SQLite, and MySQL integration tests.

For quick iteration during development, `dub test` runs only unit tests (faster but incomplete).
