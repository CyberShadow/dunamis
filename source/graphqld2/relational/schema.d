module graphqld2.relational.schema;

import std.algorithm;
import std.array;
import std.conv;
import std.meta;
import std.range : iota;
import std.traits;
import std.typecons : Nullable;

import ae.utils.promise;

import graphqld2.core;
import graphqld2.relational.eval_context;
import graphqld2.relational.optimize_context;
import graphqld2.relational.project;
import graphqld2.relational.query_node;

// ============================================================================
// Query Root Mixin
// ============================================================================

/// Mixin to define a root query field that returns all entities of a type.
/// Used in a Query struct to define the schema's entry points.
///
/// The data source is derived from the Entity's _db alias, which is set
/// via the Entity mixin. This ensures consistency between the entity
/// definition and query access.
///
/// Example:
/// ---
/// // Module-level data source
/// static MyDB myDB;
///
/// struct User {
///     mixin Entity!(myDB, "users");  // Entity owns the data source
///     mixin Col!("email", string);
/// }
///
/// struct Query {
///     mixin Table!(User, "users");   // Derives db from User._db
///     mixin Table!(Post, "posts");
/// }
///
/// void main() {
///     myDB = new MyDB(connectionString);
///     auto query = map!(u => User.email(u))(Query.users());
/// }
/// ---
mixin template Table(Entity, string fieldName) {
    import graphqld2.core.expr : Expr;

    // Metadata for schema introspection (unique struct name per field)
    mixin("struct _tableField_" ~ fieldName ~ " {
        enum name = \"" ~ fieldName ~ "\";
        alias entityType = Entity;
    }");

    // Method follows unified root field signature: (Expr!Parent, Args...) -> Expr!T
    // The parent parameter is ignored but required for uniform interface
    mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) parent) {
        return getAll!Entity();
    }");
}

/// Convenience mixin to define multiple table fields at once.
/// Field names are derived from entity type names (lowercased + pluralized).
/// Data source is derived from each entity's _db alias.
///
/// Example:
/// ---
/// static MyDB myDB;
///
/// struct User { mixin Entity!(myDB, "users"); }
/// struct Post { mixin Entity!(myDB, "posts"); }
///
/// struct Query {
///     mixin Tables!(User, Post, Comment);
///     // Equivalent to:
///     // mixin Table!(User, "users");
///     // mixin Table!(Post, "posts");
///     // mixin Table!(Comment, "comments");
/// }
/// ---
mixin template Tables(Entities...) {
    static foreach (Entity; Entities) {
        mixin Table!(Entity, defaultFieldName!Entity);
    }
}

/// Derive default field name from entity type (lowercase + "s" suffix)
private template defaultFieldName(Entity) {
    enum defaultFieldName = () {
        string name = Entity._typeName;
        // Lowercase first character
        if (name.length > 0 && name[0] >= 'A' && name[0] <= 'Z') {
            return cast(char)(name[0] + 32) ~ name[1..$] ~ "s";
        }
        return name ~ "s";
    }();
}

// ============================================================================
// Entity Mixin (Low-level)
// ============================================================================

/// Low-level mixin to define an entity (table mapping).
/// The entity struct becomes a reference type - it holds a nodeId that identifies
/// a specific row in the database. Schema metadata is static, nodeId is runtime.
///
/// The data source is bound by alias, so it must be a static/module-level variable.
/// This allows both Table queries and mutations to access the same data source.
///
/// Example:
/// ---
/// static MyDB db;
///
/// struct User {
///     mixin Entity!(db, "users");
///     mixin Col!("id", long);
///     mixin PrimaryKey!"id";
///     mixin Col!("email", string);
/// }
///
/// // Composite primary key
/// struct OrderItem {
///     mixin Entity!(db, "order_items");
///     mixin Col!("orderId", long);
///     mixin Col!("productId", long);
///     mixin PrimaryKey!("orderId", "productId");
/// }
/// ---
mixin template Entity(alias db, string tableName, string typeName = "") {
    import std.string : indexOf;

    // Runtime state: the node ID that identifies this entity reference
    string nodeId;

    // Data source (bound by alias for runtime access)
    alias _db = db;

    // Schema metadata (compile-time)
    static immutable string _table = tableName;
    static immutable string _typeName = (typeName.length > 0) ? typeName : __traits(identifier, typeof(this));

    /// Extract the local ID portion (after the colon)
    string localId() const {
        auto sep = nodeId.indexOf(':');
        return sep >= 0 ? nodeId[sep + 1 .. $] : "";
    }

    /// Check if this is a valid (non-empty) reference
    bool isValid() const {
        return nodeId.length > 0;
    }

    /// For debugging
    string toString() const { return nodeId; }
}

// ============================================================================
// Primary Key Mixin
// ============================================================================

/// Marks one or more columns as the primary key.
/// The column(s) must be defined via Col mixin.
///
/// Example:
/// ---
/// mixin Col!("id", long);
/// mixin PrimaryKey!"id";
///
/// // Composite key
/// mixin Col!("orderId", long);
/// mixin Col!("productId", long);
/// mixin PrimaryKey!("orderId", "productId");
/// ---
mixin template PrimaryKey(columnNames...) {
    static assert(columnNames.length > 0, "PrimaryKey requires at least one column name");

    struct _primaryKey {
        static immutable string[] columns = [columnNames];
    }
}

// ============================================================================
// Foreign Key Type
// ============================================================================

/// Foreign key reference to another entity.
/// Use with Col to define FK columns that reference another entity's primary key.
///
/// Examples:
///   mixin Col!("authorId", ForeignKey!User);              // references users.id
///   mixin Col!("email", ForeignKey!(User, "email"));      // references users.email
///
/// Benefits:
/// - Type is derived from the referenced column's type
/// - DDL generation automatically creates FOREIGN KEY constraints
/// - Single source of truth for the relationship
struct ForeignKey(Entity, string idField = "id") {
    /// The referenced entity type
    alias referencedEntity = Entity;

    /// The referenced column name
    enum referencedColumn = idField;

    /// The underlying storage type (derived from referenced column's type)
    private alias _ColMeta = __traits(getMember, Entity, "_colField_" ~ idField);
    alias StorageType = _ColMeta.type;
}

/// Check if a type is a ForeignKey
template isForeignKey(T) {
    static if (is(T == ForeignKey!(E, col), E, string col)) {
        enum isForeignKey = true;
    } else {
        enum isForeignKey = false;
    }
}

/// Check if a type is a Nullable ForeignKey
template isNullableForeignKey(T) {
    static if (is(T == Nullable!(ForeignKey!(E, col)), E, string col)) {
        enum isNullableForeignKey = true;
    } else {
        enum isNullableForeignKey = false;
    }
}

/// Check if a type is any kind of ForeignKey (required or nullable)
template isAnyForeignKey(T) {
    enum isAnyForeignKey = isForeignKey!T || isNullableForeignKey!T;
}

/// Get the referenced entity from a ForeignKey type
template getForeignKeyEntity(T) {
    static if (is(T == ForeignKey!(E, col), E, string col)) {
        alias getForeignKeyEntity = E;
    } else static if (is(T == Nullable!(ForeignKey!(E, col)), E, string col)) {
        alias getForeignKeyEntity = E;
    } else {
        static assert(false, "Not a ForeignKey type");
    }
}

/// Get the inner ForeignKey type from a Nullable!(ForeignKey!(...))
template getInnerForeignKey(T) {
    static if (is(T == Nullable!(ForeignKey!(E, col)), E, string col)) {
        alias getInnerForeignKey = ForeignKey!(E, col);
    } else {
        static assert(false, "Not a Nullable ForeignKey type");
    }
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
///
/// Examples:
///   mixin Col!("firstName", string);                      // regular column
///   mixin Col!("authorId", ForeignKey!User);              // required FK
///   mixin Col!("editorId", Nullable!(ForeignKey!User));   // nullable FK
///   mixin Col!("createdAt", string, "created_at");        // explicit column name
mixin template Col(string fieldName, T, string columnName = toSnakeCase(fieldName)) {
    // Import helpers needed by the mixin (so they're visible at instantiation site)
    import graphqld2.relational.schema : isForeignKey, isNullableForeignKey, getForeignKeyEntity, getInnerForeignKey, column;
    import graphqld2.core.expr : Expr;

    // Determine FK properties at compile time (before string mixin)
    static if (isNullableForeignKey!T) {
        // Extract inner ForeignKey type from Nullable!(ForeignKey!(...))
        private alias _Col_InnerFk = getInnerForeignKey!T;
        private alias _Col_FkType = _Col_InnerFk.StorageType;
        private alias _Col_ReferencedEntity = _Col_InnerFk.referencedEntity;
        private enum _Col_ReferencedColumn = _Col_InnerFk.referencedColumn;
        private enum _Col_IsForeignKey = true;
        private enum _Col_IsNullable = true;
    } else static if (isForeignKey!T) {
        private alias _Col_FkType = T.StorageType;
        private alias _Col_ReferencedEntity = getForeignKeyEntity!T;
        private enum _Col_ReferencedColumn = T.referencedColumn;
        private enum _Col_IsForeignKey = true;
        private enum _Col_IsNullable = false;
    } else {
        private enum _Col_IsForeignKey = false;
        private enum _Col_IsNullable = false;
    }

    // Generate metadata struct
    static if (_Col_IsForeignKey) {
        mixin("struct _colField_" ~ fieldName ~ " {
            enum name = \"" ~ fieldName ~ "\";
            enum column = \"" ~ columnName ~ "\";
            alias type = _Col_FkType;
            enum isForeignKey = true;
            enum isNullable = _Col_IsNullable;
            alias referencedEntity = _Col_ReferencedEntity;
            enum referencedColumn = _Col_ReferencedColumn;
        }");

        // Typed accessor - takes Expr!Entity (entity IS the reference type now)
        mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
            return e.column!(_Col_FkType, typeof(this))(\"" ~ columnName ~ "\");
        }");
    } else {
        mixin("struct _colField_" ~ fieldName ~ " {
            enum name = \"" ~ fieldName ~ "\";
            enum column = \"" ~ columnName ~ "\";
            alias type = T;
            enum isForeignKey = false;
            enum isNullable = false;
        }");

        // Typed accessor - takes Expr!Entity (entity IS the reference type now)
        mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
            return e.column!(T, typeof(this))(\"" ~ columnName ~ "\");
        }");
    }
}

/// Mixin to define a hasMany relationship.
/// Example: mixin HasMany!("posts", Post, "author_id");
mixin template HasMany(string fieldName, Child, string fk) {
    import graphqld2.core.expr : Expr;

    // Metadata for schema introspection (unique struct name per field)
    mixin("struct _hasManyField_" ~ fieldName ~ " {
        enum name = \"" ~ fieldName ~ "\";
        enum foreignKey = \"" ~ fk ~ "\";
        alias childType = Child;
    }");

    // Typed accessor - takes Expr!Parent, returns Expr!(Child[])
    mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
        return e.hasMany!(Child, fk, typeof(this))();
    }");
}

/// Mixin to define a belongsTo relationship by referencing a FK column.
/// The parent entity type and nullability are derived from the FK column definition.
///
/// Examples:
///   mixin Col!("authorId", ForeignKey!User);              // required FK column
///   mixin BelongsTo!("author", "authorId");               // derives User, nullable=false
///
///   mixin Col!("editorId", Nullable!(ForeignKey!User));   // nullable FK column
///   mixin BelongsTo!("editor", "editorId");               // derives User, nullable=true
mixin template BelongsTo(string fieldName, string fkFieldName) {
    import graphqld2.core.expr : Expr;
    import std.typecons : Nullable;
    import graphqld2.relational.schema : belongsTo;

    // Look up the FK column metadata
    private alias _BelongsTo_FkMeta = __traits(getMember, typeof(this), "_colField_" ~ fkFieldName);

    // Verify it's a foreign key column
    static assert(_BelongsTo_FkMeta.isForeignKey,
        "Field '" ~ fkFieldName ~ "' must be a ForeignKey column for BelongsTo");

    // Extract properties from FK column metadata
    private alias _BelongsTo_Parent = _BelongsTo_FkMeta.referencedEntity;
    private enum _BelongsTo_FkColumn = _BelongsTo_FkMeta.column;
    private enum _BelongsTo_IsNullable = _BelongsTo_FkMeta.isNullable;

    // Generate metadata struct
    mixin("struct _belongsToField_" ~ fieldName ~ " {
        enum name = \"" ~ fieldName ~ "\";
        enum foreignKey = _BelongsTo_FkColumn;
        enum nullable = _BelongsTo_IsNullable;
        alias parentType = _BelongsTo_Parent;
    }");

    // Generate accessor method - typed with Child and Parent entities
    static if (_BelongsTo_IsNullable) {
        mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
            return e.belongsTo!(_BelongsTo_Parent, Nullable!_BelongsTo_Parent, _BelongsTo_FkColumn, typeof(this))();
        }");
    } else {
        mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
            return e.belongsTo!(_BelongsTo_Parent, _BelongsTo_Parent, _BelongsTo_FkColumn, typeof(this))();
        }");
    }
}

// ============================================================================
// UFCS Access Functions
// ============================================================================

/// Column access - reads a column value for each entity ref.
/// Takes typed Expr!Entity for compile-time type safety.
auto column(T, Entity)(Expr!Entity input, string name) {
    return new ColumnAccessExpr!(T, Entity)(input, name);
}

/// HasMany relationship - returns collection of child entities for each parent.
/// Takes typed Expr!Parent and returns Expr!(Child[]).
auto hasMany(Child, string fk, Parent)(Expr!Parent input) {
    return new HasManyAccessExpr!(Parent, Child, fk)(input);
}

/// BelongsTo relationship - returns parent entity for each child.
/// Takes typed Expr!Child and returns Expr!Parent or Expr!(Nullable!Parent).
/// ResultType should be Parent (required FK) or Nullable!Parent (optional FK).
auto belongsTo(Parent, ResultType = Parent, string fk, Child)(Expr!Child input) {
    return new BelongsToAccessExpr!(Child, Parent, ResultType, fk)(input);
}

// ============================================================================
// Helper: Find MapExpr from _input chain
// ============================================================================

/// Walk _input chain to find the owning MapExpr and collect join info.
/// Returns the MapExpr (as Object) or null if not found.
/// Also returns the base input expression (the one that produces refs for the
/// query node's base table) via the baseInput out parameter.
///
/// Accepts ExprBase to work with any Expr!Entity type.
private Object findMapExprFromChain(ExprBase expr, ref JoinHop[] joinPath, out ExprBase baseInput) {
    import graphqld2.core.expr : EveryItemOfExprInfo;

    // Track the first expression before any belongsTo chain starts
    // This produces refs for the query node's base table
    ExprBase lastBeforeBelongsTo = expr;
    bool inBelongsToChain = false;

    while (expr !is null) {
        // Check if we've reached EveryItemOfExpr (any instantiation)
        if (auto every = cast(EveryItemOfExprInfo) expr) {
            baseInput = inBelongsToChain ? lastBeforeBelongsTo : expr;
            return every.parentMap;
        }

        // Walk through access expressions using interfaces
        if (auto col = cast(ColumnAccessInfo) expr) {
            expr = col.inputExpr;
            continue;
        }
        if (auto belongs = cast(BelongsToInfo) expr) {
            // When entering a belongsTo chain, save the input that produces base entity refs
            if (!inBelongsToChain) {
                lastBeforeBelongsTo = belongs.inputExpr;
                inBelongsToChain = true;
            }
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
        // Unknown expression type
        break;
    }
    baseInput = null;
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
    @property ExprBase inputExpr();
}

/// Interface for belongsTo expressions (for chain walking)
interface BelongsToInfo {
    @property ExprBase inputExpr();
    @property string childTable();
    @property string parentTable();
    @property string parentTypeName();
    @property string fkColumn();
}

/// Interface for hasMany expressions to expose their metadata.
interface HasManyInfo {
    /// The input expression (points to parent entity)
    @property ExprBase inputExpr();

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
    AnyRef[] filterRefs();

    /// Entity type name for the root query
    string entityTypeName();

    /// Entity table name for the root query
    string entityTable();

    /// The data fetcher for this root (may be null for legacy usage)
    DataFetcher dataFetcher();
}

/// Source ID for an entity - uses table name as unique identifier.
/// This is used to key into RelationalEvalContext for multi-source scenarios.
template entitySourceId(Entity) {
    enum entitySourceId = Entity._table;
}

/// Root expression that returns specific entities by their IDs.
/// Returns typed Entity[] for compile-time type safety.
/// Uses Entity._db for data source access.
class GetByIdsExpr(Entity) : Expr!(Entity[]), RootExprInfo {
    import graphqld2.core.optimize : ExprOptimizer;

    private Entity[] _entities;

    /// Construct from array of IDs (any type convertible to string)
    this(IdType)(IdType[] ids) {
        _entities = ids.map!(id => Entity(Entity._typeName ~ ":" ~ id.to!string)).array;
    }

    this(Entity[] entities) {
        _entities = entities;
    }

    override ExprBase[] dependencies() {
        return [];  // Root node
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies to replace
    }

    override ExprOptimizer[] requestedOptimizers() {
        // Get fetcher from Entity's data source
        auto fetcher = Entity._db;
        if (fetcher !is null) {
            return fetcher.requestedOptimizers();
        }
        return [];
    }

    override Promise!(Entity[][]) eval(EvalContext ctx) {
        // Set up RelationalEvalContext with fetcher from Entity._db
        auto fetcher = Entity._db;
        if (fetcher !is null) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext();
            if (relCtx.fetcher is null) {
                relCtx.fetcher = fetcher;
            }
        }
        // At root level, there's always exactly 1 parent (queryRoot)
        return resolve([_entities]);
    }

    @property Entity[] entities() { return _entities; }

    // RootExprInfo implementation
    FilterType filterType() { return FilterType.byIds; }
    AnyRef[] filterRefs() { return _entities.map!(e => AnyRef(e.nodeId)).array; }
    string entityTypeName() { return Entity._typeName; }
    string entityTable() { return Entity._table; }
    DataFetcher dataFetcher() { return Entity._db; }
}

/// Factory function to create GetByIdsExpr (works with any ID type)
auto getByIds(Entity, IdType)(IdType[] ids) {
    return new GetByIdsExpr!Entity(ids);
}

/// Factory function to create GetByIdsExpr for composite keys.
/// Takes an array of key-part arrays, e.g. [[1, 100], [1, 101]] for orderId, productId.
auto getByCompositeIds(Entity, IdType)(IdType[][] keyParts) {
    import graphqld2.core.types : encodeCompositeKey;

    Entity[] entities;
    foreach (parts; keyParts) {
        string[] strParts;
        foreach (p; parts) {
            strParts ~= p.to!string;
        }
        entities ~= Entity(Entity._typeName ~ ":" ~ encodeCompositeKey(strParts));
    }
    return new GetByIdsExpr!Entity(entities);
}

/// Root expression that fetches all entities of a type.
/// Returns typed Entity[] for compile-time type safety.
/// Uses Entity._db for data source access.
///
/// In the optimized path, a PrefetchExpr is created during optimization
/// and used during eval to ensure data is fetched before reading refs.
class GetAllExpr(Entity) : Expr!(Entity[]), RootExprInfo, MapExprInfo {
    import graphqld2.core.optimize : ExprOptimizer, OptimizeContext;

    private {
        PrefetchExpr _prefetch;  // Set during optimization
        int _queryNodeId = -1;   // QueryNode ID for optimized path
    }

    this() {}

    override ExprBase[] dependencies() {
        return _prefetch !is null ? [_prefetch] : [];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0 && _prefetch !is null) {
            _prefetch = cast(PrefetchExpr) newDep;
        }
    }

    override ExprOptimizer[] requestedOptimizers() {
        auto fetcher = Entity._db;
        if (fetcher !is null) {
            return fetcher.requestedOptimizers();
        }
        return [];
    }

    override Expr!(Entity[]) optimize(OptimizeContext ctx) {
        // Try to find an existing QueryNode created by ColumnAccessExpr optimizations
        // (body is optimized before collection in MapExpr)
        auto fetcher = Entity._db;
        if (fetcher is null) return this;

        auto relCtx = ctx.getSourceContext!RelationalOptimizeContext();

        // Look for a root node that matches our entity type and table
        auto node = relCtx.findRootNode(Entity._typeName, Entity._table);

        if (node is null) {
            // No node found - we're in a context where column access doesn't use optimization
            // (e.g., computed fields that don't access columns)
            // Fall back to naive path
            return this;
        }

        // Use the existing node's prefetch
        _prefetch = relCtx.getPrefetchExpr(node);
        _queryNodeId = node.id;

        return this;
    }

    override Promise!(Entity[][]) eval(EvalContext ctx) {
        auto fetcher = Entity._db;

        // Set up RelationalEvalContext with fetcher
        if (fetcher !is null) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext();
            if (relCtx.fetcher is null) {
                relCtx.fetcher = fetcher;
            }
        }

        // Optimized path: use PrefetchExpr to fetch data, then read refs
        if (_prefetch !is null) {
            return evalAs!(AnyRef[])(_prefetch, ctx).then((AnyRef[][] prefetchResults) {
                // PrefetchExpr returns refs from the QueryResult
                auto refs = prefetchResults.length > 0 ? prefetchResults[0] : [];
                // Convert AnyRef to Entity - refs already have the full nodeId
                auto entities = refs.map!(r => Entity(r.nodeId)).array;
                return [entities];
            });
        }

        // Fallback: naive path using fetchAllIds
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();
        auto ids = relCtx.fetchAllIds(Entity._table);
        auto entities = ids.map!(id => Entity(Entity._typeName ~ ":" ~ id.to!string)).array;
        // At root level, there's always exactly 1 parent (queryRoot)
        return resolve([entities]);
    }

    // RootExprInfo implementation
    FilterType filterType() { return FilterType.all; }
    AnyRef[] filterRefs() { return []; }
    string entityTypeName() { return Entity._typeName; }
    string entityTable() { return Entity._table; }
    DataFetcher dataFetcher() { return Entity._db; }

    // MapExprInfo implementation (for QueryNode creation)
    Object collection() { return this; }  // We are the root, return self as collection
}

/// Factory function to create GetAllExpr
auto getAll(Entity)() {
    return new GetAllExpr!Entity();
}

// ============================================================================
// Column Access Expression
// ============================================================================

/// Expression that reads a column from entities.
/// Takes typed Expr!Entity for type safety.
class ColumnAccessExpr(T, Entity) : Expr!T {
    private ExprBase _input;  // the entity we're reading from (type-erased for storage)
    string _column;

    this(Expr!Entity input, string column) {
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
        _input = (cast(Expr!Entity) _input).optimize(ctx);

        // Find the MapExpr this column belongs to
        JoinHop[] joinPath;
        ExprBase baseInput;
        auto mapExpr = findMapExprFromChain(_input, joinPath, baseInput);

        if (mapExpr is null) {
            // Can't optimize, use naive path
            return this;
        }

        // Get the relational optimization context for this data source
        auto relCtx = ctx.getSourceContext!RelationalOptimizeContext();

        // Get or create QueryNode for this MapExpr
        auto node = relCtx.getOrCreateNode(mapExpr, Entity._typeName, Entity._table);

        // Set the data fetcher on the node (for mutation-returned entities that bypass GetByIdsExpr)
        if (node.dataFetcher is null && Entity._db !is null) {
            node.dataFetcher = Entity._db;
        }

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
                    ExprBase parentBaseInput;
                    auto parentMapExpr = findMapExprFromChain(hasManyExpr.inputExpr, parentJoinPath, parentBaseInput);
                    if (parentMapExpr !is null) {
                        auto parentNode = relCtx.getNode(parentMapExpr);
                        if (parentNode !is null) {
                            node.setParent(parentNode, hasManyExpr.fkColumn, hasManyExpr.parentTypeName);
                        }
                    }
                }
            }
        }

        // Get the PrefetchExpr for this node
        auto prefetch = relCtx.getPrefetchExpr(node);

        if (joinPath.length == 0) {
            // Direct column access - return projection expression
            node.addColumn(_column);
            return new ProjectColumnExpr!T(node.id, _column, _input, prefetch);
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
        // Use baseInput (the expression that produces refs for the base table)
        // not _input (which may be a belongsTo that produces refs for a different table)
        return new ProjectJoinedColumnExpr!T(node.id, lastAlias, _column, baseInput, prefetch);
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto column = _column;
        auto input = _input;

        // Ensure fetcher is set up from Entity's data source
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();
        if (relCtx.fetcher is null && Entity._db !is null) {
            relCtx.fetcher = Entity._db;
        }

        // Get the entity refs from the input chain, then fetch column
        return evalRefAsAnyRef(input, ctx).then((AnyRef[] entityRefs) {
            // First, check for mutation results (mutations store their results here)
            if (relCtx.hasMutationResult(Entity._typeName)) {
                return relCtx.getMutationColumnValues!T(Entity._typeName, column, entityRefs);
            }

            // Otherwise, fetch from database
            if (relCtx.fetcher !is null) {
                return relCtx.fetcher.fetchColumn!T(Entity._table, column, entityRefs);
            }

            // Fallback to empty results
            return entityRefs.map!(_ => T.init).array;
        });
    }

    @property string column() { return _column; }
    @property ExprBase input() { return _input; }
}

// ============================================================================
// HasMany Access Expression
// ============================================================================

/// Expression representing a one-to-many relationship.
/// Takes typed Parent input, returns typed Child[] for each parent.
class HasManyAccessExpr(Parent, Child, string fk) : Expr!(Child[]), HasManyInfo {
    private ExprBase _input;

    static if (!is(Parent == void)) {
        this(Expr!Parent input) {
            _input = input;
        }
    } else {
        this(ExprBase input) {
            _input = input;
        }
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    static if (!is(Parent == void)) {
        override Expr!(Child[]) optimize(OptimizeContext ctx) {
            _input = (cast(Expr!Parent) _input).optimize(ctx);
            // HasMany doesn't transform itself - the inner MapExpr's
            // access expressions will create a child QueryNode
            return this;
        }
    } else {
        override Expr!(Child[]) optimize(OptimizeContext ctx) {
            // Can't optimize input without Parent type
            return this;
        }
    }

    override Promise!(Child[][]) eval(EvalContext ctx) {
        auto input = _input;

        // Ensure fetcher is set up from Child entity's data source
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();
        if (relCtx.fetcher is null && Child._db !is null) {
            relCtx.fetcher = Child._db;
        }

        // Get the parent refs from the input chain, then fetch children
        return evalRefAsAnyRef(input, ctx).then((AnyRef[] parentRefs) {
            // Naive path: fetch children directly
            if (relCtx.fetcher !is null) {
                auto children = relCtx.fetcher.fetchChildren(Child._table, Child._typeName, fk, parentRefs);
                // Convert AnyRef[][] to Child[][]
                return children.map!(group => group.map!(r => Child(r.nodeId)).array).array;
            }

            // Fallback to empty results
            return parentRefs.map!(_ => cast(Child[])[]).array;
        });
    }

    @property ExprBase input() { return _input; }

    // HasManyInfo implementation
    @property ExprBase inputExpr() { return _input; }
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

/// Expression representing a many-to-one relationship.
/// Takes typed Child input, returns typed Parent for each child.
/// ResultType is either Parent (required FK) or Nullable!Parent (optional FK).
/// Implements AnyRefEvaluable for type-agnostic evaluation by downstream expressions.
class BelongsToAccessExpr(Child, Parent, ResultType, string fk) : Expr!ResultType, BelongsToInfo, AnyRefEvaluable {
    private ExprBase _input;

    static if (!is(Child == void)) {
        this(Expr!Child input) {
            _input = input;
        }
    } else {
        this(ExprBase input) {
            _input = input;
        }
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    static if (!is(Child == void)) {
        override Expr!ResultType optimize(OptimizeContext ctx) {
            _input = (cast(Expr!Child) _input).optimize(ctx);
            // BelongsTo stays as-is; column access through it uses JOINs
            return this;
        }
    } else {
        override Expr!ResultType optimize(OptimizeContext ctx) {
            return this;
        }
    }

    /// Evaluate and return as AnyRef[] (for type-agnostic internal use).
    /// Converts typed Parent to AnyRef, handling Nullable properly.
    Promise!(AnyRef[]) evalAsAnyRef(EvalContext ctx) {
        return this.eval(ctx).then((ResultType[] results) {
            static if (is(ResultType == Parent)) {
                // Direct conversion from entity to AnyRef via nodeId
                return results.map!(r => AnyRef(r.nodeId)).array;
            } else static if (is(ResultType == Nullable!Parent)) {
                // Handle nullable - convert valid refs, use AnyRef.init for null
                return results.map!(r => r.isNull ? AnyRef.init : AnyRef(r.get.nodeId)).array;
            } else {
                static assert(false, "Unexpected ResultType in BelongsToAccessExpr");
            }
        });
    }

    override Promise!(ResultType[]) eval(EvalContext ctx) {
        auto input = _input;

        // Ensure fetcher is set up from Child entity's data source
        static if (!is(Child == void)) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext();
            if (relCtx.fetcher is null && Child._db !is null) {
                relCtx.fetcher = Child._db;
            }
        }

        // Get the child refs from the input chain, then fetch parent
        return evalRefAsAnyRef(input, ctx).then((AnyRef[] childRefs) {
            static if (is(Child == void)) {
                // Can't fetch without knowing child entity type
                return childRefs.map!(_ => ResultType.init).array;
            } else {
                // Naive path: fetch parent refs directly
                auto relCtx = ctx.getSourceContext!RelationalEvalContext();
                if (relCtx.fetcher !is null) {
                    auto parentRefs = relCtx.fetcher.fetchBelongsTo(Child._table, fk, Parent._typeName, childRefs);

                    static if (is(ResultType == Parent)) {
                        // Convert AnyRef[] to Parent[] via nodeId
                        return parentRefs.map!(r => Parent(r.nodeId)).array;
                    } else static if (is(ResultType == Nullable!Parent)) {
                        // Wrap in Nullable, handling invalid refs as null
                        return parentRefs.map!(r => r.isValid ? Nullable!Parent(Parent(r.nodeId)) : Nullable!Parent.init).array;
                    } else {
                        static assert(false, "ResultType must be Parent or Nullable!Parent");
                    }
                }

                return childRefs.map!(_ => ResultType.init).array;
            }
        });
    }

    @property ExprBase input() { return _input; }

    // For base class interface (runtime type checking)
    @property ExprBase inputExpr() { return _input; }
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
// Tests
// ============================================================================

unittest {
    import graphqld2.relational.demo : MockDB;

    // Dummy db for compile-time tests
    static MockDB!() db;

    // Test low-level Entity mixin (no id column)
    static struct User {
        mixin Entity!(db, "users");
        mixin Col!("id", long);
        mixin PrimaryKey!"id";
    }
    static assert(User._table == "users");
    static assert(User._typeName == "User");
    static assert(is(User._colField_id.type == long));

    // Test Entity with custom type name
    static struct Post {
        mixin Entity!(db, "posts", "BlogPost");
        mixin Col!("id", long);
        mixin PrimaryKey!"id";
    }
    static assert(Post._table == "posts");
    static assert(Post._typeName == "BlogPost");
    static assert(is(Post._colField_id.type == long));
}

unittest {
    import graphqld2.relational.demo : DemoEntity, Int64, MockDB;

    static MockDB!() db;

    // Test DemoEntity convenience (includes id column with Int64 type)
    static struct Comment {
        mixin DemoEntity!(db, "comments");
    }
    static assert(Comment._table == "comments");
    static assert(is(Comment._colField_id.type == Int64));

    // Test DemoEntity with custom ID type
    static struct UuidEntity {
        mixin DemoEntity!(db, "items", string);
    }
    static assert(is(UuidEntity._colField_id.type == string));
}

// Test optimization creates QueryNode
unittest {
    import std.json : parseJSON;
    import graphqld2.relational.demo : DemoEntity, MockDB;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    db = new MockDB!();

    // Build a simple query: map over users, get first + last name
    auto userRefs = getByIds!User([1, 2]);
    auto query = map!(
        (Expr!User user) => use(
            (string first, string last) => first ~ " " ~ last,
            user.firstName,
            user.lastName
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

// Test end-to-end with string (UUID) primary keys
unittest {
    import std.json : parseJSON;
    import ae.utils.promise.await : awaitSync;
    import graphqld2.relational.demo : DemoEntity, MockDB;

    static MockDB!() db;

    // Entity with string ID (UUID-style)
    static struct Item {
        mixin DemoEntity!(db, "items", string);
        mixin Col!("name", string);
    }

    // Set up mock data with string IDs
    db = new MockDB!();
    db.setTableData("items", `[
        {"id": "uuid-abc", "name": "First Item"},
        {"id": "uuid-def", "name": "Second Item"}
    ]`);

    // Query by string IDs
    auto query = map!(
        (Expr!Item item) => item.name
    )(getByIds!Item(["uuid-abc", "uuid-def"]));

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query, true));

    assert(result.length == 2);
    assert(result[0] == "First Item");
    assert(result[1] == "Second Item");
}

// Test belongsTo with string FKs
unittest {
    import std.json : parseJSON;
    import ae.utils.promise.await : awaitSync;
    import graphqld2.relational.demo : DemoEntity, MockDB;

    static MockDB!() db;

    static struct Category {
        mixin DemoEntity!(db, "categories", string);
        mixin Col!("name", string);
    }

    static struct Product {
        mixin DemoEntity!(db, "products", string);
        mixin Col!("name", string);
        mixin Col!("categoryId", ForeignKey!Category);
        mixin BelongsTo!("category", "categoryId");
    }

    db = new MockDB!();
    db.setTableData("categories", `[
        {"id": "cat-1", "name": "Electronics"},
        {"id": "cat-2", "name": "Books"}
    ]`);
    db.setTableData("products", `[
        {"id": "prod-a", "category_id": "cat-1", "name": "Phone"},
        {"id": "prod-b", "category_id": "cat-2", "name": "Novel"}
    ]`);

    auto query = map!(
        (Expr!Product prod) => jsonObject(
            "name", prod.name,
            "categoryName", prod.category.name
        )
    )(getByIds!Product(["prod-a", "prod-b"]));

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query, true));

    assert(result.length == 2);
    assert(result[0]["name"].str == "Phone");
    assert(result[0]["categoryName"].str == "Electronics");
    assert(result[1]["name"].str == "Novel");
    assert(result[1]["categoryName"].str == "Books");
}

// Test composite primary keys end-to-end
unittest {
    import std.json : parseJSON;
    import ae.utils.promise.await : awaitSync;
    import graphqld2.core.types : encodeCompositeKey;
    import graphqld2.relational.demo : MockDB;

    static MockDB!() db;

    // Entity with composite primary key (order_id + product_id)
    static struct OrderItem {
        mixin Entity!(db, "order_items");

        // Define the composite key columns
        mixin Col!("orderId", long);
        mixin Col!("productId", long);
        mixin PrimaryKey!("orderId", "productId");

        // Other columns
        mixin Col!("quantity", long);
        mixin Col!("price", string);  // Use string for decimal
    }

    // Verify composite key metadata
    static assert(OrderItem._primaryKey.columns == ["orderId", "productId"]);
    static assert(OrderItem._table == "order_items");
    static assert(OrderItem._typeName == "OrderItem");

    // Set up mock data
    db = new MockDB!();
    db.setPrimaryKey("order_items", "order_id", "product_id");
    db.setTableData("order_items", `[
        {"order_id": 1, "product_id": 100, "quantity": 2, "price": "10.00"},
        {"order_id": 1, "product_id": 101, "quantity": 1, "price": "25.00"},
        {"order_id": 2, "product_id": 100, "quantity": 3, "price": "10.00"}
    ]`);

    // Query using pre-encoded composite keys
    auto refs = [
        OrderItem("OrderItem:1,100"),  // order 1, product 100
        OrderItem("OrderItem:1,101")   // order 1, product 101
    ];

    auto query = map!(
        (Expr!OrderItem item) => jsonObject(
            "quantity", item.quantity,
            "price", item.price
        )
    )(new GetByIdsExpr!OrderItem(refs));

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query, true));

    assert(result.length == 2);
    assert(result[0]["quantity"].integer == 2);
    assert(result[0]["price"].str == "10.00");
    assert(result[1]["quantity"].integer == 1);
    assert(result[1]["price"].str == "25.00");
}

// Test getByCompositeIds helper function
unittest {
    import std.json : parseJSON;
    import ae.utils.promise.await : awaitSync;
    import graphqld2.relational.demo : MockDB;

    static MockDB!() db;

    static struct OrderItem {
        mixin Entity!(db, "order_items");
        mixin Col!("orderId", long);
        mixin Col!("productId", long);
        mixin PrimaryKey!("orderId", "productId");
        mixin Col!("quantity", long);
    }

    db = new MockDB!();
    db.setPrimaryKey("order_items", "order_id", "product_id");
    db.setTableData("order_items", `[
        {"order_id": 1, "product_id": 100, "quantity": 2},
        {"order_id": 1, "product_id": 101, "quantity": 1},
        {"order_id": 2, "product_id": 100, "quantity": 3}
    ]`);

    // Use getByCompositeIds helper with array of key-parts
    auto query = map!(
        (Expr!OrderItem item) => item.quantity
    )(getByCompositeIds!OrderItem([[1, 100], [2, 100]]));

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query, true));

    assert(result.length == 2);
    assert(result[0] == 2);  // order 1, product 100 -> quantity 2
    assert(result[1] == 3);  // order 2, product 100 -> quantity 3
}
