module dunamis.relational.schema.expressions;

private enum bool isStringBacked(T) = (() {
    import std.typecons : Nullable;
    import dunamis.core.types : isCustomScalar;
    static if (is(T == Nullable!U, U))
        return isStringBacked!U;
    else static if (isCustomScalar!T)
        return is(T.DType == string);
    else
        return is(T == string);
})();

import std.algorithm;
import std.array;
import std.conv;
import std.typecons : Nullable;

import ae.utils.promise;

import dunamis.core;
import dunamis.core.transparency : Transparent, seeThrough, wrappersOf;
import dunamis.relational.eval_context;
import dunamis.relational.optimize_context;
import dunamis.relational.project;
import dunamis.relational.query_node;
import dunamis.relational.schema.attrs;
import dunamis.relational.schema.types;
import dunamis.relational.schema.mixins;
import dunamis.relational.schema.interfaces;
import dunamis.relational.schema.patterns;

// ============================================================================
// UFCS Access Functions
// ============================================================================

/// Column access - reads a column value for each entity ref.
/// Takes typed Expr!Entity for compile-time type safety.
Expr!T column(T, Entity)(Expr!Entity input, string name) {
    return new ColumnAccessExpr!(T, Entity)(input, name);
}

/// HasMany relationship - returns collection of child entities for each parent.
/// Takes typed Expr!Parent and returns Expr!(Child[]), each parent's children
/// ordered by the `orderBy` child columns (unordered if empty).
Expr!(Child[]) hasMany(Child, string fk, Parent, string[] orderBy = null)(Expr!Parent input) {
    return new HasManyAccessExpr!(Parent, Child, fk, orderBy)(input);
}

/// BelongsTo relationship - returns parent entity for each child.
/// Takes typed Expr!Child and returns Expr!Parent or Expr!(Nullable!Parent).
/// ResultType should be Parent (required FK) or Nullable!Parent (optional FK).
Expr!ResultType belongsTo(Parent, ResultType = Parent, string fk, Child)(Expr!Child input) {
    return new BelongsToAccessExpr!(Child, Parent, ResultType, fk)(input);
}

// ============================================================================
// Entity Population Utilities
// ============================================================================

/// Whether the plain field `fieldName` of `Entity` is (part of) its primary key.
private enum bool isPrimaryKeyField(Entity, string fieldName) = (() {
    import dunamis.relational.schema.attrs : getPrimaryKeyFieldNames;
    foreach (f; getPrimaryKeyFieldNames!Entity)
        if (f == fieldName)
            return true;
    return false;
})();

/// Populate plain field values into entities by fetching from database.
/// Used by GetByIdsExpr and GetAllExpr in naive mode to pre-populate fields.
/// If `fetched`, the entities are rows read from the table, whose primary
/// key fields (made from their refs) need not be read again; otherwise (as
/// for entities of any ids) they are read too (a missing row's are reset).
private Promise!(Entity[]) populatePlainFields(Entity)(RelationalSession session, Entity[] entities,
        bool fetched = false) {
    import dunamis.core.join : joinAll;
    import dunamis.core.types : AnyRef;

    if (entities.length == 0) {
        return resolve(entities);
    }

    auto refs = entities.map!(e => entityToRef(e)).array;
    enum table = EntityID!Entity.table;
    enum plainFields = getPlainFieldNames!Entity;

    static if (plainFields.length == 0) {
        // No plain fields to populate
        return resolve(entities);
    } else {
        // The refs need not come from a root fetch that recorded the key
        session.notePkColumns(table, getPkColumns!Entity);

        // Fetch all plain fields in parallel
        Promise!void[] fetches;
        static foreach (fieldName; plainFields) {{
          if (!fetched || !isPrimaryKeyField!(Entity, fieldName)) {
            enum columnName = getPlainFieldColumnName!(Entity, fieldName);
            alias FieldType = typeof(__traits(getMember, Entity.init, fieldName));

            fetches ~= session.fetchColumn!FieldType(table, columnName, refs)
                .then((FieldType[] values) {
                    foreach (i, ref e; entities) {
                        __traits(getMember, e, fieldName) = values[i];
                    }
                });
          }
        }}

        // joinAll(Promise!void[]) returns Promise!void, then we return entities
        return joinAll(fetches).then(() => entities);
    }
}

// ============================================================================
// Column Access Expression
// ============================================================================

/// Push the filters, sorts and pagination wrapping a root collection into the
/// SQL query of its root QueryNode, removing the pushed wrappers from the
/// expression tree; the rest stay in the tree and are applied in memory.
///
/// `mapExpr`'s collection is a chain of wrappers over the root expression:
/// filters, sorts, limits and offsets, and maps yielding each element itself
/// or an entity cast of it (`preservesElements`) and entity casts (which
/// preserve rows and their order, so they are transparent here).  The
/// SQL query applies WHERE, then ORDER BY, then OFFSET/LIMIT, all before the
/// in-memory wrappers; so going from the root up, a wrapper is pushed only if
/// that does not move it across anything it does not commute with:
/// - a filter, unless a limit/offset is beneath it;
/// - a sort, unless a limit/offset or an in-memory sort is beneath it;
/// - an offset or limit, only if everything beneath it was pushed.
/// A filter that cannot be pushed as a whole still lets its SQL-expressible
/// conjuncts narrow the query (under the same condition) and is then applied
/// in memory. Filters may read the plain fields of the root's entity (e.g.
/// its primary key) as well as its columns (see `RootExprInfo.plainFieldColumn`).
/// A sort by a native SQL expression (see `NativeSqlInfo`) orders by a
/// computed column of the query.
private void pushDownRootCollection(QueryNode node, Object mapExpr, RootExprInfo rootExpr,
        RelationalOptimizeContext relCtx) {
    import dunamis.core.pagination : LimitInfo, OffsetInfo;
    import dunamis.core.sorting : SortByInfo;
    import dunamis.core.filtering : FilterByInfo;
    import dunamis.relational.native : sqlDialectOf;
    import dunamis.relational.sql_optimizer : extractFilterWhereClause, extractSortKey;

    // The dialect of the node's query (for native predicates)
    auto dialect = sqlDialectOf(node.dataSource);

    // links[0] is mapExpr's collection, links[$-1] wraps the root expression.
    // (A conditional collection is all or none of its source's rows, so it
    // commutes with all of them.)
    Object root;
    auto links = wrappersOf((cast(MapExprInfo) mapExpr).collection, Transparent.rows, root);

    bool allPushed = true;    // Is everything beneath the current link pushed?
    bool windowBeneath;       // Is a limit/offset (pushed or not) beneath it?
    bool sortBeneath;         // Is a sort (pushed or not) beneath it?
    bool limitPushed, offsetPushed;
    foreach_reverse (i, link; links) {
        Object parentObject = i ? links[i - 1] : mapExpr;
        auto parent = cast(ExprBase) parentObject;
        void splice(Object source) {
            parent.replaceDependency(0, cast(ExprBase) source);
        }

        if (auto filter = cast(FilterByInfo) link) {
            // (A data source whose queries are not SQL, e.g. an in-memory
            // one, evaluates no WHERE clauses: the filter stays in memory)
            if (!windowBeneath && dialect !is null) {
                auto where = extractFilterWhereClause(filter, node.table, dialect, &rootExpr.plainFieldColumn);
                if (!where.sql.isNull)
                    node.addWhereClause(where.sql.get, where.relations);
                if (where.complete) {
                    splice(filter.filterSource);
                    continue;
                }
            }
            allPushed = false;
        } else if (auto sort = cast(SortByInfo) link) {
            bool pushed;
            if (!windowBeneath && !sortBeneath) {
                auto key = extractSortKey(sort, node.table, dialect);
                if (!key.isNull) {
                    // By a column, or by a computed column (of a native
                    // SQL expression)
                    auto column = key.get.column;
                    if (column is null) {
                        column = relCtx.newComputedColumnAlias();
                        node.addComputedColumn(ComputedColumn(column, key.get.sql, key.get.type));
                    }
                    node.addOrderBy(OrderBySpec(column, key.get.direction));
                    splice(sort.sortSource);
                    pushed = true;
                }
            }
            sortBeneath = true;
            if (!pushed) allPushed = false;
        } else if (auto offset = cast(OffsetInfo) link) {
            // OFFSET applies before LIMIT, so not over a pushed limit.
            if (allPushed && !limitPushed && !offsetPushed) {
                node.setOffset(offset.offsetValue);
                splice(offset.offsetSource);
                offsetPushed = true;
            } else
                allPushed = false;
            windowBeneath = true;
        } else if (auto limit = cast(LimitInfo) link) {
            if (allPushed && !limitPushed) {
                node.setLimit(limit.limitValue);
                splice(limit.limitSource);
                limitPushed = true;
            } else
                allPushed = false;
            windowBeneath = true;
        }
    }
}

/// Whether `node` was configured to select rows of its own: as a root
/// query, or as a child layer of another node.
private bool isConfigured(QueryNode node) {
    return node.rootFilter != FilterType.none || node.parent !is null;
}

/// The QueryNode of the elements of the map `mapExpr` (rows of `table`, of
/// the entity `typeName`, from `db`), created if need be, and configured from
/// the map's collection if it is not yet: for a root collection, as a root
/// query (into which the wrappers of the collection are pushed, see
/// `pushDownRootCollection`); for a HasMany of the elements of another map,
/// as a child layer of that map's node (which is created and configured
/// likewise if need be, so that a HasMany is fetched with its parents also
/// when nothing reads a column of the parents themselves).
///
/// The node returned is unconfigured (see `isConfigured`) if the map's rows
/// cannot be selected by a query of its own; its fields are then evaluated
/// on the naive path.
private QueryNode configuredNode(OptimizeContext ctx, Object mapExpr, string typeName, string table,
        string[] pkColumns, DataSource db) {
    auto relCtx = ctx.getSourceContext!RelationalOptimizeContext();
    auto node = relCtx.getOrCreateNode(mapExpr, typeName, table, pkColumns);

    // Set the data source on the node (for mutation-returned entities that bypass GetByIdsExpr)
    if (node.dataSource is null && db !is null)
        node.dataSource = db;

    if (isConfigured(node))
        return node;
    auto mapInfo = cast(MapExprInfo) mapExpr;
    if (mapInfo is null)
        return node;
    Object coll = mapInfo.collection;

    // The root or relationship whose rows the map's elements are (seen
    // read-only, BEFORE modifying the tree): beneath the wrappers keeping
    // (some of) their source's rows. (The elements of a map other than an
    // element-preserving one are not the root's rows.)
    Object underlyingColl = seeThrough(coll, Transparent.rows);

    if (auto rootExpr = cast(RootExprInfo) underlyingColl) {
        // For root collections: unwrap pagination/sorting/filtering from the
        // expression tree and push to the QueryNode for SQL-level execution.
        pushDownRootCollection(node, mapExpr, rootExpr, relCtx);
        // The root's own order, beneath the sorts pushed (which are stable
        // in memory: it orders the rows they leave tied)
        foreach (column; rootExpr.orderColumns) {
            node.addColumn(column);
            node.addOrderBy(column);
        }
        relCtx.setRootNode(underlyingColl, node);
        if (rootExpr.filterType == FilterType.byIds) {
            node.setRootFilter(FilterType.byIds, rootExpr.filterRefs);
        } else if (rootExpr.filterType == FilterType.all) {
            node.setRootFilter(FilterType.all);
        }
    }
    else if (auto hasManyExpr = cast(HasManyInfo) underlyingColl) {
        // Child of a hasMany relationship — pagination/sorting/filtering
        // stays in the expression tree (applied at eval time, as
        // HasManyAccessExpr evaluates naively), not pushed to the QueryNode.
        JoinHop[] parentJoinPath;
        ExprBase parentBaseInput;
        ExprBase parentBaseInputAsAnyRef;
        auto parentMapExpr = findMapExprFromChain(hasManyExpr.inputExpr, parentJoinPath, parentBaseInput,
            parentBaseInputAsAnyRef, ctx);
        if (parentMapExpr is null)
            return node;
        auto parentNode = relCtx.getNode(parentMapExpr);
        if (parentNode is null) {
            // Nothing read the parents' columns: select the parents in a
            // query of their own, for their children to be selected with
            if (parentJoinPath.length)
                parentNode = configuredNode(ctx, parentMapExpr, parentJoinPath[0].sourceType,
                    parentJoinPath[0].sourceTable, parentJoinPath[0].sourcePkColumns, db);
            else if (hasManyExpr.parentTable.length && hasManyExpr.parentDataSource is db)
                parentNode = configuredNode(ctx, parentMapExpr, hasManyExpr.parentTypeName,
                    hasManyExpr.parentTable, hasManyExpr.parentPkColumns, db);
            if (parentNode is null || !isConfigured(parentNode))
                return node;
        }
        string[] parentLinkColumns;
        Nullable!JoinAlias lastAlias;
        foreach (hop; parentJoinPath) {
            if (lastAlias.isNull)
                parentNode.addColumn(hop.fk);
            else
                parentNode.addJoinedColumn(lastAlias.get, hop.fk);
            lastAlias = parentNode.addJoin(hop.targetTable,
                hop.targetType, hop.fk,
                hop.targetPkColumns, lastAlias);
        }
        if (!lastAlias.isNull) {
            foreach (pk; parentJoinPath[$ - 1].targetPkColumns) {
                parentNode.addJoinedColumn(lastAlias.get, pk);
                parentLinkColumns ~= lastAlias.get.value ~ "__" ~ pk;
            }
        }
        node.setParent(parentNode, hasManyExpr.fkColumn,
            hasManyExpr.parentTypeName, parentLinkColumns);
        foreach (column; hasManyExpr.orderColumns) {
            node.addColumn(column);
            node.addOrderBy(column);
        }
    }
    return node;
}

/// Expression that reads a column from entities.
/// Takes typed Expr!Entity for type safety.
class ColumnAccessExpr(T, Entity) : Expr!T, ColumnAccessInfo {
    private ExprBase _input;  // the entity we're reading from (type-erased for storage)
    string _column;

    this(Expr!Entity input, string column) {
        _input = input;
        _column = column;
    }

    // ColumnAccessInfo implementation
    @property ExprBase inputExpr() { return _input; }
    @property string column() { return _column; }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    override DataSource[] dataSources() {
        auto db = EntityID!Entity.db;
        return db !is null ? [db] : [];
    }

    override Expr!T optimize(OptimizeContext ctx) {
        // First optimize input
        _input = (cast(Expr!Entity) _input).optimize(ctx);

        // Find the MapExpr this column belongs to
        JoinHop[] joinPath;
        ExprBase baseInput;
        ExprBase baseInputAsAnyRef;
        auto mapExpr = findMapExprFromChain(_input, joinPath, baseInput, baseInputAsAnyRef, ctx);

        if (mapExpr is null) {
            // Can't optimize, use naive path
            return this;
        }

        auto relCtx = ctx.getSourceContext!RelationalOptimizeContext();
        auto node = joinPath.length
            ? configuredNode(ctx, mapExpr, joinPath[0].sourceType,
                joinPath[0].sourceTable, joinPath[0].sourcePkColumns, EntityID!Entity.db)
            : configuredNode(ctx, mapExpr, EntityID!Entity.typeName,
                EntityID!Entity.table, getPkColumns!Entity, EntityID!Entity.db);

        // If the node wasn't configured with a valid root filter and has no parent,
        // fall back to naive path
        if (node.rootFilter == FilterType.none && node.parent is null) {
            return this;
        }

        // Get the PrefetchExpr for this node
        auto prefetch = relCtx.getPrefetchExpr(node);

        import dunamis.relational.project : EntityToAnyRefExpr;

        if (joinPath.length == 0) {
            // Direct column access - return projection expression
            node.addColumn(_column);
            static if (isStringBacked!T)
                node.markStringColumn(_column);
            auto refInput = relCtx.refsOf!Entity(_input);
            return new ProjectionExpr!T(node.id, ProjectedColumn.column(_column), refInput, prefetch);
        }

        // Access through belongsTo chain - add JOINs
        Nullable!JoinAlias lastAlias;
        foreach (hop; joinPath) {
            if (lastAlias.isNull) {
                // First hop: FK is on the root table
                node.addColumn(hop.fk);
            } else {
                // Subsequent hops: FK is on the previously joined table
                node.addJoinedColumn(lastAlias.get, hop.fk);
            }
            // Add JOIN and get alias, tracking source for multi-hop
            lastAlias = node.addJoin(hop.targetTable, hop.targetType, hop.fk, hop.targetPkColumns, lastAlias);
        }

        // Track the column needed from the final joined table
        node.addJoinedColumn(lastAlias.get, _column);
        static if (isStringBacked!T)
            node.markJoinedStringColumn(lastAlias.get, _column);

        // Return projection that reads from the final joined table
        return new ProjectionExpr!T(node.id, ProjectedColumn.joined(lastAlias.get, _column), baseInputAsAnyRef,
            prefetch);
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto column = _column;
        auto input = _input;

        // Get session from Entity's data source
        auto db = EntityID!Entity.db;
        RelationalSession session;
        if (db !is null) {
            session = cast(RelationalSession) ctx.getSession(db);
        }

        // Get the entity refs from the input chain, then fetch column
        return evalAs!Entity(input, ctx).then((Entity[] entities) {
            AnyRef[] entityRefs = entities.map!(e => entityToRef(e)).array;

            debug(filter) {
                import std.stdio : writefln;
                writefln("    ColumnAccessExpr.eval: table=%s, column=%s, refs=%s",
                    EntityID!Entity.table, column, entityRefs.map!(r => r.toString()).array);
            }

            // The objects a mutation returned (mutations store their results
            // here), if they are all of them; others are read from the
            // database (which also holds the mutation's writes).
            if (session !is null && session.mutationResultHolds(entityRefs)) {
                return resolve(session.getMutationColumnValues!T(column, entityRefs));
            }

            // Otherwise, fetch from database (async). (The refs need not
            // come from a root fetch that recorded the key.)
            if (session !is null) {
                session.notePkColumns(EntityID!Entity.table, getPkColumns!Entity);
                return session.fetchColumn!T(EntityID!Entity.table, column, entityRefs);
            }

            // Fallback to empty results
            return resolve(entityRefs.map!(_ => T.init).array);
        });
    }

    @property ExprBase input() { return _input; }
}

// ============================================================================
// Root Expressions
// ============================================================================

/// Root expression that returns specific entities by their IDs.
class GetByIdsExpr(Entity) : Expr!(Entity[]), RootExprInfo {
    import dunamis.core.optimize : ExprOptimizer;
    import dunamis.core.datasource : DataSource;

    private Entity[] _entities;

    /// Construct from array of IDs (any type convertible to PK type)
    this(IdType)(IdType[] ids) {
        _entities = ids.map!(id => .makeEntity!(Entity, IdType)(id)).array;
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
        auto db = EntityID!Entity.db;
        if (db !is null) {
            return db.requestedOptimizers();
        }
        return [];
    }

    override DataSource[] dataSources() {
        auto db = EntityID!Entity.db;
        return db !is null ? [db] : [];
    }

    override Promise!(Entity[][]) eval(EvalContext ctx) {
        auto db = EntityID!Entity.db;

        // Populate eager fields if any exist
        enum plainFields = getPlainFieldNames!Entity;
        static if (plainFields.length > 0) {
            if (db !is null && _entities.length > 0) {
                auto session = cast(RelationalSession) ctx.getSession(db);
                return populatePlainFields!Entity(session, _entities)
                    .then((Entity[] populated) => [populated]);
            }
        }

        return resolve([_entities]);
    }

    @property Entity[] entities() { return _entities; }

    // RootExprInfo implementation
    FilterType filterType() { return FilterType.byIds; }
    string[] orderColumns() { return []; }
    string plainFieldColumn(string fieldName) { return plainFieldColumnOf!Entity(fieldName); }
    AnyRef[] filterRefs() { return _entities.map!(e => entityToRef(e)).array; }
    string entityTypeName() { return EntityID!Entity.typeName; }
    string entityTable() { return EntityID!Entity.table; }
    DataSource dataSource() { return EntityID!Entity.db; }
}

/// Factory function to create GetByIdsExpr (works with any ID type)
auto getByIds(Entity, IdType)(IdType[] ids) {
    return new GetByIdsExpr!Entity(ids);
}

/// Factory function to create GetByIdsExpr for composite keys.
auto getByCompositeIds(Entity, IdType)(IdType[][] keyParts) {
    import dunamis.core.types : AnyRef, encodeCompositeKey;

    Entity[] entities;
    foreach (parts; keyParts) {
        string[] strParts;
        foreach (p; parts) {
            strParts ~= p.to!string;
        }
        auto ref_ = AnyRef(EntityID!Entity.typeName ~ ":" ~ encodeCompositeKey(strParts));
        entities ~= makeEntityFromRef!Entity(ref_);
    }
    return new GetByIdsExpr!Entity(entities);
}

/// Convert a dynamically-evaluated primary key into a typed entity reference.
///
/// Unlike `getByIds`, this preserves the cardinality and map scope of its input
/// expression, allowing computed fields to issue ordinary relationship and
/// column requests for their parent entity without leaving the computation
/// graph.
class EntityByIdExpr(Entity, IdType) : Expr!Entity {
    private Expr!IdType _id;

    this(Expr!IdType id) { _id = id; }

    override ExprBase[] dependencies() { return [_id]; }
    override void replaceDependency(size_t index, ExprBase value) {
        assert(index == 0);
        _id = cast(Expr!IdType) value;
    }
    override DataSource[] dataSources() {
        auto db = EntityID!Entity.db;
        return db !is null ? [db] : [];
    }
    override Expr!Entity optimize(OptimizeContext ctx) {
        _id = _id.optimize(ctx);
        return this;
    }
    override Promise!(Entity[]) eval(EvalContext ctx) {
        return evalAs!IdType(_id, ctx).then((IdType[] ids) {
            Entity[] entities;
            entities.reserve(ids.length);
            foreach (id; ids)
                entities ~= .makeEntity!(Entity, IdType)(id);
            return entities;
        });
    }
}

auto entityById(Entity, IdType)(Expr!IdType id) {
    return new EntityByIdExpr!(Entity, IdType)(id);
}

/// Root expression that fetches all entities of a type, ordered by the
/// `orderBy` columns if any (unordered if empty).
class GetAllExpr(Entity, string[] orderBy = null) : Expr!(Entity[]), RootExprInfo, MapExprInfo {
    import dunamis.core.optimize : ExprOptimizer, OptimizeContext;
    import dunamis.core.datasource : DataSource;

    private {
        PrefetchExpr _prefetch;  // Set during optimization
        QueryNodeId _queryNodeId = noQueryNodeId;   // QueryNode ID for optimized path
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
        auto db = EntityID!Entity.db;
        if (db !is null) {
            return db.requestedOptimizers();
        }
        return [];
    }

    override DataSource[] dataSources() {
        auto db = EntityID!Entity.db;
        return db !is null ? [db] : [];
    }

    override Expr!(Entity[]) optimize(OptimizeContext ctx) {
        auto db = EntityID!Entity.db;
        if (db is null) return this;

        auto relCtx = ctx.getSourceContext!RelationalOptimizeContext();

        // The node configured for this root collection, if a map over it
        // reads its rows' columns; otherwise it is read on the naive path.
        // (Not another root node of the table: another root field may
        // query it differently, e.g. filtered or paginated.)
        auto node = relCtx.rootNodeOf(this);
        if (node is null) {
            return this;
        }

        _prefetch = relCtx.getPrefetchExpr(node);
        _queryNodeId = node.id;

        return this;
    }

    override Promise!(Entity[][]) eval(EvalContext ctx) {
        auto db = EntityID!Entity.db;
        if (db is null) return resolve([cast(Entity[])[]]);

        auto session = cast(RelationalSession) ctx.getSession(db);

        // Optimized path: use PrefetchExpr to fetch data, then read refs
        if (_prefetch !is null) {
            return evalAs!(AnyRef[])(_prefetch, ctx).then((AnyRef[][] prefetchResults) {
                auto refs = prefetchResults.length > 0 ? prefetchResults[0] : [];
                auto entities = refs.map!(r => makeEntityFromRef!Entity(r)).array;

                // Populate plain fields (struct instance fields) so plain methods work.
                // Column data is fetched via CTE, but plain fields need struct population.
                enum plainFields = getPlainFieldNames!Entity;
                static if (plainFields.length > 0) {
                    if (entities.length > 0) {
                        return populatePlainFields!Entity(session, entities, true)
                            .then((Entity[] populated) => [populated]);
                    }
                }

                return resolve([entities]);
            });
        }

        // Fallback: naive path using fetchAllIdsString
        return session.fetchAllIdsAsRefs(EntityID!Entity.table, EntityID!Entity.typeName, getPkColumns!Entity,
                orderBy).then((AnyRef[] refs) {
            auto entities = refs.map!(r => makeEntityFromRef!Entity(r)).array;

            enum plainFields = getPlainFieldNames!Entity;
            static if (plainFields.length > 0) {
                if (entities.length > 0) {
                    return populatePlainFields!Entity(session, entities, true)
                        .then((Entity[] populated) => [populated]);
                }
            }

            return resolve([entities]);
        });
    }

    // RootExprInfo implementation
    FilterType filterType() { return FilterType.all; }
    string[] orderColumns() { return orderBy.dup; }
    string plainFieldColumn(string fieldName) { return plainFieldColumnOf!Entity(fieldName); }
    AnyRef[] filterRefs() { return []; }
    string entityTypeName() { return EntityID!Entity.typeName; }
    string entityTable() { return EntityID!Entity.table; }
    DataSource dataSource() { return EntityID!Entity.db; }

    // MapExprInfo implementation (for QueryNode creation)
    Object collection() { return this; }
    ExprBase bodyExpr() { return null; }
}

/// Factory function to create GetAllExpr: all the entities, ordered by the
/// `orderBy` columns if any.
auto getAll(Entity, string[] orderBy = null)() {
    return new GetAllExpr!(Entity, orderBy)();
}

// ============================================================================
// HasMany Access Expression
// ============================================================================

/// Expression representing a one-to-many relationship.
/// Each parent's children are ordered by the `orderBy` child columns, if any.
class HasManyAccessExpr(Parent, Child, string fk, string[] orderBy = null) : Expr!(Child[]), HasManyInfo {
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
            return this;
        }
    } else {
        override Expr!(Child[]) optimize(OptimizeContext ctx) {
            return this;
        }
    }

    override Promise!(Child[][]) eval(EvalContext ctx) {
        auto input = _input;

        auto db = EntityID!Child.db;
        RelationalSession session;
        if (db !is null) {
            session = cast(RelationalSession) ctx.getSession(db);
        }

        static if (!is(Parent == void)) {
            auto refsPromise = evalAs!Parent(input, ctx).then((Parent[] parents) {
                return parents.map!(e => entityToRef(e)).array;
            });
        } else {
            auto refsPromise = evalAs!AnyRef(input, ctx);
        }
        return refsPromise.then((AnyRef[] parentRefs) {
            debug(filter) {
                import std.stdio : writefln, stdout;
                writefln("    HasManyAccessExpr.eval: parentRefs=%s, fk=%s, childTable=%s",
                    parentRefs.map!(r => r.toString()).array, fk, EntityID!Child.table);
                stdout.flush();
            }
            if (session !is null) {
                session.notePkColumns(EntityID!Child.table, getPkColumns!Child);
                return session.fetchChildren(EntityID!Child.table, EntityID!Child.typeName, fk, parentRefs, orderBy)
                    .then((AnyRef[][] children) {
                        debug(filter) {
                            import std.stdio : writefln, stdout;
                            writefln("    HasManyAccessExpr.eval: fetched children=%s",
                                children.map!(g => g.map!(r => r.toString()).array).array);
                            stdout.flush();
                        }
                        return children.map!(group => group.map!(r => makeEntityFromRef!Child(r)).array).array;
                    });
            }

            return resolve(parentRefs.map!(_ => cast(Child[])[]).array);
        });
    }

    @property ExprBase input() { return _input; }

    // HasManyInfo implementation
    @property ExprBase inputExpr() { return _input; }
    static if (!is(Parent == void)) {
        @property ExprBase inputAsAnyRefExpr() {
            import dunamis.relational.project : EntityToAnyRefExpr;
            return new EntityToAnyRefExpr!Parent(_input);
        }
    } else {
        @property ExprBase inputAsAnyRefExpr() { return null; }
    }
    @property string childTable() { return EntityID!Child.table; }
    @property string childTypeName() { return EntityID!Child.typeName; }
    @property string fkColumn() { return fk; }
    static if (!is(Parent == void)) {
        @property string parentTypeName() { return EntityID!Parent.typeName; }
        @property string parentTable() { return EntityID!Parent.table; }
        @property DataSource parentDataSource() { return EntityID!Parent.db; }
        @property string[] parentPkColumns() { return getPkColumns!Parent; }
    } else {
        @property string parentTypeName() { return ""; }
        @property string parentTable() { return ""; }
        @property DataSource parentDataSource() { return null; }
        @property string[] parentPkColumns() { return []; }
    }
    @property string[] orderColumns() { return orderBy.dup; }
}

// ============================================================================
// BelongsTo Access Expression
// ============================================================================

/// Expression representing a many-to-one relationship.
class BelongsToAccessExpr(Child, Parent, ResultType, string fk) : Expr!ResultType, BelongsToInfo {
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
            import std.typecons : Nullable;

            _input = (cast(Expr!Child) _input).optimize(ctx);

            static if (!is(ResultType == Nullable!Parent)) {
                return this;
            } else {
                JoinHop[] joinPath;
                ExprBase baseInput;
                ExprBase baseInputAsAnyRef;
                auto mapExpr = findMapExprFromChain(_input, joinPath, baseInput, baseInputAsAnyRef, ctx);

                if (mapExpr is null) {
                    return this;
                }

                auto relCtx = ctx.getSourceContext!RelationalOptimizeContext();
                auto node = joinPath.length
                    ? configuredNode(ctx, mapExpr, joinPath[0].sourceType,
                        joinPath[0].sourceTable, joinPath[0].sourcePkColumns, EntityID!Child.db)
                    : configuredNode(ctx, mapExpr, EntityID!Child.typeName,
                        EntityID!Child.table, getPkColumns!Child, EntityID!Child.db);
                if (!isConfigured(node)) {
                    return this;
                }

                // The FK: a column of the node's rows, or of the table the
                // belongsTo chain reaching the child joins
                string fkColumn = fk;
                if (joinPath.length) {
                    Nullable!JoinAlias lastAlias;
                    foreach (hop; joinPath) {
                        if (lastAlias.isNull)
                            node.addColumn(hop.fk);
                        else
                            node.addJoinedColumn(lastAlias.get, hop.fk);
                        lastAlias = node.addJoin(hop.targetTable, hop.targetType, hop.fk,
                            hop.targetPkColumns, lastAlias);
                    }
                    node.addJoinedColumn(lastAlias.get, fk);
                    fkColumn = lastAlias.get.value ~ "__" ~ fk;
                } else
                    node.addColumn(fk);

                auto prefetch = relCtx.getPrefetchExpr(node);

                import dunamis.relational.project : ProjectBelongsToExpr, ProjectTypedBelongsToExpr, EntityToAnyRefExpr;
                auto refBaseInput = baseInputAsAnyRef !is null
                    ? baseInputAsAnyRef
                    : relCtx.refsOf!Child(baseInput);
                auto innerProj = new ProjectBelongsToExpr(node.id, fkColumn, EntityID!Parent.typeName, refBaseInput, prefetch);
                return new ProjectTypedBelongsToExpr!(Child, Parent, ResultType, fk)(innerProj, refBaseInput);
            }
        }
    } else {
        override Expr!ResultType optimize(OptimizeContext ctx) {
            return this;
        }
    }

    override Promise!(ResultType[]) eval(EvalContext ctx) {
        auto input = _input;

        static if (!is(Child == void)) {
            auto db = EntityID!Child.db;
            RelationalSession session;
            if (db !is null) {
                session = cast(RelationalSession) ctx.getSession(db);
            }
        }

        static if (!is(Child == void)) {
            auto refsPromise = evalAs!Child(input, ctx).then((Child[] children) {
                return children.map!(e => entityToRef(e)).array;
            });
        } else {
            auto refsPromise = evalAs!AnyRef(input, ctx);
        }
        return refsPromise.then((AnyRef[] childRefs) {
            static if (is(Child == void)) {
                return resolve(childRefs.map!(_ => ResultType.init).array);
            } else {
                if (session !is null) {
                    return session.fetchBelongsTo(EntityID!Child.table, fk, EntityID!Parent.typeName, childRefs)
                        .then((AnyRef[] parentRefs) {
                            static if (is(ResultType == Parent)) {
                                return requiredParents!(Child, Parent)(parentRefs, childRefs,
                                    EntityID!Child.typeName ~ "." ~ fk);
                            } else static if (is(ResultType == Nullable!Parent)) {
                                return parentRefs.map!(r => r.isValid ? Nullable!Parent(makeEntityFromRef!Parent(r)) : Nullable!Parent.init).array;
                            } else {
                                static assert(false, "ResultType must be Parent or Nullable!Parent");
                            }
                        });
                }

                return resolve(childRefs.map!(_ => ResultType.init).array);
            }
        });
    }

    @property ExprBase input() { return _input; }

    // BelongsToInfo implementation
    @property ExprBase inputExpr() { return _input; }
    static if (!is(Child == void)) {
        @property ExprBase inputAsAnyRefExpr() {
            import dunamis.relational.project : EntityToAnyRefExpr;
            return new EntityToAnyRefExpr!Child(_input);
        }
        @property string childTable() { return EntityID!Child.table; }
        @property string childTypeName() { return EntityID!Child.typeName; }
        @property string[] childPkColumns() { return getPkColumns!Child; }
    } else {
        @property ExprBase inputAsAnyRefExpr() { return null; }
        @property string childTable() { return ""; }
        @property string childTypeName() { return ""; }
        @property string[] childPkColumns() { return []; }
    }
    @property string parentTable() { return EntityID!Parent.table; }
    @property string parentTypeName() { return EntityID!Parent.typeName; }
    @property string fkColumn() { return fk; }
    @property string[] parentPkColumns() { return getPkColumns!Parent; }
}

// ============================================================================
// Tests
// ============================================================================

// Test isPlainField detection
unittest {
    import dunamis.relational.demo : MockDB;

    static MockDB!() db;

    @Entity!(db, "test_entities")
    static struct TestEntity {
        @PrimaryKey long id;
        string nickname;       // Plain field - auto-detected
        string displayName;    // Plain field - auto-detected
    }

    static assert(isPlainField!(TestEntity, "nickname"), "nickname should be a plain field");
    static assert(isPlainField!(TestEntity, "displayName"), "displayName should be a plain field");
    static assert(isPlainField!(TestEntity, "id"), "id should be a plain field");

    alias plainFields = getPlainFieldNames!TestEntity;
    static assert(plainFields.length == 3, "Should have 3 plain fields (id, nickname, displayName)");

    static assert(getPlainFieldColumnName!(TestEntity, "nickname") == "nickname",
        "nickname column name should be 'nickname'");
    static assert(getPlainFieldColumnName!(TestEntity, "displayName") == "display_name",
        "displayName column name should be 'display_name' (snake_case)");
}

unittest {
    import std.traits : hasUDA, getUDAs;
    import dunamis.relational.demo : MockDB;

    static MockDB!() db;

    @Entity!(db, "users")
    static struct User {
        @PrimaryKey @SqlColumn("id") long id;
    }
    static assert(EntityID!User.table == "users");
    static assert(EntityID!User.typeName == "User");
    static assert(hasUDA!(User.id, SqlColumn));
    static assert(hasUDA!(User.id, PrimaryKey));
    static assert(getUDAs!(User.id, SqlColumn)[0].name == "id");

    @Entity!(db, "posts", "BlogPost")
    static struct Post {
        @PrimaryKey @SqlColumn("id") long id;
    }
    static assert(EntityID!Post.table == "posts");
    static assert(EntityID!Post.typeName == "BlogPost");
    static assert(hasUDA!(Post.id, SqlColumn));
    static assert(hasUDA!(Post.id, PrimaryKey));
}

unittest {
    import std.traits : hasUDA, getUDAs;
    import dunamis.relational.demo : DemoEntity, DemoId, Int64, MockDB;

    static MockDB!() db;

    @Entity!(db, "comments")
    static struct Comment {
        mixin DemoId;
    }
    static assert(EntityID!Comment.table == "comments");
    static assert(hasUDA!(Comment.id, SqlColumn));
    static assert(hasUDA!(Comment.id, PrimaryKey));

    @Entity!(db, "items")
    static struct UuidEntity {
        mixin DemoId!string;
    }
    static assert(hasUDA!(UuidEntity.id, SqlColumn));
}

// Test optimization creates QueryNode
unittest {
    import std.json : parseJSON;
    import dunamis.relational.demo : DemoId, MockDB;

    static MockDB!() db;

    @Entity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    db = new MockDB!();

    auto userRefs = getByIds!User([1, 2]);
    auto query = map!(
        (Expr!User user) => use(
            (string first, string last) => first ~ " " ~ last,
            user.firstName,
            user.lastName
        )
    )(userRefs);

    auto optCtx = new OptimizeContext();
    auto optimized = query.optimize(optCtx);

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
    import dunamis.relational.demo : DemoId, MockDB;

    static MockDB!() db;

    @Entity!(db, "items")
    static struct Item {
        mixin DemoId!string;
        mixin Col!("name", string);
    }

    db = new MockDB!();
    db.setTableData("items", `[
        {"id": "uuid-abc", "name": "First Item"},
        {"id": "uuid-def", "name": "Second Item"}
    ]`);

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
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;

    static MockDB!() db;

    @DemoEntity!(db, "categories")
    static struct Category {
        mixin DemoId!string;
        mixin Col!("name", string);
    }

    @DemoEntity!(db, "products")
    static struct Product {
        mixin DemoId!string;
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
    import std.traits : hasUDA;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.types : AnyRef;
    import dunamis.core.types : encodeCompositeKey;
    import dunamis.relational.demo : MockDB;

    static MockDB!() db;

    @Entity!(db, "order_items")
    static struct OrderItem {
        @PrimaryKey @SqlColumn("order_id") long orderId;
        @PrimaryKey @SqlColumn("product_id") long productId;
        mixin Col!("quantity", long);
        mixin Col!("price", string);
    }

    static assert(hasUDA!(OrderItem.orderId, PrimaryKey));
    static assert(hasUDA!(OrderItem.productId, PrimaryKey));
    static assert(EntityID!OrderItem.table == "order_items");
    static assert(EntityID!OrderItem.typeName == "OrderItem");

    db = new MockDB!();
    db.setPrimaryKey("order_items", "order_id", "product_id");
    db.setTableData("order_items", `[
        {"order_id": 1, "product_id": 100, "quantity": 2, "price": "10.00"},
        {"order_id": 1, "product_id": 101, "quantity": 1, "price": "25.00"},
        {"order_id": 2, "product_id": 100, "quantity": 3, "price": "10.00"}
    ]`);

    auto refs = [
        makeEntityFromRef!OrderItem(AnyRef("OrderItem:1,100")),
        makeEntityFromRef!OrderItem(AnyRef("OrderItem:1,101"))
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
    import dunamis.relational.demo : MockDB;

    static MockDB!() db;

    @Entity!(db, "order_items")
    static struct OrderItem {
        @PrimaryKey @SqlColumn("order_id") long orderId;
        @PrimaryKey @SqlColumn("product_id") long productId;
        mixin Col!("quantity", long);
    }

    db = new MockDB!();
    db.setPrimaryKey("order_items", "order_id", "product_id");
    db.setTableData("order_items", `[
        {"order_id": 1, "product_id": 100, "quantity": 2},
        {"order_id": 1, "product_id": 101, "quantity": 1},
        {"order_id": 2, "product_id": 100, "quantity": 3}
    ]`);

    auto query = map!(
        (Expr!OrderItem item) => item.quantity
    )(getByCompositeIds!OrderItem([[1, 100], [2, 100]]));

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query, true));

    assert(result.length == 2);
    assert(result[0] == 2);
    assert(result[1] == 3);
}

// Test makeEntity and entityToRef roundtrip
unittest {
    import dunamis.core.types : AnyRef, decodeCompositeKey;
    import dunamis.relational.demo : DemoId, MockDB;

    static MockDB!() db;

    @Entity!(db, "users")
    static struct User {
        mixin DemoId;
    }

    auto user1 = makeEntity!User(42);
    assert(entityToRef(user1).id == "User:42");
    static assert(is(typeof(user1) == User));

    // Roundtrip: entity → ref → entity
    auto ref1 = entityToRef(user1);
    auto user2 = makeEntityFromRef!User(ref1);
    assert(entityToRef(user2) == ref1);

    // Composite key decoding via AnyRef
    assert(decodeCompositeKey(AnyRef("OrderItem:100,200").localId) == ["100", "200"]);
    assert(decodeCompositeKey(AnyRef("OrderItem:order-1,prod-2").localId) == ["order-1", "prod-2"]);
}

// A filter above a map that does not preserve the root rows (here: each
// user's manager) is about the mapped entities, not the root rows, so it must
// not be pushed into the root query.
version (unittest) {
    import dunamis.relational.demo : MockDB;

    private MockDB!() staffDb;

    // Module-level: a self-referencing entity cannot be declared in a function.
    @Entity!(staffDb, "staff")
    private struct Staff {
        @PrimaryKey long id;
        mixin Col!("name", string);
        mixin ForeignKeyCol!("managerId", Staff, long);
        mixin BelongsTo!("manager", "managerId");
    }
}

unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.filtering : filterBy;

    foreach (optimize; [false, true]) {
        auto db = staffDb = new MockDB!();
        db.setTableData("staff", `[
            {"id": 1, "name": "Alice", "manager_id": 2},
            {"id": 2, "name": "Bob", "manager_id": 3},
            {"id": 3, "name": "Carol", "manager_id": 3}
        ]`);

        auto query = map!((Expr!Staff m) => m.name)(
            filterBy!((Expr!Staff m) => m.name.eq("Bob"))(
                map!((Expr!Staff s) => s.manager)(getAll!Staff())));

        auto result = awaitSync(new Executor().execute(query, optimize));
        assert(result == ["Bob"], (optimize ? "optimized" : "naive") ~ ": " ~ result.to!string);
    }
}
