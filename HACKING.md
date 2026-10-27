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

### Compiler Memory Benchmark

Schemas are compile-time constructs, and compiling one (and the GraphQL
compiler for it) takes memory and time growing with its numbers of types and
fields. `tools/schema_bench.d` generates a synthetic schema module of a given
size (entities, columns, relationships, computed fields of various kinds,
mutations; see `--help`) to measure how:

```bash
dub run -q --single tools/schema_bench.d -- --entities=16 --object-fields=1 --ops > /tmp/bench.d
/usr/bin/time -f '%M KB, %e s' ldc2 -c -o- \
  $(dub describe -q --compiler=ldc2 --config=library --data=versions,import-paths) /tmp/bench.d
```

`-o-` measures the front-end only; to include code generation (about as much
again), compile to an object file instead (e.g. `-g -of=/tmp/bench.o`, as
application builds do). Compare two configurations differing in one
dimension to get the cost of a field or type of a kind.

See [ARCHITECTURE.md](ARCHITECTURE.md) for high-level architecture details.
