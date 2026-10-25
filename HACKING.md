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
dub test --compiler=ldc2              # Unit tests only
dub test --compiler=ldc2 -d=sql       # With SQL debug output
dub test --compiler=ldc2 -d=graphql   # Show generated GraphQL schema
dub test --compiler=ldc2 -d=ddl       # Show generated SQL DDL
```

The `unit-tests` flake check runs
`dub test --compiler=ldc2 --config=library --build=ci-unittest`. Note that
the `ci` build type does not compile unittests (it is used for the
integration-test executables), so `dub test --build=ci` runs nothing.

An integration suite can also be run outside Nix: build it with e.g.
`dub build --compiler=ldc2 --config=postgres-integration --build=ci` and run
`build/dunamis` with `PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE` (or the
`MYSQL_*` variables) pointing at a scratch database; see `flake.nix`.

See [ARCHITECTURE.md](ARCHITECTURE.md) for high-level architecture details.
