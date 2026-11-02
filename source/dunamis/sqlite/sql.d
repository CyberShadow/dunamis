module dunamis.sqlite.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.json;

import dunamis.relational.mutation : InsertInput, UpdateInput;
import dunamis.sqlite.dialect : sqliteDialect;
import dunamis.relational.sql_fragment : Sql, SqlName, sql;

// ============================================================================
// Mutation SQL Generation
// ============================================================================

/// The columns `columns` (as the schema names them), comma-separated.
private Sql columnList(string[] columns) {
    return Sql.join!", "(columns.map!(c => sql(i"$(SqlName(c))")).array);
}

/// Generate INSERT SQL for SQLite.
/// SQLite 3.35+ supports RETURNING, but for compatibility we use last_insert_rowid().
Sql generateInsertSQL(string table, InsertInput input) {
    auto columns = input.columns;

    if (columns.length == 0) {
        // No columns - use DEFAULT VALUES
        return sql(i"INSERT INTO $(SqlName(table)) DEFAULT VALUES");
    }

    // The values (as literals)
    auto values = Sql.join!", "(input.orderedValues.map!(v => sql(i"$(v)")).array);
    return sql(i"INSERT INTO $(SqlName(table)) ($(columnList(columns))) VALUES ($(values))");
}

/// Generate SELECT SQL to fetch the last inserted row.
Sql generateSelectLastInsertSQL(string table) {
    return sql(i"SELECT * FROM $(SqlName(table)) WHERE id = last_insert_rowid()");
}

/// Generate SELECT SQL to fetch a row by PK values from insert input.
/// Used for composite PKs or non-auto-increment PKs where last_insert_rowid() doesn't apply.
Sql generateSelectByPkSQL(string table, string[] pkColumns, InsertInput input) {
    Sql[] conditions;
    foreach (col; pkColumns)
        if (col in input.values)
            conditions ~= sql(i"$(SqlName(col)) = $(input.values[col])");
    return sql(i"SELECT * FROM $(SqlName(table)) WHERE $(Sql.join!" AND "(conditions))");
}

/// Generate a WHERE clause for PK column(s) matching a set of IDs.
private Sql generatePkWhereClause(string table, string[] pkColumns, string[] ids) {
    import dunamis.relational.keys : keyValues, singleKeyValue;

    if (pkColumns.length == 1) {
        // Single PK: WHERE col IN ('id1','id2')
        auto quotedIds = Sql.join!","(ids.map!(id => sql(i"$(singleKeyValue(id))")).array);
        return sql(i"$(SqlName(pkColumns[0])) IN ($(quotedIds))");
    } else {
        // Composite PK: WHERE (col1 = 'v1' AND col2 = 'v2') OR ...
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

/// Generate UPDATE SQL for SQLite.
Sql generateUpdateSQL(string table, UpdateInput input, string[] pkColumns) {
    auto columns = input.columns;
    auto target = SqlName(table);

    if (columns.length == 0) {
        // No columns to update - just return the rows
        return sql(i"SELECT * FROM $(target) WHERE $(generatePkWhereClause(table, pkColumns, input.ids))");
    }

    // The SET clauses, with the values (as literals)
    auto values = input.orderedValues;
    Sql[] setClauses;
    foreach (i, col; columns)
        setClauses ~= sql(i"$(SqlName(col)) = $(values[i])");

    auto where = generatePkWhereClause(table, pkColumns, input.ids);
    return sql(i"UPDATE $(target) SET $(Sql.join!", "(setClauses)) WHERE $(where)");
}

/// Generate SELECT SQL to fetch updated rows.
Sql generateSelectUpdatedSQL(string table, string[] ids, string[] pkColumns) {
    return sql(i"SELECT * FROM $(SqlName(table)) WHERE $(generatePkWhereClause(table, pkColumns, ids))");
}

/// Generate DELETE SQL for SQLite.
Sql generateDeleteSQL(string table, string[] ids, string[] pkColumns) {
    return sql(i"DELETE FROM $(SqlName(table)) WHERE $(generatePkWhereClause(table, pkColumns, ids))");
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

    auto sql = generateInsertSQL("users", input).render(sqliteDialect());
    assert(sql.canFind("INSERT INTO users"));
    assert(sql.canFind("'Alice'") || sql.canFind("'alice@test.com'"));
}

unittest {
    // Test INSERT with no columns
    auto input = InsertInput.init;
    auto sql = generateInsertSQL("users", input).render(sqliteDialect());
    assert(sql.canFind("DEFAULT VALUES"));
}

unittest {
    // Test UPDATE SQL generation
    auto input = UpdateInput(
        ["1", "2", "3"],
        ["first_name": JSONValue("Bob")]
    );

    auto sql = generateUpdateSQL("users", input, ["id"]).render(sqliteDialect());
    assert(sql.canFind("UPDATE users"));
    assert(sql.canFind("first_name = 'Bob'"));
    assert(sql.canFind("IN ('1','2','3')"));
}

unittest {
    // Test DELETE SQL generation
    auto sql = generateDeleteSQL("users", ["1", "2", "3"], ["id"]).render(sqliteDialect());
    assert(sql.canFind("DELETE FROM users"));
    assert(sql.canFind("IN ('1','2','3')"));
}
