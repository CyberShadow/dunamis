module dunamis.postgres.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.json;
import std.range : iota;

import dunamis.relational.mutation : InsertInput, UpdateInput;
import dunamis.relational.query_node : QueryNode, QueryNodeId, FilterType;
import dunamis.relational.sql_optimizer : SqlOptimizer;

// ============================================================================
// Mutation SQL Generation
// ============================================================================

/// Escape a string for use in PostgreSQL SQL.
/// Uses single-quote doubling for safety.
string escapeSqlString(string s) {
    import std.string : replace;
    // Double single quotes to escape them
    return "'" ~ s.replace("'", "''") ~ "'";
}

/// Convert JSONValue to a properly quoted SQL literal.
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
            // PostgreSQL array format: ARRAY['val1','val2']
            auto elements = val.array.map!(v => jsonToSqlLiteral(v)).array;
            return "ARRAY[" ~ elements.join(",") ~ "]";
        case JSONType.object:
            // JSON object - serialize as JSON string
            return escapeSqlString(val.toString());
    }
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
    assert(escapeSqlString("hello") == "'hello'");
    assert(escapeSqlString("it's") == "'it''s'");
    assert(escapeSqlString("O'Brien") == "'O''Brien'");
}

unittest {
    // Test jsonToSqlLiteral
    assert(jsonToSqlLiteral(JSONValue("hello")) == "'hello'");
    assert(jsonToSqlLiteral(JSONValue(42)) == "42");
    assert(jsonToSqlLiteral(JSONValue(true)) == "TRUE");
    assert(jsonToSqlLiteral(JSONValue(false)) == "FALSE");
    assert(jsonToSqlLiteral(JSONValue(null)) == "NULL");
}

// ============================================================================
// Query SQL Generation (CTE-based)
// ============================================================================

/// Generate a complete CTE-based SQL query (without computed columns).
string toSQL(QueryNode[] nodes) {
    return toSQL(nodes, null);
}

/// Generate a complete CTE-based SQL query with computed columns.
string toSQL(QueryNode[] nodes, SqlOptimizer sqlOpt) {
    if (nodes.length == 0)
        return "";

    auto sql = appender!string;

    // Build CTEs for each layer
    sql ~= "WITH\n";

    string[] ctes;
    foreach (node; nodes) {
        ctes ~= toCTEWithComputed(node, sqlOpt);
    }
    sql ~= ctes.join(",\n");

    // Final SELECT: aggregate all layers into JSON
    // PostgreSQL: use subquery with ORDER BY to preserve sorting in json_agg
    sql ~= "\nSELECT json_build_object(\n";
    string[] jsonParts;
    foreach (node; nodes) {
        if (node.orderBy_.length > 0) {
            // Subquery orders rows before json_agg processes them
            string[] orderParts;
            foreach (spec; node.orderBy_) {
                orderParts ~= format("%s%s", spec.column, spec.descending ? " DESC" : "");
            }
            auto orderByClause = orderParts.join(", ");
            jsonParts ~= format("  'layer%d', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM layer%d ORDER BY %s) t)",
                node.id.value, node.id.value, orderByClause);
        } else {
            jsonParts ~= format("  'layer%d', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer%d t)",
                node.id.value, node.id.value);
        }
    }
    sql ~= jsonParts.join(",\n");
    sql ~= "\n)\n";

    auto result = sql.data;

    // Debug output for real applications running with -debug=sql
    debug(sql) {
        import std.stdio : writeln;
        writeln(result);
    }

    return result;
}

/// Generate CTE for a single QueryNode with computed columns
private string toCTEWithComputed(QueryNode node, SqlOptimizer sqlOpt) {
    // Use window function for per-parent pagination on child nodes
    if (node.useWindowFunction) {
        return toCTEWithWindowFunction(node, sqlOpt);
    }

    auto sql = appender!string;

    sql ~= format("  layer%d AS (\n", node.id.value);
    sql ~= "    SELECT ";
    sql ~= toSelectWithComputed(node, sqlOpt);
    sql ~= format("\n    FROM %s", node.table);

    // Add JOINs for belongsTo relationships
    foreach (joinInfo; node.joins) {
        auto sourceRef = !joinInfo.sourceAlias.isNull ? joinInfo.sourceAlias.get.value : node.table;
        sql ~= format("\n    LEFT JOIN %s %s ON %s.%s = %s.id",
            joinInfo.targetTable, joinInfo.alias_.value,
            sourceRef, joinInfo.fk, joinInfo.alias_.value);
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
                sql ~= format("%s.id = ANY($1)", node.table);
                break;
        }
    } else {
        sql ~= format("%s.%s IN (SELECT id FROM layer%d)",
            node.table, node.parentFk, node.parent.id.value);
    }

    // Add custom WHERE clause from filter predicates
    if (node.whereClause_.length > 0) {
        sql ~= format("\n      AND (%s)", node.whereClause_);
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

/// Generate CTE for a child node with per-parent pagination using window functions.
///
/// Generates SQL like:
/// ```sql
/// layer1 AS (
///   SELECT id, title, author_id FROM (
///     SELECT posts.*, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY id) as _rn
///     FROM posts WHERE author_id IN (SELECT id FROM layer0)
///   ) t WHERE _rn > offset AND _rn <= offset + limit
/// )
/// ```
private string toCTEWithWindowFunction(QueryNode node, SqlOptimizer sqlOpt) {
    assert(!node.isRoot, "Window function pagination only applies to child nodes");

    auto sql = appender!string;

    // Build ORDER BY for window function (defaults to id if not specified)
    string windowOrderBy;
    if (node.orderBy_.length > 0) {
        string[] orderParts;
        foreach (spec; node.orderBy_) {
            orderParts ~= format("%s%s", spec.column, spec.descending ? " DESC" : "");
        }
        windowOrderBy = orderParts.join(", ");
    } else {
        windowOrderBy = "id";
    }

    sql ~= format("  layer%d AS (\n", node.id.value);

    // Outer SELECT: project needed columns from the windowed subquery
    sql ~= "    SELECT ";
    sql ~= toSelectWithComputed(node, sqlOpt, "_inner");  // Use _inner alias prefix
    sql ~= " FROM (\n";

    // Inner SELECT: compute row numbers partitioned by parent FK
    sql ~= format("      SELECT %s.*, ROW_NUMBER() OVER (PARTITION BY %s ORDER BY %s) AS _rn\n",
        node.table, node.parentFk, windowOrderBy);
    sql ~= format("      FROM %s\n", node.table);

    // Add JOINs for belongsTo relationships in the inner query
    foreach (joinInfo; node.joins) {
        auto sourceRef = !joinInfo.sourceAlias.isNull ? joinInfo.sourceAlias.get.value : node.table;
        sql ~= format("      LEFT JOIN %s %s ON %s.%s = %s.id\n",
            joinInfo.targetTable, joinInfo.alias_.value,
            sourceRef, joinInfo.fk, joinInfo.alias_.value);
    }

    // WHERE clause for inner query
    sql ~= format("      WHERE %s.%s IN (SELECT id FROM layer%d)",
        node.table, node.parentFk, node.parent.id.value);

    // Add custom WHERE clause from filter predicates
    if (node.whereClause_.length > 0) {
        sql ~= format("\n        AND (%s)", node.whereClause_);
    }

    sql ~= "\n    ) _inner\n";

    // WHERE clause for outer query: filter by row number
    sql ~= "    WHERE ";
    if (!node.perParentOffset_.isNull && !node.perParentLimit_.isNull) {
        // Both offset and limit: _rn > offset AND _rn <= offset + limit
        auto offset = node.perParentOffset_.get;
        auto limit = node.perParentLimit_.get;
        sql ~= format("_rn > %d AND _rn <= %d", offset, offset + limit);
    } else if (!node.perParentOffset_.isNull) {
        // Only offset: _rn > offset
        sql ~= format("_rn > %d", node.perParentOffset_.get);
    } else if (!node.perParentLimit_.isNull) {
        // Only limit: _rn <= limit
        sql ~= format("_rn <= %d", node.perParentLimit_.get);
    } else {
        // No pagination (shouldn't happen if useWindowFunction is true)
        sql ~= "1=1";
    }

    sql ~= "\n  )";
    return sql.data;
}

/// Generate SQL SELECT clause including computed columns.
/// If tableAlias is provided, uses that instead of node.table for column references.
/// For window function CTEs, this is used to select from the inner subquery.
string toSelectWithComputed(QueryNode node, SqlOptimizer sqlOpt, string tableAlias = null) {
    string[] selectParts;

    // Use provided alias or default to table name
    auto tableName = tableAlias !is null ? tableAlias : node.table;

    // Regular columns from main table
    foreach (col; node.columns) {
        selectParts ~= format("%s.%s", tableName, col);
    }

    // Columns from JOINed tables
    // For window function queries, joined columns are already computed in the inner subquery
    // and appear as aliased columns (e.g., j0__id)
    foreach (joinInfo; node.joins) {
        if (auto cols = joinInfo.alias_ in node.joinedColumns) {
            foreach (col; *cols) {
                if (tableAlias !is null) {
                    // From window subquery: columns are already aliased
                    selectParts ~= format("%s.%s__%s AS %s__%s",
                        tableName, joinInfo.alias_.value, col, joinInfo.alias_.value, col);
                } else {
                    selectParts ~= format("%s.%s AS %s__%s",
                        joinInfo.alias_.value, col, joinInfo.alias_.value, col);
                }
            }
        }
    }

    // Computed columns (if SqlOptimizer is provided)
    // Note: Computed columns are not supported with window functions yet
    if (sqlOpt !is null && tableAlias is null) {
        foreach (computed; sqlOpt.getComputedColumns(node.id)) {
            selectParts ~= format("%s AS %s", computed.sqlExpr, computed.alias_);
        }
    }

    return selectParts.join(", ");
}

// ============================================================================
// Query SQL Generation Tests
// ============================================================================

unittest {
    // Test SQL generation with LIMIT/OFFSET
    auto node = new QueryNode(QueryNodeId(0), "User", "users");
    node.addColumn("first_name");
    node.setRootFilter(FilterType.all);
    node.setLimit(10);
    node.setOffset(20);

    auto sql = toCTEWithComputed(node, null);

    // Verify SQL contains LIMIT and OFFSET clauses
    assert(sql.canFind("LIMIT 10"), "SQL should contain LIMIT 10: " ~ sql);
    assert(sql.canFind("OFFSET 20"), "SQL should contain OFFSET 20: " ~ sql);
    assert(sql.canFind("users.first_name"), "SQL should contain column: " ~ sql);
}

unittest {
    // Test SQL generation with LIMIT only (no offset)
    auto node = new QueryNode(QueryNodeId(0), "Post", "posts");
    node.addColumn("title");
    node.setRootFilter(FilterType.all);
    node.setLimit(5);
    // No offset

    auto sql = toCTEWithComputed(node, null);

    assert(sql.canFind("LIMIT 5"), "SQL should contain LIMIT 5: " ~ sql);
    assert(!sql.canFind("OFFSET"), "SQL should not contain OFFSET: " ~ sql);
}

unittest {
    // Test SQL generation with OFFSET only (no limit)
    auto node = new QueryNode(QueryNodeId(0), "Comment", "comments");
    node.addColumn("body");
    node.setRootFilter(FilterType.all);
    node.setOffset(15);
    // No limit

    auto sql = toCTEWithComputed(node, null);

    assert(sql.canFind("OFFSET 15"), "SQL should contain OFFSET 15: " ~ sql);
    assert(!sql.canFind("LIMIT"), "SQL should not contain LIMIT: " ~ sql);
}
