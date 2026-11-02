module dunamis.postgres.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.json;

import dunamis.relational.mutation : InsertInput, UpdateInput;
import dunamis.postgres.dialect : postgresDialect;
import dunamis.relational.sql_fragment : Sql, SqlName, SqlValue, sql;

// ============================================================================
// Mutation SQL Generation
// ============================================================================

/// The columns `columns` (as the schema names them), comma-separated.
private Sql columnList(string[] columns) {
    return Sql.join!", "(columns.map!(c => sql(i"$(SqlName(c))")).array);
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
Sql generateInsertSQL(string table, InsertInput input) {
    auto columns = input.columns;
    auto into = SqlName(table);

    if (columns.length == 0) {
        // No columns - use DEFAULT VALUES
        return sql(i"WITH inserted AS (INSERT INTO $(into) DEFAULT VALUES RETURNING *) SELECT row_to_json(t) FROM inserted t");
    }

    // The values (as literals)
    auto values = Sql.join!", "(input.orderedValues.map!(v => sql(i"$(v)")).array);
    auto insert = sql(i"INSERT INTO $(into) ($(columnList(columns))) VALUES ($(values)) RETURNING *");
    return sql(i"WITH inserted AS ($(insert)) SELECT row_to_json(t) FROM inserted t");
}

/// Generate a WHERE clause for PK column(s) matching a set of IDs.
private Sql generatePkWhereClause(string[] pkColumns, string[] ids) {
    import dunamis.relational.keys : keyValues, singleKeyValue;

    if (pkColumns.length == 1) {
        // Single PK: col = ANY('{"id1","id2"}'), one array
        auto keys = SqlValue.array(ids.map!(id => SqlValue.of(singleKeyValue(id))).array);
        return sql(i"$(SqlName(pkColumns[0])) = ANY($(keys))");
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
///   WHERE id = ANY('{"1","2","3"}')
///   RETURNING *
/// )
/// SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM updated t
/// ```
Sql generateUpdateSQL(string table, UpdateInput input, string[] pkColumns) {
    auto columns = input.columns;
    auto whereClause = generatePkWhereClause(pkColumns, input.ids);
    auto target = SqlName(table);

    if (columns.length == 0) {
        // No columns to update - just return the rows
        return sql(i"SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM $(target) WHERE $(whereClause)) t");
    }

    // The SET clauses, with the values (as literals)
    auto values = input.orderedValues;
    Sql[] setClauses;
    foreach (i, col; columns)
        setClauses ~= sql(i"$(SqlName(col)) = $(values[i])");

    auto update = sql(i"UPDATE $(target) SET $(Sql.join!", "(setClauses)) WHERE $(whereClause) RETURNING *");
    return sql(i"WITH updated AS ($(update)) SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM updated t");
}

/// Generate DELETE SQL returning count of deleted rows.
Sql generateDeleteSQL(string table, string[] ids, string[] pkColumns) {
    auto whereClause = generatePkWhereClause(pkColumns, ids);
    return sql(i"WITH deleted AS (DELETE FROM $(SqlName(table)) WHERE $(whereClause) RETURNING *) SELECT COUNT(*)::int FROM deleted");
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

    auto sql = generateInsertSQL("users", input).renderInline(postgresDialect());
    assert(sql.canFind("INSERT INTO users"));
    assert(sql.canFind("RETURNING *"));
    assert(sql.canFind("row_to_json"));
    assert(sql.canFind("'Alice'") || sql.canFind("'alice@test.com'"));
}

unittest {
    // Test INSERT with no columns
    auto input = InsertInput.init;
    auto sql = generateInsertSQL("users", input).renderInline(postgresDialect());
    assert(sql.canFind("DEFAULT VALUES"));
}

unittest {
    // Test UPDATE SQL generation with embedded values
    auto input = UpdateInput(
        ["1", "2", "3"],
        ["first_name": JSONValue("Bob")]
    );

    auto bound = generateUpdateSQL("users", input, ["id"]).render(postgresDialect());
    assert(bound.text.canFind("UPDATE users SET first_name = $1 WHERE id = ANY($2) RETURNING *"), bound.text);
    assert(bound.text.canFind("json_agg"));
    assert(bound.params == [SqlValue.of(JSONValue("Bob")),
        SqlValue.array([SqlValue.of("1"), SqlValue.of("2"), SqlValue.of("3")])]);
}

unittest {
    // Test DELETE SQL generation with embedded IDs
    auto sql = generateDeleteSQL("users", ["1", "2", "3"], ["id"]).renderInline(postgresDialect());
    assert(sql.canFind("DELETE FROM users"));
    assert(sql.canFind(`id = ANY('{"1","2","3"}')`), sql);
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

/// The query `query` (generated by Dunamis: a SELECT, or a WITH clause and
/// the query it is of), which reads the relations `names`, with those of
/// them which `relationOf` resolves to a FROM item (e.g. a call of a
/// set-returning function; empty: not a relation it resolves) bound by a
/// common table expression of that name added to the query:
///
///     WITH name AS NOT MATERIALIZED (SELECT * FROM item), ... <query>
///
/// (merged into the query's own WITH clause, if it has one). PostgreSQL
/// inlines such a CTE where the name is referenced, as if the item were
/// written there under the name as alias, so that the query's references to
/// the name (in FROM and JOIN clauses, and in subqueries of its conditions
/// alike) read the item. A query naming no relation which `relationOf`
/// resolves is returned as it is.
Sql bindRelations(Sql query, const(string)[] names, scope Sql delegate(string name) relationOf) {
    import std.ascii : isAlpha, isAlphaNum;
    import dunamis.relational.sql_fragment : Ident;

    static bool isIdentStart(char c) { return isAlpha(c) || c == '_' || c >= 0x80; }
    static bool isIdentChar(char c) { return isAlphaNum(c) || c == '_' || c == '$' || c >= 0x80; }

    Sql[] bindings;
    bool[string] seen;
    foreach (name; names) {
        if (name in seen)
            continue;
        seen[name] = true;
        auto relation = relationOf(name);
        if (relation.empty || relation == sql(i"$(SqlName(name))"))
            continue;
        bool plain = isIdentStart(name[0]) && (cast(const(ubyte)[]) name).all!(ch => isIdentChar(cast(char) ch) && !(ch >= 'A' && ch <= 'Z'));
        auto alias_ = plain ? sql(i"$(SqlName(name))") : sql(i"$(Ident(name))");
        bindings ~= sql(i"$(alias_) AS NOT MATERIALIZED (SELECT * FROM $(relation))");
    }
    if (!bindings.length)
        return query;

    auto list = Sql.join!", "(bindings);
    auto withClause = query.withoutPrefix!"WITH";
    if (!withClause.isNull)
        return sql(i"WITH $(list),$(withClause.get)");
    return sql(i"WITH $(list)\n$(query)");
}

unittest {
    Sql delegate(string) relations(Sql[string] map) {
        return (string name) => map.get(name, Sql.init);
    }
    string text(Sql s) { return s.renderInline(postgresDialect()); }
    auto day = "2026-10-30";
    auto r = relations(["app_users": sql(i"app.users_at(NULL, 3, -2, false, $(day)::date)"),
        "app_posts": sql(i"app.posts_at(NULL, 3, -2, false, $(day)::date)")]);

    // Nothing to bind: the query itself
    auto plain = sql(i"SELECT id FROM users WHERE name = $("app_users")");
    assert(bindRelations(plain, ["users"], r) == plain);
    assert(text(bindRelations(sql(i"SELECT 1"), ["app_users"], delegate Sql(string _) => Sql.init)) == "SELECT 1");

    // A query; the relations its subqueries and joins read (each bound once)
    assert(text(bindRelations(sql(i"SELECT u.id FROM app_users u LEFT JOIN app_users j0 ON u.id = j0.id"),
            ["app_users", "app_users"], r)) ==
        "WITH app_users AS NOT MATERIALIZED (SELECT * FROM app.users_at(NULL, 3, -2, false, '2026-10-30'::date))\n" ~
        "SELECT u.id FROM app_users u LEFT JOIN app_users j0 ON u.id = j0.id");
    assert(text(bindRelations(sql(i"SELECT 1 FROM app_posts WHERE EXISTS (SELECT 1 FROM app_users c0)"),
            ["app_posts", "app_users", "tasks"], r)) ==
        "WITH app_posts AS NOT MATERIALIZED (SELECT * FROM app.posts_at(NULL, 3, -2, false, '2026-10-30'::date)), " ~
        "app_users AS NOT MATERIALIZED (SELECT * FROM app.users_at(NULL, 3, -2, false, '2026-10-30'::date))\n" ~
        "SELECT 1 FROM app_posts WHERE EXISTS (SELECT 1 FROM app_users c0)");

    // The query's own CTEs (as Dunamis' layered queries have them)
    assert(text(bindRelations(sql(i"WITH\n  layer0 AS (SELECT app_users.id FROM app_users)\nSELECT 1"),
            ["app_users"], r)) ==
        "WITH app_users AS NOT MATERIALIZED (SELECT * FROM app.users_at(NULL, 3, -2, false, '2026-10-30'::date)),\n" ~
        "  layer0 AS (SELECT app_users.id FROM app_users)\nSELECT 1");

    // Names which are not identifiers are quoted
    assert(text(bindRelations(sql(i`SELECT * FROM "T"`), ["T"], relations(["T": sql(i"f()")]))) ==
        "WITH \"T\" AS NOT MATERIALIZED (SELECT * FROM f())\nSELECT * FROM \"T\"");
}
