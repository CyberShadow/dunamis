{
  description = "Dunamis - GraphQL server for D that eliminates N+1 queries through expression-based query optimization";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Only include D sources and dub config — exclude .md, docs, etc.
        dubSrc = pkgs.lib.cleanSourceWith {
          src = self;
          filter = path: type:
            let baseName = baseNameOf path; in
            type == "directory" ||
            pkgs.lib.hasSuffix ".d" baseName ||
            baseName == "dub.sdl";
        };

        # Build the postgres integration test executable
        postgresTestBin = pkgs.buildDubPackage {
          pname = "dunamis-postgres-test";
          version = "0.0.1";
          src = dubSrc;
          dubLock = ./dub-lock.json;
          dubBuildType = "ci";
          dubBuildFlags = [ "--config=postgres-integration" ];
          dontStrip = true;
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp build/dunamis $out/bin/postgres_test
            runHook postInstall
          '';
        };

        # Build the sqlite integration test executable
        sqliteTestBin = pkgs.buildDubPackage {
          pname = "dunamis-sqlite-test";
          version = "0.0.1";
          src = dubSrc;
          dubLock = ./dub-lock.json;
          dubBuildType = "ci";
          dubBuildFlags = [ "--config=sqlite-integration" ];
          dontStrip = true;
          buildInputs = [ pkgs.sqlite ];
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp build/dunamis $out/bin/sqlite_test
            runHook postInstall
          '';
        };

        # Build the mysql integration test executable
        mysqlTestBin = pkgs.buildDubPackage {
          pname = "dunamis-mysql-test";
          version = "0.0.1";
          src = dubSrc;
          dubLock = ./dub-lock.json;
          dubBuildType = "ci";
          dubBuildFlags = [ "--config=mysql-integration" ];
          dontStrip = true;
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp build/dunamis $out/bin/mysql_test
            runHook postInstall
          '';
        };
      in {
        checks = {
          # D unit tests via dub
          unit-tests = pkgs.buildDubPackage {
            pname = "dunamis-unit-tests";
            version = "0.0.1";
            src = dubSrc;

            dubLock = ./dub-lock.json;

            # Run unit tests instead of building
            buildPhase = ''
              runHook preBuild
              echo "=== Running D unit tests ==="
              dub test --compiler=ldc2 --config=library --build=ci
              runHook postBuild
            '';

            installPhase = ''
              touch $out
            '';
          };

          # PostgreSQL integration tests
          postgres-integration = pkgs.stdenv.mkDerivation {
            name = "dunamis-postgres-integration";
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
            name = "dunamis-sqlite-integration";
            dontUnpack = true;

            buildPhase = ''
              # Run tests (uses in-memory SQLite database)
              ${sqliteTestBin}/bin/sqlite_test
            '';

            installPhase = ''
              touch $out
            '';
          };

          # MySQL integration tests
          mysql-integration = pkgs.stdenv.mkDerivation {
            name = "dunamis-mysql-integration";
            dontUnpack = true;
            nativeBuildInputs = [ pkgs.mariadb ];

            buildPhase = ''
              export HOME="$TMPDIR"
              export MYSQL_HOME="$TMPDIR/mysql"
              export MYSQL_DATADIR="$MYSQL_HOME/data"
              export MYSQL_SOCKET="$MYSQL_HOME/mysql.sock"
              export MYSQL_HOST="localhost"
              export MYSQL_TCP_PORT="3306"
              export MYSQL_USER="root"
              export MYSQL_DATABASE="testdb"
              export MYSQL_PWD=""

              mkdir -p "$MYSQL_HOME"

              # Initialize MySQL/MariaDB data directory
              mysql_install_db --datadir="$MYSQL_DATADIR" --auth-root-authentication-method=normal

              # Start MySQL server
              mysqld --datadir="$MYSQL_DATADIR" \
                     --socket="$MYSQL_SOCKET" \
                     --port="$MYSQL_TCP_PORT" \
                     --skip-networking=0 \
                     --bind-address="127.0.0.1" &
              MYSQL_PID=$!

              # Wait for MySQL to start
              for i in $(seq 1 30); do
                if mysqladmin --socket="$MYSQL_SOCKET" ping &>/dev/null; then
                  break
                fi
                sleep 1
              done

              # Create test database
              mysql --socket="$MYSQL_SOCKET" -u root -e "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE;"

              # Run tests
              ${mysqlTestBin}/bin/mysql_test

              # Cleanup
              kill $MYSQL_PID 2>/dev/null || true
              wait $MYSQL_PID 2>/dev/null || true
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
            pkgs.mariadb
            pkgs.curl
            pkgs.sqlite
          ];

          shellHook = ''
            echo "Dunamis development shell"
            echo "Run 'dub test' for unit tests"
            echo "Run 'nix flake check' for all tests (unit + integration)"
          '';
        };
      }
    );
}
