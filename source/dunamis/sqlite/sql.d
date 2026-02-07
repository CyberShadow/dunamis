module dunamis.sqlite.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.json;

import dunamis.relational.mutation : InsertInput, UpdateInput;
import dunamis.sqlite.dialect : sqliteDialect;

// ============================================================================
// Mutation SQL Generation
// ============================================================================

/// Escape a string for use in SQLite SQL.
private string escapeSqlString(string s) {
    return sqliteDialect().escapeSqlString(s);
}

/// Convert JSONValue to a properly quoted SQLite SQL literal.
private string jsonToSqlLiteral(JSONValue val) {
    return sqliteDialect().jsonToSqlLiteral(val);
}

/// Generate INSERT SQL for SQLite.
/// SQLite 3.35+ supports RETURNING, but for compatibility we use last_insert_rowid().
/// Returns the SQL and a flag indicating if we need a follow-up SELECT.
string generateInsertSQL(string table, InsertInput input) {
    auto columns = input.columns;

    if (columns.length == 0) {
        // No columns - use DEFAULT VALUES
        return format("INSERT INTO %s DEFAULT VALUES", table);
    }

    // Convert values to SQL literals
    auto values = input.orderedValues;
    auto literals = values.map!(v => jsonToSqlLiteral(v)).array;

    return format(
        "INSERT INTO %s (%s) VALUES (%s)",
        table,
        columns.join(", "),
        literals.join(", ")
    );
}

/// Generate SELECT SQL to fetch the last inserted row.
string generateSelectLastInsertSQL(string table) {
    return format(
        "SELECT * FROM %s WHERE id = last_insert_rowid()",
        table
    );
}

/// Generate UPDATE SQL for SQLite.
string generateUpdateSQL(string table, UpdateInput input) {
    auto columns = input.columns;
    auto idsList = input.ids.map!(id => id.to!string).join(",");

    if (columns.length == 0) {
        // No columns to update - just return the rows
        return format(
            "SELECT * FROM %s WHERE id IN (%s)",
            table,
            idsList
        );
    }

    // Build SET clauses with embedded values
    auto values = input.orderedValues;
    string[] setClauses;
    foreach (i, col; columns) {
        setClauses ~= format("%s = %s", col, jsonToSqlLiteral(values[i]));
    }

    return format(
        "UPDATE %s SET %s WHERE id IN (%s)",
        table,
        setClauses.join(", "),
        idsList
    );
}

/// Generate SELECT SQL to fetch updated rows.
string generateSelectUpdatedSQL(string table, long[] ids) {
    auto idsList = ids.map!(id => id.to!string).join(",");
    return format(
        "SELECT * FROM %s WHERE id IN (%s)",
        table,
        idsList
    );
}

/// Generate DELETE SQL for SQLite.
string generateDeleteSQL(string table, long[] ids) {
    auto idsList = ids.map!(id => id.to!string).join(",");
    return format(
        "DELETE FROM %s WHERE id IN (%s)",
        table,
        idsList
    );
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // Test SQL escaping
    auto dialect = sqliteDialect();
    assert(dialect.escapeSqlString("hello") == "'hello'");
    assert(dialect.escapeSqlString("it's") == "'it''s'");
    assert(dialect.escapeSqlString("O'Brien") == "'O''Brien'");
}

unittest {
    // Test jsonToSqlLiteral
    auto dialect = sqliteDialect();
    assert(dialect.jsonToSqlLiteral(JSONValue("hello")) == "'hello'");
    assert(dialect.jsonToSqlLiteral(JSONValue(42)) == "42");
    assert(dialect.jsonToSqlLiteral(JSONValue(true)) == "1");
    assert(dialect.jsonToSqlLiteral(JSONValue(false)) == "0");
    assert(dialect.jsonToSqlLiteral(JSONValue(null)) == "NULL");
}

unittest {
    // Test INSERT SQL generation
    auto input = InsertInput([
        "first_name": JSONValue("Alice"),
        "email": JSONValue("alice@test.com")
    ]);

    auto sql = generateInsertSQL("users", input);
    assert(sql.canFind("INSERT INTO users"));
    assert(sql.canFind("'Alice'") || sql.canFind("'alice@test.com'"));
}

unittest {
    // Test INSERT with no columns
    auto input = InsertInput.init;
    auto sql = generateInsertSQL("users", input);
    assert(sql.canFind("DEFAULT VALUES"));
}

unittest {
    // Test UPDATE SQL generation
    auto input = UpdateInput(
        [1, 2, 3],
        ["first_name": JSONValue("Bob")]
    );

    auto sql = generateUpdateSQL("users", input);
    assert(sql.canFind("UPDATE users"));
    assert(sql.canFind("first_name = 'Bob'"));
    assert(sql.canFind("IN (1,2,3)"));
}

unittest {
    // Test DELETE SQL generation
    auto sql = generateDeleteSQL("users", [1, 2, 3]);
    assert(sql.canFind("DELETE FROM users"));
    assert(sql.canFind("IN (1,2,3)"));
}
