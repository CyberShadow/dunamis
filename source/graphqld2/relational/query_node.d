module graphqld2.relational.query_node;

import std.algorithm;
import std.array;
import std.conv;

import graphqld2.core.types : Ref;

// ============================================================================
// Filter Types (for root queries)
// ============================================================================

/// Filter type for root queries.
/// Used to configure how root data is fetched.
enum FilterType {
    none,    // Not a root (child of another node)
    all,     // Fetch all entities
    byId,    // Fetch single entity by ID
    byIds,   // Fetch multiple entities by IDs
}

// ============================================================================
// Query Node - Represents a SQL query scope
// ============================================================================

/// Represents a query scope (one per MapExpr).
/// Accumulates columns to fetch and tracks relationships to other nodes.
///
/// QueryNodes form a forest (multiple trees). Each root node represents
/// an independent query (e.g., getByIds!User, getAll!Post). Child nodes
/// represent hasMany relationships and depend on their parent's results.
///
/// JOINs are used for belongsTo relationships within the same node,
/// avoiding separate queries for 1:1 traversals.
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
}

// ============================================================================
// Supporting Types
// ============================================================================

/// Information about a JOIN for belongsTo access
struct JoinInfo {
    string targetTable;   // Table to join to
    string targetType;    // Entity type name
    string fk;            // Foreign key column in source table
    string alias_;        // SQL alias (e.g., "j0")
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

    assert(parent.isRoot);
    assert(!child.isRoot);
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
