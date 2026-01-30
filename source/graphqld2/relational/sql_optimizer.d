module graphqld2.relational.sql_optimizer;

import std.algorithm;
import std.array;
import std.conv;
import std.traits;
import std.typecons : Nullable;

import ae.utils.promise;

import graphqld2.core.types;
import graphqld2.core.eval;
import graphqld2.core.expr;
import graphqld2.core.optimize : OptimizeContext, ExprOptimizer;
import graphqld2.relational.eval_context : RelationalEvalContext;
import graphqld2.relational.query_node;
import graphqld2.relational.schema;
import graphqld2.relational.project;

// ============================================================================
// SQL Literal Generation
// ============================================================================

/// Convert a D value to a SQL literal string
string toSqlLiteral(T)(T value) {
    static if (is(T == string)) {
        // Escape single quotes for SQL
        return "'" ~ value.replace("'", "''") ~ "'";
    } else static if (is(T == bool)) {
        return value ? "TRUE" : "FALSE";
    } else static if (is(T == typeof(null))) {
        return "NULL";
    } else static if (isNumeric!T) {
        return value.to!string;
    } else {
        // Fall back to string conversion with quoting
        return "'" ~ value.to!string.replace("'", "''") ~ "'";
    }
}

/// Convert a ConstantInfo to SQL literal using runtime type dispatch
string constantToSqlLiteral(ConstantInfo info) {
    auto type = info.valueType;
    auto strValue = info.valueAsString;

    // Check for string types
    if (type == typeid(string)) {
        return "'" ~ strValue.replace("'", "''") ~ "'";
    }
    // Check for bool
    if (type == typeid(bool)) {
        return strValue == "true" ? "TRUE" : "FALSE";
    }
    // Numeric types pass through as-is
    if (type == typeid(int) || type == typeid(long) ||
        type == typeid(float) || type == typeid(double) ||
        type == typeid(uint) || type == typeid(ulong) ||
        type == typeid(short) || type == typeid(ushort)) {
        return strValue;
    }
    // Default: quote as string
    return "'" ~ strValue.replace("'", "''") ~ "'";
}

// ============================================================================
// Computed Column Support
// ============================================================================

/// A computed column to be added to a QueryNode's SELECT clause
struct ComputedColumn {
    string alias_;     // SQL alias (e.g., "computed_0")
    string sqlExpr;    // SQL expression (e.g., "first_name || ' ' || last_name")
    TypeInfo type;     // Result type for creating typed projection
}

// ============================================================================
// SQL Optimizer
// ============================================================================

/// External optimizer that walks expression trees and applies SQL push-down.
/// Uses the dependencies()/replaceDependency() interface for tree traversal.
///
/// Usage:
///   1. First run the standard optimizer to create QueryNodes and ProjectionExprs
///   2. Then run SqlOptimizer to find BinaryOpExprs over projections
///   3. SqlOptimizer replaces them with ProjectComputedExprs
///   4. Computed columns are added to QueryNode SQL generation
///
/// Data sources that support SQL computed columns should return an instance
/// of this class from their requestedOptimizers() method.
class SqlOptimizer : ExprOptimizer {
    /// Track computed columns per QueryNode ID
    private ComputedColumn[][int] _computedColumns;

    /// Next computed column alias counter
    private int _nextComputedAlias = 0;

    /// Optimize an expression tree, applying SQL push-down where possible.
    /// This should be called AFTER the standard optimizer has run.
    override void optimize(ExprBase expr, OptimizeContext ctx) {
        optimizeRecursive(expr, ctx);
    }

    /// Recursively optimize expression and its children
    private void optimizeRecursive(ExprBase expr, OptimizeContext ctx) {
        // First, try to optimize this node (which may replace children)
        tryPushDown(expr, ctx);

        // Then recurse into children (some may have been replaced above)
        auto deps = expr.dependencies();
        foreach (dep; deps) {
            optimizeRecursive(dep, ctx);
        }
    }

    /// Try to push down an expression to SQL
    private void tryPushDown(ExprBase parent, OptimizeContext ctx) {
        auto deps = parent.dependencies();

        foreach (i, dep; deps) {
            // Check if this dependency is a binary operation that could be pushed down
            if (auto binOp = cast(BinaryOpInfo) dep) {
                auto replacement = tryPushDownBinaryOp(dep, binOp, ctx);
                if (replacement !is null && replacement !is dep) {
                    parent.replaceDependency(i, replacement);
                }
            }
        }
    }

    /// Try to push down a binary operation to SQL
    private ExprBase tryPushDownBinaryOp(ExprBase expr, BinaryOpInfo binOp, OptimizeContext ctx) {
        // Check if both operands can be translated to SQL
        int queryNodeId = -1;
        auto leftSql = tryGetSqlExpr(binOp.left, queryNodeId);
        auto rightSql = tryGetSqlExpr(binOp.right, queryNodeId);

        if (leftSql.isNull || rightSql.isNull || queryNodeId < 0) {
            // Can't push down - operands aren't SQL-translatable or from different nodes
            return null;
        }

        // Extract the input and prefetch from one of the projection expressions
        auto input = extractInputFromExpr(binOp.left);
        if (input is null) {
            input = extractInputFromExpr(binOp.right);
        }
        if (input is null) {
            // Can't find input - shouldn't happen if we have valid projections
            return null;
        }

        auto prefetch = extractPrefetchFromExpr(binOp.left);
        if (prefetch is null) {
            prefetch = extractPrefetchFromExpr(binOp.right);
        }
        if (prefetch is null) {
            // Can't find prefetch - shouldn't happen if we have valid projections
            return null;
        }

        // Build the SQL expression
        auto sqlOp = toSqlOp(binOp.operator);
        auto sqlExpr = "(" ~ leftSql.get ~ " " ~ sqlOp ~ " " ~ rightSql.get ~ ")";

        // Create computed column alias
        auto alias_ = "computed_" ~ (_nextComputedAlias++).to!string;

        // Register the computed column
        if (queryNodeId !in _computedColumns) {
            _computedColumns[queryNodeId] = [];
        }
        _computedColumns[queryNodeId] ~= ComputedColumn(alias_, sqlExpr, expr.resultType);

        // Create and return projection for computed column
        return createProjectComputedExpr(queryNodeId, alias_, expr.resultType, input, prefetch);
    }

    /// Extract the input expression from a projection or binary op
    private Expr!Ref extractInputFromExpr(ExprBase expr) {
        // Check dependencies - projection expressions have their input as first dependency
        auto deps = expr.dependencies();
        if (deps.length > 0) {
            if (auto refExpr = cast(Expr!Ref) deps[0]) {
                return refExpr;
            }
        }
        // Recurse into binary ops
        if (auto binOp = cast(BinaryOpInfo) expr) {
            auto left = extractInputFromExpr(binOp.left);
            if (left !is null) return left;
            return extractInputFromExpr(binOp.right);
        }
        return null;
    }

    /// Extract the PrefetchExpr from a projection or binary op
    private PrefetchExpr extractPrefetchFromExpr(ExprBase expr) {
        // Check dependencies - projection expressions have prefetch as second dependency
        auto deps = expr.dependencies();
        if (deps.length > 1) {
            if (auto prefetch = cast(PrefetchExpr) deps[1]) {
                return prefetch;
            }
        }
        // Recurse into binary ops
        if (auto binOp = cast(BinaryOpInfo) expr) {
            auto left = extractPrefetchFromExpr(binOp.left);
            if (left !is null) return left;
            return extractPrefetchFromExpr(binOp.right);
        }
        return null;
    }

    /// Try to get SQL expression for an operand.
    /// Also tracks the queryNodeId to ensure all parts come from the same node.
    private Nullable!string tryGetSqlExpr(ExprBase expr, ref int queryNodeId) {
        // Check if it's a column projection
        if (auto projCol = cast(ProjectColumnInfo) expr) {
            if (queryNodeId < 0) {
                queryNodeId = projCol.queryNodeId;
            } else if (queryNodeId != projCol.queryNodeId) {
                // Different query nodes - can't combine
                return Nullable!string.init;
            }
            // Get the table name from QueryNode
            // For now, just use the column name directly (assumes single table)
            return Nullable!string(projCol.column);
        }

        // Check if it's a joined column projection
        if (auto projJoin = cast(ProjectJoinedColumnInfo) expr) {
            if (queryNodeId < 0) {
                queryNodeId = projJoin.queryNodeId;
            } else if (queryNodeId != projJoin.queryNodeId) {
                return Nullable!string.init;
            }
            return Nullable!string(projJoin.joinAlias ~ "." ~ projJoin.column);
        }

        // Check if it's a constant
        if (auto constInfo = cast(ConstantInfo) expr) {
            return Nullable!string(constantToSqlLiteral(constInfo));
        }

        // Check if it's a nested binary op
        if (auto binOp = cast(BinaryOpInfo) expr) {
            auto leftSql = tryGetSqlExpr(binOp.left, queryNodeId);
            auto rightSql = tryGetSqlExpr(binOp.right, queryNodeId);
            if (!leftSql.isNull && !rightSql.isNull) {
                auto sqlOp = toSqlOp(binOp.operator);
                return Nullable!string("(" ~ leftSql.get ~ " " ~ sqlOp ~ " " ~ rightSql.get ~ ")");
            }
        }

        return Nullable!string.init;
    }

    /// Create a ProjectComputedExpr for the given result type.
    /// Since we need to create a typed expression but only have TypeInfo at runtime,
    /// we use a factory approach with common types.
    private ExprBase createProjectComputedExpr(int queryNodeId, string alias_, TypeInfo type, Expr!Ref input, PrefetchExpr prefetch) {
        // Handle common types
        if (type == typeid(string)) {
            return new ProjectComputedExpr!string(queryNodeId, alias_, input, prefetch);
        }
        if (type == typeid(int)) {
            return new ProjectComputedExpr!int(queryNodeId, alias_, input, prefetch);
        }
        if (type == typeid(long)) {
            return new ProjectComputedExpr!long(queryNodeId, alias_, input, prefetch);
        }
        if (type == typeid(float)) {
            return new ProjectComputedExpr!float(queryNodeId, alias_, input, prefetch);
        }
        if (type == typeid(double)) {
            return new ProjectComputedExpr!double(queryNodeId, alias_, input, prefetch);
        }
        if (type == typeid(bool)) {
            return new ProjectComputedExpr!bool(queryNodeId, alias_, input, prefetch);
        }

        // Unsupported type - return null (caller should keep original expression)
        return null;
    }

    /// Get computed columns for a QueryNode (for SQL generation)
    ComputedColumn[] getComputedColumns(int queryNodeId) {
        return _computedColumns.get(queryNodeId, []);
    }

    /// Check if a QueryNode has any computed columns
    bool hasComputedColumns(int queryNodeId) {
        return queryNodeId in _computedColumns && _computedColumns[queryNodeId].length > 0;
    }

    /// Get all computed columns keyed by QueryNode ID
    const(ComputedColumn[][int]) allComputedColumns() {
        return _computedColumns;
    }
}

// ============================================================================
// Computed Column Projection Expression
// ============================================================================

/// Projection expression that reads a computed column from QueryResult.
/// Created by SqlOptimizer when pushing down expressions to SQL.
class ProjectComputedExpr(T) : Expr!T {
    private int _queryNodeId;
    private string _alias;
    private ExprBase _input;     // The input chain (for deriving refs)
    private ExprBase _prefetch;  // PrefetchExpr - ensures data is loaded

    this(int queryNodeId, string alias_, Expr!Ref input, PrefetchExpr prefetch) {
        _queryNodeId = queryNodeId;
        _alias = alias_;
        _input = input;
        _prefetch = prefetch;
    }

    override ExprBase[] dependencies() {
        return [_input, _prefetch];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
        else if (index == 1)
            _prefetch = newDep;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto queryNodeId = _queryNodeId;
        auto alias_ = _alias;
        auto input = _input;

        // Ensure data is prefetched, then evaluate input, then read
        return evalAs!(Ref[])(_prefetch, ctx).then((_) {
            return evalAs!Ref(input, ctx);
        }).then((Ref[] refs) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext();
            return relCtx.getColumnValues!T(queryNodeId, alias_, refs);
        });
    }

    @property int queryNodeId() { return _queryNodeId; }
    @property string columnAlias() { return _alias; }
}

// ============================================================================
// SQL Generation with Computed Columns
// ============================================================================

/// Generate a complete CTE-based SQL query (without computed columns).
string toSQL(QueryNode[] nodes) {
    return toSQL(nodes, null);
}

/// Generate a complete CTE-based SQL query with computed columns.
string toSQL(QueryNode[] nodes, SqlOptimizer sqlOpt) {
    import std.format : format;

    if (nodes.length == 0)
        return "";

    auto sql = appender!string;

    // Build CTEs for each layer
    sql ~= "WITH\n";

    string[] ctes;
    foreach (node; nodes) {
        ctes ~= toCTEWithComputed(node, sqlOpt);
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

/// Generate CTE for a single QueryNode with computed columns
private string toCTEWithComputed(QueryNode node, SqlOptimizer sqlOpt) {
    import std.format : format;

    auto sql = appender!string;

    sql ~= format("  layer%d AS (\n", node.id);
    sql ~= "    SELECT ";
    sql ~= toSelectWithComputed(node, sqlOpt);
    sql ~= format("\n    FROM %s", node.table);

    // Add JOINs for belongsTo relationships
    foreach (joinInfo; node.joins) {
        sql ~= format("\n    LEFT JOIN %s %s ON %s.%s = %s.id",
            joinInfo.targetTable, joinInfo.alias_,
            node.table, joinInfo.fk, joinInfo.alias_);
    }

    // WHERE clause
    sql ~= "\n    WHERE ";
    if (node.isRoot) {
        final switch (node.rootFilter) {
            case FilterType.none:
            case FilterType.all:
                sql ~= "1=1";
                break;
            case FilterType.byId:
            case FilterType.byIds:
                sql ~= format("%s.id = ANY($1)", node.table);
                break;
        }
    } else {
        sql ~= format("%s.%s IN (SELECT id FROM layer%d)",
            node.table, node.parentFk, node.parent.id);
    }

    sql ~= "\n  )";
    return sql.data;
}

/// Generate SQL SELECT clause including computed columns
string toSelectWithComputed(QueryNode node, SqlOptimizer sqlOpt) {
    import std.format : format;

    string[] selectParts;

    // Regular columns from main table
    foreach (col; node.columns) {
        selectParts ~= format("%s.%s", node.table, col);
    }

    // Columns from JOINed tables
    foreach (joinInfo; node.joins) {
        if (auto cols = joinInfo.alias_ in node.joinedColumns) {
            foreach (col; *cols) {
                selectParts ~= format("%s.%s AS %s__%s",
                    joinInfo.alias_, col, joinInfo.alias_, col);
            }
        }
    }

    // Computed columns (if SqlOptimizer is provided)
    if (sqlOpt !is null) {
        foreach (computed; sqlOpt.getComputedColumns(node.id)) {
            selectParts ~= format("%s AS %s", computed.sqlExpr, computed.alias_);
        }
    }

    return selectParts.join(", ");
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test SQL literal generation
    assert(toSqlLiteral("hello") == "'hello'");
    assert(toSqlLiteral("it's") == "'it''s'");
    assert(toSqlLiteral(42) == "42");
    assert(toSqlLiteral(3.14f) == "3.14");
    assert(toSqlLiteral(true) == "TRUE");
    assert(toSqlLiteral(false) == "FALSE");
}

unittest {
    // Test SqlOptimizer creation
    auto optimizer = new SqlOptimizer();
    assert(optimizer !is null);
    assert(!optimizer.hasComputedColumns(0));
}

unittest {
    // Test computed column detection
    // Create a mock expression tree: ProjectColumn + " " + ProjectColumn

    // Create mock QueryNode and PrefetchExpr
    auto node = new QueryNode(0, "User", "users");
    auto prefetch = new PrefetchExpr(node);

    // Create a mock input (EveryItemOfExpr)
    auto item = new EveryItemOfExpr();

    // First, set up mock projections with input and prefetch
    auto proj1 = new ProjectColumnExpr!string(0, "first_name", item, prefetch);
    auto proj2 = new ProjectColumnExpr!string(0, "last_name", item, prefetch);

    // Create binary op: proj1 ~ " " ~ proj2
    auto space = constant(" ", proj1);  // Derive length from proj1
    auto concat1 = new BinaryOpExpr!(string, "~", string)(proj1, space);
    auto concat2 = new BinaryOpExpr!(string, "~", string)(concat1, proj2);

    // Wrap in a UseExpr so we can test replacement
    auto wrapper = use((string s) => s, concat2);

    // Run SQL optimizer
    auto ctx = new OptimizeContext();
    auto sqlOpt = new SqlOptimizer();
    sqlOpt.optimize(wrapper, ctx);

    // Check that computed columns were created
    assert(sqlOpt.hasComputedColumns(0));
    auto computed = sqlOpt.getComputedColumns(0);
    assert(computed.length >= 1);
}

unittest {
    // Test ProjectComputedExpr
    auto node = new QueryNode(0, "User", "users");
    auto prefetch = new PrefetchExpr(node);
    auto item = new EveryItemOfExpr();
    auto proj = new ProjectComputedExpr!string(0, "computed_0", item, prefetch);
    assert(proj.queryNodeId == 0);
    assert(proj.columnAlias == "computed_0");
    assert(proj.dependencies().length == 2);  // input and prefetch
}
