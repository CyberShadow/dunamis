module dunamis.relational.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.typecons : Nullable;

import dunamis.relational.query_node : QueryNode, QueryNodeId, FilterType;
import dunamis.relational.sql_dialect : SqlDialect;

// ============================================================================
// Query SQL Generation (CTE-based, dialect-agnostic)
// ============================================================================

/// Generate a complete CTE-based SQL query (without computed columns or dialect).
string toSQL(QueryNode[] nodes) {
    return toSQL(nodes, null);
}

/// The most layers the final SELECT of a query puts into one JSON object;
/// the layers of a query with more are grouped into objects (of at most as
/// many) under the keys `layerGroupKey ~ n` (see loadLayerResults).
enum size_t layerGroupSize = 40;

/// ditto
enum string layerGroupKey = "layers";

/// Generate a complete CTE-based SQL query with computed columns.
/// Root nodes are filtered by their own root filter.
string toSQL(QueryNode[] nodes, SqlDialect dialect) {
    return toSQL(nodes, dialect, Nullable!FilterType.init);
}

/// ditto, filtering the root node(s) by `rootFilter` (the root selection
/// of the evaluation executing the query) instead.
string toSQL(QueryNode[] nodes, SqlDialect dialect, FilterType rootFilter) {
    return toSQL(nodes, dialect, Nullable!FilterType(rootFilter));
}

private string toSQL(QueryNode[] nodes, SqlDialect dialect,
        Nullable!FilterType rootFilter) {
    if (nodes.length == 0)
        return "";

    auto sql = appender!string;

    // Build CTEs for each layer
    sql ~= "WITH\n";

    // Nodes whose rows another node's layer holds have no layer of their
    // own (see QueryNode.mergeFrom)
    nodes = nodes.filter!(node => node.sameRowsAs is null).array;

    string[] ctes;
    foreach (node; nodes) {
        if (node.useWindowFunction) {
            ctes ~= toCTEWithWindowFunction(node, dialect);
        } else {
            ctes ~= toCTE(node, dialect,
                rootFilter.isNull ? node.rootFilter : rootFilter.get);
        }
    }
    sql ~= ctes.join(",\n");

    // Final SELECT: aggregate all layers into JSON
    string[] jsonParts;
    foreach (node; nodes) {
        string orderByClause;
        if (node.orderBy_.length > 0) {
            string[] orderParts;
            foreach (spec; node.orderBy_) {
                orderParts ~= format("%s%s", spec.column, spec.descending ? " DESC" : "");
            }
            orderByClause = orderParts.join(", ");
        }
        jsonParts ~= format("  'layer%d', %s",
            node.id.value, dialect.aggregateLayerJson(node.id.value, orderByClause));
    }
    // (Functions take at most 100 arguments in PostgreSQL: more layers are
    // grouped into objects of `layerGroupSize` layers, see layerGroupKey.)
    string object(string[] parts) {
        return format("%s(\n%s\n)", dialect.jsonObjectFunc(), parts.join(",\n"));
    }
    if (jsonParts.length > layerGroupSize) {
        string[] groups;
        for (size_t i = 0; i < jsonParts.length; i += layerGroupSize) {
            auto end = i + layerGroupSize < jsonParts.length ? i + layerGroupSize : jsonParts.length;
            groups ~= format("  '%s%d', %s", layerGroupKey, i / layerGroupSize, object(jsonParts[i .. end]));
        }
        jsonParts = groups;
    }
    sql ~= "\nSELECT " ~ object(jsonParts) ~ "\n";

    auto result = sql.data;

    debug(sql) {
        import std.stdio : writeln;
        writeln(result);
    }

    return result;
}

/// Generate CTE for a single QueryNode.
private string toCTE(QueryNode node, SqlDialect dialect) {
    return toCTE(node, dialect, node.rootFilter);
}

/// ditto, filtering a root node by `rootFilter`.
private string toCTE(QueryNode node, SqlDialect dialect,
        FilterType rootFilter) {
    auto sql = appender!string;

    sql ~= format("  layer%d AS (\n", node.id.value);
    sql ~= "    SELECT ";
    sql ~= buildSelectColumns(node, dialect);

    // Dialect-specific: add per-row JSON wrapping if needed
    auto rowJsonFunc = dialect.rowJsonFunc();
    if (rowJsonFunc.length > 0) {
        sql ~= format(",\n           %s(%s) AS row_json",
            rowJsonFunc, buildJsonObjectArgs(node));
    }

    sql ~= format("\n    FROM %s", node.table);

    // JOINs for belongsTo relationships
    foreach (joinInfo; node.joins) {
        auto sourceRef = !joinInfo.sourceAlias.isNull ? joinInfo.sourceAlias.get.value : node.table;
        auto targetPk = joinInfo.targetPkColumns.length > 0 ? joinInfo.targetPkColumns[0] : "id";
        sql ~= format("\n    LEFT JOIN %s %s ON %s.%s = %s.%s",
            joinInfo.targetTable, joinInfo.alias_.value,
            sourceRef, joinInfo.fk, joinInfo.alias_.value, targetPk);
    }

    // WHERE clause
    sql ~= "\n    WHERE ";
    if (node.isRoot) {
        final switch (rootFilter) {
            case FilterType.none:
            case FilterType.all:
                sql ~= "1=1";
                break;
            case FilterType.byId:
            case FilterType.byIds:
                sql ~= dialect.rootIdFilter(node.table, node.pkColumns);
                break;
        }
    } else {
        // Use parent's PK columns for the subselect
        auto parentPkCols = node.parentLinkColumns;
        auto parentPkSelect = parentPkCols.length == 1 ? parentPkCols[0] : parentPkCols.join(", ");
        sql ~= format("%s.%s IN (SELECT %s FROM layer%d)",
            node.table, node.parentFk, parentPkSelect, node.parent.layerNode.id.value);
    }

    // Custom WHERE clause from filter predicates
    if (auto where = node.whereClause(dialect)) {
        sql ~= format("\n      AND (%s)", where);
    }

    // ORDER BY (a column, or a computed column, as its expression)
    if (node.orderBy_.length > 0) {
        string[] orderParts;
        foreach (spec; node.orderBy_) {
            string key = node.table ~ "." ~ spec.column;
            foreach (computed; node.computedColumns)
                if (computed.alias_ == spec.column)
                    key = computed.sqlExpr;
            orderParts ~= format("%s%s", key, spec.descending ? " DESC" : "");
        }
        sql ~= format("\n    ORDER BY %s", orderParts.join(", "));
    }

    // LIMIT
    if (!node.limit_.isNull) {
        sql ~= format("\n    LIMIT %d", node.limit_.get);
    }

    // OFFSET
    if (!node.offset_.isNull) {
        sql ~= format("\n    OFFSET %d", node.offset_.get);
    }

    sql ~= "\n  )";
    return sql.data;
}

/// Generate CTE for a child node with per-parent pagination using window functions.
private string toCTEWithWindowFunction(QueryNode node, SqlDialect dialect) {
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
        windowOrderBy = node.pkColumns.join(", ");
    }

    sql ~= format("  layer%d AS (\n", node.id.value);

    // Outer SELECT: project needed columns from the windowed subquery
    sql ~= "    SELECT ";
    sql ~= buildSelectColumns(node, dialect, "_inner");

    // Add per-row JSON wrapping if needed (for SQLite/MySQL style)
    auto rowJsonFunc = dialect.rowJsonFunc();
    if (rowJsonFunc.length > 0) {
        sql ~= format(",\n           %s(%s) AS row_json",
            rowJsonFunc, buildJsonObjectArgs(node, "_inner"));
    }

    sql ~= " FROM (\n";

    // Inner SELECT: compute row numbers partitioned by parent FK
    sql ~= format("      SELECT %s.*, ROW_NUMBER() OVER (PARTITION BY %s ORDER BY %s) AS _rn\n",
        node.table, node.parentFk, windowOrderBy);
    sql ~= format("      FROM %s\n", node.table);

    // JOINs in the inner query
    foreach (joinInfo; node.joins) {
        auto sourceRef = !joinInfo.sourceAlias.isNull ? joinInfo.sourceAlias.get.value : node.table;
        auto targetPk = joinInfo.targetPkColumns.length > 0 ? joinInfo.targetPkColumns[0] : "id";
        sql ~= format("      LEFT JOIN %s %s ON %s.%s = %s.%s\n",
            joinInfo.targetTable, joinInfo.alias_.value,
            sourceRef, joinInfo.fk, joinInfo.alias_.value, targetPk);
    }

    // WHERE clause for inner query
    auto parentPkCols = node.parentLinkColumns;
    auto parentPkSelect = parentPkCols.length == 1 ? parentPkCols[0] : parentPkCols.join(", ");
    sql ~= format("      WHERE %s.%s IN (SELECT %s FROM layer%d)",
        node.table, node.parentFk, parentPkSelect, node.parent.layerNode.id.value);

    // Custom WHERE clause
    if (auto where = node.whereClause(dialect)) {
        sql ~= format("\n        AND (%s)", where);
    }

    sql ~= "\n    ) _inner\n";

    // WHERE clause for outer query: filter by row number
    sql ~= "    WHERE ";
    if (!node.perParentOffset_.isNull && !node.perParentLimit_.isNull) {
        auto offset = node.perParentOffset_.get;
        auto limit = node.perParentLimit_.get;
        sql ~= format("_rn > %d AND _rn <= %d", offset, offset + limit);
    } else if (!node.perParentOffset_.isNull) {
        sql ~= format("_rn > %d", node.perParentOffset_.get);
    } else if (!node.perParentLimit_.isNull) {
        sql ~= format("_rn <= %d", node.perParentLimit_.get);
    } else {
        sql ~= "1=1";
    }

    sql ~= "\n  )";
    return sql.data;
}

/// Generate SQL SELECT clause including computed columns.
/// If tableAlias is provided, uses that instead of node.table for column references
/// (used for window function CTEs where the outer SELECT references the inner subquery).
string buildSelectColumns(QueryNode node, SqlDialect dialect, string tableAlias = null) {
    string[] selectParts;

    auto tableName = tableAlias !is null ? tableAlias : node.table;

    // Regular columns from main table
    foreach (col; node.columns) {
        selectParts ~= col in node.stringColumns
            ? format("%s AS %s", dialect.castToText(tableName ~ "." ~ col), col)
            : format("%s.%s", tableName, col);
    }

    // Columns from JOINed tables
    foreach (joinInfo; node.joins) {
        if (auto cols = joinInfo.alias_ in node.joinedColumns) {
            foreach (col; *cols) {
                bool isStringColumn;
                if (auto stringCols = joinInfo.alias_ in node.joinedStringColumns)
                    isStringColumn = (col in *stringCols) !is null;
                if (tableAlias !is null) {
                    // From window subquery: columns are already aliased
                    selectParts ~= format("%s.%s__%s AS %s__%s",
                        tableName, joinInfo.alias_.value, col, joinInfo.alias_.value, col);
                } else {
                    selectParts ~= isStringColumn
                        ? format("%s AS %s__%s",
                            dialect.castToText(joinInfo.alias_.value ~ "." ~ col),
                            joinInfo.alias_.value, col)
                        : format("%s.%s AS %s__%s",
                            joinInfo.alias_.value, col, joinInfo.alias_.value, col);
                }
            }
        }
    }

    // Computed columns
    // Not supported with window functions yet (computed columns come from base table)
    if (tableAlias is null) {
        foreach (computed; node.computedColumns) {
            selectParts ~= format("%s AS %s", computed.sqlExpr, computed.alias_);
        }
    }

    return selectParts.join(", ");
}

/// Build key-value argument pairs for json_object/JSON_OBJECT row wrapping.
/// Returns "'col1', table.col1, 'col2', table.col2, ..." format.
string buildJsonObjectArgs(QueryNode node, string tableAlias = null) {
    string[] args;

    auto tableName = tableAlias !is null ? tableAlias : node.table;

    // Regular columns from main table
    foreach (col; node.columns) {
        args ~= format("'%s', %s.%s", col, tableName, col);
    }

    // Columns from JOINed tables
    foreach (joinInfo; node.joins) {
        if (auto cols = joinInfo.alias_ in node.joinedColumns) {
            foreach (col; *cols) {
                if (tableAlias !is null) {
                    args ~= format("'%s__%s', %s.%s__%s",
                        joinInfo.alias_.value, col, tableName, joinInfo.alias_.value, col);
                } else {
                    args ~= format("'%s__%s', %s.%s",
                        joinInfo.alias_.value, col, joinInfo.alias_.value, col);
                }
            }
        }
    }

    // Computed columns
    if (tableAlias is null) {
        foreach (computed; node.computedColumns) {
            args ~= format("'%s', %s", computed.alias_, computed.sqlExpr);
        }
    }

    return args.join(", ");
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    import dunamis.mysql.dialect : mysqlDialect;
    import dunamis.postgres.dialect : postgresDialect;

    // String columns (own and joined) are cast to text in the dialect's syntax
    auto node = new QueryNode(QueryNodeId(0), "Post", "posts", ["id"]);
    node.addColumn("title");
    node.markStringColumn("title");
    auto j = node.addJoin("users", "User", "author_id", ["id"]);
    node.addJoinedColumn(j, "name");
    node.markJoinedStringColumn(j, "name");

    auto pg = buildSelectColumns(node, postgresDialect());
    assert(pg == "posts.id, posts.title::text AS title, j0.id AS j0__id, j0.name::text AS j0__name", pg);
    auto my = buildSelectColumns(node, mysqlDialect());
    assert(my == "posts.id, CAST(posts.title AS CHAR) AS title, j0.id AS j0__id, CAST(j0.name AS CHAR) AS j0__name", my);
}

unittest {
    import dunamis.postgres.dialect : postgresDialect;

    // Test SQL generation with LIMIT/OFFSET
    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    node.addColumn("first_name");
    node.setRootFilter(FilterType.all);
    node.setLimit(10);
    node.setOffset(20);

    auto sql = toCTE(node, postgresDialect());

    assert(sql.canFind("LIMIT 10"), "SQL should contain LIMIT 10: " ~ sql);
    assert(sql.canFind("OFFSET 20"), "SQL should contain OFFSET 20: " ~ sql);
    assert(sql.canFind("users.first_name"), "SQL should contain column: " ~ sql);
}

unittest {
    import dunamis.postgres.dialect : postgresDialect;

    // Test SQL generation with LIMIT only (no offset)
    auto node = new QueryNode(QueryNodeId(0), "Post", "posts", ["id"]);
    node.addColumn("title");
    node.setRootFilter(FilterType.all);
    node.setLimit(5);

    auto sql = toCTE(node, postgresDialect());

    assert(sql.canFind("LIMIT 5"), "SQL should contain LIMIT 5: " ~ sql);
    assert(!sql.canFind("OFFSET"), "SQL should not contain OFFSET: " ~ sql);
}

unittest {
    import dunamis.postgres.dialect : postgresDialect;

    // Test SQL generation with OFFSET only (no limit)
    auto node = new QueryNode(QueryNodeId(0), "Comment", "comments", ["id"]);
    node.addColumn("body");
    node.setRootFilter(FilterType.all);
    node.setOffset(15);

    auto sql = toCTE(node, postgresDialect());

    assert(sql.canFind("OFFSET 15"), "SQL should contain OFFSET 15: " ~ sql);
    assert(!sql.canFind("LIMIT"), "SQL should not contain LIMIT: " ~ sql);
}

unittest {
    import dunamis.postgres.dialect : postgresDialect;

    // Test that PostgreSQL dialect uses ANY($1) and no row_json
    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    node.addColumn("first_name");
    node.setRootFilter(FilterType.byIds);

    auto sql = toCTE(node, postgresDialect());

    assert(sql.canFind("ANY($1)"), "PostgreSQL should use ANY($1): " ~ sql);
    assert(!sql.canFind("row_json"), "PostgreSQL should not have row_json in CTE: " ~ sql);
}

unittest {
    import dunamis.postgres.dialect : postgresDialect;

    // A node merged into another (see QueryNode.mergeFrom) has no layer of
    // its own; its children are selected against that node's layer
    auto users = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    users.setRootFilter(FilterType.all);
    auto posts1 = new QueryNode(QueryNodeId(1), "Post", "posts", ["id"]);
    auto posts2 = new QueryNode(QueryNodeId(2), "Post", "posts", ["id"]);
    posts1.setParent(users, "author_id", "User");
    posts2.setParent(users, "author_id", "User");
    posts1.addColumn("title");
    posts2.addColumn("body");
    auto comments = new QueryNode(QueryNodeId(3), "Comment", "comments", ["id"]);
    comments.setParent(posts2, "post_id", "Post");
    posts1.mergeFrom(posts2);

    auto sql = toSQL(users.allNodesInTree(), postgresDialect());
    assert(sql.canFind("layer1 AS") && !sql.canFind("layer2") && sql.canFind("layer3 AS"), sql);
    assert(sql.canFind("posts.title, posts.body"), sql);
    assert(sql.canFind("comments.post_id IN (SELECT id FROM layer1)"), sql);
}
