module dunamis.relational.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.typecons : Nullable;

import dunamis.relational.query_node : QueryNode, QueryNodeId, FilterType;
import dunamis.relational.sql_dialect : SqlDialect, layerName, qualifiedColumn;
import dunamis.relational.sql_fragment : Sql, SqlName, sql;

// ============================================================================
// Query SQL Generation (CTE-based, dialect-agnostic)
// ============================================================================

/// The most layers the final SELECT of a query puts into one JSON object;
/// the layers of a query with more are grouped into objects (of at most as
/// many) under the keys `layerGroupKey ~ n` (see loadLayerResults).
enum size_t layerGroupSize = 40;

/// ditto
enum string layerGroupKey = "layers";

/// Generate a complete CTE-based SQL query with computed columns.
/// Root nodes are filtered by their own root filter.
Sql toSQL(QueryNode[] nodes, SqlDialect dialect) {
    return toSQL(nodes, dialect, Nullable!FilterType.init, Sql.init);
}

/// ditto, filtering the root node(s) by `rootFilter` (the root selection
/// of the evaluation executing the query) instead: by their keys, `rootIds`
/// (the list of their values, see `SqlDialect.rootIdFilter`).
Sql toSQL(QueryNode[] nodes, SqlDialect dialect, FilterType rootFilter, Sql rootIds = Sql.init) {
    return toSQL(nodes, dialect, Nullable!FilterType(rootFilter), rootIds);
}

private Sql toSQL(QueryNode[] nodes, SqlDialect dialect, Nullable!FilterType rootFilter, Sql rootIds) {
    if (nodes.length == 0)
        return Sql.init;

    // Nodes whose rows another node's layer holds have no layer of their
    // own (see QueryNode.mergeFrom)
    nodes = nodes.filter!(node => node.sameRowsAs is null).array;

    // A CTE for each layer
    Sql[] ctes;
    foreach (node; nodes)
        ctes ~= toCTE(node, dialect, rootFilter.isNull ? node.rootFilter : rootFilter.get, rootIds);

    // Final SELECT: aggregate all layers into JSON
    Sql[] jsonParts;
    foreach (node; nodes) {
        Sql[] orderParts;
        foreach (spec; node.orderBy_)
            orderParts ~= dialect.orderByTerm(sql(i"$(SqlName(orderKeyColumn(node, spec.column)))"), spec.descending);
        auto layer = dialect.aggregateLayerJson(node.id.value, Sql.join!", "(orderParts));
        jsonParts ~= sql(i"  $(layerName(node.id.value).name), $(layer)");
    }
    // (Functions take at most 100 arguments in PostgreSQL: more layers are
    // grouped into objects of `layerGroupSize` layers, see layerGroupKey.)
    Sql object(Sql[] parts) {
        return sql(i"$(dialect.jsonObjectFunc())(\n$(Sql.join!",\n"(parts))\n)");
    }
    if (jsonParts.length > layerGroupSize) {
        Sql[] groups;
        for (size_t i = 0; i < jsonParts.length; i += layerGroupSize) {
            auto end = i + layerGroupSize < jsonParts.length ? i + layerGroupSize : jsonParts.length;
            auto key = layerGroupKey ~ (i / layerGroupSize).to!string;
            groups ~= sql(i"  $(key), $(object(jsonParts[i .. end]))");
        }
        jsonParts = groups;
    }
    auto result = sql(i"WITH\n$(Sql.join!",\n"(ctes))\nSELECT $(object(jsonParts))\n");

    debug(sql) {
        import std.stdio : writeln;
        writeln(result.render(dialect));
    }

    return result;
}

/// The relations (see `QueryNode.relations`) the query of `nodes` (see
/// toSQL) reads, each once.
string[] relationsOf(QueryNode[] nodes) {
    string[] result;
    foreach (node; nodes)
        if (node.sameRowsAs is null)
            foreach (relation; node.relations)
                if (!result.canFind(relation))
                    result ~= relation;
    return result;
}

/// Generate CTE for a single QueryNode.
private Sql toCTE(QueryNode node, SqlDialect dialect) {
    return toCTE(node, dialect, node.rootFilter, Sql.init);
}

/// ditto, filtering a root node by `rootFilter` (by the keys `rootIds`).
private Sql toCTE(QueryNode node, SqlDialect dialect, FilterType rootFilter, Sql rootIds) {
    auto table = SqlName(node.table);
    Sql[] parts;

    parts ~= sql(i"  $(layerName(node.id.value)) AS (\n    SELECT $(buildSelectColumns(node, dialect))");

    // Dialect-specific: add per-row JSON wrapping if needed
    auto rowJsonFunc = dialect.rowJsonFunc();
    if (!rowJsonFunc.empty)
        parts ~= sql(i",\n           $(rowJsonFunc)($(buildJsonObjectArgs(node))) AS row_json");

    parts ~= sql(i"\n    FROM $(table)");

    // JOINs for belongsTo relationships
    foreach (joinInfo; node.joins) {
        auto sourceRef = !joinInfo.sourceAlias.isNull ? joinInfo.sourceAlias.get.value : node.table;
        // (A foreign key column refers to a single-column key)
        assert(joinInfo.targetPkColumns.length == 1, "A JOIN of " ~ joinInfo.targetTable ~ " by a composite key");
        auto target = SqlName(joinInfo.targetTable), alias_ = SqlName(joinInfo.alias_.value);
        auto fk = qualifiedColumn(sourceRef, joinInfo.fk);
        auto pk = qualifiedColumn(joinInfo.alias_.value, joinInfo.targetPkColumns[0]);
        parts ~= sql(i"\n    LEFT JOIN $(target) $(alias_) ON $(fk) = $(pk)");
    }

    // WHERE clause
    if (node.isRoot) {
        final switch (rootFilter) {
            case FilterType.none:
            case FilterType.all:
                parts ~= sql(i"\n    WHERE 1=1");
                break;
            case FilterType.byId:
            case FilterType.byIds:
                parts ~= sql(i"\n    WHERE $(dialect.rootIdFilter(node.table, node.pkColumns, rootIds))");
                break;
        }
    } else {
        // Use parent's PK columns for the subselect
        auto parentPk = Sql.join!", "(node.parentLinkColumns.map!(c => sql(i"$(SqlName(c))")).array);
        auto parentLayer = layerName(node.parent.layerNode.id.value);
        parts ~= sql(i"\n    WHERE $(qualifiedColumn(node.table, node.parentFk)) IN (SELECT $(parentPk) FROM $(parentLayer))");
    }

    // Custom WHERE clause from filter predicates
    auto where = node.whereClause();
    if (!where.empty)
        parts ~= sql(i"\n      AND ($(where))");

    // ORDER BY (a column, or a computed column, as its expression)
    if (node.orderBy_.length > 0) {
        Sql[] orderParts;
        foreach (spec; node.orderBy_) {
            auto key = qualifiedColumn(node.table, spec.column);
            foreach (computed; node.computedColumns)
                if (computed.alias_ == spec.column)
                    key = computed.sqlExpr;
            orderParts ~= dialect.orderByTerm(key, spec.descending);
        }
        parts ~= sql(i"\n    ORDER BY $(Sql.join!", "(orderParts))");
    }

    // LIMIT
    if (!node.limit_.isNull)
        parts ~= sql(i"\n    LIMIT $(node.limit_.get)");

    // OFFSET
    if (!node.offset_.isNull)
        parts ~= sql(i"\n    OFFSET $(node.offset_.get)");

    parts ~= sql(i"\n  )");
    return Sql.join!""(parts);
}

/// Generate SQL SELECT clause including computed columns.
Sql buildSelectColumns(QueryNode node, SqlDialect dialect) {
    Sql[] selectParts;

    auto tableName = node.table;

    // Regular columns from main table
    foreach (col; node.columns) {
        auto column = qualifiedColumn(tableName, col);
        selectParts ~= col in node.stringColumns
            ? sql(i"$(dialect.castToText(column)) AS $(SqlName(col))")
            : column;
    }

    // Columns from JOINed tables
    foreach (joinInfo; node.joins) {
        if (auto cols = joinInfo.alias_ in node.joinedColumns) {
            foreach (col; *cols) {
                bool isStringColumn;
                if (auto stringCols = joinInfo.alias_ in node.joinedStringColumns)
                    isStringColumn = (col in *stringCols) !is null;
                auto column = qualifiedColumn(joinInfo.alias_.value, col);
                auto alias_ = SqlName(joinInfo.alias_.value ~ "__" ~ col);
                selectParts ~= isStringColumn
                    ? sql(i"$(dialect.castToText(column)) AS $(alias_)")
                    : sql(i"$(column) AS $(alias_)");
            }
        }
    }

    // Computed columns
    foreach (computed; node.computedColumns)
        selectParts ~= sql(i"$(computed.sqlExpr) AS $(SqlName(computed.alias_))");

    // The ORDER BY columns which the layer does not select as they are (see
    // orderKeyColumn), for ordering its rows when they are aggregated
    foreach (spec; node.orderBy_) {
        auto key = orderKeyColumn(node, spec.column);
        auto keyColumn = sql(i"$(qualifiedColumn(tableName, spec.column)) AS $(SqlName(key))");
        if (key != spec.column && !selectParts.canFind(keyColumn))
            selectParts ~= keyColumn;
    }

    return Sql.join!", "(selectParts);
}

/// The column of a layer by which its rows are ordered (when they are
/// aggregated) for the ORDER BY column `column` of its node: the column
/// itself, or the computed column of that name; but a column the layer
/// casts to text (see QueryNode.stringColumns), whose text values would
/// order otherwise (e.g. numbers, or a database enum's labels), or which it
/// does not select, is selected as it is under another name
/// (`orderkey__<column>`).
private string orderKeyColumn(QueryNode node, string column) {
    foreach (computed; node.computedColumns)
        if (computed.alias_ == column)
            return column;
    if (column in node.stringColumns || !node.columns.canFind(column))
        return "orderkey__" ~ column;
    return column;
}

/// Build key-value argument pairs for json_object/JSON_OBJECT row wrapping:
/// "'col1', table.col1, 'col2', table.col2, ...".
Sql buildJsonObjectArgs(QueryNode node) {
    Sql[] args;

    auto tableName = node.table;

    // Regular columns from main table
    foreach (col; node.columns)
        args ~= sql(i"$(col), $(qualifiedColumn(tableName, col))");

    // Columns from JOINed tables
    foreach (joinInfo; node.joins) {
        if (auto cols = joinInfo.alias_ in node.joinedColumns) {
            foreach (col; *cols) {
                auto key = joinInfo.alias_.value ~ "__" ~ col;
                args ~= sql(i"$(key), $(qualifiedColumn(joinInfo.alias_.value, col))");
            }
        }
    }

    // Computed columns
    foreach (computed; node.computedColumns)
        args ~= sql(i"$(computed.alias_), $(computed.sqlExpr)");

    return Sql.join!", "(args);
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

    auto pg = buildSelectColumns(node, postgresDialect()).render(postgresDialect());
    assert(pg == "posts.id, posts.title::text AS title, j0.id AS j0__id, j0.name::text AS j0__name", pg);
    auto my = buildSelectColumns(node, mysqlDialect()).render(mysqlDialect());
    assert(my == "posts.id, CAST(posts.title AS CHAR) AS title, j0.id AS j0__id, CAST(j0.name AS CHAR) AS j0__name", my);
}

// The rows of a layer are aggregated in the order of its ORDER BY, by the
// columns' values: those of a column the layer casts to text (e.g. a numeric
// read as a string, whose text would order otherwise), or does not select,
// are selected as they are, under another name
unittest {
    import dunamis.postgres.dialect : postgresDialect;
    import dunamis.core.sorting : OrderBySpec, SortDirection;

    auto node = new QueryNode(QueryNodeId(0), "OrderItem", "order_items", ["id"]);
    node.addColumn("net_amount");
    node.markStringColumn("net_amount");
    node.addColumn("note");
    node.setRootFilter(FilterType.all);
    node.addOrderBy(OrderBySpec("net_amount", SortDirection.DESC));
    node.addOrderBy(OrderBySpec("note"));
    node.addOrderBy(OrderBySpec("position"));
    auto sql = toSQL([node], postgresDialect()).render(postgresDialect());
    assert(sql.canFind("SELECT order_items.id, order_items.net_amount::text AS net_amount, order_items.note, " ~
        "order_items.net_amount AS orderkey__net_amount, order_items.position AS orderkey__position\n"), sql);
    assert(sql.canFind("ORDER BY order_items.net_amount DESC, order_items.note, order_items.position\n"), sql);
    assert(sql.canFind("FROM layer0 ORDER BY orderkey__net_amount DESC, note, orderkey__position)"), sql);
}

unittest {
    import dunamis.postgres.dialect : postgresDialect;

    // Test SQL generation with LIMIT/OFFSET
    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    node.addColumn("first_name");
    node.setRootFilter(FilterType.all);
    node.setLimit(10);
    node.setOffset(20);

    auto sql = toCTE(node, postgresDialect()).render(postgresDialect());

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

    auto sql = toCTE(node, postgresDialect()).render(postgresDialect());

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

    auto sql = toCTE(node, postgresDialect()).render(postgresDialect());

    assert(sql.canFind("OFFSET 15"), "SQL should contain OFFSET 15: " ~ sql);
    assert(!sql.canFind("LIMIT"), "SQL should not contain LIMIT: " ~ sql);
}

unittest {
    import dunamis.postgres.dialect : postgresDialect;

    // Test that PostgreSQL dialect uses ANY($1) and no row_json
    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    node.addColumn("first_name");
    node.setRootFilter(FilterType.byIds);

    auto sql = toCTE(node, postgresDialect()).render(postgresDialect());

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

    auto sql = toSQL(users.allNodesInTree(), postgresDialect()).render(postgresDialect());
    assert(sql.canFind("layer1 AS") && !sql.canFind("layer2") && sql.canFind("layer3 AS"), sql);
    assert(sql.canFind("posts.title, posts.body"), sql);
    assert(sql.canFind("comments.post_id IN (SELECT id FROM layer1)"), sql);
}
