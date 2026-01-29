module graphqld2.relational.schema;

import std.algorithm;
import std.array;
import std.conv;
import std.meta;
import std.range : iota;
import std.traits;
import std.typecons : Nullable;

import graphqld2.core;
import graphqld2.relational.eval_context;
import graphqld2.relational.optimize_context;
import graphqld2.relational.project;
import graphqld2.relational.query_node;

// ============================================================================
// Entity Mixin
// ============================================================================

/// Mixin to define an entity (table mapping)
/// Adds _typeName (for node ID encoding) and _table (for SQL generation)
mixin template Entity(string tableName, string typeName = "", string sourceId = "default") {
    static immutable string _table = tableName;
    static immutable string _typeName = (typeName.length > 0) ? typeName : __traits(identifier, typeof(this));
    static immutable string _sourceId = sourceId;
}

// ============================================================================
// Field Definition Mixins
// ============================================================================

/// Convert camelCase to snake_case at compile time
private string toSnakeCase(string input) {
    if (input.length == 0) return "";

    string result;
    foreach (i, c; input) {
        if (c >= 'A' && c <= 'Z') {
            if (i > 0) result ~= '_';
            result ~= cast(char)(c + 32);  // toLowerCase
        } else {
            result ~= c;
        }
    }
    return result;
}

/// Mixin to define a column accessor.
/// Example: mixin Col!("firstName", string);  // generates firstName() method, maps to "first_name" column
/// Example: mixin Col!("createdAt", string, "created_at");  // explicit column name
mixin template Col(string fieldName, T, string columnName = toSnakeCase(fieldName)) {
    mixin("static auto " ~ fieldName ~ "(Expr!Ref e) {
        return e.column!(T, typeof(this))(\"" ~ columnName ~ "\");
    }");
}

/// Mixin to define a hasMany relationship.
/// Example: mixin HasMany!("posts", Post, "author_id");
mixin template HasMany(string fieldName, Child, string fk) {
    mixin("static auto " ~ fieldName ~ "(Expr!Ref e) {
        return e.hasMany!(Child, fk, typeof(this))();
    }");
}

/// Mixin to define a required belongsTo relationship.
/// Example: mixin BelongsTo!("author", User, "author_id");
mixin template BelongsTo(string fieldName, Parent, string fk) {
    mixin("static auto " ~ fieldName ~ "(Expr!Ref e) {
        return e.belongsTo!(Parent, Ref, fk, typeof(this))();
    }");
}

/// Mixin to define an optional belongsTo relationship (nullable FK).
/// Example: mixin BelongsToOptional!("manager", User, "manager_id");
mixin template BelongsToOptional(string fieldName, Parent, string fk) {
    mixin("static auto " ~ fieldName ~ "(Expr!Ref e) {
        return e.belongsTo!(Parent, Nullable!Ref, fk, typeof(this))();
    }");
}

// ============================================================================
// UFCS Access Functions
// ============================================================================

/// Column access - reads a column value for each input ref
auto column(T, Entity = void)(Expr!Ref input, string name) {
    static if (is(Entity == void)) {
        static assert(false, "Entity type must be specified for column access");
    } else {
        return new ColumnAccessExpr!(T, Entity)(input, name);
    }
}

/// HasMany relationship - returns collection of child refs for each parent ref
auto hasMany(Child, string fk, Parent = void)(Expr!Ref input) {
    static if (is(Parent == void)) {
        return new HasManyAccessExpr!(void, Child, fk)(input);
    } else {
        return new HasManyAccessExpr!(Parent, Child, fk)(input);
    }
}

/// BelongsTo relationship - returns parent ref for each child ref
/// RefType can be Ref (required FK) or Nullable!Ref (optional FK)
auto belongsTo(Parent, RefType = Ref, string fk, Child = void)(Expr!Ref input) {
    return new BelongsToAccessExpr!(Child, Parent, RefType, fk)(input);
}

// ============================================================================
// Helper: Find MapExpr from _input chain
// ============================================================================

/// Walk _input chain to find the owning MapExpr and collect join info.
/// Returns the MapExpr (as Object) or null if not found.
private Object findMapExprFromChain(Expr!Ref expr, ref JoinHop[] joinPath) {
    while (expr !is null) {
        // Check if we've reached EveryItemOfExpr
        if (auto every = cast(EveryItemOfExpr) expr) {
            return every._parentMap;
        }

        // Walk through access expressions using interfaces
        if (auto col = cast(ColumnAccessInfo) expr) {
            expr = col.inputExpr;
            continue;
        }
        if (auto belongs = cast(BelongsToInfo) expr) {
            // Collect join info for belongsTo hops
            joinPath = [JoinHop(
                belongs.childTable,
                belongs.parentTable,
                belongs.parentTypeName,
                belongs.fkColumn
            )] ~ joinPath;
            expr = belongs.inputExpr;
            continue;
        }
        if (auto hasMany = cast(HasManyInfo) expr) {
            expr = hasMany.inputExpr;
            continue;
        }
        if (auto ident = cast(IdentityExpr) expr) {
            // Identity doesn't continue the chain
            break;
        }

        // Unknown expression type
        break;
    }
    return null;
}

/// A single hop in a belongsTo chain (for JOIN generation)
struct JoinHop {
    string sourceTable;   // e.g., "posts"
    string targetTable;   // e.g., "users"
    string targetType;    // e.g., "User"
    string fk;            // e.g., "author_id"
}

// ============================================================================
// Base classes for runtime type checking
// ============================================================================

/// Interface for column access expressions (for chain walking)
interface ColumnAccessInfo {
    @property Expr!Ref inputExpr();
}

/// Interface for belongsTo expressions (for chain walking)
interface BelongsToInfo {
    @property Expr!Ref inputExpr();
    @property string childTable();
    @property string parentTable();
    @property string parentTypeName();
    @property string fkColumn();
}

/// Interface for hasMany expressions to expose their metadata.
interface HasManyInfo {
    /// The input expression (points to parent entity)
    @property Expr!Ref inputExpr();

    /// Foreign key column in child table
    @property string fkColumn();

    /// Child entity type name
    @property string childTypeName();

    /// Child table name
    @property string childTable();

    /// Parent entity type name (for ref encoding)
    @property string parentTypeName();
}

// ============================================================================
// Root Expressions
// ============================================================================

/// Interface for root expressions (GetByIds, GetAll) to expose filter info.
/// Used by optimizer to configure QueryNodes correctly.
interface RootExprInfo {
    /// The filter type (all, byIds)
    FilterType filterType();

    /// For byIds: the refs to filter by
    Ref[] filterRefs();

    /// Entity type name for the root query
    string entityTypeName();

    /// Entity table name for the root query
    string entityTable();
}

/// Root expression that returns specific entities by their IDs
class GetByIdsExpr(Entity) : Expr!(Ref[]), RootExprInfo {
    private Ref[] _refs;

    this(long[] ids) {
        _refs = ids.map!(id => makeRef(Entity._typeName, id)).array;
    }

    this(Ref[] refs) {
        _refs = refs;
    }

    override ExprBase[] dependencies() {
        return [];  // Root node
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies to replace
    }

    override Ref[][] eval(EvalContext ctx) {
        // One result (the same ref array) per parent in currentRefs
        auto parentCount = ctx.currentRefs.length;
        return iota(parentCount).map!(_ => _refs).array;
    }

    @property Ref[] refs() { return _refs; }

    // RootExprInfo implementation
    FilterType filterType() { return FilterType.byIds; }
    Ref[] filterRefs() { return _refs; }
    string entityTypeName() { return Entity._typeName; }
    string entityTable() { return Entity._table; }
}

/// Factory function to create GetByIdsExpr
auto getByIds(Entity)(long[] ids) {
    return new GetByIdsExpr!Entity(ids);
}

/// Root expression that fetches all entities of a type
class GetAllExpr(Entity) : Expr!(Ref[]), RootExprInfo {
    override ExprBase[] dependencies() {
        return [];  // Root node
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies to replace
    }

    override Ref[][] eval(EvalContext ctx) {
        // Fetch all IDs from data source, encode as refs
        auto relCtx = ctx.getSourceContext!RelationalEvalContext(Entity._sourceId);
        auto ids = relCtx.fetchAllIds(Entity._table);
        auto refs = ids.map!(id => makeRef(Entity._typeName, id)).array;
        // Return same refs for each parent in currentRefs
        auto parentCount = ctx.currentRefs.length;
        return iota(parentCount).map!(_ => refs).array;
    }

    // RootExprInfo implementation
    FilterType filterType() { return FilterType.all; }
    Ref[] filterRefs() { return []; }
    string entityTypeName() { return Entity._typeName; }
    string entityTable() { return Entity._table; }
}

/// Factory function to create GetAllExpr
auto getAll(Entity)() {
    return new GetAllExpr!Entity();
}

// ============================================================================
// Column Access Expression
// ============================================================================

/// Expression that reads a column from entities
class ColumnAccessExpr(T, Entity) : Expr!T {
    private ExprBase _input;  // the entity ref we're reading from (type-erased)
    string _column;

    this(Expr!Ref input, string column) {
        _input = input;
        _column = column;
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        // First optimize input
        _input = (cast(Expr!Ref) _input).optimize(ctx);

        // Find the MapExpr this column belongs to
        JoinHop[] joinPath;
        auto mapExpr = findMapExprFromChain(cast(Expr!Ref) _input, joinPath);

        if (mapExpr is null) {
            // Can't optimize, use naive path
            return this;
        }

        // Get the relational optimization context for this data source
        auto relCtx = ctx.getSourceContext!RelationalOptimizeContext(Entity._sourceId);

        // Get or create QueryNode for this MapExpr
        auto node = relCtx.getOrCreateNode(mapExpr, Entity._typeName, Entity._table);

        // Configure the node based on collection type (if not already configured)
        if (node.rootFilter == FilterType.none && node.parent is null) {
            if (auto mapInfo = cast(MapExprInfo) mapExpr) {
                auto coll = mapInfo.collection;

                // Check if collection is a root expression
                if (auto rootExpr = cast(RootExprInfo) coll) {
                    if (rootExpr.filterType == FilterType.byIds) {
                        node.setRootFilter(FilterType.byIds, rootExpr.filterRefs);
                    } else if (rootExpr.filterType == FilterType.all) {
                        node.setRootFilter(FilterType.all);
                    }
                }
                // Check if collection is a hasMany relationship
                else if (auto hasManyExpr = cast(HasManyInfo) coll) {
                    // Child of a hasMany relationship
                    // Find the parent MapExpr by following parentInput
                    JoinHop[] parentJoinPath;
                    auto parentMapExpr = findMapExprFromChain(hasManyExpr.inputExpr, parentJoinPath);
                    if (parentMapExpr !is null) {
                        auto parentNode = relCtx.getNode(parentMapExpr);
                        if (parentNode !is null) {
                            node.setParent(parentNode, hasManyExpr.fkColumn, hasManyExpr.parentTypeName);
                        }
                    }
                }
            }
        }

        if (joinPath.length == 0) {
            // Direct column access - return projection expression
            node.addColumn(_column);
            return new ProjectColumnExpr!T(node.id, _column);
        }

        // Access through belongsTo chain - add JOINs
        // Each hop: source table -> target table via FK
        string lastAlias;
        foreach (hop; joinPath) {
            // Add the FK column to ensure it's fetched (needed for JOIN)
            node.addColumn(hop.fk);
            // Add JOIN and get alias
            lastAlias = node.addJoin(hop.targetTable, hop.targetType, hop.fk);
        }

        // Track the column needed from the final joined table
        node.addJoinedColumn(lastAlias, _column);

        // Return projection that reads from the final joined table
        return new ProjectJoinedColumnExpr!T(node.id, lastAlias, _column);
    }

    override T[] eval(EvalContext ctx) {
        // Get the entity refs from the input chain
        Ref[] entityRefs = evalAs!Ref(_input, ctx);

        auto relCtx = ctx.getSourceContext!RelationalEvalContext(Entity._sourceId);
        if (relCtx.fetcher !is null) {
            return relCtx.fetcher.fetchColumn!T(Entity._table, _column, entityRefs);
        }

        // Fallback to empty results
        return entityRefs.map!(_ => T.init).array;
    }

    @property string column() { return _column; }
    @property ExprBase input() { return _input; }
}

// ============================================================================
// HasMany Access Expression
// ============================================================================

/// Expression representing a one-to-many relationship
/// Returns Ref[] for each input ref (the child entities)
class HasManyAccessExpr(Parent, Child, string fk) : Expr!(Ref[]), HasManyInfo {
    private ExprBase _input;

    this(Expr!Ref input) {
        _input = input;
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    override Expr!(Ref[]) optimize(OptimizeContext ctx) {
        _input = (cast(Expr!Ref) _input).optimize(ctx);
        // HasMany doesn't transform itself - the inner MapExpr's
        // access expressions will create a child QueryNode
        return this;
    }

    override Ref[][] eval(EvalContext ctx) {
        // Get the parent refs from the input chain
        Ref[] parentRefs = evalAs!Ref(_input, ctx);

        // Naive path: fetch children directly
        auto relCtx = ctx.getSourceContext!RelationalEvalContext(Child._sourceId);
        if (relCtx.fetcher !is null) {
            return relCtx.fetcher.fetchChildren(Child._table, Child._typeName, fk, parentRefs);
        }

        // Fallback to empty results
        return parentRefs.map!(_ => cast(Ref[])[]).array;
    }

    @property ExprBase input() { return _input; }

    // HasManyInfo implementation
    @property Expr!Ref inputExpr() { return cast(Expr!Ref) _input; }
    @property string childTable() { return Child._table; }
    @property string childTypeName() { return Child._typeName; }
    @property string fkColumn() { return fk; }
    static if (!is(Parent == void)) {
        @property string parentTypeName() { return Parent._typeName; }
    } else {
        @property string parentTypeName() { return ""; }
    }
}

// ============================================================================
// BelongsTo Access Expression
// ============================================================================

/// Expression representing a many-to-one relationship
/// Returns parent Ref for each child ref
class BelongsToAccessExpr(Child, Parent, RefType, string fk) : Expr!RefType, BelongsToInfo {
    private ExprBase _input;

    this(Expr!Ref input) {
        _input = input;
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    override Expr!RefType optimize(OptimizeContext ctx) {
        _input = (cast(Expr!Ref) _input).optimize(ctx);
        // BelongsTo stays as-is; column access through it uses JOINs
        return this;
    }

    override RefType[] eval(EvalContext ctx) {
        // Get the child refs from the input chain
        Ref[] childRefs = evalAs!Ref(_input, ctx);

        static if (is(Child == void)) {
            // Can't fetch without knowing child entity type
            return childRefs.map!(_ => RefType.init).array;
        } else {
            // Naive path: fetch parent refs directly
            auto relCtx = ctx.getSourceContext!RelationalEvalContext(Child._sourceId);
            if (relCtx.fetcher !is null) {
                auto parentRefs = relCtx.fetcher.fetchBelongsTo(Child._table, fk, Parent._typeName, childRefs);

                static if (is(RefType == Ref)) {
                    return parentRefs;
                } else static if (is(RefType == Nullable!Ref)) {
                    // Wrap in Nullable
                    return parentRefs.map!(r => r.isValid ? Nullable!Ref(r) : Nullable!Ref.init).array;
                } else {
                    static assert(false, "RefType must be Ref or Nullable!Ref");
                }
            }

            return childRefs.map!(_ => RefType.init).array;
        }
    }

    @property ExprBase input() { return _input; }

    // For base class interface (runtime type checking)
    @property Expr!Ref inputExpr() { return cast(Expr!Ref) _input; }
    static if (!is(Child == void)) {
        @property string childTable() { return Child._table; }
    } else {
        @property string childTable() { return ""; }
    }
    @property string parentTable() { return Parent._table; }
    @property string parentTypeName() { return Parent._typeName; }
    @property string fkColumn() { return fk; }
}

// ============================================================================
// Identity Expression (pass-through for Ref)
// ============================================================================

/// Expression that returns its input ref unchanged
/// Used when accessing fields directly from the iteration item
class IdentityExpr : Expr!Ref {
    override ExprBase[] dependencies() {
        return [];  // Leaf node
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies
    }

    override Ref[] eval(EvalContext ctx) {
        return ctx.currentRefs;
    }
}

/// Get the identity expression (returns input unchanged)
auto identity() {
    return new IdentityExpr();
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test Entity mixin
    struct User {
        mixin Entity!"users";
    }
    static assert(User._table == "users");
    static assert(User._typeName == "User");
    static assert(User._sourceId == "default");

    struct Post {
        mixin Entity!("posts", "BlogPost");
    }
    static assert(Post._table == "posts");
    static assert(Post._typeName == "BlogPost");
}

unittest {
    // Test column access with mock fetcher
    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);

    auto ctx = new EvalContext();
    auto relCtx = ctx.getSourceContext!RelationalEvalContext();
    relCtx.fetcher = fetcher;

    // Create an identity expression as input
    auto userExpr = identity();
    auto firstNameExpr = User.firstName(userExpr);

    ctx.currentRefs = [Ref("User:1"), Ref("User:2")];
    auto names = firstNameExpr.eval(ctx);
    assert(names == ["Alice", "Bob"]);
}

unittest {
    // Test hasMany relationship
    struct Post {
        mixin Entity!"posts";
    }

    struct User {
        mixin Entity!"users";
        mixin HasMany!("posts", Post, "author_id");
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 1, "title": "World"},
        {"id": 3, "author_id": 2, "title": "D Lang"}
    ]`);

    auto ctx = new EvalContext();
    auto relCtx = ctx.getSourceContext!RelationalEvalContext();
    relCtx.fetcher = fetcher;

    auto userExpr = identity();
    auto postsExpr = User.posts(userExpr);

    ctx.currentRefs = [Ref("User:1"), Ref("User:2")];
    auto postGroups = postsExpr.eval(ctx);

    assert(postGroups.length == 2);
    assert(postGroups[0].length == 2);  // User:1 has 2 posts
    assert(postGroups[1].length == 1);  // User:2 has 1 post
}

unittest {
    // Test belongsTo relationship
    struct User {
        mixin Entity!"users";
    }

    struct Post {
        mixin Entity!"posts";
        mixin BelongsTo!("author", User, "author_id");
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 10, "title": "Hello"},
        {"id": 2, "author_id": 20, "title": "World"}
    ]`);

    auto ctx = new EvalContext();
    auto relCtx = ctx.getSourceContext!RelationalEvalContext();
    relCtx.fetcher = fetcher;

    auto postExpr = identity();
    auto authorExpr = Post.author(postExpr);

    ctx.currentRefs = [Ref("Post:1"), Ref("Post:2")];
    auto authors = authorExpr.eval(ctx);

    assert(authors == [Ref("User:10"), Ref("User:20")]);
}

unittest {
    // Test chained access: post.author().firstName()
    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
    }

    struct Post {
        mixin Entity!"posts";
        mixin BelongsTo!("author", User, "author_id");

        // Computed field: access through relationship
        static auto authorName(Expr!Ref p) {
            return User.firstName(author(p));
        }
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 10},
        {"id": 2, "author_id": 20}
    ]`);
    fetcher.setTableData("users", `[
        {"id": 10, "first_name": "Alice"},
        {"id": 20, "first_name": "Bob"}
    ]`);

    auto ctx = new EvalContext();
    auto relCtx = ctx.getSourceContext!RelationalEvalContext();
    relCtx.fetcher = fetcher;

    auto postExpr = identity();
    auto authorNameExpr = Post.authorName(postExpr);

    ctx.currentRefs = [Ref("Post:1"), Ref("Post:2")];
    auto names = authorNameExpr.eval(ctx);

    assert(names == ["Alice", "Bob"]);
}

// Test optimization creates QueryNode
unittest {
    import std.json : parseJSON;

    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    // Build a simple query: map over users, get first + last name
    auto userRefs = getByIds!User([1, 2]);
    auto query = map!(
        (Expr!Ref user) => use(
            (string first, string last) => first ~ " " ~ last,
            User.firstName(user),
            User.lastName(user)
        )
    )(userRefs);

    // Optimize
    auto optCtx = new OptimizeContext();
    auto optimized = query.optimize(optCtx);

    // Check that a QueryNode was created
    auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();
    auto nodes = relCtx.allNodes();
    assert(nodes.length == 1);
    assert(nodes[0].typeName == "User");
    assert(nodes[0].table == "users");
    assert(nodes[0].columns.canFind("first_name"));
    assert(nodes[0].columns.canFind("last_name"));
}
