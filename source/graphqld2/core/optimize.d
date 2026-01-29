module graphqld2.core.optimize;

import std.algorithm;
import std.array;
import std.conv;
import std.typecons : Nullable, nullable;

import graphqld2.core.types;
import graphqld2.core.eval;
import graphqld2.core.expr;

// ============================================================================
// Query Node
// ============================================================================

/// Represents a query scope (one per MapExpr).
/// Accumulates columns to fetch and tracks relationships to other nodes.
class QueryNode {
    /// Unique ID for this query node
    int id;

    /// Entity type name (e.g., "User")
    string typeName;

    /// Table name (e.g., "users")
    string table;

    /// Columns to fetch (always includes "id")
    string[] columns;

    /// Parent node (for hasMany relationships)
    QueryNode parent;

    /// Foreign key linking to parent (for hasMany)
    string parentFk;

    /// Parent type name (for encoding parent refs)
    string parentTypeName;

    /// Root filter type (for root nodes)
    FilterType rootFilter = FilterType.none;

    /// Root filter IDs (for byId/byIds filters)
    Ref[] rootFilterRefs;

    /// JOINs for belongsTo chains
    JoinInfo[] joins;

    /// Columns needed from each joined table (alias -> columns)
    string[][string] joinedColumns;

    /// Next join alias counter
    private int _nextJoinAlias = 0;

    this(int id, string typeName, string table) {
        this.id = id;
        this.typeName = typeName;
        this.table = table;
        this.columns = ["id"];  // Always need ID
    }

    /// Add a column to fetch
    void addColumn(string column) {
        if (!columns.canFind(column)) {
            columns ~= column;
        }
    }

    /// Set this as a child node (hasMany relationship)
    void setParent(QueryNode parent, string fk, string parentTypeName) {
        this.parent = parent;
        this.parentFk = fk;
        this.parentTypeName = parentTypeName;
        addColumn(fk);  // Need FK for grouping
    }

    /// Set root filter (for root nodes)
    void setRootFilter(FilterType filter, Ref[] refs = null) {
        this.rootFilter = filter;
        this.rootFilterRefs = refs;
    }

    /// Add a JOIN for belongsTo chain access.
    /// Returns the join alias to use for column access.
    string addJoin(string targetTable, string targetType, string fk) {
        // Check if we already have this join
        foreach (j; joins) {
            if (j.targetTable == targetTable && j.fk == fk) {
                return j.alias_;
            }
        }

        // Create new join
        auto alias_ = "j" ~ (_nextJoinAlias++).to!string;
        joins ~= JoinInfo(targetTable, targetType, fk, alias_);
        return alias_;
    }

    /// Add a column to fetch from a joined table.
    void addJoinedColumn(string joinAlias, string column) {
        if (joinAlias !in joinedColumns) {
            joinedColumns[joinAlias] = ["id"];  // Always need id
        }
        if (!joinedColumns[joinAlias].canFind(column)) {
            joinedColumns[joinAlias] ~= column;
        }
    }

    /// Check if this is a root node (no parent)
    @property bool isRoot() const {
        return parent is null;
    }

    /// Generate SQL CTE (Common Table Expression) for this layer.
    /// Used by toSQL() to build the full query.
    string toCTE() const {
        import std.array : join;
        import std.format : format;

        auto sql = appender!string;

        sql ~= format("  layer%d AS (\n", id);
        sql ~= "    SELECT ";

        // Select columns from main table
        string[] selectParts;
        foreach (col; columns) {
            selectParts ~= format("%s.%s", table, col);
        }

        // Select columns from JOINed tables (for belongsTo)
        foreach (joinInfo; joins) {
            if (auto cols = joinInfo.alias_ in joinedColumns) {
                foreach (col; *cols) {
                    selectParts ~= format("%s.%s AS %s__%s",
                        joinInfo.alias_, col, joinInfo.alias_, col);
                }
            }
        }

        sql ~= selectParts.join(", ");
        sql ~= format("\n    FROM %s", table);

        // Add JOINs for belongsTo relationships
        foreach (joinInfo; joins) {
            sql ~= format("\n    LEFT JOIN %s %s ON %s.%s = %s.id",
                joinInfo.targetTable, joinInfo.alias_,
                table, joinInfo.fk, joinInfo.alias_);
        }

        // WHERE clause
        sql ~= "\n    WHERE ";
        if (isRoot) {
            final switch (rootFilter) {
                case FilterType.none:
                    sql ~= "1=1";
                    break;
                case FilterType.all:
                    sql ~= "1=1";
                    break;
                case FilterType.byId:
                    sql ~= format("%s.id = ANY($1)", table);
                    break;
                case FilterType.byIds:
                    sql ~= format("%s.id = ANY($1)", table);
                    break;
            }
        } else {
            // Child layer: filter by FK in parent layer
            sql ~= format("%s.%s IN (SELECT id FROM layer%d)",
                table, parentFk, parent.id);
        }

        sql ~= "\n  )";
        return sql.data;
    }
}

/// Generate a complete CTE-based SQL query from a list of QueryNodes.
/// This produces a single query that fetches all layers and aggregates to JSON.
string toSQL(QueryNode[] nodes) {
    import std.array : join;
    import std.format : format;

    if (nodes.length == 0)
        return "";

    auto sql = appender!string;

    // Build CTEs for each layer
    sql ~= "WITH\n";

    string[] ctes;
    foreach (node; nodes) {
        ctes ~= node.toCTE();
    }
    sql ~= ctes.join(",\n");

    // Final SELECT: aggregate all layers into JSON
    sql ~= "\nSELECT json_build_object(\n";
    string[] jsonParts;
    foreach (node; nodes) {
        jsonParts ~= format("  'layer%d', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer%d t)",
            node.id, node.id);
    }
    sql ~= jsonParts.join(",\n");
    sql ~= "\n)";

    return sql.data;
}

/// Information about a JOIN for belongsTo access
struct JoinInfo {
    string targetTable;   // Table to join to
    string targetType;    // Entity type name
    string fk;            // Foreign key column in source table
    string alias_;        // SQL alias (e.g., "j0")
}

/// Filter type for root queries
enum FilterType {
    none,    // Not a root (child of another node)
    all,     // Fetch all entities
    byId,    // Fetch single entity by ID
    byIds,   // Fetch multiple entities by IDs
}

// ============================================================================
// Optimize Context
// ============================================================================

/// Manages optimization state during expression tree transformation.
/// Holds QueryNodes keyed by MapExpr identity.
class OptimizeContext {
    private {
        /// Query nodes keyed by MapExpr identity (using Object pointer)
        QueryNode[void*] _queryNodes;

        /// Next query node ID
        int _nextNodeId = 0;

        /// Data fetcher (needed to build queries)
        DataFetcher _fetcher;
    }

    this(DataFetcher fetcher = null) {
        _fetcher = fetcher;
    }

    /// Get or create a QueryNode for a MapExpr.
    /// Called by access expressions during optimization.
    QueryNode getOrCreateNode(Object mapExpr, string typeName, string table) {
        auto key = cast(void*) mapExpr;
        if (key in _queryNodes) {
            return _queryNodes[key];
        }

        auto node = new QueryNode(_nextNodeId++, typeName, table);
        _queryNodes[key] = node;
        return node;
    }

    /// Get existing node for a MapExpr (returns null if not found)
    QueryNode getNode(Object mapExpr) {
        auto key = cast(void*) mapExpr;
        return _queryNodes.get(key, null);
    }

    /// Get all query nodes (for executor to fetch data)
    QueryNode[] allNodes() {
        return _queryNodes.values;
    }

    /// Get nodes in execution order (parents before children)
    QueryNode[] nodesInOrder() {
        auto nodes = allNodes();

        // Topological sort: roots first, then children
        QueryNode[] result;
        bool[int] added;

        void addWithDeps(QueryNode node) {
            if (node.id in added) return;
            if (node.parent !is null) {
                addWithDeps(node.parent);
            }
            result ~= node;
            added[node.id] = true;
        }

        foreach (node; nodes) {
            addWithDeps(node);
        }

        return result;
    }

    @property DataFetcher fetcher() { return _fetcher; }
}

// ============================================================================
// Helper: Find MapExpr from _input chain
// ============================================================================

/// Walk _input chain to find the owning MapExpr.
/// Access expressions call this during optimization to find their query scope.
///
/// Returns: tuple of (MapExpr as Object, entity type info) or null if not found.
Object findMapExpr(Expr!Ref expr) {
    import graphqld2.core.expr : EveryItemOfExpr;

    while (expr !is null) {
        // Found the placeholder? Return its parent map.
        if (auto every = cast(EveryItemOfExpr) expr) {
            return every._parentMap;
        }

        // Try to continue through access expressions
        // This uses runtime type checking since we can't import relational here
        expr = getInputExpr(expr);
    }
    return null;
}

/// Get the _input field from an access expression using runtime reflection.
/// Returns null if the expression doesn't have an _input field.
private Expr!Ref getInputExpr(Expr!Ref expr) {
    // Use __traits to check for _input field at compile time isn't possible
    // here since we're dealing with runtime types. Instead, we'll handle
    // this in the access expressions themselves.
    return null;
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test QueryNode basics
    auto node = new QueryNode(0, "User", "users");
    assert(node.id == 0);
    assert(node.typeName == "User");
    assert(node.table == "users");
    assert(node.columns == ["id"]);
    assert(node.isRoot);

    node.addColumn("first_name");
    node.addColumn("last_name");
    node.addColumn("first_name");  // Duplicate
    assert(node.columns == ["id", "first_name", "last_name"]);
}

unittest {
    // Test QueryNode parent-child relationship
    auto parent = new QueryNode(0, "User", "users");
    auto child = new QueryNode(1, "Post", "posts");
    child.setParent(parent, "author_id", "User");

    assert(parent.isRoot);   // Parent has no parent, so is root
    assert(!child.isRoot);   // Child has a parent
    assert(child.parent is parent);
    assert(child.parentFk == "author_id");
    assert(child.columns.canFind("author_id"));
}

unittest {
    // Test QueryNode JOINs
    auto node = new QueryNode(0, "Post", "posts");
    auto alias1 = node.addJoin("users", "User", "author_id");
    auto alias2 = node.addJoin("categories", "Category", "category_id");
    auto alias3 = node.addJoin("users", "User", "author_id");  // Duplicate

    assert(alias1 == "j0");
    assert(alias2 == "j1");
    assert(alias3 == "j0");  // Returns existing alias
    assert(node.joins.length == 2);
}

unittest {
    // Test OptimizeContext
    auto ctx = new OptimizeContext();

    // Create a mock "MapExpr" object
    auto map1 = new Object();
    auto map2 = new Object();

    auto node1 = ctx.getOrCreateNode(map1, "User", "users");
    auto node2 = ctx.getOrCreateNode(map2, "Post", "posts");
    auto node1again = ctx.getOrCreateNode(map1, "User", "users");

    assert(node1.id == 0);
    assert(node2.id == 1);
    assert(node1again is node1);  // Same node returned

    assert(ctx.allNodes().length == 2);
}

unittest {
    // Test nodesInOrder with parent-child
    auto ctx = new OptimizeContext();

    auto map1 = new Object();
    auto map2 = new Object();

    auto parent = ctx.getOrCreateNode(map1, "User", "users");
    auto child = ctx.getOrCreateNode(map2, "Post", "posts");
    child.setParent(parent, "author_id", "User");

    auto ordered = ctx.nodesInOrder();
    assert(ordered.length == 2);
    assert(ordered[0] is parent);  // Parent comes first
    assert(ordered[1] is child);
}
