module dunamis.sqlite.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.json;

import dunamis.relational.mutation : InsertInput, UpdateInput;
import dunamis.relational.query_node : QueryNode, FilterType;
import dunamis.relational.sql_optimizer : SqlOptimizer;

// ============================================================================
// SQLite SQL Escaping
// ============================================================================

/// Escape a string for use in SQLite SQL.
/// Uses single-quote doubling for safety.
string escapeSqlString(string s) {
    import std.string : replace;
    return "'" ~ s.replace("'", "''") ~ "'";
}

/// Convert JSONValue to a properly quoted SQLite SQL literal.
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
            return "1";  // SQLite uses 1 for true
        case JSONType.false_:
            return "0";  // SQLite uses 0 for false
        case JSONType.null_:
            return "NULL";
        case JSONType.array:
            // SQLite JSON array format: json_array(val1, val2, ...)
            auto elements = val.array.map!(v => jsonToSqlLiteral(v)).array;
            return "json_array(" ~ elements.join(",") ~ ")";
        case JSONType.object:
            // JSON object - serialize as JSON string
            return escapeSqlString(val.toString());
    }
}

// ============================================================================
// Query SQL Generation (CTE-based)
// ============================================================================

/// Generate a complete CTE-based SQL query for SQLite.
string toSQL(QueryNode[] nodes) {
    return toSQL(nodes, null);
}

/// Generate a complete CTE-based SQL query with computed columns for SQLite.
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

    // Final SELECT: aggregate all layers into JSON using SQLite's json_object
    // SQLite: use subquery with ORDER BY to preserve sorting in json_group_array
    sql ~= "\nSELECT json_object(\n";
    string[] jsonParts;
    foreach (node; nodes) {
        // SQLite: json_group_array to aggregate rows, or empty array if no rows
        if (node.orderBy_.length > 0) {
            // Subquery orders rows before aggregation
            string[] orderParts;
            foreach (spec; node.orderBy_) {
                orderParts ~= format("%s%s", spec.column, spec.descending ? " DESC" : "");
            }
            auto orderByClause = orderParts.join(", ");
            jsonParts ~= format("  'layer%d', COALESCE((SELECT json_group_array(json(row_json)) FROM (SELECT * FROM layer%d ORDER BY %s)), json('[]'))",
                node.id, node.id, orderByClause);
        } else {
            jsonParts ~= format("  'layer%d', COALESCE((SELECT json_group_array(json(row_json)) FROM layer%d), json('[]'))",
                node.id, node.id);
        }
    }
    sql ~= jsonParts.join(",\n");
    sql ~= "\n)\n";

    return sql.data;
}

/// Generate CTE for a single QueryNode (SQLite version)
private string toCTE(QueryNode node, SqlOptimizer sqlOpt) {
    auto sql = appender!string;

    sql ~= format("  layer%d AS (\n", node.id);
    sql ~= "    SELECT ";
    sql ~= toSelect(node, sqlOpt);

    // SQLite: wrap each row as JSON using json_object
    sql ~= format(",\n           json_object(%s) AS row_json",
        buildJsonObjectArgs(node, sqlOpt));

    sql ~= format("\n    FROM %s", node.table);

    // Add JOINs for belongsTo relationships
    foreach (joinInfo; node.joins) {
        auto sourceRef = joinInfo.sourceAlias !is null ? joinInfo.sourceAlias : node.table;
        sql ~= format("\n    LEFT JOIN %s %s ON %s.%s = %s.id",
            joinInfo.targetTable, joinInfo.alias_,
            sourceRef, joinInfo.fk, joinInfo.alias_);
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
                // SQLite: use IN clause with placeholder for IDs
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

/// Build json_object arguments for all columns in a row
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
    assert(escapeSqlString("hello") == "'hello'");
    assert(escapeSqlString("it's") == "'it''s'");
    assert(escapeSqlString("O'Brien") == "'O''Brien'");
}

unittest {
    // Test jsonToSqlLiteral
    assert(jsonToSqlLiteral(JSONValue("hello")) == "'hello'");
    assert(jsonToSqlLiteral(JSONValue(42)) == "42");
    assert(jsonToSqlLiteral(JSONValue(true)) == "1");
    assert(jsonToSqlLiteral(JSONValue(false)) == "0");
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
