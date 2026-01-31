{
  description = "graphqld2 - GraphQL server with bulk data resolution";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # ae library with full psql implementation
    ae = {
      url = "github:CyberShadow/ae/11ce638e8d9639ab64a862a33be96da554dca3b4";
      flake = false;
    };
    # graphqld parser
    graphqld = {
      url = "github:burner/graphqld/542374109b26018c9542631c90d1ba2acef32a8b";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ae, graphqld }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        checks = {
          # PostgreSQL integration test with HTTP server and curl
          postgres-integration = pkgs.stdenv.mkDerivation {
            name = "graphqld2-postgres-test";
            src = self;

            nativeBuildInputs = [ pkgs.postgresql pkgs.ldc pkgs.curl ];

            buildPhase = ''
              export HOME="$TMPDIR"
              export PGDATA="$TMPDIR/pgdata"
              export PGHOST="$TMPDIR"
              export PGUSER="testuser"
              export PGPASSWORD="testpass"
              export PGDATABASE="testdb"

              echo "=== Initializing PostgreSQL ==="
              initdb -D "$PGDATA" --auth=trust --username=postgres

              cat >> "$PGDATA/postgresql.conf" <<EOF
              unix_socket_directories = '$TMPDIR'
              listen_addresses = 'localhost'
              port = 5432
              password_encryption = scram-sha-256
              EOF

              cat > "$PGDATA/pg_hba.conf" <<EOF
              local   all             postgres                                trust
              local   all             all                                     scram-sha-256
              host    all             all             127.0.0.1/32            scram-sha-256
              host    all             all             ::1/128                 scram-sha-256
              EOF

              echo "=== Starting PostgreSQL ==="
              pg_ctl -D "$PGDATA" -l "$PGDATA/logfile" start -w

              echo "=== Creating test user and database ==="
              psql -h "$TMPDIR" -U postgres -d postgres -c "CREATE USER $PGUSER WITH PASSWORD '$PGPASSWORD';"
              psql -h "$TMPDIR" -U postgres -d postgres -c "CREATE DATABASE $PGDATABASE OWNER $PGUSER;"

              echo "=== Creating test schema and data ==="
              psql -h "$TMPDIR" -U postgres -d "$PGDATABASE" <<SQL
              CREATE TABLE users (
                id SERIAL PRIMARY KEY,
                first_name TEXT NOT NULL,
                last_name TEXT NOT NULL
              );

              CREATE TABLE posts (
                id SERIAL PRIMARY KEY,
                title TEXT NOT NULL,
                author_id INTEGER REFERENCES users(id)
              );

              INSERT INTO users (first_name, last_name) VALUES
                ('Alice', 'Smith'),
                ('Bob', 'Jones'),
                ('Carol', 'White');

              INSERT INTO posts (title, author_id) VALUES
                ('Hello World', 1),
                ('GraphQL Rocks', 1),
                ('D Programming', 2);

              GRANT ALL ON users TO $PGUSER;
              GRANT ALL ON posts TO $PGUSER;
              GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $PGUSER;
              SQL

              export PGHOST="localhost"

              echo "=== Building integration test ==="

              # Set up import paths
              mkdir -p "$TMPDIR/import"
              cp -r ${ae} "$TMPDIR/import/ae"
              cp -r ${graphqld}/source/graphql "$TMPDIR/import/graphql"

              # Compile the integration test
              ldc2 \
                -i \
                -I"$TMPDIR/import" \
                -I"$src/source" \
                -I"$src/integration" \
                -of="$TMPDIR/postgres_test" \
                "$src/integration/postgres_test.d"

              echo "=== Starting HTTP server ==="
              "$TMPDIR/postgres_test" &
              SERVER_PID=$!

              # Wait for server to be ready
              for i in $(seq 1 30); do
                if curl -s http://localhost:8080/health > /dev/null 2>&1; then
                  echo "Server is ready"
                  break
                fi
                sleep 0.5
              done

              echo "=== Running curl tests ==="

              # Test 1: Simple query
              echo "Test 1: Query users"
              RESULT=$(curl -s -X POST http://localhost:8080/graphql \
                -H 'Content-Type: application/json' \
                -d '{"query": "{ users { firstName lastName } }"}')
              echo "Response: $RESULT"

              # Verify response contains expected data
              if echo "$RESULT" | grep -q "Alice"; then
                echo "✓ Found Alice in response"
              else
                echo "✗ Alice not found in response"
                kill $SERVER_PID 2>/dev/null
                exit 1
              fi

              if echo "$RESULT" | grep -q "Bob"; then
                echo "✓ Found Bob in response"
              else
                echo "✗ Bob not found in response"
                kill $SERVER_PID 2>/dev/null
                exit 1
              fi

              if echo "$RESULT" | grep -q "Carol"; then
                echo "✓ Found Carol in response"
              else
                echo "✗ Carol not found in response"
                kill $SERVER_PID 2>/dev/null
                exit 1
              fi

              # Test 2: Mutation - create user
              echo ""
              echo "Test 2: Mutation - create user"
              RESULT=$(curl -s -X POST http://localhost:8080/graphql \
                -H 'Content-Type: application/json' \
                -d '{"query": "mutation { createUserWithName(firstName: \"Test\", lastName: \"User\") { firstName lastName } }"}')
              echo "Response: $RESULT"

              if echo "$RESULT" | grep -q "Test"; then
                echo "✓ Found Test in response"
              else
                echo "✗ Test not found in response"
                kill $SERVER_PID 2>/dev/null
                exit 1
              fi

              if echo "$RESULT" | grep -q "User"; then
                echo "✓ Found User in response"
              else
                echo "✗ User not found in response"
                kill $SERVER_PID 2>/dev/null
                exit 1
              fi

              # Test 3: Verify mutation persisted - query should now include new user
              echo ""
              echo "Test 3: Query to verify mutation persisted"
              RESULT=$(curl -s -X POST http://localhost:8080/graphql \
                -H 'Content-Type: application/json' \
                -d '{"query": "{ users { firstName lastName } }"}')
              echo "Response: $RESULT"

              if echo "$RESULT" | grep -q "Test"; then
                echo "✓ New user 'Test' found in query response"
              else
                echo "✗ New user 'Test' not found - mutation may not have persisted"
                kill $SERVER_PID 2>/dev/null
                exit 1
              fi

              echo "=== Stopping server ==="
              kill $SERVER_PID 2>/dev/null

              echo "=== Stopping PostgreSQL ==="
              pg_ctl -D "$PGDATA" stop -m fast

              echo ""
              echo "=== All PostgreSQL integration tests passed! ==="
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
          ];

          shellHook = ''
            echo "graphqld2 development shell"
            echo "Run 'dub test' for unit tests"
            echo "Run 'nix flake check' for integration tests"
          '';
        };
      }
    );
}
