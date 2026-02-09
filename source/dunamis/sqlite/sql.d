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

/// Generate SELECT SQL to fetch a row by PK values from insert input.
/// Used for composite PKs or non-auto-increment PKs where last_insert_rowid() doesn't apply.
string generateSelectByPkSQL(string table, string[] pkColumns, InsertInput input) {
    string[] conditions;
    foreach (col; pkColumns) {
        if (col in input.values) {
            conditions ~= format("%s = %s", col, jsonToSqlLiteral(input.values[col]));
        }
    }
    return format(
        "SELECT * FROM %s WHERE %s",
        table,
        conditions.join(" AND ")
    );
}

/// Generate a WHERE clause for PK column(s) matching a set of IDs.
private string generatePkWhereClause(string table, string[] pkColumns, string[] ids) {
    import dunamis.core.types : decodeCompositeKey;
    auto dialect = sqliteDialect();

    if (pkColumns.length == 1) {
        // Single PK: WHERE col IN ('id1','id2')
        auto quotedIds = ids.map!(id => dialect.escapeSqlString(id)).join(",");
        return format("%s IN (%s)", pkColumns[0], quotedIds);
    } else {
        // Composite PK: WHERE (col1 = 'v1' AND col2 = 'v2') OR ...
        string[] conditions;
        foreach (id; ids) {
            auto parts = decodeCompositeKey(id);
            string[] eqs;
            foreach (i, col; pkColumns) {
                eqs ~= format("%s = %s", col, dialect.escapeSqlString(i < parts.length ? parts[i] : ""));
            }
            conditions ~= "(" ~ eqs.join(" AND ") ~ ")";
        }
        return conditions.join(" OR ");
    }
}

/// Generate UPDATE SQL for SQLite.
string generateUpdateSQL(string table, UpdateInput input, string[] pkColumns = ["id"]) {
    auto columns = input.columns;

    if (columns.length == 0) {
        // No columns to update - just return the rows
        return format(
            "SELECT * FROM %s WHERE %s",
            table,
            generatePkWhereClause(table, pkColumns, input.ids)
        );
    }

    // Build SET clauses with embedded values
    auto values = input.orderedValues;
    string[] setClauses;
    foreach (i, col; columns) {
        setClauses ~= format("%s = %s", col, jsonToSqlLiteral(values[i]));
    }

    return format(
        "UPDATE %s SET %s WHERE %s",
        table,
        setClauses.join(", "),
        generatePkWhereClause(table, pkColumns, input.ids)
    );
}

/// Generate SELECT SQL to fetch updated rows.
string generateSelectUpdatedSQL(string table, string[] ids, string[] pkColumns = ["id"]) {
    return format(
        "SELECT * FROM %s WHERE %s",
        table,
        generatePkWhereClause(table, pkColumns, ids)
    );
}

/// Generate DELETE SQL for SQLite.
string generateDeleteSQL(string table, string[] ids, string[] pkColumns = ["id"]) {
    return format(
        "DELETE FROM %s WHERE %s",
        table,
        generatePkWhereClause(table, pkColumns, ids)
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
        ["1", "2", "3"],
        ["first_name": JSONValue("Bob")]
    );

    auto sql = generateUpdateSQL("users", input);
    assert(sql.canFind("UPDATE users"));
    assert(sql.canFind("first_name = 'Bob'"));
    assert(sql.canFind("IN ('1','2','3')"));
}

unittest {
    // Test DELETE SQL generation
    auto sql = generateDeleteSQL("users", ["1", "2", "3"]);
    assert(sql.canFind("DELETE FROM users"));
    assert(sql.canFind("IN ('1','2','3')"));
}
