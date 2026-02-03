module graphqld2.mysql.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.json;

import graphqld2.relational.mutation : InsertInput, UpdateInput;
import graphqld2.relational.query_node : QueryNode, FilterType;
import graphqld2.relational.sql_optimizer : SqlOptimizer;

// ============================================================================
// MySQL SQL Escaping
// ============================================================================

/// Escape a string for use in MySQL SQL.
/// Uses single-quote doubling and backslash escaping for safety.
string escapeSqlString(string s) {
    import std.string : replace;
    // MySQL escaping: double single quotes and escape backslashes
    return "'" ~ s.replace("\\", "\\\\").replace("'", "''") ~ "'";
}

/// Convert JSONValue to a properly quoted MySQL SQL literal.
string jsonToSqlLiteral(JSONValue val) {
    final switch (val.type) {
        case JSONType.string:
            return escapeSqlString(val.str);
        case JSONType.integer:
            return val.integer.to!string;
        case JSONType.uinteger:
            return val.uinteger.to!string;
        case JSONType.float_:
            return val.floating.to!string;
        case JSONType.true_:
            return "TRUE";
        case JSONType.false_:
            return "FALSE";
        case JSONType.null_:
            return "NULL";
        case JSONType.array:
            // MySQL JSON array format: JSON_ARRAY(val1, val2, ...)
            auto elements = val.array.map!(v => jsonToSqlLiteral(v)).array;
            return "JSON_ARRAY(" ~ elements.join(",") ~ ")";
        case JSONType.object:
            // JSON object - serialize as JSON string
            return escapeSqlString(val.toString());
    }
}

// ============================================================================
// Query SQL Generation (CTE-based)
// ============================================================================

/// Generate a complete CTE-based SQL query for MySQL.
string toSQL(QueryNode[] nodes) {
    return toSQL(nodes, null);
}

/// Generate a complete CTE-based SQL query with computed columns for MySQL.
/// Note: MySQL 8.0+ supports CTEs with recursive capability.
string toSQL(QueryNode[] nodes, SqlOptimizer sqlOpt) {
    if (nodes.length == 0)
        return "";

    auto sql = appender!string;

    // Build CTEs for each layer
    sql ~= "WITH\n";

    string[] ctes;
    foreach (node; nodes) {
        ctes ~= toCTE(node, sqlOpt);
    }
    sql ~= ctes.join(",\n");

    // Final SELECT: aggregate all layers into JSON using MySQL's JSON_OBJECT
    // MySQL 8.0+: Use ORDER BY inside JSON_ARRAYAGG to preserve sorting
    sql ~= "\nSELECT JSON_OBJECT(\n";
    string[] jsonParts;
    foreach (node; nodes) {
        // MySQL: COALESCE with JSON_ARRAYAGG, or empty JSON array if no rows
        // Note: JSON_ARRAYAGG returns NULL if no rows, so we wrap with COALESCE
        if (node.orderBy_.length > 0) {
            string[] orderParts;
            foreach (spec; node.orderBy_) {
                orderParts ~= format("%s%s", spec.column, spec.descending ? " DESC" : "");
            }
            string orderByClause = orderParts.join(", ");
            // MySQL aggregate ORDER BY syntax: JSON_ARRAYAGG(expr ORDER BY col)
            jsonParts ~= format("  'layer%d', COALESCE((SELECT JSON_ARRAYAGG(row_json ORDER BY %s) FROM layer%d), JSON_ARRAY())",
                node.id, orderByClause, node.id);
        } else {
            jsonParts ~= format("  'layer%d', COALESCE((SELECT JSON_ARRAYAGG(row_json) FROM layer%d), JSON_ARRAY())",
                node.id, node.id);
        }
    }
    sql ~= jsonParts.join(",\n");
    sql ~= "\n) AS result\n";

    return sql.data;
}

/// Generate CTE for a single QueryNode (MySQL version)
private string toCTE(QueryNode node, SqlOptimizer sqlOpt) {
    auto sql = appender!string;

    sql ~= format("  layer%d AS (\n", node.id);
    sql ~= "    SELECT ";
    sql ~= toSelect(node, sqlOpt);

    // MySQL: wrap each row as JSON using JSON_OBJECT
    sql ~= format(",\n           JSON_OBJECT(%s) AS row_json",
        buildJsonObjectArgs(node, sqlOpt));

    sql ~= format("\n    FROM %s", node.table);

    // Add JOINs for belongsTo relationships
    foreach (joinInfo; node.joins) {
        sql ~= format("\n    LEFT JOIN %s %s ON %s.%s = %s.id",
            joinInfo.targetTable, joinInfo.alias_,
            node.table, joinInfo.fk, joinInfo.alias_);
    }

    // WHERE clause
    sql ~= "\n    WHERE ";
    if (node.isRoot) {
        final switch (node.rootFilter) {
            case FilterType.none:
            case FilterType.all:
                sql ~= "1=1";
                break;
            case FilterType.byId:
            case FilterType.byIds:
                // MySQL: use IN clause with placeholder for IDs
                // The actual IDs will be substituted by the fetcher
                sql ~= format("%s.id IN ({{IDS}})", node.table);
                break;
        }
    } else {
        sql ~= format("%s.%s IN (SELECT id FROM layer%d)",
            node.table, node.parentFk, node.parent.id);
    }

    // ORDER BY clause (sorting)
    if (node.orderBy_.length > 0) {
        string[] orderParts;
        foreach (spec; node.orderBy_) {
            orderParts ~= format("%s.%s%s", node.table, spec.column,
                spec.descending ? " DESC" : "");
        }
        sql ~= format("\n    ORDER BY %s", orderParts.join(", "));
    }

    // LIMIT clause (pagination)
    if (!node.limit_.isNull) {
        sql ~= format("\n    LIMIT %d", node.limit_.get);
    }

    // OFFSET clause (pagination)
    if (!node.offset_.isNull) {
        sql ~= format("\n    OFFSET %d", node.offset_.get);
    }

    sql ~= "\n  )";
    return sql.data;
}

/// Generate SQL SELECT clause including computed columns
private string toSelect(QueryNode node, SqlOptimizer sqlOpt) {
    string[] selectParts;

    // Regular columns from main table
    foreach (col; node.columns) {
        selectParts ~= format("%s.%s", node.table, col);
    }

    // Columns from JOINed tables
    foreach (joinInfo; node.joins) {
        if (auto cols = joinInfo.alias_ in node.joinedColumns) {
            foreach (col; *cols) {
                selectParts ~= format("%s.%s AS %s__%s",
                    joinInfo.alias_, col, joinInfo.alias_, col);
            }
        }
    }

    // Computed columns (if SqlOptimizer is provided)
    if (sqlOpt !is null) {
        foreach (computed; sqlOpt.getComputedColumns(node.id)) {
            selectParts ~= format("%s AS %s", computed.sqlExpr, computed.alias_);
        }
    }

    return selectParts.join(", ");
}

/// Build JSON_OBJECT arguments for all columns in a row
private string buildJsonObjectArgs(QueryNode node, SqlOptimizer sqlOpt) {
    string[] args;

    // Regular columns from main table
    foreach (col; node.columns) {
        args ~= format("'%s', %s.%s", col, node.table, col);
    }

    // Columns from JOINed tables
    foreach (joinInfo; node.joins) {
        if (auto cols = joinInfo.alias_ in node.joinedColumns) {
            foreach (col; *cols) {
                args ~= format("'%s__%s', %s.%s",
                    joinInfo.alias_, col, joinInfo.alias_, col);
            }
        }
    }

    // Computed columns
    if (sqlOpt !is null) {
        foreach (computed; sqlOpt.getComputedColumns(node.id)) {
            args ~= format("'%s', %s", computed.alias_, computed.sqlExpr);
        }
    }

    return args.join(", ");
}

// ============================================================================
// Mutation SQL Generation
// ============================================================================

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

/// Generate UPDATE SQL for MySQL.
string generateUpdateSQL(string table, UpdateInput input) {
    auto columns = input.columns;
    auto idsList = input.ids.map!(id => id.to!string).join(",");

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
        "UPDATE %s SET %s WHERE id IN (%s)",
        table,
        setClauses.join(", "),
        idsList
    );
}

/// Generate SELECT SQL to fetch updated rows as JSON.
/// Returns JSON with 'id' and the provided columns.
string generateSelectUpdatedSQL(string table, long[] ids, string[] columns) {
    auto idsList = ids.map!(id => id.to!string).join(",");

    // Build JSON_OBJECT arguments: 'id', id, 'col1', col1, ...
    string[] jsonArgs = ["'id'", "id"];
    foreach (col; columns) {
        jsonArgs ~= format("'%s'", col);
        jsonArgs ~= col;
    }

    return format(
        "SELECT JSON_OBJECT(%s) AS json_row FROM %s WHERE id IN (%s)",
        jsonArgs.join(", "),
        table,
        idsList
    );
}

/// Generate DELETE SQL for MySQL.
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
    assert(escapeSqlString("hello") == "'hello'");
    assert(escapeSqlString("it's") == "'it''s'");
    assert(escapeSqlString("O'Brien") == "'O''Brien'");
    assert(escapeSqlString("back\\slash") == "'back\\\\slash'");
}

unittest {
    // Test jsonToSqlLiteral
    assert(jsonToSqlLiteral(JSONValue("hello")) == "'hello'");
    assert(jsonToSqlLiteral(JSONValue(42)) == "42");
    assert(jsonToSqlLiteral(JSONValue(true)) == "TRUE");
    assert(jsonToSqlLiteral(JSONValue(false)) == "FALSE");
    assert(jsonToSqlLiteral(JSONValue(null)) == "NULL");
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
    auto sql = generateSelectUpdatedSQL("users", [1, 2], ["first_name"]);
    assert(sql.canFind("JSON_OBJECT"));
    assert(sql.canFind("'id', id"));
    assert(sql.canFind("'first_name', first_name"));
    assert(sql.canFind("IN (1,2)"));
}
