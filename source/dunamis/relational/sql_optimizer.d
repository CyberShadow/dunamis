module dunamis.relational.sql_optimizer;

import std.algorithm;
import std.array;
import std.conv;
import std.json : JSONValue;
import std.typecons : Nullable;

import dunamis.core.types;
import dunamis.core.expr;
import dunamis.core.filtering : FilterByInfo, FilterItemInfo;
import dunamis.core.sorting : SortByInfo, SortItemInfo, SortDirection;
import dunamis.core.transparency : Transparent, seeThrough, wrapped;
import dunamis.core.optimize : OptimizeContext, ExprOptimizer;
import dunamis.relational.native : NativeSqlInfo;
import dunamis.relational.optimize_context : RelationalOptimizeContext;
import dunamis.relational.query_node;
import dunamis.relational.schema;
import dunamis.relational.project;
import dunamis.relational.sql_dialect;

/// Convert a ConstantInfo to SQL literal using runtime type dispatch
string constantToSqlLiteral(ConstantInfo info) {
    return sqlLiteral(info.valueType, info.valueAsString);
}

// ============================================================================
// SQL Optimizer
// ============================================================================

/// External optimizer that walks expression trees and applies SQL push-down.
/// Uses the dependencies()/replaceDependency() interface for tree traversal.
///
/// Usage:
///   1. First run the standard optimizer to create QueryNodes and ProjectionExprs
///   2. Then run SqlOptimizer to find expressions over projections (e.g.
///      BinaryOpExprs) which the queries of their nodes can compute
///   3. SqlOptimizer replaces them with ProjectionExprs of computed columns
///   4. Computed columns are added to their QueryNode for SQL generation
///
/// The optimizer holds no per-request state: everything it produces is part
/// of the optimized tree (its QueryNodes and projections), so one instance
/// can serve a data source's concurrent requests, and an optimized tree can
/// be evaluated any number of times.
///
/// Data sources that support SQL computed columns should return an instance
/// of this class from their requestedOptimizers() method.
class SqlOptimizer : ExprOptimizer {
    /// SQL dialect for database-specific SQL generation
    protected SqlDialect _dialect;

    /// Create a SqlOptimizer with a specific dialect
    this(SqlDialect dialect) {
        _dialect = dialect;
    }

    /// Optimize an expression tree, applying SQL push-down where possible.
    /// This should be called AFTER the standard optimizer has run.
    override void optimize(ExprBase expr, OptimizeContext ctx) {
        optimizeRecursive(expr, ctx);
        mergeSameRowNodes(ctx);
    }

    /// Merge the query nodes of the data sources this optimizer serves
    /// which select the same rows as another node of their tree (see
    /// `QueryNode.selectsSameRowsAs`) into that node, so that their rows
    /// are selected by one SQL layer rather than by several identical ones
    /// (as when several fields map over the same relationship). Done once
    /// the tree's nodes are complete (their columns, JOINs and computed
    /// columns), in an order which does not depend on the tree's
    /// traversal: by node id, parents first, so that the children of
    /// merged nodes are merged in turn.
    private void mergeSameRowNodes(OptimizeContext ctx) {
        auto relCtx = ctx.getSourceContext!RelationalOptimizeContext();
        auto nodes = relCtx.allNodes();
        nodes.sort!((a, b) => a.id.value < b.id.value);
        QueryNode[] ordered;
        bool[QueryNode] added;
        void add(QueryNode node) {
            if (node in added)
                return;
            if (node.parent !is null)
                add(node.parent);
            added[node] = true;
            ordered ~= node;
        }
        foreach (node; nodes)
            add(node);

        // Layers selecting each table's rows, by parent layer
        QueryNode[][string] layers;
        foreach (node; ordered) {
            if (node.isRoot || node.sameRowsAs !is null || node.dataSource is null ||
                    !node.dataSource.requestedOptimizers().canFind!(o => cast(Object) o is this))
                continue;
            auto key = node.table ~ "\0" ~ node.parent.layerNode.id.value.to!string;
            bool merged;
            foreach (layer; layers.get(key, null))
                if (layer.selectsSameRowsAs(node, _dialect)) {
                    layer.mergeFrom(node);
                    merged = true;
                    break;
                }
            if (!merged)
                layers[key] ~= node;
        }
    }

    /// Recursively optimize expression and its children: push the
    /// dependencies of `expr` down (see tryPushDown), outermost first, then
    /// those of the dependencies (some may have been replaced).
    private void optimizeRecursive(ExprBase expr, OptimizeContext ctx) {
        foreach (i, dep; expr.dependencies())
            if (auto replacement = tryPushDown(dep, ctx))
                expr.replaceDependency(i, replacement);
        foreach (dep; expr.dependencies())
            optimizeRecursive(dep, ctx);
    }

    /// If the query of a node can compute the expression `expr` (see
    /// `SqlTranslator.computedColumn`), register it as a computed column of
    /// the node and return the projection of that column (which replaces
    /// `expr`, evaluating it in memory where the node's session does not
    /// compute columns); otherwise null.
    ///
    /// The expressions computed are operations (operators, conditions,
    /// `some` over to-many relationships, native SQL expressions) on the
    /// node's columns (projections of them) and constants; columns and
    /// constants themselves are read as they are.
    private ExprBase tryPushDown(ExprBase expr, OptimizeContext ctx) {
        if (!isComputable(expr))
            return null;
        auto relCtx = ctx.getSourceContext!RelationalOptimizeContext();
        auto translator = SqlTranslator.ofNodeRows(_dialect, relCtx, ctx, expr);
        if (translator is null)
            return null;
        auto sql = translator.computedColumn(expr);
        if (sql is null)
            return null;
        auto node = translator.node;
        auto prefetch = relCtx.getPrefetchExpr(node);
        auto alias_ = relCtx.newComputedColumnAlias();
        auto projection = cast(NativeSqlInfo) expr
            ? (cast(NativeSqlInfo) expr).projectComputed(node.id, alias_, translator.nodeRefs, prefetch)
            : computedProjection(node.id, alias_, expr.resultType, translator.nodeRefs, prefetch, expr);
        if (projection is null)
            return null;
        node.addComputedColumn(ComputedColumn(alias_, sql, expr.resultType, translator.relations));
        return projection;
    }

    /// Whether `expr` is an operation which a query may compute (see
    /// tryPushDown).
    private static bool isComputable(ExprBase expr) {
        return cast(BinaryOpInfo) expr || cast(UnaryOpInfo) expr || cast(TernaryInfo) expr ||
            cast(IsNullInfo) expr || cast(CollectionPredicateInfo) expr || cast(NativeSqlInfo) expr ||
            cast(MembershipInfo) expr || cast(LikeInfo) expr;
    }

    /// Create a ProjectionExpr of a computed column for the given result type,
    /// replacing the expression `original`, or null if the type is not one
    /// of those computed columns may have.
    /// Since we need to create a typed expression but only have TypeInfo at runtime,
    /// we use a factory approach with common types.
    private static ExprBase computedProjection(QueryNodeId queryNodeId, string alias_, TypeInfo type,
            ExprBase input, PrefetchExpr prefetch, ExprBase original) {
        static foreach (T; AliasSeq!(string, int, long, float, double, bool))
            if (type == typeid(T))
                return new ProjectionExpr!T(queryNodeId, ProjectedColumn.computed(alias_), input, prefetch, original);
        return null;
    }
}

private import std.meta : AliasSeq;

// ============================================================================
// Filter WHERE Clause Generation
// ============================================================================

/// The WHERE SQL of a filter predicate (see `extractFilterWhereClause`).
struct FilterWhereClause {
    /// The SQL condition, or null if no part of the predicate can be
    /// expressed in SQL.
    Nullable!DialectSql sql;
    /// Whether `sql` is equivalent to the whole predicate; otherwise it is
    /// only implied by it (it is the conjunction of those top-level `&&`
    /// conjuncts of the predicate which can be expressed in SQL), so it can
    /// only narrow the rows that the whole predicate is then evaluated on.
    bool complete;
    /// The relations its subqueries read (see `SqlTranslator.relations`).
    string[] relations;
}

/// Extract WHERE clause SQL from a FilterByInfo by pattern-matching its
/// predicate (see `extractWhereFromExpr`): of the predicate, or else of
/// those of its top-level `&&` conjuncts which can be expressed in SQL.
/// `dialect` is the dialect of the query (null if unknown, e.g. not a SQL
/// data source's): native SQL expressions (see `NativeSqlInfo`) are only
/// expressed in a dialect which has a native form of them. `plainFieldColumn`
/// (if not null) gives the columns of the plain fields of the filtered entity
/// (see `PlainFieldInfo`), so that conditions on them can be expressed too.
FilterWhereClause extractFilterWhereClause(FilterByInfo filterInfo, string table = null,
        SqlDialect dialect = null, string delegate(string) plainFieldColumn = null) {
    auto filterItem = filterInfo.filterItem;
    auto translator = SqlTranslator.ofFilter(dialect, filterItem, plainFieldColumn);
    FilterWhereClause extract(Object expr) {
        if (auto binOp = cast(BinaryOpInfo) expr) {
            if (binOp.operator == "&&") {
                auto left = extract(binOp.left), right = extract(binOp.right);
                if (left.sql.isNull)
                    return FilterWhereClause(right.sql, false);
                if (right.sql.isNull)
                    return FilterWhereClause(left.sql, false);
                return FilterWhereClause(Nullable!DialectSql(conjunction(left.sql.get, right.sql.get)),
                    left.complete && right.complete);
            }
        }
        auto sql = translator.condition(expr, filterItem, table);
        return FilterWhereClause(sql, !sql.isNull);
    }
    auto clause = extract(filterInfo.filterPredicate);
    clause.relations = translator.relations;
    return clause;
}

/// Recursively extract WHERE SQL from an expression tree: the condition the
/// predicate `expr` puts on the rows of `table` that `filterItem` stands for
/// (see `SqlTranslator.condition`). Reads of the item's plain fields (see
/// `PlainFieldInfo`) are reads of their columns that `plainFieldColumn`
/// gives (if not null). A predicate with any part that cannot be expressed
/// in SQL gives null.
Nullable!DialectSql extractWhereFromExpr(Object expr, Object filterItem, string table = null,
        SqlDialect dialect = null, string delegate(string) plainFieldColumn = null) {
    return SqlTranslator.ofFilter(dialect, filterItem, plainFieldColumn).condition(expr, filterItem, table);
}

/// `l AND r`
private DialectSql conjunction(DialectSql l, DialectSql r) {
    return (SqlDialect d) => "(" ~ l(d) ~ " AND " ~ r(d) ~ ")";
}

// ============================================================================
// Expression Translation
// ============================================================================

/// The translator of expressions into SQL: the conditions of WHERE clauses
/// (filter predicates, see `extractWhereFromExpr`), the computed columns of
/// query nodes (see `SqlOptimizer`) and the keys of sorts (see
/// `extractSortKey`) are what it renders of their expressions. It renders
/// the values and conditions of the rows of a table, as an item (of a
/// filter, a sort, or a collection predicate) or the elements of a map,
/// whose query node it selects, stand for them:
/// - in *filter mode*, of the rows `rootItem` stands for: reads of columns
///   of the item (and of rows related to it, see below), constants and native
///   SQL expressions (see `NativeSqlInfo`) of these, and conditions on these
///   (comparisons of a column with a constant, or of native expressions;
///   logical operations; null tests; membership tests; LIKE patterns);
/// - in *node mode*, of the rows of a query node (the map's elements, the
///   items of the filters and sorts it applies): also projections of the
///   node's columns (see `ProjectionExpr`), and any operation of the dialect
///   on these (arithmetic, comparisons of any values, conditional values,
///   conditions as values).
/// In both, a condition on a belongs-to relationship becomes a condition on
/// the row's foreign key (`fk IN (SELECT pk FROM parent WHERE ...)`, also
/// through chains of relationships), and `some` over a to-many relationship
/// an `EXISTS` subquery over the child table (its predicate translated in
/// the same mode, on the child rows its placeholder stands for).
///
/// A translator records the aliases of the subqueries it renders; in node
/// mode, the node of the expressions it translates, and the refs of that
/// node's rows (for the projection reading a computed column).
final class SqlTranslator {
    /// The dialect of the query (null if unknown).
    private SqlDialect dialect;
    private int aliases;

    /// The relations (tables of entities) the subqueries of the SQL
    /// rendered read, besides the rows' own table (see
    /// `QueryNode.relations`).
    string[] relations;

    /// The item of the filter extracted (not of the filters of collections
    /// within it), and the columns of its plain fields (null if unknown).
    private Object rootItem;
    private string delegate(string) rootPlainFieldColumn;

    /// (Node mode) The optimization's contexts, the node whose rows the
    /// values are of, and the refs of these rows (when known; null if
    /// nothing translated gave them).
    private RelationalOptimizeContext relCtx;
    private OptimizeContext optimizeCtx;
    QueryNode node;
    ExprBase nodeRefs;

    /// Whether operands may be any value computed in SQL (node mode), or
    /// only columns, constants and native expressions (filter mode: the
    /// conditions on other values, e.g. comparisons of two columns, which
    /// treat NULL values otherwise than evaluation in memory does, are
    /// evaluated in memory).
    private bool anyValues;

    private this() {}

    /// A translator of the conditions on the rows `item` stands for (filter
    /// mode).
    static SqlTranslator ofFilter(SqlDialect dialect, Object item, string delegate(string) plainFieldColumn = null) {
        auto t = new SqlTranslator;
        t.dialect = dialect;
        t.rootItem = item;
        t.rootPlainFieldColumn = plainFieldColumn;
        return t;
    }

    /// A translator of the values of the rows of a query node (node mode):
    /// of the node whose rows `expr` reads, the first that it
    /// reads; or null if it reads none.
    static SqlTranslator ofNodeRows(SqlDialect dialect, RelationalOptimizeContext relCtx,
            OptimizeContext optimizeCtx, ExprBase expr) {
        auto t = new SqlTranslator;
        t.dialect = dialect;
        t.relCtx = relCtx;
        t.optimizeCtx = optimizeCtx;
        t.anyValues = true;
        t.node = t.firstNodeRead(expr);
        return t.node is null ? null : t;
    }

    /// The SQL computing `expr` in the query of the translator's node (node
    /// mode), as a column of its SELECT clause, or null if it cannot be
    /// computed there (or the refs of its rows are unknown).
    string computedColumn(ExprBase expr) {
        assert(relCtx !is null, "computedColumn: not a translator of a node's values");
        auto value = rowValue(expr, null, node.table);
        if (!value.valid || value.constant || value.path.hops.length || nodeRefs is null)
            return null;
        return value.render(node.table);
    }

    /// The query node (see `nodeOfMap`) of the first projection
    /// (of its node's column) or map item (of the map's node) among `expr`
    /// and its dependencies, or null.
    private QueryNode firstNodeRead(ExprBase expr) {
        if (expr is null)
            return null;
        if (auto projection = cast(ProjectionInfo) expr)
            return projectionNode(expr);
        if (auto map = itemMap(expr))
            return nodeOfMap(map);
        foreach (dep; expr.dependencies())
            if (auto found = firstNodeRead(dep))
                return found;
        return null;
    }

    /// The query node of a projection (see `ProjectionInfo`).
    private static QueryNode projectionNode(ExprBase projection) {
        auto prefetch = cast(PrefetchExpr) projection.dependencies()[1];
        assert(prefetch !is null, "A projection without a PrefetchExpr");
        return prefetch.node;
    }

    /// The map whose elements `item` is (an item of the map, or of a filter
    /// or sort which the map's collection applies), or null.
    private Object itemMap(Object item) {
        if (auto every = cast(EveryItemOfExprInfo) item)
            return every.parentMap;
        if (cast(FilterItemInfo) item || cast(SortItemInfo) item)
            return optimizeCtx.elementOwner(item);
        return null;
    }

    /// The query node of the elements of `map`, or null. (A node which is
    /// not configured as a root query or a child layer, e.g. of a mutation's
    /// objects, selects the rows of the refs bound to the map, see
    /// `PrefetchExpr`.)
    private QueryNode nodeOfMap(Object map) {
        return map is null ? null : relCtx.getNode(map);
    }

    /// A fresh table alias for a subquery.
    private string newAlias() {
        return "_f" ~ (++aliases).to!string;
    }

    /// Whether `entity` is the item `item` (or, `item` being null, in node
    /// mode, a row of the translator's node: then `refs`, if not null, are
    /// the refs of `entity`'s rows).
    private bool isItem(Object entity, Object item, ExprBase refs) {
        if (item !is null)
            return entity is item;
        if (relCtx is null || nodeOfMap(itemMap(entity)) !is node)
            return false;
        if (nodeRefs is null)
            nodeRefs = refs;
        return true;
    }

    /// One belongs-to step from a row to its related row.
    static struct Hop {
        string fk;           // foreign key column of the row
        string parentTable;  // the related row's table
        string parentPk;     // and its (single-column) primary key
    }

    /// The row a predicate's operand belongs to: the item (`hops` empty) or a
    /// row related to it through belongs-to relationships.
    static struct RowPath {
        bool valid;
        Hop[] hops;
    }

    /// Resolve an entity expression to the item it is, or the row related to
    /// the item through belongs-to relationships, seeing through entity casts
    /// and nullable unwrapping. (`refs` are the refs of `entity`'s rows, if
    /// known: see isItem.)
    private RowPath resolveRow(Object entity, Object item, ExprBase refs = null) {
        while (true) {
            if (entity is null)
                return RowPath.init;
            if (isItem(entity, item, refs))
                return RowPath(true);
            if (auto inner = wrapped(entity, Transparent.entity)) {
                entity = inner;
                continue;
            }
            if (auto belongsTo = cast(BelongsToInfo) entity) {
                auto parentPk = belongsTo.parentPkColumns;
                if (parentPk.length != 1)
                    return RowPath.init;
                auto path = resolveRow(belongsTo.inputExpr, item,
                    item is null ? belongsTo.inputAsAnyRefExpr : null);
                if (!path.valid)
                    return RowPath.init;
                path.hops ~= Hop(belongsTo.fkColumn, belongsTo.parentTable, parentPk[0]);
                return path;
            }
            return RowPath.init;
        }
    }

    /// The SQL condition, on the rows of `table`, that the row `path` leads to
    /// satisfies the condition `condition` renders for a table reference.
    private DialectSql onRow(RowPath path, string table, DialectSql delegate(string rowTable) condition) {
        if (path.hops.length == 0)
            return condition(table);
        auto hop = path.hops[0];
        auto alias_ = newAlias();
        auto inner = onRow(RowPath(true, path.hops[1 .. $]), alias_, condition);
        auto fk = qualified(table, hop.fk);
        auto subquery = "SELECT " ~ alias_ ~ "." ~ hop.parentPk ~ " FROM " ~ hop.parentTable ~ " " ~ alias_ ~
            " WHERE ";
        relations ~= hop.parentTable;
        return (SqlDialect d) => "(" ~ fk ~ " IN (" ~ subquery ~ inner(d) ~ "))";
    }

    private static string qualified(string table, string column) {
        return (table.length ? table ~ "." : "") ~ column;
    }

    /// The column an operand reads, on the row it belongs to.
    private bool resolveColumn(Object expr, Object item, out RowPath path, out string column) {
        // A nullable column's values, unwrapped, or a column's values cast
        // (e.g. a value type's, to a plugin's wrapper of the type)
        expr = seeThrough(expr, Transparent.value);
        // A plain field of the filter's own item, stored in a column
        if (auto plain = cast(PlainFieldInfo) expr) {
            if (item is null || item !is rootItem || rootPlainFieldColumn is null)
                return false;
            path = resolveRow(plain.plainFieldOwner, item);
            if (!path.valid || path.hops.length)
                return false;
            column = rootPlainFieldColumn(plain.plainFieldName);
            return column !is null;
        }
        auto colAccess = cast(ColumnAccessInfo) expr;
        if (colAccess is null) return false;
        path = resolveRow(colAccess.inputExpr, item);
        column = colAccess.column;
        return path.valid;
    }

    /// The SQL of a value on the rows of `table`: a constant (on no row),
    /// or a value of the row `path` leads to, as `render` renders it for
    /// that row's table reference.
    static struct RowValue {
        bool valid;
        bool constant;
        bool native;     // Is it (or does it contain) a native SQL expression?
        RowPath path;
        string delegate(string rowTable) render;
    }

    /// The value of the values `values` (of one row, or constants), as
    /// `render` renders it on their SQL; invalid if they are not.
    private static RowValue combined(RowValue[] values, string delegate(string[] sql) render) {
        auto result = RowValue(true, true, false, RowPath(true));
        foreach (value; values) {
            if (!value.valid)
                return RowValue.init;
            result.native |= value.native;
            if (value.constant)
                continue;
            if (!result.constant && value.path.hops != result.path.hops)
                return RowValue.init;
            result.constant = false;
            result.path = value.path;
        }
        result.render = (string rowTable) {
            auto sql = new string[values.length];
            foreach (i, value; values)
                sql[i] = value.render(rowTable);
            return render(sql);
        };
        return result;
    }

    /// Whether `expr` is a condition (see `condition`), rather than a value
    /// of its operands.
    private static bool isCondition(Object expr) {
        if (auto binOp = cast(BinaryOpInfo) expr)
            return ["&&", "||", "==", "!=", "<", "<=", ">", ">="].canFind(binOp.operator);
        if (auto unaryOp = cast(UnaryOpInfo) expr)
            return unaryOp.operator == "!";
        return cast(IsNullInfo) expr || cast(CollectionPredicateInfo) expr || cast(MembershipInfo) expr ||
            cast(LikeInfo) expr;
    }

    /// The SQL of the value `expr` of the rows `item` stands for (whose
    /// table reference is `table`): a constant, a column of a row (see
    /// `resolveColumn`), or a native SQL expression (see `NativeSqlInfo`)
    /// having a native form in the dialect, on such values of one row; in
    /// node mode, also a projection of a column of the node, and (see
    /// `anyValues`) an operation on such values of one row, or a condition.
    private RowValue rowValue(Object expr, Object item, string table) {
        if (anyValues && isCondition(expr)) {
            auto condition = condition(expr, item, table);
            if (condition.isNull)
                return RowValue.init;
            auto sql = condition.get()(dialect);
            return RowValue(true, false, false, RowPath(true), (string) => sql);
        }
        auto literal = extractConstant(expr);
        if (!literal.isNull) {
            auto sql = literal.get;
            return RowValue(true, true, false, RowPath(true), (string) => sql);
        }
        RowPath path;
        string column;
        if (resolveColumn(expr, item, path, column))
            return RowValue(true, false, false, path, (string rowTable) => qualified(rowTable, column));
        // A native expression's values, unwrapped or cast (as a column's)
        expr = seeThrough(expr, Transparent.value);
        if (auto projection = cast(ProjectionInfo) expr)
            return projectionValue(cast(ExprBase) expr, projection, item);
        if (auto native = cast(NativeSqlInfo) expr) {
            if (dialect is null || !native.hasNativeSql(dialect))
                return RowValue.init;
            auto queryDialect = dialect;
            auto value = combined(native.nativeOperands.map!(operand => rowValue(operand, item, table)).array,
                (string[] sql) => native.nativeSql(queryDialect, sql));
            value.native = true;
            return value;
        }
        if (!anyValues)
            return RowValue.init;
        auto queryDialect = dialect;
        if (auto binOp = cast(BinaryOpInfo) expr) {
            auto op = binOp.operator;
            return combined([rowValue(binOp.left, item, table), rowValue(binOp.right, item, table)],
                (string[] sql) => queryDialect.binaryOp(op, sql[0], sql[1]));
        }
        if (auto unaryOp = cast(UnaryOpInfo) expr) {
            auto op = unaryOp.operator;
            return combined([rowValue(unaryOp.operand, item, table)],
                (string[] sql) => queryDialect.unaryOp(op, sql[0]));
        }
        if (auto ternary = cast(TernaryInfo) expr)
            return combined([rowValue(ternary.condition, item, table), rowValue(ternary.trueExpr, item, table),
                    rowValue(ternary.falseExpr, item, table)],
                (string[] sql) => queryDialect.caseWhen(sql[0], sql[1], sql[2]));
        return RowValue.init;
    }

    /// The value a projection reads (see `ProjectionInfo`), of a row of the
    /// translator's node (node mode, `item` being null): its column, a
    /// column of a table the node's query joins, or the expression of a
    /// computed column of the node.
    private RowValue projectionValue(ExprBase expr, ProjectionInfo projection, Object item) {
        if (item !is null || relCtx is null || projectionNode(expr) !is node)
            return RowValue.init;
        if (nodeRefs is null)
            nodeRefs = expr.dependencies()[0];
        auto projected = projection.projected;
        final switch (projected.kind) {
            case ProjectedColumn.Kind.column:
                auto column = projected.name;
                return RowValue(true, false, false, RowPath(true), (string rowTable) => qualified(rowTable, column));
            case ProjectedColumn.Kind.joined:
                auto sql = projected.join.value ~ "." ~ projected.name;
                return RowValue(true, false, false, RowPath(true), (string) => sql);
            case ProjectedColumn.Kind.computed:
                foreach (computed; node.computedColumns)
                    if (computed.alias_ == projected.name) {
                        auto sql = computed.sqlExpr;
                        return RowValue(true, false, false, RowPath(true), (string) => sql);
                    }
                return RowValue.init;
        }
    }

    /// The SQL of the operand `expr` of a condition, on the row `path` leads
    /// to (see resolveRow): a column, or (see anyValues) any value of a row
    /// (not a constant).
    private bool operandValue(Object expr, Object item, string table, out RowPath path,
            out string delegate(string rowTable) render) {
        string column;
        if (resolveColumn(expr, item, path, column)) {
            render = (string rowTable) => qualified(rowTable, column);
            return true;
        }
        if (!anyValues)
            return false;
        auto value = rowValue(expr, item, table);
        if (!value.valid || value.constant)
            return false;
        path = value.path;
        render = value.render;
        return true;
    }

    /// The SQL condition the predicate `expr` puts on the rows of `table`
    /// which `item` stands for (in node mode, `item` being null, the rows of
    /// the translator's node), or null if it cannot be expressed in SQL.
    Nullable!DialectSql condition(Object expr, Object item, string table) {
        // Handle binary operators: AND, OR, comparison operators
        if (auto binOp = cast(BinaryOpInfo) expr) {
            string op = binOp.operator;

            // Logical operators: AND, OR
            if (op == "&&" || op == "||") {
                auto leftSql = condition(binOp.left, item, table);
                auto rightSql = condition(binOp.right, item, table);
                if (!leftSql.isNull && !rightSql.isNull) {
                    string sqlOp = (op == "&&") ? "AND" : "OR";
                    auto l = leftSql.get, r = rightSql.get;
                    return Nullable!DialectSql((SqlDialect d) => "(" ~ l(d) ~ " " ~ sqlOp ~ " " ~ r(d) ~ ")");
                }
                return Nullable!DialectSql.init;
            }

            // Comparison operators: ==, !=, <, <=, >, >=
            if (op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=") {
                // Try to match: column op constant or constant op column
                RowPath path;
                string column;
                string value;
                bool isColumnOnLeft;
                auto leftConst = extractConstant(binOp.left);
                auto rightConst = extractConstant(binOp.right);
                if (!rightConst.isNull && resolveColumn(binOp.left, item, path, column)) {
                    value = rightConst.get;
                    isColumnOnLeft = true;
                } else if (!leftConst.isNull && resolveColumn(binOp.right, item, path, column)) {
                    value = leftConst.get;
                    isColumnOnLeft = false;
                } else {
                    // Comparisons of native SQL expressions (with constants,
                    // columns or native expressions of the same row), or (see
                    // anyValues) of any values of one row
                    auto left = rowValue(binOp.left, item, table);
                    auto right = rowValue(binOp.right, item, table);
                    if (!left.valid || !right.valid || !(left.native || right.native || anyValues) ||
                            (left.constant && right.constant) ||
                            (!left.constant && !right.constant && left.path.hops != right.path.hops))
                        return Nullable!DialectSql.init;
                    auto valueOp = translateComparisonOp(op, true);
                    return Nullable!DialectSql(onRow(left.constant ? right.path : left.path, table,
                        (string rowTable) {
                            auto sql = "(" ~ left.render(rowTable) ~ " " ~ valueOp ~ " " ~ right.render(rowTable) ~ ")";
                            return (SqlDialect _) => sql;
                        }));
                }

                string sqlOp = translateComparisonOp(op, isColumnOnLeft);
                return Nullable!DialectSql(onRow(path, table, (string rowTable) {
                    auto sql = qualified(rowTable, column) ~ " " ~ sqlOp ~ " " ~ value;
                    return (SqlDialect _) => sql;
                }));
            }
        }

        // Handle unary NOT operator
        if (auto unaryOp = cast(UnaryOpInfo) expr) {
            if (unaryOp.operator == "!") {
                auto operandSql = condition(unaryOp.operand, item, table);
                if (!operandSql.isNull) {
                    auto operand = operandSql.get;
                    return Nullable!DialectSql((SqlDialect d) => "NOT " ~ operand(d));
                }
                return Nullable!DialectSql.init;
            }
        }

        // Handle null checks of nullable columns and relationships, (see
        // anyValues) and of any values
        if (auto isNullOp = cast(IsNullInfo) expr) {
            RowPath path;
            string delegate(string) render;
            if (auto belongsTo = cast(BelongsToInfo) isNullOp.operand) {
                // A nullable belongs-to relationship is null if its foreign key is.
                path = resolveRow(belongsTo.inputExpr, item, item is null ? belongsTo.inputAsAnyRefExpr : null);
                auto fk = belongsTo.fkColumn;
                render = (string rowTable) => qualified(rowTable, fk);
            } else
                operandValue(isNullOp.operand, item, table, path, render);
            if (!path.valid)
                return Nullable!DialectSql.init;
            return Nullable!DialectSql(onRow(path, table, (string rowTable) {
                auto sql = "(" ~ render(rowTable) ~ " IS NULL)";
                return (SqlDialect _) => sql;
            }));
        }

        // Handle `some` over a to-many relationship
        if (auto collPred = cast(CollectionPredicateInfo) expr) {
            // The collection, seen through element-wise entity casts
            auto hasMany = cast(HasManyInfo) seeThrough(collPred.collection, Transparent.elements);
            if (hasMany is null || hasMany.parentPkColumns.length != 1)
                return Nullable!DialectSql.init;
            auto path = resolveRow(hasMany.inputExpr, item, item is null ? hasMany.inputAsAnyRefExpr : null);
            if (!path.valid)
                return Nullable!DialectSql.init;
            auto childAlias = newAlias();
            auto predicate = condition(collPred.predicate, collPred.itemPlaceholder, childAlias);
            if (predicate.isNull)
                return Nullable!DialectSql.init;
            auto pred = predicate.get;
            auto childTable = hasMany.childTable;
            relations ~= childTable;
            auto fk = hasMany.fkColumn;
            auto parentPk = hasMany.parentPkColumns[0];
            return Nullable!DialectSql(onRow(path, table, (string rowTable) {
                auto subquery = "SELECT 1 FROM " ~ childTable ~ " " ~ childAlias ~
                    " WHERE " ~ childAlias ~ "." ~ fk ~ " = " ~ qualified(rowTable, parentPk) ~ " AND ";
                return (SqlDialect d) => d.existsSubquery(subquery ~ pred(d));
            }));
        }

        // Handle membership tests of columns (isAmong)
        if (auto membership = cast(MembershipInfo) expr) {
            RowPath path;
            string delegate(string) render;
            if (operandValue(membership.operand, item, table, path, render)) {
                auto valueType = membership.valueType;
                auto values = membership.valuesAsStrings;
                if (values.length == 0)
                    return dialectAgnostic("1=0");
                return Nullable!DialectSql(onRow(path, table, (string rowTable) {
                    auto operandSql = render(rowTable);
                    return (SqlDialect d) => d.membershipOp(operandSql, valueType, values);
                }));
            }
            return Nullable!DialectSql.init;
        }

        // Handle constant true/false
        if (auto constInfo = cast(ConstantInfo) expr) {
            if (constInfo.valueType == typeid(bool)) {
                bool val = constInfo.valueAsString == "true";
                return dialectAgnostic(val ? "1=1" : "1=0");
            }
        }

        // Handle LIKE expressions (contains, startsWith, endsWith, like)
        if (auto likeInfo = cast(LikeInfo) expr) {
            RowPath path;
            string delegate(string) render;
            if (operandValue(likeInfo.likeOperand, item, table, path, render)) {
                // The pattern already has % and _ escaped as \% and \_ by
                // escapeLikePattern() (or is a LIKE pattern); the dialect
                // quotes it and picks the (case-sensitive or -insensitive)
                // matching operator.
                string escapedPattern = likeInfo.likePattern.replace("'", "''");
                bool caseInsensitive = likeInfo.caseInsensitive;
                return Nullable!DialectSql(onRow(path, table, (string rowTable) {
                    auto operandSql = render(rowTable);
                    return (SqlDialect d) => d.likeOp(operandSql, escapedPattern, caseInsensitive);
                }));
            }
            return Nullable!DialectSql.init;
        }

        // Handle native conditions, in a dialect which has a native form of
        // them, on values of one row (columns, constants, native
        // expressions), and (see anyValues) other values used as conditions
        auto exprBase = cast(ExprBase) expr;
        if (exprBase is null || exprBase.resultType != typeid(bool) || isCondition(expr) ||
                (cast(NativeSqlInfo) expr is null && !anyValues))
            return Nullable!DialectSql.init;
        auto value = rowValue(expr, item, table);
        if (!value.valid || value.constant)
            return Nullable!DialectSql.init;
        auto render = value.render;
        return Nullable!DialectSql(onRow(value.path, table, (string rowTable) {
            auto sql = render(rowTable);
            return (SqlDialect _) => sql;
        }));
    }
}

// ============================================================================
// Sort Keys
// ============================================================================

/// The ORDER BY key of a sort (see `SortByInfo`) whose predicate compares
/// the same value of the two items compared, `<` (ascending) or `>`
/// (descending): a column of the items, or a native SQL expression (see
/// `NativeSqlInfo`) of them which `dialect` (that of the query of the rows
/// sorted, null if unknown) has a native form of, rendered on the rows of
/// `table`; or null if the sort is not such a one.
///
/// The predicate is either a `<` / `>` comparison, or an ordering of values
/// (see `OrderComparisonInfo`), whose nulls come last ascending and first
/// descending (as the dialects order them, see `SqlDialect.orderByTerm`),
/// and whose enum members come in declaration order: the key of an enum
/// value is the position of its label (in a CASE expression), whatever
/// order the database has of the labels.
Nullable!SortKey extractSortKey(SortByInfo sort, string table, SqlDialect dialect) {
    import dunamis.core.sorting : OrderComparisonInfo;

    ExprBase leftOperand, rightOperand;
    SortDirection direction;
    string[] enumLabels;
    if (auto ordering = cast(OrderComparisonInfo) sort.sortPredicate) {
        leftOperand = ordering.left;
        rightOperand = ordering.right;
        direction = ordering.direction;
        enumLabels = ordering.enumLabels;
    } else {
        auto binOp = cast(BinaryOpInfo) sort.sortPredicate;
        if (binOp is null || (binOp.operator != "<" && binOp.operator != ">"))
            return Nullable!SortKey.init;
        leftOperand = binOp.left;
        rightOperand = binOp.right;
        direction = binOp.operator == "<" ? SortDirection.ASC : SortDirection.DESC;
    }
    auto leftItem = sort.sortLeftItem, rightItem = sort.sortRightItem;
    auto left = SqlTranslator.ofFilter(dialect, leftItem), right = SqlTranslator.ofFilter(dialect, rightItem);

    // A column of the items themselves
    auto leftColumn = cast(ColumnAccessInfo) leftOperand, rightColumn = cast(ColumnAccessInfo) rightOperand;
    if (leftColumn !is null && rightColumn !is null) {
        auto leftRow = left.resolveRow(leftColumn.inputExpr, leftItem);
        auto rightRow = right.resolveRow(rightColumn.inputExpr, rightItem);
        if (!(leftRow.valid && !leftRow.hops.length && rightRow.valid && !rightRow.hops.length &&
                leftColumn.column == rightColumn.column))
            return Nullable!SortKey.init;
        if (enumLabels is null)
            return Nullable!SortKey(SortKey(leftColumn.column, null, null, direction));
        // An enum column: by the position of its label (rendered for the
        // dialect, if it is known)
        if (dialect is null)
            return Nullable!SortKey.init;
        auto sql = enumPositionSql(dialect, SqlTranslator.qualified(table, leftColumn.column), enumLabels);
        return Nullable!SortKey(SortKey(null, sql, typeid(int), direction));
    }

    // A native expression of the items themselves (the same on both)
    if (dialect is null)
        return Nullable!SortKey.init;
    auto leftValue = left.rowValue(leftOperand, leftItem, table);
    auto rightValue = right.rowValue(rightOperand, rightItem, table);
    if (!leftValue.valid || !rightValue.valid || !leftValue.native || leftValue.constant || rightValue.constant ||
            leftValue.path.hops.length || rightValue.path.hops.length)
        return Nullable!SortKey.init;
    auto sql = leftValue.render(table);
    if (sql != rightValue.render(table))
        return Nullable!SortKey.init;
    if (enumLabels !is null)
        return Nullable!SortKey(SortKey(null, enumPositionSql(dialect, sql, enumLabels), typeid(int), direction));
    return Nullable!SortKey(SortKey(null, sql, leftOperand.resultType, direction));
}

/// The SQL of the position of the enum value `sql` (by its stored label)
/// among the labels `labels`, starting from 0; NULL for NULL (and for a
/// label which is not one of them).
string enumPositionSql(SqlDialect dialect, string sql, string[] labels) {
    import std.conv : to;
    string result = "CASE " ~ sql;
    foreach (i, label; labels)
        result ~= " WHEN " ~ dialect.escapeSqlString(label) ~ " THEN " ~ i.to!string;
    return result ~ " END";
}

/// ditto
struct SortKey {
    /// The column of the items (or null)
    string column;
    /// Or the SQL of the native expression, and its result type
    string sql;
    TypeInfo type;
    SortDirection direction;
}

private Nullable!DialectSql dialectAgnostic(string sql) {
    return Nullable!DialectSql((SqlDialect) => sql);
}

/// Extract SQL literal from a constant expression.
private Nullable!string extractConstant(Object expr) {
    auto constInfo = cast(ConstantInfo) expr;
    if (constInfo is null) return Nullable!string.init;

    return Nullable!string(constantToSqlLiteral(constInfo));
}

/// Convert comparison operator to SQL, handling operand order.
string translateComparisonOp(string op, bool columnOnLeft) {
    if (columnOnLeft) {
        // column op value - use operator as-is
        switch (op) {
            case "==": return "=";
            case "!=": return "<>";
            case "<": return "<";
            case "<=": return "<=";
            case ">": return ">";
            case ">=": return ">=";
            default: return op;
        }
    } else {
        // value op column - reverse operator
        switch (op) {
            case "==": return "=";
            case "!=": return "<>";
            case "<": return ">";    // value < column → column > value
            case "<=": return ">=";
            case ">": return "<";
            case ">=": return "<=";
            default: return op;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test SqlOptimizer creation
    // Use a simple test dialect
    static class TestDialect : SqlDialect {
        override string binaryOp(string op, string leftSql, string rightSql) {
            return "(" ~ leftSql ~ " " ~ op ~ " " ~ rightSql ~ ")";
        }
        override string unaryOp(string op, string operandSql) {
            if (op == "!") return "(NOT " ~ operandSql ~ ")";
            return "(" ~ op ~ operandSql ~ ")";
        }
        override string caseWhen(string conditionSql, string trueSql, string falseSql) {
            return "(CASE WHEN " ~ conditionSql ~ " THEN " ~ trueSql ~ " ELSE " ~ falseSql ~ " END)";
        }
        override string isNullOp(string operandSql) {
            return "(" ~ operandSql ~ " IS NULL)";
        }
        override string existsSubquery(string subquery) {
            return "EXISTS (" ~ subquery ~ ")";
        }
        override string notExistsSubquery(string subquery) {
            return "NOT EXISTS (" ~ subquery ~ ")";
        }
        override string membershipOp(string operandSql, TypeInfo valueType, string[] values) {
            import dunamis.relational.sql_dialect : inListSql;
            return inListSql(operandSql, valueType, values);
        }

        override string likeOp(string operandSql, string pattern, bool caseInsensitive) {
            if (caseInsensitive) {
                return "(LOWER(" ~ operandSql ~ ") LIKE LOWER('" ~ pattern ~ `') ESCAPE '\')`;
            }
            return "(" ~ operandSql ~ " LIKE '" ~ pattern ~ `' ESCAPE '\')`;
        }
        override string name() { return "Test"; }
        override string escapeSqlString(string s) { return "'" ~ s ~ "'"; }
        override string jsonToSqlLiteral(JSONValue) { return "NULL"; }
        override string rootIdFilter(string table, string[] pkColumns) { return table ~ "." ~ pkColumns[0] ~ " = ANY($1)"; }
        override string jsonObjectFunc() { return "json_build_object"; }
        override string rowJsonFunc() { return ""; }
        override string emptyJsonArray() { return "'[]'::json"; }
        override string aggregateLayerJson(int, string) { return ""; }
        override string castToText(string sql) { return sql ~ "::text"; }
        override string orderByTerm(string sql, bool descending) { return sql ~ (descending ? " DESC" : ""); }
    }
    auto optimizer = new SqlOptimizer(new TestDialect());
    assert(optimizer !is null);
}

unittest {
    // Test computed column detection
    // Create a mock expression tree: projection + " " + projection

    // Minimal entity for testing
    static struct TestUser {
        import dunamis.relational.schema.attrs : PrimaryKey;
        @PrimaryKey string id;
    }

    // Create mock QueryNode and PrefetchExpr
    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    auto prefetch = new PrefetchExpr(node);

    // Create a mock input
    auto item = new EveryItemOfExpr!TestUser();

    // First, set up mock projections with input and prefetch
    auto proj1 = new ProjectionExpr!string(QueryNodeId(0), ProjectedColumn.column("first_name"), item, prefetch);
    auto proj2 = new ProjectionExpr!string(QueryNodeId(0), ProjectedColumn.column("last_name"), item, prefetch);

    // Create binary op: proj1 ~ " " ~ proj2
    auto space = constant(" ", proj1);  // Derive length from proj1
    auto concat1 = new BinaryOpExpr!(string, "~", string)(proj1, space);
    auto concat2 = new BinaryOpExpr!(string, "~", string)(concat1, proj2);

    // Wrap in a UseExpr so we can test replacement
    auto wrapper = use((string s) => s, concat2);

    // Run SQL optimizer with test dialect
    static class TestDialect : SqlDialect {
        override string binaryOp(string op, string leftSql, string rightSql) {
            return "(" ~ leftSql ~ " " ~ op ~ " " ~ rightSql ~ ")";
        }
        override string unaryOp(string op, string operandSql) {
            if (op == "!") return "(NOT " ~ operandSql ~ ")";
            return "(" ~ op ~ operandSql ~ ")";
        }
        override string caseWhen(string conditionSql, string trueSql, string falseSql) {
            return "(CASE WHEN " ~ conditionSql ~ " THEN " ~ trueSql ~ " ELSE " ~ falseSql ~ " END)";
        }
        override string isNullOp(string operandSql) {
            return "(" ~ operandSql ~ " IS NULL)";
        }
        override string existsSubquery(string subquery) {
            return "EXISTS (" ~ subquery ~ ")";
        }
        override string notExistsSubquery(string subquery) {
            return "NOT EXISTS (" ~ subquery ~ ")";
        }
        override string membershipOp(string operandSql, TypeInfo valueType, string[] values) {
            import dunamis.relational.sql_dialect : inListSql;
            return inListSql(operandSql, valueType, values);
        }

        override string likeOp(string operandSql, string pattern, bool caseInsensitive) {
            if (caseInsensitive) {
                return "(LOWER(" ~ operandSql ~ ") LIKE LOWER('" ~ pattern ~ `') ESCAPE '\')`;
            }
            return "(" ~ operandSql ~ " LIKE '" ~ pattern ~ `' ESCAPE '\')`;
        }
        override string name() { return "Test"; }
        override string escapeSqlString(string s) { return "'" ~ s ~ "'"; }
        override string jsonToSqlLiteral(JSONValue) { return "NULL"; }
        override string rootIdFilter(string table, string[] pkColumns) { return table ~ "." ~ pkColumns[0] ~ " = ANY($1)"; }
        override string jsonObjectFunc() { return "json_build_object"; }
        override string rowJsonFunc() { return ""; }
        override string emptyJsonArray() { return "'[]'::json"; }
        override string aggregateLayerJson(int, string) { return ""; }
        override string castToText(string sql) { return sql ~ "::text"; }
        override string orderByTerm(string sql, bool descending) { return sql ~ (descending ? " DESC" : ""); }
    }
    auto ctx = new OptimizeContext();
    auto sqlOpt = new SqlOptimizer(new TestDialect());
    sqlOpt.optimize(wrapper, ctx);

    // Check that computed columns were created
    auto computed = node.computedColumns;
    assert(computed.length >= 1);
}

unittest {
    // Test ProjectionExpr of a computed column
    static struct TestUser {
        import dunamis.relational.schema.attrs : PrimaryKey;
        @PrimaryKey string id;
    }

    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    auto prefetch = new PrefetchExpr(node);
    auto item = new EveryItemOfExpr!TestUser();
    auto proj = new ProjectionExpr!string(QueryNodeId(0), ProjectedColumn.computed("computed_0"), item, prefetch,
        constant("computed", item));
    assert(proj.queryNodeId == QueryNodeId(0));
    assert(proj.projected.resultColumn == "computed_0");
    assert(proj.dependencies().length == 2);  // input and prefetch
}
