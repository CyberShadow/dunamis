module dunamis.mysql.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.json;

import dunamis.relational.mutation : InsertInput, UpdateInput;
import dunamis.mysql.dialect : mysqlDialect;
import dunamis.relational.sql_fragment : Sql, SqlName, sql;

// ============================================================================
// Mutation SQL Generation
// ============================================================================

/// The columns `columns` (as the schema names them), comma-separated.
private Sql columnList(string[] columns) {
    return Sql.join!", "(columns.map!(c => sql(i"$(SqlName(c))")).array);
}

/// The arguments of JSON_OBJECT of the columns `columns` (each once): their
/// names (as keys) and values.
private Sql jsonObjectArgs(string[] columns) {
    Sql[] args;
    bool[string] seen;
    foreach (col; columns) {
        if (col in seen)
            continue;
        seen[col] = true;
        args ~= sql(i"$(col), $(SqlName(col))");
    }
    return Sql.join!", "(args);
}

/// Generate INSERT SQL for MySQL.
/// MySQL doesn't have a RETURNING clause, so we need to use LAST_INSERT_ID().
Sql generateInsertSQL(string table, InsertInput input) {
    auto columns = input.columns;

    if (columns.length == 0) {
        // No columns - use default values
        return sql(i"INSERT INTO $(SqlName(table)) () VALUES ()");
    }

    // The values (as literals)
    auto values = Sql.join!", "(input.orderedValues.map!(v => sql(i"$(v)")).array);
    return sql(i"INSERT INTO $(SqlName(table)) ($(columnList(columns))) VALUES ($(values))");
}

/// Generate SELECT SQL to fetch the last inserted row as JSON.
/// Uses LAST_INSERT_ID() to get the auto-generated ID.
/// Returns JSON with 'id' and the provided columns.
Sql generateSelectLastInsertSQL(string table, string[] columns) {
    // JSON_OBJECT arguments: 'id', id, 'col1', col1, ...
    // (`id` is not deduplicated against the columns, as it never was)
    Sql[] args = [sql(i"'id', id")];
    foreach (col; columns)
        args ~= sql(i"$(col), $(SqlName(col))");
    return sql(i"SELECT JSON_OBJECT($(Sql.join!", "(args))) AS json_row FROM $(SqlName(table)) WHERE id = LAST_INSERT_ID()");
}

/// Generate SELECT SQL to fetch a row by PK values from insert input.
/// Used for composite PKs or non-auto-increment PKs where LAST_INSERT_ID() doesn't apply.
/// Returns JSON with PK columns and all other input columns.
Sql generateSelectByPkSQL(string table, string[] pkColumns, string[] inputColumns, InsertInput input) {
    // WHERE clause from PK values
    Sql[] conditions;
    foreach (col; pkColumns)
        if (col in input.values)
            conditions ~= sql(i"$(SqlName(col)) = $(input.values[col])");

    auto object = jsonObjectArgs(pkColumns ~ inputColumns);
    return sql(i"SELECT JSON_OBJECT($(object)) AS json_row FROM $(SqlName(table)) WHERE $(Sql.join!" AND "(conditions))");
}

/// Generate a WHERE clause for PK column(s) matching a set of IDs.
private Sql generatePkWhereClause(string[] pkColumns, string[] ids) {
    import dunamis.relational.keys : keyValues, singleKeyValue;

    if (pkColumns.length == 1) {
        // Single PK: col IN ('id1','id2')
        auto quotedIds = Sql.join!","(ids.map!(id => sql(i"$(singleKeyValue(id))")).array);
        return sql(i"$(SqlName(pkColumns[0])) IN ($(quotedIds))");
    } else {
        // Composite PK: (col1 = 'v1' AND col2 = 'v2') OR ...
        Sql[] conditions;
        foreach (id; ids) {
            auto parts = keyValues(id);
            Sql[] eqs;
            foreach (i, col; pkColumns)
                eqs ~= sql(i"$(SqlName(col)) = $(i < parts.length ? parts[i] : "")");
            conditions ~= sql(i"($(Sql.join!" AND "(eqs)))");
        }
        return Sql.join!" OR "(conditions);
    }
}

/// Generate UPDATE SQL for MySQL (empty if there is nothing to update).
Sql generateUpdateSQL(string table, UpdateInput input, string[] pkColumns) {
    auto columns = input.columns;

    if (columns.length == 0) {
        // No columns to update - nothing to do
        return Sql.init;
    }

    // The SET clauses, with the values (as literals)
    auto values = input.orderedValues;
    Sql[] setClauses;
    foreach (i, col; columns)
        setClauses ~= sql(i"$(SqlName(col)) = $(values[i])");

    auto where = generatePkWhereClause(pkColumns, input.ids);
    return sql(i"UPDATE $(SqlName(table)) SET $(Sql.join!", "(setClauses)) WHERE $(where)");
}

/// Generate SELECT SQL to fetch updated rows as JSON.
/// Returns JSON with PK columns and the provided value columns.
Sql generateSelectUpdatedSQL(string table, string[] ids, string[] columns, string[] pkColumns) {
    auto object = jsonObjectArgs(pkColumns ~ columns);
    return sql(i"SELECT JSON_OBJECT($(object)) AS json_row FROM $(SqlName(table)) WHERE $(generatePkWhereClause(pkColumns, ids))");
}

/// Generate DELETE SQL for MySQL.
Sql generateDeleteSQL(string table, string[] ids, string[] pkColumns) {
    return sql(i"DELETE FROM $(SqlName(table)) WHERE $(generatePkWhereClause(pkColumns, ids))");
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

    auto sql = generateInsertSQL("users", input).render(mysqlDialect());
    assert(sql.canFind("INSERT INTO users"));
    assert(sql.canFind("'Alice'") || sql.canFind("'alice@test.com'"));
}

unittest {
    // Test INSERT with no columns
    auto input = InsertInput.init;
    auto sql = generateInsertSQL("users", input).render(mysqlDialect());
    assert(sql.canFind("() VALUES ()"));
}

unittest {
    // Test UPDATE SQL generation
    auto input = UpdateInput(
        ["1", "2", "3"],
        ["first_name": JSONValue("Bob")]
    );

    auto sql = generateUpdateSQL("users", input, ["id"]).render(mysqlDialect());
    assert(sql.canFind("UPDATE users"));
    assert(sql.canFind("first_name = 'Bob'"));
    assert(sql.canFind("IN ('1','2','3')"));
}

unittest {
    // Test DELETE SQL generation
    auto sql = generateDeleteSQL("users", ["1", "2", "3"], ["id"]).render(mysqlDialect());
    assert(sql.canFind("DELETE FROM users"));
    assert(sql.canFind("IN ('1','2','3')"));
}

unittest {
    // Test SELECT after INSERT SQL generation
    auto sql = generateSelectLastInsertSQL("users", ["first_name", "email"]).render(mysqlDialect());
    assert(sql.canFind("JSON_OBJECT"));
    assert(sql.canFind("'id', id"));
    assert(sql.canFind("'first_name', first_name"));
    assert(sql.canFind("LAST_INSERT_ID()"));
}

unittest {
    // Test SELECT after UPDATE SQL generation
    auto sql = generateSelectUpdatedSQL("users", ["1", "2"], ["first_name"], ["id"]).render(mysqlDialect());
    assert(sql.canFind("JSON_OBJECT"));
    assert(sql.canFind("'id', id"));
    assert(sql.canFind("'first_name', first_name"));
    assert(sql.canFind("IN ('1','2')"));
}
