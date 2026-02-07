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
string generateUpdateSQL(string table, UpdateInput input) {
    auto columns = input.columns;
    auto idsArray = "ARRAY[" ~ input.ids.map!(id => id.to!string).join(",") ~ "]";

    if (columns.length == 0) {
        // No columns to update - just return the rows
        return format(
            "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (" ~
            "SELECT * FROM %s WHERE id = ANY(%s)" ~
            ") t",
            table,
            idsArray
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
        "UPDATE %s SET %s WHERE id = ANY(%s) RETURNING *" ~
        ") SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM updated t",
        table,
        setClauses.join(", "),
        idsArray
    );
}

/// Generate DELETE SQL returning count of deleted rows.
/// IDs are embedded directly in the SQL.
///
/// Example output:
/// ```sql
/// WITH deleted AS (
///   DELETE FROM users WHERE id = ANY(ARRAY[1,2,3]) RETURNING id
/// )
/// SELECT COUNT(*) FROM deleted
/// ```
string generateDeleteSQL(string table, long[] ids) {
    auto idsArray = "ARRAY[" ~ ids.map!(id => id.to!string).join(",") ~ "]";
    return format(
        "WITH deleted AS (" ~
        "DELETE FROM %s WHERE id = ANY(%s) RETURNING id" ~
        ") SELECT COUNT(*)::int FROM deleted",
        table,
        idsArray
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
        [1, 2, 3],
        ["first_name": JSONValue("Bob")]
    );

    auto sql = generateUpdateSQL("users", input);
    assert(sql.canFind("UPDATE users"));
    assert(sql.canFind("first_name = 'Bob'"));
    assert(sql.canFind("ARRAY[1,2,3]"));
    assert(sql.canFind("RETURNING *"));
    assert(sql.canFind("json_agg"));
}

unittest {
    // Test DELETE SQL generation with embedded IDs
    auto sql = generateDeleteSQL("users", [1, 2, 3]);
    assert(sql.canFind("DELETE FROM users"));
    assert(sql.canFind("ARRAY[1,2,3]"));
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
