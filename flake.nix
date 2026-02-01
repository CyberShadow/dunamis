{
  description = "graphqld2 - GraphQL server with bulk data resolution";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Build the postgres integration test executable
        postgresTestBin = pkgs.buildDubPackage {
          pname = "graphqld2-postgres-test";
          version = "0.0.1";
          src = self;
          dubLock = ./dub-lock.json;
          dubBuildFlags = [ "--config=postgres-integration" ];
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp build/graphqld2 $out/bin/postgres_test
            runHook postInstall
          '';
        };

        # Build the sqlite integration test executable
        sqliteTestBin = pkgs.buildDubPackage {
          pname = "graphqld2-sqlite-test";
          version = "0.0.1";
          src = self;
          dubLock = ./dub-lock.json;
          dubBuildFlags = [ "--config=sqlite-integration" ];
          buildInputs = [ pkgs.sqlite ];
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp build/graphqld2 $out/bin/sqlite_test
            runHook postInstall
          '';
        };
      in {
        checks = {
          # D unit tests via dub
          unit-tests = pkgs.buildDubPackage {
            pname = "graphqld2-unit-tests";
            version = "0.0.1";
            src = self;

            dubLock = ./dub-lock.json;

            # Run unit tests instead of building
            buildPhase = ''
              runHook preBuild
              echo "=== Running D unit tests ==="
              dub test --compiler=ldc2 --config=library
              runHook postBuild
            '';

            installPhase = ''
              touch $out
            '';
          };

          # PostgreSQL integration tests
          postgres-integration = pkgs.stdenv.mkDerivation {
            name = "graphqld2-postgres-integration";
            dontUnpack = true;
            nativeBuildInputs = [ pkgs.postgresql ];

            buildPhase = ''
              export HOME="$TMPDIR"
              export PGDATA="$TMPDIR/pgdata"
              export PGHOST="localhost"
              export PGPORT="5432"
              export PGUSER="postgres"
              export PGDATABASE="testdb"
              export PGPASSWORD=""

              # Initialize and start PostgreSQL
              initdb -D "$PGDATA" --auth=trust --username=postgres
              echo "unix_socket_directories = '$TMPDIR'" >> "$PGDATA/postgresql.conf"
              echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"
              pg_ctl -D "$PGDATA" -l "$PGDATA/logfile" start -w

              # Create test database
              createdb -h "$TMPDIR" -U postgres "$PGDATABASE"

              # Run tests (schema setup, seeding, and tests all happen in D)
              ${postgresTestBin}/bin/postgres_test

              # Cleanup (use immediate mode for faster shutdown in CI)
              pg_ctl -D "$PGDATA" stop -m immediate -t 5
            '';

            installPhase = ''
              touch $out
            '';
          };

          # SQLite integration tests
          sqlite-integration = pkgs.stdenv.mkDerivation {
            name = "graphqld2-sqlite-integration";
            dontUnpack = true;

            buildPhase = ''
              # Run tests (uses in-memory SQLite database)
              ${sqliteTestBin}/bin/sqlite_test
            '';

            installPhase = ''
              touch $out
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.ldc
            pkgs.postgresql
            pkgs.curl
            pkgs.sqlite
          ];

          shellHook = ''
            echo "graphqld2 development shell"
            echo "Run 'dub test' for unit tests"
            echo "Run 'nix flake check' for all tests (unit + integration)"
          '';
        };
      }
    );
}
