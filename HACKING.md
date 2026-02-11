### Running Tests

```bash
# Full test suite (requires Nix)
nix flake check
```

This is the primary way to run tests. It runs:
- Unit tests
- PostgreSQL integration tests (spins up a real PostgreSQL instance)
- SQLite integration tests (uses in-memory database)
- MySQL integration tests (spins up a MariaDB instance)

Each integration test creates tables via DDL generation, seeds data via mutations,
starts an HTTP server, and runs GraphQL queries to verify end-to-end functionality.

**Quick iteration** (unit tests only, faster but incomplete):

```bash
dub test              # Unit tests only
dub test -d=sql       # With SQL debug output
dub test -d=graphql   # Show generated GraphQL schema
dub test -d=ddl       # Show generated SQL DDL
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for high-level architecture details.
