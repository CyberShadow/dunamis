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
    import dunamis.core.types : decodeCompositeKey;
    auto dialect = postgresDialect();

    if (pkColumns.length == 1) {
        // Single PK: col = ANY(ARRAY['id1','id2'])
        auto quotedIds = ids.map!(id => dialect.escapeSqlString(id)).join(",");
        return format("%s = ANY(ARRAY[%s])", pkColumns[0], quotedIds);
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

/// The statement `sql` with the relations it references bound: each name of
/// a relation in it (an identifier, not qualified, outside literals and
/// comments) which `relationOf` resolves to a FROM item (e.g. a call of a
/// set-returning function; null: not a relation it resolves) is bound by a
/// common table expression of that name added to the statement:
///
///     WITH name AS NOT MATERIALIZED (SELECT * FROM item), ... <statement>
///
/// (merged into the statement's own WITH clause, if it has one). PostgreSQL
/// inlines such a CTE where the name is referenced, as if the item were
/// written there under the name as alias, so that the statement's
/// references to the name (in FROM and JOIN clauses, and in subqueries of
/// its conditions alike) read the item. An identifier which is not a
/// relation of the statement (a column, say) but has such a name binds a CTE
/// which the statement does not use, which is harmless. Only statements
/// which can have a WITH clause (SELECT, INSERT, UPDATE, DELETE, VALUES,
/// TABLE, MERGE, or a parenthesized query) are bound; others are returned as
/// they are, as are statements naming no relation which `relationOf`
/// resolves. `sql` is one statement.
const(char)[] bindRelations(const(char)[] sql, scope string delegate(string name) relationOf) {
    import std.ascii : isAlpha, isAlphaNum, isDigit, isWhite, toLower;
    import std.string : indexOf;

    static bool isIdentStart(char c) { return isAlpha(c) || c == '_' || c >= 0x80; }
    static bool isIdentChar(char c) { return isAlphaNum(c) || c == '_' || c == '$' || c >= 0x80; }

    // The names (in the order they first appear) and their relations
    string[] names, relations;
    bool[string] seen;
    void candidate(string name) {
        if (name in seen)
            return;
        seen[name] = true;
        auto relation = relationOf(name);
        if (relation !is null && relation != name) {
            names ~= name;
            relations ~= relation;
        }
    }
    // Whether the token at `start` is qualified (follows a '.')
    bool qualified(size_t start) {
        while (start > 0 && isWhite(sql[start - 1]))
            start--;
        return start > 0 && sql[start - 1] == '.';
    }

    size_t i = 0;
    // The end of a quoted section starting at `i` (after its closing quote
    // `q`, doubled to escape it; with backslash escapes if `backslashes`)
    size_t skipQuoted(size_t i, char q, bool backslashes) {
        i++;
        while (i < sql.length) {
            if (backslashes && sql[i] == '\\') {
                i += 2;
                continue;
            }
            if (sql[i] == q) {
                if (i + 1 < sql.length && sql[i + 1] == q) {
                    i += 2;
                    continue;
                }
                return i + 1;
            }
            i++;
        }
        return i;
    }
    while (i < sql.length) {
        auto c = sql[i];
        if (c == '\'') {
            // (E'...': the E was read as an identifier just before)
            bool escaped = i > 0 && (sql[i - 1] == 'E' || sql[i - 1] == 'e') &&
                (i < 2 || !isIdentChar(sql[i - 2]));
            i = skipQuoted(i, '\'', escaped);
        } else if (c == '"') {
            auto start = i;
            i = skipQuoted(i, '"', false);
            if (!qualified(start) && i - start >= 2)
                candidate(sql[start + 1 .. i - 1].replace(`""`, `"`).idup);
        } else if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
            while (i < sql.length && sql[i] != '\n')
                i++;
        } else if (c == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
            size_t depth = 1;
            i += 2;
            while (i < sql.length && depth) {
                if (sql[i] == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
                    depth++;
                    i += 2;
                } else if (sql[i] == '*' && i + 1 < sql.length && sql[i + 1] == '/') {
                    depth--;
                    i += 2;
                } else
                    i++;
            }
        } else if (c == '$') {
            // A dollar-quoted string ($tag$...$tag$), or a parameter ($1)
            auto end = i + 1;
            while (end < sql.length && isIdentChar(sql[end]) && sql[end] != '$')
                end++;
            if (end < sql.length && sql[end] == '$' && (end == i + 1 || !isDigit(sql[i + 1]))) {
                auto tag = sql[i .. end + 1];
                auto close = sql[end + 1 .. $].indexOf(tag);
                i = close < 0 ? sql.length : end + 1 + close + tag.length;
            } else
                i = end;
        } else if (isIdentStart(c)) {
            auto start = i;
            while (i < sql.length && isIdentChar(sql[i]))
                i++;
            if (!qualified(start)) {
                auto word = sql[start .. i];
                char[] folded = new char[word.length];
                foreach (k, w; word)
                    folded[k] = toLower(w);
                candidate(cast(string) folded);
            }
        } else if (isDigit(c)) {
            while (i < sql.length && (isIdentChar(sql[i]) || sql[i] == '.'))
                i++;
        } else
            i++;
    }
    if (!names.length)
        return sql;

    // Where the statement starts (after whitespace and comments), and its
    // first word
    size_t start = 0;
    while (start < sql.length) {
        if (isWhite(sql[start]))
            start++;
        else if (sql[start .. $].startsWith("--")) {
            while (start < sql.length && sql[start] != '\n')
                start++;
        } else if (sql[start .. $].startsWith("/*")) {
            auto close = sql[start + 2 .. $].indexOf("*/");
            start = close < 0 ? sql.length : start + 2 + close + 2;
        } else
            break;
    }
    string wordAt(size_t at) {
        auto end = at;
        while (end < sql.length && isIdentChar(sql[end]))
            end++;
        char[] word = new char[end - at];
        foreach (k, w; sql[at .. end])
            word[k] = toLower(w);
        return cast(string) word;
    }
    auto first = wordAt(start);

    string bindings;
    foreach (k, name; names) {
        bool plain = isIdentStart(name[0]) && (cast(const(ubyte)[]) name).all!(ch => isIdentChar(cast(char) ch) && !(ch >= 'A' && ch <= 'Z'));
        bindings ~= (k ? ", " : "") ~ (plain ? name : `"` ~ name.replace(`"`, `""`) ~ `"`) ~
            " AS NOT MATERIALIZED (SELECT * FROM " ~ relations[k] ~ ")";
    }
    if (first == "with") {
        auto at = start + 4;
        // (WITH RECURSIVE: the bindings join its list)
        auto next = at;
        while (next < sql.length && isWhite(sql[next]))
            next++;
        if (wordAt(next) == "recursive")
            at = next + "recursive".length;
        return sql[0 .. at] ~ " " ~ bindings ~ "," ~ sql[at .. $];
    }
    if (["select", "insert", "update", "delete", "values", "table", "merge"].canFind(first) ||
            (start < sql.length && sql[start] == '('))
        return sql[0 .. start] ~ "WITH " ~ bindings ~ "\n" ~ sql[start .. $];
    return sql;
}

unittest {
    string delegate(string) relations(string[string] map) {
        return (string name) => map.get(name, null);
    }
    auto r = relations(["app_users": "app.users_at(NULL, 3, -2, false, DATE '2026-10-30')",
        "app_posts": "app.posts_at(NULL, 3, -2, false, DATE '2026-10-30')"]);

    // Nothing to bind: the statement itself
    enum plain = "SELECT id FROM users WHERE name = 'app_users'";
    assert(bindRelations(plain, r) is plain);
    assert(bindRelations("SELECT 1", delegate string(string _) => null) == "SELECT 1");

    // A query; its subqueries and joins (each name bound once)
    assert(bindRelations("SELECT u.id FROM app_users u LEFT JOIN app_users j0 ON u.id = j0.id", r) ==
        "WITH app_users AS NOT MATERIALIZED (SELECT * FROM app.users_at(NULL, 3, -2, false, DATE '2026-10-30'))\n" ~
        "SELECT u.id FROM app_users u LEFT JOIN app_users j0 ON u.id = j0.id");
    assert(bindRelations("  SELECT 1 FROM app_posts WHERE EXISTS (SELECT 1 FROM APP_USERS c0)", r) ==
        "  WITH app_posts AS NOT MATERIALIZED (SELECT * FROM app.posts_at(NULL, 3, -2, false, DATE '2026-10-30')), " ~
        "app_users AS NOT MATERIALIZED (SELECT * FROM app.users_at(NULL, 3, -2, false, DATE '2026-10-30'))\n" ~
        "SELECT 1 FROM app_posts WHERE EXISTS (SELECT 1 FROM APP_USERS c0)");

    // The statement's own CTEs (as Dunamis' layered queries have them)
    assert(bindRelations("WITH\n  layer0 AS (SELECT app_users.id FROM app_users)\nSELECT 1", r) ==
        "WITH app_users AS NOT MATERIALIZED (SELECT * FROM app.users_at(NULL, 3, -2, false, DATE '2026-10-30')),\n" ~
        "  layer0 AS (SELECT app_users.id FROM app_users)\nSELECT 1");
    auto b = relations(["t": "f()"]);
    assert(bindRelations("with recursive x AS (SELECT * FROM t) SELECT * FROM x", b) ==
        "with recursive t AS NOT MATERIALIZED (SELECT * FROM f()), x AS (SELECT * FROM t) SELECT * FROM x");
    assert(bindRelations("UPDATE data.t SET a = s.a FROM t s", b) ==
        "WITH t AS NOT MATERIALIZED (SELECT * FROM f())\nUPDATE data.t SET a = s.a FROM t s");

    // Not names of relations: in literals, comments, dollar quotes,
    // qualified names; parameters
    foreach (sql; ["SELECT 't' FROM x", "SELECT E'\\'t' FROM x", "SELECT $$t$$, $q$ t $q$ FROM x",
            "SELECT 1 -- t\nFROM x", "SELECT /* t /* t */ t */ 1 FROM x", "SELECT s.t FROM s", "SELECT $1 FROM x",
            "SELECT 1t FROM x"])
        assert(bindRelations(sql, b) is sql, sql);
    // Quoted names are as they are
    assert(bindRelations(`SELECT * FROM "t"`, b) == "WITH t AS NOT MATERIALIZED (SELECT * FROM f())\nSELECT * FROM \"t\"");
    assert(bindRelations(`SELECT * FROM "T"`, b) == `SELECT * FROM "T"`);
    assert(bindRelations(`SELECT * FROM "T"`, relations(["T": "f()"])) ==
        "WITH \"T\" AS NOT MATERIALIZED (SELECT * FROM f())\nSELECT * FROM \"T\"");

    // Statements without a WITH clause are not bound
    foreach (sql; ["SET LOCAL x = t", "BEGIN", "SAVEPOINT t"])
        assert(bindRelations(sql, b) is sql, sql);
    assert(bindRelations("(SELECT * FROM t) UNION ALL (SELECT 1)", b) ==
        "WITH t AS NOT MATERIALIZED (SELECT * FROM f())\n(SELECT * FROM t) UNION ALL (SELECT 1)");
}
