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
/// Example:
/// ---
/// struct Query {
///     mixin Table!(User, "users");   // generates: static auto users(db) => getAll!User(db)
///     mixin Table!(Post, "posts");
/// }
///
/// auto query = map!(u => User.firstName(u))(Query.users(db));
/// ---
mixin template Table(Entity, string fieldName) {
    // Metadata for schema introspection (unique struct name per field)
    mixin("struct _tableField_" ~ fieldName ~ " {
        enum name = \"" ~ fieldName ~ "\";
        alias entityType = Entity;
    }");

    mixin("static auto " ~ fieldName ~ "(DataFetcher db) {
        return getAll!Entity(db);
    }");
}

// ============================================================================
// Entity Mixin (Low-level)
// ============================================================================

/// Low-level mixin to define an entity (table mapping).
/// Only provides table metadata - no columns are added automatically.
/// Use with Col and PrimaryKey mixins to define the schema.
///
/// Example:
/// ---
/// struct User {
///     mixin Entity!"users";
///     mixin Col!("id", long);
///     mixin PrimaryKey!"id";
///     mixin Col!("email", string);
/// }
///
/// // Composite primary key
/// struct OrderItem {
///     mixin Entity!"order_items";
///     mixin Col!("orderId", long);
///     mixin Col!("productId", long);
///     mixin PrimaryKey!("orderId", "productId");
/// }
/// ---
mixin template Entity(string tableName, string typeName = "", string sourceId = "default") {
    static immutable string _table = tableName;
    static immutable string _typeName = (typeName.length > 0) ? typeName : __traits(identifier, typeof(this));
    static immutable string _sourceId = sourceId;
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

        mixin("static auto " ~ fieldName ~ "(Expr!Ref e) {
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

        mixin("static auto " ~ fieldName ~ "(Expr!Ref e) {
            return e.column!(T, typeof(this))(\"" ~ columnName ~ "\");
        }");
    }
}

/// Mixin to define a hasMany relationship.
/// Example: mixin HasMany!("posts", Post, "author_id");
mixin template HasMany(string fieldName, Child, string fk) {
    // Metadata for schema introspection (unique struct name per field)
    mixin("struct _hasManyField_" ~ fieldName ~ " {
        enum name = \"" ~ fieldName ~ "\";
        enum foreignKey = \"" ~ fk ~ "\";
        alias childType = Child;
    }");

    mixin("static auto " ~ fieldName ~ "(Expr!Ref e) {
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

    // Generate accessor method
    static if (_BelongsTo_IsNullable) {
        mixin("static auto " ~ fieldName ~ "(Expr!Ref e) {
            return e.belongsTo!(_BelongsTo_Parent, Nullable!Ref, _BelongsTo_FkColumn, typeof(this))();
        }");
    } else {
        mixin("static auto " ~ fieldName ~ "(Expr!Ref e) {
            return e.belongsTo!(_BelongsTo_Parent, Ref, _BelongsTo_FkColumn, typeof(this))();
        }");
    }
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
/// Also returns the base input expression (the one that produces refs for the
/// query node's base table) via the baseInput out parameter.
private Object findMapExprFromChain(Expr!Ref expr, ref JoinHop[] joinPath, out Expr!Ref baseInput) {
    // Track the first expression before any belongsTo chain starts
    // This produces refs for the query node's base table
    Expr!Ref lastBeforeBelongsTo = expr;
    bool inBelongsToChain = false;

    while (expr !is null) {
        // Check if we've reached EveryItemOfExpr
        if (auto every = cast(EveryItemOfExpr) expr) {
            baseInput = inBelongsToChain ? lastBeforeBelongsTo : every;
            return every._parentMap;
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

    /// The data fetcher for this root (may be null for legacy usage)
    DataFetcher dataFetcher();
}

/// Root expression that returns specific entities by their IDs
class GetByIdsExpr(Entity) : Expr!(Ref[]), RootExprInfo {
    import graphqld2.core.optimize : ExprOptimizer;

    private Ref[] _refs;
    private DataFetcher _fetcher;

    /// Construct from array of IDs (any type convertible to string)
    this(IdType)(IdType[] ids, DataFetcher fetcher = null) {
        _refs = ids.map!(id => makeRef(Entity._typeName, id.to!string)).array;
        _fetcher = fetcher;
    }

    this(Ref[] refs, DataFetcher fetcher = null) {
        _refs = refs;
        _fetcher = fetcher;
    }

    override ExprBase[] dependencies() {
        return [];  // Root node
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies to replace
    }

    override ExprOptimizer[] requestedOptimizers() {
        if (_fetcher !is null) {
            return _fetcher.requestedOptimizers();
        }
        return [];
    }

    override Promise!(Ref[][]) eval(EvalContext ctx) {
        // Set up RelationalEvalContext with fetcher if we have one
        if (_fetcher !is null) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext(Entity._sourceId);
            if (relCtx.fetcher is null) {
                relCtx.fetcher = _fetcher;
            }
        }
        // At root level, there's always exactly 1 parent (queryRoot)
        return resolve([_refs]);
    }

    @property Ref[] refs() { return _refs; }

    // RootExprInfo implementation
    FilterType filterType() { return FilterType.byIds; }
    Ref[] filterRefs() { return _refs; }
    string entityTypeName() { return Entity._typeName; }
    string entityTable() { return Entity._table; }
    DataFetcher dataFetcher() { return _fetcher; }
}

/// Factory function to create GetByIdsExpr (works with any ID type)
auto getByIds(Entity, IdType)(IdType[] ids) {
    return new GetByIdsExpr!Entity(ids);
}

/// Factory function to create GetByIdsExpr with a data fetcher
auto getByIds(Entity, IdType)(IdType[] ids, DataFetcher fetcher) {
    return new GetByIdsExpr!Entity(ids, fetcher);
}

/// Factory function to create GetByIdsExpr for composite keys.
/// Takes an array of key-part arrays, e.g. [[1, 100], [1, 101]] for orderId, productId.
auto getByCompositeIds(Entity, IdType)(IdType[][] keyParts, DataFetcher fetcher = null) {
    import graphqld2.core.types : encodeCompositeKey;

    Ref[] refs;
    foreach (parts; keyParts) {
        string[] strParts;
        foreach (p; parts) {
            strParts ~= p.to!string;
        }
        string keyStr = strParts.length == 1 ? strParts[0] : encodeCompositeKey(strParts);
        refs ~= makeRef(Entity._typeName, keyStr);
    }
    return new GetByIdsExpr!Entity(refs, fetcher);
}

/// Root expression that fetches all entities of a type
class GetAllExpr(Entity) : Expr!(Ref[]), RootExprInfo {
    import graphqld2.core.optimize : ExprOptimizer;

    private DataFetcher _fetcher;

    this(DataFetcher fetcher = null) {
        _fetcher = fetcher;
    }

    override ExprBase[] dependencies() {
        return [];  // Root node
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies to replace
    }

    override ExprOptimizer[] requestedOptimizers() {
        if (_fetcher !is null) {
            return _fetcher.requestedOptimizers();
        }
        return [];
    }

    override Promise!(Ref[][]) eval(EvalContext ctx) {
        // Set up RelationalEvalContext with fetcher if we have one
        if (_fetcher !is null) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext(Entity._sourceId);
            if (relCtx.fetcher is null) {
                relCtx.fetcher = _fetcher;
            }
        }

        // Fetch all IDs from data source, encode as refs
        auto relCtx = ctx.getSourceContext!RelationalEvalContext(Entity._sourceId);
        auto ids = relCtx.fetchAllIds(Entity._table);
        auto refs = ids.map!(id => makeRef(Entity._typeName, id)).array;
        // At root level, there's always exactly 1 parent (queryRoot)
        return resolve([refs]);
    }

    // RootExprInfo implementation
    FilterType filterType() { return FilterType.all; }
    Ref[] filterRefs() { return []; }
    string entityTypeName() { return Entity._typeName; }
    string entityTable() { return Entity._table; }
    DataFetcher dataFetcher() { return _fetcher; }
}

/// Factory function to create GetAllExpr
auto getAll(Entity)() {
    return new GetAllExpr!Entity();
}

/// Factory function to create GetAllExpr with a data fetcher
auto getAll(Entity)(DataFetcher fetcher) {
    return new GetAllExpr!Entity(fetcher);
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
        Expr!Ref baseInput;
        auto mapExpr = findMapExprFromChain(cast(Expr!Ref) _input, joinPath, baseInput);

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
                    Expr!Ref parentBaseInput;
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
            return new ProjectColumnExpr!T(node.id, _column, cast(Expr!Ref) _input, prefetch);
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

        // Get the entity refs from the input chain, then fetch column
        return evalAs!Ref(input, ctx).then((Ref[] entityRefs) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext(Entity._sourceId);
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

    override Promise!(Ref[][]) eval(EvalContext ctx) {
        auto input = _input;

        // Get the parent refs from the input chain, then fetch children
        return evalAs!Ref(input, ctx).then((Ref[] parentRefs) {
            // Naive path: fetch children directly
            auto relCtx = ctx.getSourceContext!RelationalEvalContext(Child._sourceId);
            if (relCtx.fetcher !is null) {
                return relCtx.fetcher.fetchChildren(Child._table, Child._typeName, fk, parentRefs);
            }

            // Fallback to empty results
            return parentRefs.map!(_ => cast(Ref[])[]).array;
        });
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

    override Promise!(RefType[]) eval(EvalContext ctx) {
        auto input = _input;

        // Get the child refs from the input chain, then fetch parent
        return evalAs!Ref(input, ctx).then((Ref[] childRefs) {
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
        });
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
// Tests
// ============================================================================

unittest {
    // Test low-level Entity mixin (no id column)
    struct User {
        mixin Entity!"users";
        mixin Col!("id", long);
        mixin PrimaryKey!"id";
    }
    static assert(User._table == "users");
    static assert(User._typeName == "User");
    static assert(User._sourceId == "default");
    static assert(is(User._colField_id.type == long));

    // Test Entity with custom type name
    struct Post {
        mixin Entity!("posts", "BlogPost");
        mixin Col!("id", long);
        mixin PrimaryKey!"id";
    }
    static assert(Post._table == "posts");
    static assert(Post._typeName == "BlogPost");
    static assert(is(Post._colField_id.type == long));
}

unittest {
    import graphqld2.relational.demo : DemoEntity;

    // Test DemoEntity convenience (includes id column)
    struct Comment {
        mixin DemoEntity!"comments";
    }
    static assert(Comment._table == "comments");
    static assert(is(Comment._colField_id.type == long));

    // Test DemoEntity with custom ID type
    struct UuidEntity {
        mixin DemoEntity!("items", string);
    }
    static assert(is(UuidEntity._colField_id.type == string));
}

// Test optimization creates QueryNode
unittest {
    import std.json : parseJSON;
    import graphqld2.relational.demo : DemoEntity;

    struct User {
        mixin DemoEntity!"users";
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

// Test end-to-end with string (UUID) primary keys
unittest {
    import std.json : parseJSON;
    import ae.utils.promise.await : awaitSync;
    import graphqld2.relational.demo : DemoEntity;

    // Entity with string ID (UUID-style)
    struct Item {
        mixin DemoEntity!("items", string);
        mixin Col!("name", string);
    }

    // Set up mock data with string IDs
    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("items", `[
        {"id": "uuid-abc", "name": "First Item"},
        {"id": "uuid-def", "name": "Second Item"}
    ]`);

    // Query by string IDs
    auto query = map!(
        (Expr!Ref item) => Item.name(item)
    )(getByIds!Item(["uuid-abc", "uuid-def"], fetcher));

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
    import graphqld2.relational.demo : DemoEntity;

    struct Category {
        mixin DemoEntity!("categories", string);
        mixin Col!("name", string);
    }

    struct Product {
        mixin DemoEntity!("products", string);
        mixin Col!("name", string);
        mixin Col!("categoryId", ForeignKey!Category);
        mixin BelongsTo!("category", "categoryId");
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("categories", `[
        {"id": "cat-1", "name": "Electronics"},
        {"id": "cat-2", "name": "Books"}
    ]`);
    fetcher.setTableData("products", `[
        {"id": "prod-a", "category_id": "cat-1", "name": "Phone"},
        {"id": "prod-b", "category_id": "cat-2", "name": "Novel"}
    ]`);

    auto query = map!(
        (Expr!Ref prod) => jsonObject(
            "name", Product.name(prod),
            "categoryName", Category.name(Product.category(prod))
        )
    )(getByIds!Product(["prod-a", "prod-b"], fetcher));

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

    // Entity with composite primary key (order_id + product_id)
    struct OrderItem {
        mixin Entity!"order_items";

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
    auto fetcher = new MockDataFetcher();
    fetcher.setPrimaryKey("order_items", "order_id", "product_id");
    fetcher.setTableData("order_items", `[
        {"order_id": 1, "product_id": 100, "quantity": 2, "price": "10.00"},
        {"order_id": 1, "product_id": 101, "quantity": 1, "price": "25.00"},
        {"order_id": 2, "product_id": 100, "quantity": 3, "price": "10.00"}
    ]`);

    // Query using pre-encoded composite keys
    auto refs = [
        Ref("OrderItem:1,100"),  // order 1, product 100
        Ref("OrderItem:1,101")   // order 1, product 101
    ];

    auto query = map!(
        (Expr!Ref item) => jsonObject(
            "quantity", OrderItem.quantity(item),
            "price", OrderItem.price(item)
        )
    )(new GetByIdsExpr!OrderItem(refs, fetcher));

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

    struct OrderItem {
        mixin Entity!"order_items";
        mixin Col!("orderId", long);
        mixin Col!("productId", long);
        mixin PrimaryKey!("orderId", "productId");
        mixin Col!("quantity", long);
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setPrimaryKey("order_items", "order_id", "product_id");
    fetcher.setTableData("order_items", `[
        {"order_id": 1, "product_id": 100, "quantity": 2},
        {"order_id": 1, "product_id": 101, "quantity": 1},
        {"order_id": 2, "product_id": 100, "quantity": 3}
    ]`);

    // Use getByCompositeIds helper with array of key-parts
    auto query = map!(
        (Expr!Ref item) => OrderItem.quantity(item)
    )(getByCompositeIds!OrderItem([[1, 100], [2, 100]], fetcher));

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query, true));

    assert(result.length == 2);
    assert(result[0] == 2);  // order 1, product 100 -> quantity 2
    assert(result[1] == 3);  // order 2, product 100 -> quantity 3
}
