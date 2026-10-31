module dunamis.postgres.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.json;

import dunamis.relational.mutation : InsertInput, UpdateInput;
import dunamis.postgres.dialect : postgresDialect;

// ============================================================================
// Mutation SQL Generation
// ============================================================================

/// Escape a string for use in PostgreSQL SQL.
private string escapeSqlString(string s) {
    return postgresDialect().escapeSqlString(s);
}

/// Convert JSONValue to a properly quoted SQL literal.
private string jsonToSqlLiteral(JSONValue val) {
    return postgresDialect().jsonToSqlLiteral(val);
}

/// Generate INSERT SQL with RETURNING clause.
/// Values are embedded directly in the SQL (properly escaped).
/// Result is wrapped in row_to_json for consistent JSON parsing.
/// Uses CTE structure for better compatibility with prepared statements.
///
/// Example output:
/// ```sql
/// WITH inserted AS (
///   INSERT INTO users (first_name, last_name, email)
///   VALUES ('Alice', 'Smith', 'alice@test.com')
///   RETURNING *
/// )
/// SELECT row_to_json(t) FROM inserted t
/// ```
string generateInsertSQL(string table, InsertInput input) {
    auto columns = input.columns;

    if (columns.length == 0) {
        // No columns - use DEFAULT VALUES
        return format(
            "WITH inserted AS (" ~
            "INSERT INTO %s DEFAULT VALUES RETURNING *" ~
            ") SELECT row_to_json(t) FROM inserted t",
            table
        );
    }

    // Convert values to SQL literals
    auto values = input.orderedValues;
    auto literals = values.map!(v => jsonToSqlLiteral(v)).array;

    return format(
        "WITH inserted AS (" ~
        "INSERT INTO %s (%s) VALUES (%s) RETURNING *" ~
        ") SELECT row_to_json(t) FROM inserted t",
        table,
        columns.join(", "),
        literals.join(", ")
    );
}

/// Generate UPDATE SQL with RETURNING clause.
/// Values are embedded directly in the SQL (properly escaped).
/// Result is wrapped in json_agg for multiple rows.
/// Uses CTE structure for better compatibility with prepared statements.
///
/// Example output:
/// ```sql
/// WITH updated AS (
///   UPDATE users
///   SET first_name = 'Bob', last_name = 'Smith'
///   WHERE id = ANY(ARRAY[1,2,3])
///   RETURNING *
/// )
/// SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM updated t
/// ```
/// Generate a WHERE clause for PK column(s) matching a set of IDs.
private string generatePkWhereClause(string[] pkColumns, string[] ids) {
    import dunamis.relational.keys : keyValues, singleKeyValue;
    auto dialect = postgresDialect();

    if (pkColumns.length == 1) {
        // Single PK: col = ANY(ARRAY['id1','id2'])
        auto quotedIds = ids.map!(id => dialect.escapeSqlString(singleKeyValue(id))).join(",");
        return format("%s = ANY(ARRAY[%s])", pkColumns[0], quotedIds);
    } else {
        // Composite PK: (col1 = 'v1' AND col2 = 'v2') OR ...
        string[] conditions;
        foreach (id; ids) {
            auto parts = keyValues(id);
            string[] eqs;
            foreach (i, col; pkColumns) {
                eqs ~= format("%s = %s", col, dialect.escapeSqlString(i < parts.length ? parts[i] : ""));
            }
            conditions ~= "(" ~ eqs.join(" AND ") ~ ")";
        }
        return conditions.join(" OR ");
    }
}

string generateUpdateSQL(string table, UpdateInput input, string[] pkColumns) {
    auto columns = input.columns;
    auto whereClause = generatePkWhereClause(pkColumns, input.ids);

    if (columns.length == 0) {
        // No columns to update - just return the rows
        return format(
            "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (" ~
            "SELECT * FROM %s WHERE %s" ~
            ") t",
            table,
            whereClause
        );
    }

    // Build SET clauses with embedded values
    auto values = input.orderedValues;
    string[] setClauses;
    foreach (i, col; columns) {
        setClauses ~= format("%s = %s", col, jsonToSqlLiteral(values[i]));
    }

    return format(
        "WITH updated AS (" ~
        "UPDATE %s SET %s WHERE %s RETURNING *" ~
        ") SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM updated t",
        table,
        setClauses.join(", "),
        whereClause
    );
}

/// Generate DELETE SQL returning count of deleted rows.
string generateDeleteSQL(string table, string[] ids, string[] pkColumns) {
    auto whereClause = generatePkWhereClause(pkColumns, ids);
    return format(
        "WITH deleted AS (" ~
        "DELETE FROM %s WHERE %s RETURNING *" ~
        ") SELECT COUNT(*)::int FROM deleted",
        table,
        whereClause
    );
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // Test INSERT SQL generation with embedded values
    auto input = InsertInput([
        "first_name": JSONValue("Alice"),
        "email": JSONValue("alice@test.com")
    ]);

    auto sql = generateInsertSQL("users", input);
    assert(sql.canFind("INSERT INTO users"));
    assert(sql.canFind("RETURNING *"));
    assert(sql.canFind("row_to_json"));
    assert(sql.canFind("'Alice'") || sql.canFind("'alice@test.com'"));
}

unittest {
    // Test INSERT with no columns
    auto input = InsertInput.init;
    auto sql = generateInsertSQL("users", input);
    assert(sql.canFind("DEFAULT VALUES"));
}

unittest {
    // Test UPDATE SQL generation with embedded values
    auto input = UpdateInput(
        ["1", "2", "3"],
        ["first_name": JSONValue("Bob")]
    );

    auto sql = generateUpdateSQL("users", input, ["id"]);
    assert(sql.canFind("UPDATE users"));
    assert(sql.canFind("first_name = 'Bob'"));
    assert(sql.canFind("ARRAY['1','2','3']"));
    assert(sql.canFind("RETURNING *"));
    assert(sql.canFind("json_agg"));
}

unittest {
    // Test DELETE SQL generation with embedded IDs
    auto sql = generateDeleteSQL("users", ["1", "2", "3"], ["id"]);
    assert(sql.canFind("DELETE FROM users"));
    assert(sql.canFind("ARRAY['1','2','3']"));
    assert(sql.canFind("COUNT(*)"));
}

unittest {
    // Test SQL escaping
    auto dialect = postgresDialect();
    assert(dialect.escapeSqlString("hello") == "'hello'");
    assert(dialect.escapeSqlString("it's") == "'it''s'");
    assert(dialect.escapeSqlString("O'Brien") == "'O''Brien'");
}

unittest {
    // Test jsonToSqlLiteral
    auto dialect = postgresDialect();
    assert(dialect.jsonToSqlLiteral(JSONValue("hello")) == "'hello'");
    assert(dialect.jsonToSqlLiteral(JSONValue(42)) == "42");
    assert(dialect.jsonToSqlLiteral(JSONValue(true)) == "TRUE");
    assert(dialect.jsonToSqlLiteral(JSONValue(false)) == "FALSE");
    assert(dialect.jsonToSqlLiteral(JSONValue(null)) == "NULL");
}

// ============================================================================
// Relation binding (see PostgresSession.setRelationResolver)
// ============================================================================

/// The query `sql` (generated by Dunamis: a SELECT, or a WITH clause and the
/// query it is of), which reads the relations `names`, with those of them
/// which `relationOf` resolves to a FROM item (e.g. a call of a set-returning
/// function; null: not a relation it resolves) bound by a common table
/// expression of that name added to the query:
///
///     WITH name AS NOT MATERIALIZED (SELECT * FROM item), ... <query>
///
/// (merged into the query's own WITH clause, if it has one). PostgreSQL
/// inlines such a CTE where the name is referenced, as if the item were
/// written there under the name as alias, so that the query's references to
/// the name (in FROM and JOIN clauses, and in subqueries of its conditions
/// alike) read the item. A query naming no relation which `relationOf`
/// resolves is returned as it is.
const(char)[] bindRelations(const(char)[] sql, const(string)[] names, scope string delegate(string name) relationOf) {
    import std.ascii : isAlpha, isAlphaNum, isWhite, toLower;

    static bool isIdentStart(char c) { return isAlpha(c) || c == '_' || c >= 0x80; }
    static bool isIdentChar(char c) { return isAlphaNum(c) || c == '_' || c == '$' || c >= 0x80; }

    string bindings;
    bool[string] seen;
    foreach (name; names) {
        if (name in seen)
            continue;
        seen[name] = true;
        auto relation = relationOf(name);
        if (relation is null || relation == name)
            continue;
        bool plain = isIdentStart(name[0]) && (cast(const(ubyte)[]) name).all!(ch => isIdentChar(cast(char) ch) && !(ch >= 'A' && ch <= 'Z'));
        bindings ~= (bindings.length ? ", " : "") ~ (plain ? name : `"` ~ name.replace(`"`, `""`) ~ `"`) ~
            " AS NOT MATERIALIZED (SELECT * FROM " ~ relation ~ ")";
    }
    if (!bindings.length)
        return sql;

    size_t start = 0;
    while (start < sql.length && isWhite(sql[start]))
        start++;
    auto rest = sql[start .. $];
    if (rest.length >= 4 && rest[0 .. 4].map!(c => toLower(c)).equal("with") &&
            (rest.length == 4 || !isIdentChar(rest[4])))
        return sql[0 .. start + 4] ~ " " ~ bindings ~ "," ~ sql[start + 4 .. $];
    return sql[0 .. start] ~ "WITH " ~ bindings ~ "\n" ~ sql[start .. $];
}

unittest {
    string delegate(string) relations(string[string] map) {
        return (string name) => map.get(name, null);
    }
    auto r = relations(["app_users": "app.users_at(NULL, 3, -2, false, DATE '2026-10-30')",
        "app_posts": "app.posts_at(NULL, 3, -2, false, DATE '2026-10-30')"]);

    // Nothing to bind: the query itself
    enum plain = "SELECT id FROM users WHERE name = 'app_users'";
    assert(bindRelations(plain, ["users"], r) is plain);
    assert(bindRelations("SELECT 1", ["app_users"], delegate string(string _) => null) == "SELECT 1");

    // A query; the relations its subqueries and joins read (each bound once)
    assert(bindRelations("SELECT u.id FROM app_users u LEFT JOIN app_users j0 ON u.id = j0.id",
            ["app_users", "app_users"], r) ==
        "WITH app_users AS NOT MATERIALIZED (SELECT * FROM app.users_at(NULL, 3, -2, false, DATE '2026-10-30'))\n" ~
        "SELECT u.id FROM app_users u LEFT JOIN app_users j0 ON u.id = j0.id");
    assert(bindRelations("  SELECT 1 FROM app_posts WHERE EXISTS (SELECT 1 FROM app_users c0)",
            ["app_posts", "app_users", "tasks"], r) ==
        "  WITH app_posts AS NOT MATERIALIZED (SELECT * FROM app.posts_at(NULL, 3, -2, false, DATE '2026-10-30')), " ~
        "app_users AS NOT MATERIALIZED (SELECT * FROM app.users_at(NULL, 3, -2, false, DATE '2026-10-30'))\n" ~
        "SELECT 1 FROM app_posts WHERE EXISTS (SELECT 1 FROM app_users c0)");

    // The query's own CTEs (as Dunamis' layered queries have them)
    assert(bindRelations("WITH\n  layer0 AS (SELECT app_users.id FROM app_users)\nSELECT 1", ["app_users"], r) ==
        "WITH app_users AS NOT MATERIALIZED (SELECT * FROM app.users_at(NULL, 3, -2, false, DATE '2026-10-30')),\n" ~
        "  layer0 AS (SELECT app_users.id FROM app_users)\nSELECT 1");

    // Names which are not identifiers are quoted
    assert(bindRelations(`SELECT * FROM "T"`, ["T"], relations(["T": "f()"])) ==
        "WITH \"T\" AS NOT MATERIALIZED (SELECT * FROM f())\nSELECT * FROM \"T\"");
}
