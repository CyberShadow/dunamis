module dunamis.mysql.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.json;

import dunamis.relational.mutation : InsertInput, UpdateInput;
import dunamis.mysql.dialect : mysqlDialect;

// ============================================================================
// Mutation SQL Generation
// ============================================================================

/// Escape a string for use in MySQL SQL.
private string escapeSqlString(string s) {
    return mysqlDialect().escapeSqlString(s);
}

/// Convert JSONValue to a properly quoted MySQL SQL literal.
private string jsonToSqlLiteral(JSONValue val) {
    return mysqlDialect().jsonToSqlLiteral(val);
}

/// Generate INSERT SQL for MySQL.
/// MySQL doesn't have a RETURNING clause, so we need to use LAST_INSERT_ID().
string generateInsertSQL(string table, InsertInput input) {
    auto columns = input.columns;

    if (columns.length == 0) {
        // No columns - use default values
        return format("INSERT INTO %s () VALUES ()", table);
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

/// Generate SELECT SQL to fetch the last inserted row as JSON.
/// Uses LAST_INSERT_ID() to get the auto-generated ID.
/// Returns JSON with 'id' and the provided columns.
string generateSelectLastInsertSQL(string table, string[] columns) {
    // Build JSON_OBJECT arguments: 'id', id, 'col1', col1, ...
    string[] jsonArgs = ["'id'", "id"];
    foreach (col; columns) {
        jsonArgs ~= format("'%s'", col);
        jsonArgs ~= col;
    }

    return format(
        "SELECT JSON_OBJECT(%s) AS json_row FROM %s WHERE id = LAST_INSERT_ID()",
        jsonArgs.join(", "),
        table
    );
}

/// Generate SELECT SQL to fetch a row by PK values from insert input.
/// Used for composite PKs or non-auto-increment PKs where LAST_INSERT_ID() doesn't apply.
/// Returns JSON with PK columns and all other input columns.
string generateSelectByPkSQL(string table, string[] pkColumns, string[] inputColumns, InsertInput input) {
    import std.algorithm : canFind;

    // Build JSON_OBJECT arguments from PK columns + input columns
    string[] jsonArgs;
    bool[string] seen;
    foreach (col; pkColumns) {
        jsonArgs ~= format("'%s'", col);
        jsonArgs ~= col;
        seen[col] = true;
    }
    foreach (col; inputColumns) {
        if (col !in seen) {
            jsonArgs ~= format("'%s'", col);
            jsonArgs ~= col;
            seen[col] = true;
        }
    }

    // Build WHERE clause from PK values
    string[] conditions;
    foreach (col; pkColumns) {
        if (col in input.values) {
            conditions ~= format("%s = %s", col, jsonToSqlLiteral(input.values[col]));
        }
    }

    return format(
        "SELECT JSON_OBJECT(%s) AS json_row FROM %s WHERE %s",
        jsonArgs.join(", "),
        table,
        conditions.join(" AND ")
    );
}

/// Generate a WHERE clause for PK column(s) matching a set of IDs.
private string generatePkWhereClause(string[] pkColumns, string[] ids) {
    import dunamis.core.types : decodeCompositeKey;
    auto dialect = mysqlDialect();

    if (pkColumns.length == 1) {
        // Single PK: col IN ('id1','id2')
        auto quotedIds = ids.map!(id => dialect.escapeSqlString(id)).join(",");
        return format("%s IN (%s)", pkColumns[0], quotedIds);
    } else {
        // Composite PK: (col1 = 'v1' AND col2 = 'v2') OR ...
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

/// Generate UPDATE SQL for MySQL.
string generateUpdateSQL(string table, UpdateInput input, string[] pkColumns = ["id"]) {
    auto columns = input.columns;

    if (columns.length == 0) {
        // No columns to update - nothing to do
        return "";
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
        generatePkWhereClause(pkColumns, input.ids)
    );
}

/// Generate SELECT SQL to fetch updated rows as JSON.
/// Returns JSON with PK columns and the provided value columns.
string generateSelectUpdatedSQL(string table, string[] ids, string[] columns, string[] pkColumns = ["id"]) {
    // Build JSON_OBJECT arguments from PK columns + value columns
    string[] jsonArgs;
    bool[string] seen;
    foreach (col; pkColumns) {
        jsonArgs ~= format("'%s'", col);
        jsonArgs ~= col;
        seen[col] = true;
    }
    foreach (col; columns) {
        if (col !in seen) {
            jsonArgs ~= format("'%s'", col);
            jsonArgs ~= col;
        }
    }

    return format(
        "SELECT JSON_OBJECT(%s) AS json_row FROM %s WHERE %s",
        jsonArgs.join(", "),
        table,
        generatePkWhereClause(pkColumns, ids)
    );
}

/// Generate DELETE SQL for MySQL.
string generateDeleteSQL(string table, string[] ids, string[] pkColumns = ["id"]) {
    return format(
        "DELETE FROM %s WHERE %s",
        table,
        generatePkWhereClause(pkColumns, ids)
    );
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // Test SQL escaping
    auto dialect = mysqlDialect();
    assert(dialect.escapeSqlString("hello") == "'hello'");
    assert(dialect.escapeSqlString("it's") == "'it''s'");
    assert(dialect.escapeSqlString("O'Brien") == "'O''Brien'");
    assert(dialect.escapeSqlString("back\\slash") == "'back\\\\slash'");
}

unittest {
    // Test jsonToSqlLiteral
    auto dialect = mysqlDialect();
    assert(dialect.jsonToSqlLiteral(JSONValue("hello")) == "'hello'");
    assert(dialect.jsonToSqlLiteral(JSONValue(42)) == "42");
    assert(dialect.jsonToSqlLiteral(JSONValue(true)) == "TRUE");
    assert(dialect.jsonToSqlLiteral(JSONValue(false)) == "FALSE");
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
    assert(sql.canFind("() VALUES ()"));
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

unittest {
    // Test SELECT after INSERT SQL generation
    auto sql = generateSelectLastInsertSQL("users", ["first_name", "email"]);
    assert(sql.canFind("JSON_OBJECT"));
    assert(sql.canFind("'id', id"));
    assert(sql.canFind("'first_name', first_name"));
    assert(sql.canFind("LAST_INSERT_ID()"));
}

unittest {
    // Test SELECT after UPDATE SQL generation
    auto sql = generateSelectUpdatedSQL("users", ["1", "2"], ["first_name"]);
    assert(sql.canFind("JSON_OBJECT"));
    assert(sql.canFind("'id', id"));
    assert(sql.canFind("'first_name', first_name"));
    assert(sql.canFind("IN ('1','2')"));
}
