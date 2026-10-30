module dunamis.relational.query_node;

import std.algorithm;
import std.array;
import std.conv;
import std.typecons : Nullable;

import dunamis.core.types : AnyRef;
import dunamis.core.sorting : OrderBySpec, SortDirection;
import dunamis.core.datasource : DataSource;
import dunamis.relational.sql_dialect : DialectSql, SqlDialect;

// ============================================================================
// Typed Identifiers
// ============================================================================

/// Typed wrapper for QueryNode IDs. Prevents confusion with other ints.
///
/// `value` numbers the nodes of one optimized tree (it names their SQL
/// layers); `tree` tells the trees optimized in a process apart, so that the
/// results of the nodes of different trees evaluated on one session (for
/// example of a nested evaluation, see `evaluateNested`) do not collide.
struct QueryNodeId {
    int value;
    uint tree;
}

/// Sentinel for "no QueryNode assigned yet" (replaces -1 convention).
enum QueryNodeId noQueryNodeId = QueryNodeId(-1);

/// Typed wrapper for SQL join aliases (e.g., "j0", "j1").
/// Prevents confusion with column name strings.
struct JoinAlias {
    string value;
}

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

/// A computed column added to a QueryNode's SELECT clause by SQL push-down.
struct ComputedColumn {
    string alias_;     // SQL alias (e.g., "computed_0")
    string sqlExpr;    // SQL expression (e.g., "first_name || ' ' || last_name")
    TypeInfo type;     // Result type for creating typed projection
}

/// The rows a root QueryNode selects in one evaluation.
/// Usually the node's own filter (fixed at optimization time); for root nodes
/// whose rows are only known at evaluation time (e.g. mutation-returned
/// entities), the refs bound by that evaluation. Passed to the session
/// alongside the node, so that QueryNodes stay read-only after optimization.
struct RootSelection {
    FilterType filter = FilterType.none;
    AnyRef[] refs;
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
    QueryNodeId id;

    /// Entity type name (e.g., "User")
    string typeName;

    /// Table name (e.g., "users")
    string table;

    /// Primary key SQL column names for this entity (e.g., ["id"] or ["order_id", "product_id"])
    string[] pkColumns;

    /// Columns to fetch (always includes PK columns)
    string[] columns;

    /// Columns whose D/GraphQL representation is string-backed. PostgreSQL
    /// JSON aggregation must cast these to text first, otherwise numeric
    /// values lose precision or display scale.
    bool[string] stringColumns;

    /// Parent node (for hasMany relationships)
    QueryNode parent;

    /// Child nodes (for hasMany relationships)
    QueryNode[] children;

    /// Foreign key linking to parent (for hasMany)
    string parentFk;

    /// Parent type name (for encoding parent refs)
    string parentTypeName;

    /// Columns in the parent CTE which identify the entity owning this
    /// hasMany relation. Usually the parent's PK, but for hasMany reached
    /// through belongsTo these are projected JOIN columns (for example
    /// `j0__id`).
    string[] parentLinkColumns;

    /// Root filter type (for root nodes)
    FilterType rootFilter = FilterType.none;

    /// Root filter IDs (for byId/byIds filters)
    AnyRef[] rootFilterRefs;

    /// Data source for this query node (set during optimization from Entity._db)
    DataSource dataSource;

    /// MapExpr identity for looking up currentRefs at eval time
    /// Used for mutation-returned entities where refs aren't known at optimization time
    Object mapExpr;

    /// JOINs for belongsTo chains
    JoinInfo[] joins;

    /// Columns needed from each joined table (alias -> columns)
    string[][JoinAlias] joinedColumns;
    bool[string][JoinAlias] joinedStringColumns;

    /// Pagination: limit number of results (global, for root queries)
    Nullable!size_t limit_;

    /// Pagination: skip first N results (global, for root queries)
    Nullable!size_t offset_;

    /// Sorting: order results by columns
    OrderBySpec[] orderBy_;

    /// Per-parent pagination (for child/hasMany nodes): limit per parent
    Nullable!size_t perParentLimit_;

    /// Per-parent pagination (for child/hasMany nodes): offset per parent
    Nullable!size_t perParentOffset_;

    /// True when window functions should be used for per-parent pagination
    /// Set when this is a child node with perParentLimit_ or perParentOffset_
    bool useWindowFunction = false;

    /// WHERE clause SQL expression (generated by optimizer from predicate)
    /// Multiple clauses are combined with AND.
    /// WHERE predicates (ANDed), rendered for the target dialect.
    DialectSql[] whereClauses_;

    /// Computed columns (SQL expressions pushed down by SqlOptimizer).
    /// Part of the optimized plan, so that rendering SQL needs no optimizer
    /// state.
    ComputedColumn[] computedColumns;

    /// The node whose layer holds this node's rows, if it is not its own
    /// (see `mergeFrom`): set at optimization time, when another node of
    /// the tree selects the same rows.
    QueryNode sameRowsAs;

    /// Next join alias counter
    private int _nextJoinAlias = 0;

    this(QueryNodeId id, string typeName, string table, string[] pkColumns) {
        assert(typeName.length > 0, "QueryNode typeName must not be empty");
        assert(table.length > 0, "QueryNode table must not be empty");
        this.id = id;
        this.typeName = typeName;
        this.table = table;
        this.pkColumns = pkColumns;
        this.columns = pkColumns.dup;  // Always need PK columns
    }

    /// Add a column to fetch
    void addColumn(string column) {
        if (!columns.canFind(column)) {
            columns ~= column;
        }
    }

    void markStringColumn(string column) {
        stringColumns[column] = true;
    }

    /// Set this as a child node (hasMany relationship)
    void setParent(QueryNode parent, string fk, string parentTypeName,
            string[] parentLinkColumns = null) {
        assert(this.parent is null, "setParent must only be called once");
        assert(parent !is null, "parent must not be null");
        assert(fk.length > 0, "FK column must not be empty");
        this.parent = parent;
        this.parentFk = fk;
        this.parentTypeName = parentTypeName;
        this.parentLinkColumns = parentLinkColumns.length
            ? parentLinkColumns.dup : parent.pkColumns.dup;
        addColumn(fk);  // Need FK for grouping

        // Also add to parent's children list
        parent.children ~= this;
    }

    /// Set root filter (for root nodes)
    void setRootFilter(FilterType filter, AnyRef[] refs = null) {
        this.rootFilter = filter;
        this.rootFilterRefs = refs;
    }

    /// The rows this node selects by its own (optimization-time) root filter.
    @property RootSelection rootSelection() {
        return RootSelection(rootFilter, rootFilterRefs);
    }

    /// Add a JOIN for belongsTo chain access.
    /// sourceAlias: for multi-hop chains, the alias of the previous join (null = root table).
    /// Returns the join alias to use for column access.
    JoinAlias addJoin(string targetTable, string targetType, string fk,
                      string[] targetPkColumns,
                      Nullable!JoinAlias sourceAlias = Nullable!JoinAlias.init) {
        // Check if we already have this join
        foreach (j; joins) {
            if (j.targetTable == targetTable && j.fk == fk && j.sourceAlias == sourceAlias) {
                return j.alias_;
            }
        }

        // Create new join
        auto alias_ = JoinAlias("j" ~ (_nextJoinAlias++).to!string);
        assert(!joins.map!(j => j.alias_).canFind(alias_), "Generated join alias collision: " ~ alias_.value);
        joins ~= JoinInfo(targetTable, targetType, fk, alias_, sourceAlias, targetPkColumns);

        // Pre-seed joined columns with target PK columns
        joinedColumns[alias_] = targetPkColumns.dup;

        return alias_;
    }

    /// Add a column to fetch from a joined table.
    void addJoinedColumn(JoinAlias joinAlias, string column) {
        if (joinAlias !in joinedColumns) {
            // Fallback: look up PK columns from JoinInfo if available
            string[] seed = ["id"];
            foreach (j; joins) {
                if (j.alias_ == joinAlias) {
                    seed = j.targetPkColumns.dup;
                    break;
                }
            }
            joinedColumns[joinAlias] = seed;
        }
        if (!joinedColumns[joinAlias].canFind(column)) {
            joinedColumns[joinAlias] ~= column;
        }
    }

    void markJoinedStringColumn(JoinAlias joinAlias, string column) {
        joinedStringColumns[joinAlias][column] = true;
    }

    /// Check if this is a root node (no parent)
    @property bool isRoot() const {
        return parent is null;
    }

    /// Set pagination limit
    void setLimit(size_t n) {
        limit_ = n;
    }

    /// Set pagination offset
    void setOffset(size_t n) {
        offset_ = n;
    }

    /// Add ORDER BY clause
    void addOrderBy(string column, SortDirection direction = SortDirection.ASC) {
        orderBy_ ~= OrderBySpec(column, direction);
    }

    /// Add ORDER BY clause (convenience)
    void addOrderBy(OrderBySpec spec) {
        orderBy_ ~= spec;
    }

    /// Add a computed column to the SELECT clause
    void addComputedColumn(ComputedColumn column) {
        computedColumns ~= column;
    }

    /// Add a WHERE predicate (ANDed with existing ones)
    void addWhereClause(DialectSql clause) {
        whereClauses_ ~= clause;
    }

    /// ditto
    void addWhereClause(string clause) {
        addWhereClause((SqlDialect) => clause);
    }

    /// The combined WHERE predicate for `dialect` (empty if none).
    string whereClause(SqlDialect dialect) {
        string result;
        foreach (clause; whereClauses_) {
            auto sql = clause(dialect);
            result = result.length == 0 ? sql : "(" ~ result ~ ") AND (" ~ sql ~ ")";
        }
        return result;
    }

    /// The node whose SQL layer holds this node's rows: itself, or the node
    /// it was merged into (see `mergeFrom`).
    @property QueryNode layerNode() {
        auto node = this;
        while (node.sameRowsAs !is null)
            node = node.sameRowsAs;
        return node;
    }

    /// Whether this node and `other` (both child layers) select the same
    /// rows: of the same table and type, of the same parent rows (the
    /// layers of their parents being the same), through the same link,
    /// with the same conditions (`dialect` rendering their WHERE clauses),
    /// order and window; and whether `other`'s rows can be read from this
    /// node's layer (see `mergeFrom`): its JOINs are the same as this
    /// node's, or extend them (or are extended by them).
    bool selectsSameRowsAs(QueryNode other, SqlDialect dialect) {
        if (other is this || isRoot || other.isRoot)
            return false;
        if (other.dataSource !is dataSource || other.typeName != typeName || other.table != table ||
                other.pkColumns != pkColumns)
            return false;
        if (other.parent.layerNode !is parent.layerNode || other.parentFk != parentFk ||
                other.parentTypeName != parentTypeName || other.parentLinkColumns != parentLinkColumns)
            return false;
        if (useWindowFunction || other.useWindowFunction || other.orderBy_ != orderBy_ ||
                other.limit_ != limit_ || other.offset_ != offset_ ||
                other.perParentLimit_ != perParentLimit_ || other.perParentOffset_ != perParentOffset_)
            return false;
        if (other.whereClauses_.length != whereClauses_.length ||
                (whereClauses_.length && other.whereClause(dialect) != whereClause(dialect)))
            return false;
        // (LEFT JOINs of belongs-to parents by their keys select no other
        // rows; the joins of both are named alike)
        auto common = joins.length < other.joins.length ? joins.length : other.joins.length;
        return joins[0 .. common] == other.joins[0 .. common];
    }

    /// Merge `other` (which selects the same rows, see
    /// `selectsSameRowsAs`) into this node: this node's layer then also
    /// fetches what `other` reads (its columns, JOINs and computed
    /// columns), and holds `other`'s rows (`other.sameRowsAs`). Done at
    /// optimization time, once the tree's nodes are complete.
    void mergeFrom(QueryNode other) {
        assert(other.sameRowsAs is null && sameRowsAs is null, "Merging merged query nodes");
        foreach (column; other.columns)
            addColumn(column);
        foreach (column, _; other.stringColumns)
            markStringColumn(column);
        foreach (join; other.joins[joins.length < other.joins.length ? joins.length : $ .. $]) {
            joins ~= join;
            joinedColumns[join.alias_] = join.targetPkColumns.dup;
        }
        if (_nextJoinAlias < other._nextJoinAlias)
            _nextJoinAlias = other._nextJoinAlias;
        foreach (alias_, cols; other.joinedColumns)
            foreach (column; cols)
                addJoinedColumn(alias_, column);
        foreach (alias_, cols; other.joinedStringColumns)
            foreach (column, _; cols)
                markJoinedStringColumn(alias_, column);
        foreach (computed; other.computedColumns)
            if (!computedColumns.canFind!(c => c.alias_ == computed.alias_))
                addComputedColumn(computed);
        other.sameRowsAs = this;
    }

    /// Get all nodes in the tree rooted at this node (including self).
    /// Returns nodes in BFS order (parents before children).
    QueryNode[] allNodesInTree() {
        QueryNode[] result;
        QueryNode[] queue = [this];

        while (queue.length > 0) {
            auto node = queue[0];
            queue = queue[1..$];
            result ~= node;
            queue ~= node.children;
        }

        return result;
    }
}

// ============================================================================
// Supporting Types
// ============================================================================

/// Information about a JOIN for belongsTo access
struct JoinInfo {
    string targetTable;           // Table to join to
    string targetType;            // Entity type name
    string fk;                    // Foreign key column in source table
    JoinAlias alias_;             // SQL alias (e.g., "j0")
    Nullable!JoinAlias sourceAlias;  // Source alias for multi-hop chains (null = root table)
    string[] targetPkColumns;     // PK columns of the target table (e.g., ["id"])
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test QueryNode basics
    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    assert(node.id == QueryNodeId(0));
    assert(node.typeName == "User");
    assert(node.table == "users");
    assert(node.pkColumns == ["id"]);
    assert(node.columns == ["id"]);
    assert(node.isRoot);

    node.addColumn("first_name");
    node.addColumn("last_name");
    node.addColumn("first_name");  // Duplicate
    assert(node.columns == ["id", "first_name", "last_name"]);
}

unittest {
    // Test QueryNode parent-child relationship
    auto parent = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    auto child = new QueryNode(QueryNodeId(1), "Post", "posts", ["id"]);
    child.setParent(parent, "author_id", "User");

    assert(parent.isRoot);
    assert(!child.isRoot);
    assert(child.parent is parent);
    assert(child.parentFk == "author_id");
    assert(child.columns.canFind("author_id"));
}

unittest {
    // Test QueryNode JOINs
    auto node = new QueryNode(QueryNodeId(0), "Post", "posts", ["id"]);
    auto alias1 = node.addJoin("users", "User", "author_id", ["id"]);
    auto alias2 = node.addJoin("categories", "Category", "category_id", ["id"]);
    auto alias3 = node.addJoin("users", "User", "author_id", ["id"]);  // Duplicate

    assert(alias1 == JoinAlias("j0"));
    assert(alias2 == JoinAlias("j1"));
    assert(alias3 == JoinAlias("j0"));  // Returns existing alias
    assert(node.joins.length == 2);
}

unittest {
    // Test QueryNode ORDER BY
    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    assert(node.orderBy_.length == 0);

    node.addOrderBy("last_name", SortDirection.ASC);
    node.addOrderBy("first_name", SortDirection.DESC);

    assert(node.orderBy_.length == 2);
    assert(node.orderBy_[0].column == "last_name");
    assert(node.orderBy_[0].direction == SortDirection.ASC);
    assert(node.orderBy_[1].column == "first_name");
    assert(node.orderBy_[1].direction == SortDirection.DESC);
}

unittest {
    import dunamis.postgres.dialect : postgresDialect;

    // Child layers of the same parent rows, link, order and conditions
    // select the same rows: one layer reads what both read
    auto users = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    auto posts1 = new QueryNode(QueryNodeId(1), "Post", "posts", ["id"]);
    auto posts2 = new QueryNode(QueryNodeId(2), "Post", "posts", ["id"]);
    auto otherPosts = new QueryNode(QueryNodeId(3), "Post", "posts", ["id"]);
    posts1.setParent(users, "author_id", "User");
    posts2.setParent(users, "author_id", "User");
    otherPosts.setParent(users, "editor_id", "User");
    posts1.addColumn("title");
    auto j = posts1.addJoin("categories", "Category", "category_id", ["id"]);
    posts1.addJoinedColumn(j, "name");
    posts2.addColumn("body");
    posts2.markStringColumn("body");
    posts2.addComputedColumn(ComputedColumn("computed_0", "length(body)", typeid(int)));

    auto dialect = postgresDialect();
    assert(posts1.selectsSameRowsAs(posts2, dialect) && posts2.selectsSameRowsAs(posts1, dialect));
    assert(!posts1.selectsSameRowsAs(otherPosts, dialect));
    assert(!users.selectsSameRowsAs(posts1, dialect));
    posts2.addWhereClause("posts.draft");
    assert(!posts1.selectsSameRowsAs(posts2, dialect));
    posts2.whereClauses_ = null;
    // Other JOINs under the same name: other columns
    auto k = posts2.addJoin("users", "User", "editor_id", ["id"]);
    assert(k == j && !posts1.selectsSameRowsAs(posts2, dialect));
    posts2.joins = null;
    posts2.joinedColumns = null;

    posts1.mergeFrom(posts2);
    assert(posts2.sameRowsAs is posts1 && posts2.layerNode is posts1 && posts1.layerNode is posts1);
    assert(posts1.columns == ["id", "author_id", "title", "body"] && "body" in posts1.stringColumns);
    assert(posts1.joins.length == 1 && posts1.joinedColumns[j] == ["id", "name"]);
    assert(posts1.computedColumns.length == 1);

    // Children of merged nodes have the same parent rows
    auto comments1 = new QueryNode(QueryNodeId(4), "Comment", "comments", ["id"]);
    auto comments2 = new QueryNode(QueryNodeId(5), "Comment", "comments", ["id"]);
    comments1.setParent(posts1, "post_id", "Post");
    comments2.setParent(posts2, "post_id", "Post");
    assert(comments1.selectsSameRowsAs(comments2, dialect));
}
