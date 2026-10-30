module dunamis.relational.sql_optimizer;

import std.algorithm;
import std.array;
import std.conv;
import std.json : JSONValue;
import std.traits;
import std.typecons : Nullable;

import ae.utils.promise;

import dunamis.core.types;
import dunamis.core.eval;
import dunamis.core.expr;
import dunamis.core.filtering : FilterByInfo;
import dunamis.core.sorting : SortByInfo;
import dunamis.core.optimize : OptimizeContext, ExprOptimizer;
import dunamis.relational.eval_context : RelationalSession, QueryResult;
import dunamis.relational.native : NativeSqlInfo;
import dunamis.relational.query_node;
import dunamis.relational.schema;
import dunamis.relational.project;
import dunamis.relational.sql_dialect;

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
    import dunamis.relational.sql_dialect : sqlLiteral;
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
///   2. Then run SqlOptimizer to find BinaryOpExprs over projections
///   3. SqlOptimizer replaces them with ProjectComputedExprs
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
        import dunamis.relational.optimize_context : RelationalOptimizeContext;

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

    /// Register a computed column on `node`, returning its alias.
    private string addComputedColumn(QueryNode node, string sqlExpr, TypeInfo type,
            OptimizeContext ctx) {
        import dunamis.relational.optimize_context : RelationalOptimizeContext;
        auto alias_ = ctx.getSourceContext!RelationalOptimizeContext().newComputedColumnAlias();
        node.addComputedColumn(ComputedColumn(alias_, sqlExpr, type));
        return alias_;
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

            // Check if this dependency is a unary operation that could be pushed down
            if (auto unaryOp = cast(UnaryOpInfo) dep) {
                auto replacement = tryPushDownUnaryOp(dep, unaryOp, ctx);
                if (replacement !is null && replacement !is dep) {
                    parent.replaceDependency(i, replacement);
                }
            }

            // Check if this dependency is a ternary operation that could be pushed down
            if (auto ternaryOp = cast(TernaryInfo) dep) {
                auto replacement = tryPushDownTernaryOp(dep, ternaryOp, ctx);
                if (replacement !is null && replacement !is dep) {
                    parent.replaceDependency(i, replacement);
                }
            }

            // Check if this dependency is an isNull check that could be pushed down
            if (auto isNullOp = cast(IsNullInfo) dep) {
                auto replacement = tryPushDownIsNull(dep, isNullOp, ctx);
                if (replacement !is null && replacement !is dep) {
                    parent.replaceDependency(i, replacement);
                }
            }

            // Check if this dependency is a some/every predicate that could be pushed down
            if (auto collPred = cast(CollectionPredicateInfo) dep) {
                auto replacement = tryPushDownCollectionPredicate(dep, collPred, ctx);
                if (replacement !is null && replacement !is dep) {
                    parent.replaceDependency(i, replacement);
                }
            }

            // Check if this dependency is a native SQL expression that could be pushed down
            if (auto native = cast(NativeSqlInfo) dep) {
                auto replacement = tryPushDownNative(dep, native, ctx);
                if (replacement !is null && replacement !is dep) {
                    parent.replaceDependency(i, replacement);
                }
            }
        }
    }

    /// Try to push down a binary operation to SQL
    protected ExprBase tryPushDownBinaryOp(ExprBase expr, BinaryOpInfo binOp, OptimizeContext ctx) {
        // Check if both operands can be translated to SQL
        QueryNodeId queryNodeId = noQueryNodeId;
        auto leftSql = tryGetSqlExpr(binOp.left, queryNodeId);
        auto rightSql = tryGetSqlExpr(binOp.right, queryNodeId);

        if (leftSql.isNull || rightSql.isNull || queryNodeId == noQueryNodeId) {
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

        // Build the SQL expression using dialect-specific formatting
        auto sqlExpr = _dialect.binaryOp(binOp.operator, leftSql.get, rightSql.get);

        // Register the computed column on the projections' QueryNode
        assert(prefetch.node.id == queryNodeId, "Computed column operands from another QueryNode");
        auto alias_ = addComputedColumn(prefetch.node, sqlExpr, expr.resultType, ctx);

        // Create and return projection for computed column
        return createProjectComputedExpr(queryNodeId, alias_, expr.resultType, input, prefetch, expr);
    }

    /// Try to push down a unary operation to SQL
    protected ExprBase tryPushDownUnaryOp(ExprBase expr, UnaryOpInfo unaryOp, OptimizeContext ctx) {
        // Check if operand can be translated to SQL
        QueryNodeId queryNodeId = noQueryNodeId;
        auto operandSql = tryGetSqlExpr(unaryOp.operand, queryNodeId);

        if (operandSql.isNull || queryNodeId == noQueryNodeId) {
            return null;
        }

        // Extract input and prefetch from the operand
        auto input = extractInputFromExpr(unaryOp.operand);
        if (input is null) {
            return null;
        }

        auto prefetch = extractPrefetchFromExpr(unaryOp.operand);
        if (prefetch is null) {
            return null;
        }

        // Build the SQL expression using dialect-specific formatting
        auto sqlExpr = _dialect.unaryOp(unaryOp.operator, operandSql.get);

        // Register the computed column on the projections' QueryNode
        assert(prefetch.node.id == queryNodeId, "Computed column operands from another QueryNode");
        auto alias_ = addComputedColumn(prefetch.node, sqlExpr, expr.resultType, ctx);

        // Create and return projection for computed column
        return createProjectComputedExpr(queryNodeId, alias_, expr.resultType, input, prefetch, expr);
    }

    /// Try to push down a ternary operation to SQL
    protected ExprBase tryPushDownTernaryOp(ExprBase expr, TernaryInfo ternaryOp, OptimizeContext ctx) {
        // Check if all operands can be translated to SQL and come from the same QueryNode
        QueryNodeId queryNodeId = noQueryNodeId;
        auto condSql = tryGetSqlExpr(ternaryOp.condition, queryNodeId);
        auto trueSql = tryGetSqlExpr(ternaryOp.trueExpr, queryNodeId);
        auto falseSql = tryGetSqlExpr(ternaryOp.falseExpr, queryNodeId);

        if (condSql.isNull || trueSql.isNull || falseSql.isNull || queryNodeId == noQueryNodeId) {
            return null;
        }

        // Extract input and prefetch from one of the operands
        auto input = extractInputFromExpr(ternaryOp.condition);
        if (input is null) {
            input = extractInputFromExpr(ternaryOp.trueExpr);
        }
        if (input is null) {
            input = extractInputFromExpr(ternaryOp.falseExpr);
        }
        if (input is null) {
            return null;
        }

        auto prefetch = extractPrefetchFromExpr(ternaryOp.condition);
        if (prefetch is null) {
            prefetch = extractPrefetchFromExpr(ternaryOp.trueExpr);
        }
        if (prefetch is null) {
            prefetch = extractPrefetchFromExpr(ternaryOp.falseExpr);
        }
        if (prefetch is null) {
            return null;
        }

        // Build the SQL expression using dialect-specific formatting
        auto sqlExpr = _dialect.caseWhen(condSql.get, trueSql.get, falseSql.get);

        // Register the computed column on the projections' QueryNode
        assert(prefetch.node.id == queryNodeId, "Computed column operands from another QueryNode");
        auto alias_ = addComputedColumn(prefetch.node, sqlExpr, expr.resultType, ctx);

        // Create and return projection for computed column
        return createProjectComputedExpr(queryNodeId, alias_, expr.resultType, input, prefetch, expr);
    }

    /// Try to push down an isNull check to SQL
    protected ExprBase tryPushDownIsNull(ExprBase expr, IsNullInfo isNullOp, OptimizeContext ctx) {
        // Check if operand can be translated to SQL
        QueryNodeId queryNodeId = noQueryNodeId;
        auto operandSql = tryGetSqlExpr(isNullOp.operand, queryNodeId);

        if (operandSql.isNull || queryNodeId == noQueryNodeId) {
            return null;
        }

        // Extract input and prefetch from the operand
        auto input = extractInputFromExpr(isNullOp.operand);
        if (input is null) {
            return null;
        }

        auto prefetch = extractPrefetchFromExpr(isNullOp.operand);
        if (prefetch is null) {
            return null;
        }

        // Build the SQL expression using dialect-specific formatting
        auto sqlExpr = _dialect.isNullOp(operandSql.get);

        // Register the computed column on the projections' QueryNode
        assert(prefetch.node.id == queryNodeId, "Computed column operands from another QueryNode");
        auto alias_ = addComputedColumn(prefetch.node, sqlExpr, typeid(bool), ctx);

        // Create and return projection for computed column
        return createProjectComputedExpr(queryNodeId, alias_, typeid(bool), input, prefetch, expr);
    }

    /// Try to push down a native SQL expression (see `NativeSqlInfo`) to a
    /// computed column, if the dialect has a native form of it and its
    /// operands are SQL of one query node (columns, constants, or other
    /// expressions computed in SQL).
    protected ExprBase tryPushDownNative(ExprBase expr, NativeSqlInfo native, OptimizeContext ctx) {
        if (!native.hasNativeSql(_dialect))
            return null;
        QueryNodeId queryNodeId = noQueryNodeId;
        auto sqlExpr = tryGetSqlExpr(expr, queryNodeId);
        if (sqlExpr.isNull || queryNodeId == noQueryNodeId)
            return null;
        auto input = extractInputFromExpr(expr);
        auto prefetch = extractPrefetchFromExpr(expr);
        if (input is null || prefetch is null)
            return null;
        assert(prefetch.node.id == queryNodeId, "Computed column operands from another QueryNode");
        auto alias_ = addComputedColumn(prefetch.node, sqlExpr.get, expr.resultType, ctx);
        return native.projectComputed(queryNodeId, alias_, input, prefetch);
    }

    /// Try to push down a collection predicate (some/every) to SQL EXISTS subquery.
    ///
    /// Converts:
    ///   some!((p) => p.isPublished)(user.posts)
    /// To:
    ///   EXISTS (SELECT 1 FROM posts WHERE posts.author_id = users.id AND posts.is_published = TRUE)
    protected ExprBase tryPushDownCollectionPredicate(ExprBase expr, CollectionPredicateInfo collPred, OptimizeContext ctx) {
        import dunamis.relational.optimize_context : RelationalOptimizeContext;

        // The collection must be a HasMany relationship
        auto hasManyInfo = cast(HasManyInfo) collPred.collection;
        if (hasManyInfo is null) {
            return null;  // Can only push down HasMany collections
        }

        // Get info about the relationship
        auto childTable = hasManyInfo.childTable;
        auto fkColumn = hasManyInfo.fkColumn;

        // Try to convert the predicate to SQL (operating on the child table)
        auto predicateSql = tryGetPredicateSql(collPred.predicate, collPred.itemPlaceholder, childTable);
        if (predicateSql.isNull) {
            return null;  // Can't convert predicate to SQL
        }

        // Find the parent QueryNode from the HasMany's input expression
        auto relCtx = ctx.getSourceContext!RelationalOptimizeContext();
        if (relCtx is null) {
            return null;
        }

        // Get the parent table name - walk up to find the MapExpr's QueryNode
        JoinHop[] joinPath;
        ExprBase baseInput;
        ExprBase baseInputAsAnyRef;
        auto parentMapExpr = findMapExprFromChain(hasManyInfo.inputExpr, joinPath, baseInput, baseInputAsAnyRef);
        if (parentMapExpr is null) {
            return null;
        }

        auto parentNode = relCtx.getNode(parentMapExpr);
        if (parentNode is null) {
            return null;
        }

        auto parentTable = parentNode.table;
        auto prefetch = relCtx.getPrefetchExpr(parentNode);

        // Build the EXISTS subquery
        // SELECT 1 FROM childTable WHERE childTable.fk = parentTable.id AND predicate
        string subquery = "SELECT 1 FROM " ~ childTable ~
                         " WHERE " ~ childTable ~ "." ~ fkColumn ~ " = " ~ parentTable ~ ".id";

        if (predicateSql.get.length > 0) {
            subquery ~= " AND " ~ predicateSql.get;
        }

        // Build the EXISTS SQL expression
        // Note: every() is now implemented as not(some(not(pred))), so all collection
        // predicates here are some(). The outer not() is pushed down separately.
        string sqlExpr = _dialect.existsSubquery(subquery);

        // Get the input expression that provides parent entity refs as AnyRef
        // HasManyInfo knows the Parent type at compile time and creates the wrapper
        auto input = hasManyInfo.inputAsAnyRefExpr;
        if (input is null) {
            return null;
        }

        // Register the computed column on the parent QueryNode
        auto alias_ = addComputedColumn(parentNode, sqlExpr, typeid(bool), ctx);

        // Create and return projection for computed column
        return createProjectComputedExpr(parentNode.id, alias_, typeid(bool), input, prefetch, expr);
    }

    /// Try to convert a predicate expression to SQL for use in EXISTS subquery.
    /// The predicate operates on child entities, so column accesses on the placeholder
    /// are converted to references to the child table.
    private Nullable!string tryGetPredicateSql(ExprBase predicate, Object itemPlaceholder, string childTable) {
        // Check if it's a column access on the placeholder
        if (auto colAccess = cast(ColumnAccessInfo) predicate) {
            // Check if the input is the placeholder (or reaches it through the chain)
            if (isPlaceholderAccess(colAccess.inputExpr, itemPlaceholder)) {
                return Nullable!string(childTable ~ "." ~ colAccess.column);
            }
        }

        // Check if it's a binary operation
        if (auto binOp = cast(BinaryOpInfo) predicate) {
            auto leftSql = tryGetPredicateSql(binOp.left, itemPlaceholder, childTable);
            auto rightSql = tryGetPredicateSql(binOp.right, itemPlaceholder, childTable);
            if (!leftSql.isNull && !rightSql.isNull) {
                return Nullable!string(_dialect.binaryOp(binOp.operator, leftSql.get, rightSql.get));
            }
        }

        // Check if it's a unary operation
        if (auto unaryOp = cast(UnaryOpInfo) predicate) {
            auto operandSql = tryGetPredicateSql(unaryOp.operand, itemPlaceholder, childTable);
            if (!operandSql.isNull) {
                return Nullable!string(_dialect.unaryOp(unaryOp.operator, operandSql.get));
            }
        }

        // Check if it's a ternary operation
        if (auto ternaryOp = cast(TernaryInfo) predicate) {
            auto condSql = tryGetPredicateSql(ternaryOp.condition, itemPlaceholder, childTable);
            auto trueSql = tryGetPredicateSql(ternaryOp.trueExpr, itemPlaceholder, childTable);
            auto falseSql = tryGetPredicateSql(ternaryOp.falseExpr, itemPlaceholder, childTable);
            if (!condSql.isNull && !trueSql.isNull && !falseSql.isNull) {
                return Nullable!string(_dialect.caseWhen(condSql.get, trueSql.get, falseSql.get));
            }
        }

        // Check if it's an isNull check
        if (auto isNullOp = cast(IsNullInfo) predicate) {
            auto operandSql = tryGetPredicateSql(isNullOp.operand, itemPlaceholder, childTable);
            if (!operandSql.isNull) {
                return Nullable!string(_dialect.isNullOp(operandSql.get));
            }
        }

        // Check if it's a constant
        if (auto constInfo = cast(ConstantInfo) predicate) {
            return Nullable!string(constantToSqlLiteral(constInfo));
        }

        return Nullable!string.init;
    }

    /// Check if an expression is or reaches the placeholder through the chain.
    private bool isPlaceholderAccess(ExprBase expr, Object placeholder) {
        if (expr is null) return false;

        // Direct match
        if (cast(Object) expr is placeholder) {
            return true;
        }

        // Check if it's EveryItemOfExpr with matching parent
        if (auto everyItem = cast(EveryItemOfExprInfo) expr) {
            if (everyItem.parentMap is placeholder) {
                return true;
            }
        }

        return false;
    }

    /// Extract the input expression from a projection, binary op, unary op, or ternary op.
    /// Returns the entity ref source (e.g., EveryItemOfExpr) that provides the
    /// refs for looking up computed column values.
    private ExprBase extractInputFromExpr(ExprBase expr) {
        // Check for binary ops and recurse
        if (auto binOp = cast(BinaryOpInfo) expr) {
            auto left = extractInputFromExpr(binOp.left);
            if (left !is null) return left;
            return extractInputFromExpr(binOp.right);
        }

        // Check for unary ops and recurse
        if (auto unaryOp = cast(UnaryOpInfo) expr) {
            return extractInputFromExpr(unaryOp.operand);
        }

        // Check for ternary ops and recurse
        if (auto ternaryOp = cast(TernaryInfo) expr) {
            auto result = extractInputFromExpr(ternaryOp.condition);
            if (result !is null) return result;
            result = extractInputFromExpr(ternaryOp.trueExpr);
            if (result !is null) return result;
            return extractInputFromExpr(ternaryOp.falseExpr);
        }

        // Check for isNull ops and recurse
        if (auto isNullOp = cast(IsNullInfo) expr) {
            return extractInputFromExpr(isNullOp.operand);
        }

        // Check for native SQL expressions and recurse into their operands
        if (auto native = cast(NativeSqlInfo) expr) {
            foreach (operand; native.nativeOperands)
                if (auto result = extractInputFromExpr(operand))
                    return result;
            return null;
        }

        // Check for projection expressions - they have input as first dependency
        if (cast(ProjectColumnInfo) expr !is null || cast(ProjectJoinedColumnInfo) expr !is null) {
            auto deps = expr.dependencies();
            if (deps.length > 0) {
                return deps[0];  // Input expression that produces entity refs
            }
        }

        // Constants don't have input
        if (cast(ConstantInfo) expr !is null) {
            return null;
        }

        return null;
    }

    /// Extract the PrefetchExpr from a projection, binary op, unary op, or ternary op.
    /// Returns the PrefetchExpr that ensures data is loaded before reading.
    private PrefetchExpr extractPrefetchFromExpr(ExprBase expr) {
        // Check for binary ops and recurse
        if (auto binOp = cast(BinaryOpInfo) expr) {
            auto left = extractPrefetchFromExpr(binOp.left);
            if (left !is null) return left;
            return extractPrefetchFromExpr(binOp.right);
        }

        // Check for unary ops and recurse
        if (auto unaryOp = cast(UnaryOpInfo) expr) {
            return extractPrefetchFromExpr(unaryOp.operand);
        }

        // Check for ternary ops and recurse
        if (auto ternaryOp = cast(TernaryInfo) expr) {
            auto result = extractPrefetchFromExpr(ternaryOp.condition);
            if (result !is null) return result;
            result = extractPrefetchFromExpr(ternaryOp.trueExpr);
            if (result !is null) return result;
            return extractPrefetchFromExpr(ternaryOp.falseExpr);
        }

        // Check for isNull ops and recurse
        if (auto isNullOp = cast(IsNullInfo) expr) {
            return extractPrefetchFromExpr(isNullOp.operand);
        }

        // Check for native SQL expressions and recurse into their operands
        if (auto native = cast(NativeSqlInfo) expr) {
            foreach (operand; native.nativeOperands)
                if (auto result = extractPrefetchFromExpr(operand))
                    return result;
            return null;
        }

        // Check for projection expressions - they have prefetch as second dependency
        if (cast(ProjectColumnInfo) expr !is null || cast(ProjectJoinedColumnInfo) expr !is null) {
            auto deps = expr.dependencies();
            if (deps.length > 1) {
                if (auto prefetch = cast(PrefetchExpr) deps[1]) {
                    return prefetch;
                }
            }
        }

        return null;
    }

    /// Try to get SQL expression for an operand.
    /// Also tracks the queryNodeId to ensure all parts come from the same node.
    private Nullable!string tryGetSqlExpr(ExprBase expr, ref QueryNodeId queryNodeId) {
        // Check if it's a column projection
        if (auto projCol = cast(ProjectColumnInfo) expr) {
            if (queryNodeId == noQueryNodeId) {
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
            if (queryNodeId == noQueryNodeId) {
                queryNodeId = projJoin.queryNodeId;
            } else if (queryNodeId != projJoin.queryNodeId) {
                return Nullable!string.init;
            }
            return Nullable!string(projJoin.joinAlias.value ~ "." ~ projJoin.column);
        }

        // Check if it's a computed column projection (e.g., EXISTS subquery)
        if (auto projComputed = cast(ProjectComputedInfo) expr) {
            if (queryNodeId == noQueryNodeId) {
                queryNodeId = projComputed.queryNodeId;
            } else if (queryNodeId != projComputed.queryNodeId) {
                return Nullable!string.init;
            }
            return Nullable!string(projComputed.columnAlias);
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
                return Nullable!string(_dialect.binaryOp(binOp.operator, leftSql.get, rightSql.get));
            }
        }

        // Check if it's a nested unary op
        if (auto unaryOp = cast(UnaryOpInfo) expr) {
            auto operandSql = tryGetSqlExpr(unaryOp.operand, queryNodeId);
            if (!operandSql.isNull) {
                return Nullable!string(_dialect.unaryOp(unaryOp.operator, operandSql.get));
            }
        }

        // Check if it's a nested ternary op
        if (auto ternaryOp = cast(TernaryInfo) expr) {
            auto condSql = tryGetSqlExpr(ternaryOp.condition, queryNodeId);
            auto trueSql = tryGetSqlExpr(ternaryOp.trueExpr, queryNodeId);
            auto falseSql = tryGetSqlExpr(ternaryOp.falseExpr, queryNodeId);
            if (!condSql.isNull && !trueSql.isNull && !falseSql.isNull) {
                return Nullable!string(_dialect.caseWhen(condSql.get, trueSql.get, falseSql.get));
            }
        }

        // Check if it's a nested isNull op
        if (auto isNullOp = cast(IsNullInfo) expr) {
            auto operandSql = tryGetSqlExpr(isNullOp.operand, queryNodeId);
            if (!operandSql.isNull) {
                return Nullable!string(_dialect.isNullOp(operandSql.get));
            }
        }

        // Check if it's a native SQL expression (of a dialect having a
        // native form of it) on operands which are SQL themselves
        if (auto native = cast(NativeSqlInfo) expr) {
            if (native.hasNativeSql(_dialect)) {
                auto operands = native.nativeOperands;
                auto operandSql = new string[operands.length];
                foreach (i, operand; operands) {
                    auto sql = tryGetSqlExpr(operand, queryNodeId);
                    if (sql.isNull)
                        return Nullable!string.init;
                    operandSql[i] = sql.get;
                }
                return Nullable!string(native.nativeSql(_dialect, operandSql));
            }
        }

        return Nullable!string.init;
    }

    /// Create a ProjectComputedExpr for the given result type, replacing
    /// the expression `original`.
    /// Since we need to create a typed expression but only have TypeInfo at runtime,
    /// we use a factory approach with common types.
    private ExprBase createProjectComputedExpr(QueryNodeId queryNodeId, string alias_, TypeInfo type, ExprBase input,
            PrefetchExpr prefetch, ExprBase original) {
        // Handle common types
        if (type == typeid(string)) {
            return new ProjectComputedExpr!string(queryNodeId, alias_, input, prefetch, original);
        }
        if (type == typeid(int)) {
            return new ProjectComputedExpr!int(queryNodeId, alias_, input, prefetch, original);
        }
        if (type == typeid(long)) {
            return new ProjectComputedExpr!long(queryNodeId, alias_, input, prefetch, original);
        }
        if (type == typeid(float)) {
            return new ProjectComputedExpr!float(queryNodeId, alias_, input, prefetch, original);
        }
        if (type == typeid(double)) {
            return new ProjectComputedExpr!double(queryNodeId, alias_, input, prefetch, original);
        }
        if (type == typeid(bool)) {
            return new ProjectComputedExpr!bool(queryNodeId, alias_, input, prefetch, original);
        }

        // Unsupported type - return null (caller should keep original expression)
        return null;
    }

}

// ============================================================================
// Computed Column Projection Expression
// ============================================================================

/// Interface for ProjectComputedExpr pattern matching by external optimizers
interface ProjectComputedInfo {
    @property QueryNodeId queryNodeId();
    @property string columnAlias();
}

/// Projection expression that reads a computed column from QueryResult.
/// Created by SqlOptimizer when pushing down expressions to SQL.
class ProjectComputedExpr(T) : Expr!T, ProjectComputedInfo {
    private QueryNodeId _queryNodeId;
    private string _alias;
    private ExprBase _input;     // The input chain (for deriving refs)
    private ExprBase _prefetch;  // PrefetchExpr - ensures data is loaded
    private ExprBase _inMemory;  // The expression computed, as evaluated in memory

    /// Accepts ExprBase to work with both typed Expr!Entity and untyped Expr!AnyRef.
    /// `inMemory` is the expression (an Expr!T) the computed column is the
    /// value of: it is evaluated in memory on a session which does not
    /// compute columns (see `RelationalSession.computesColumns`).
    this(QueryNodeId queryNodeId, string alias_, ExprBase input, PrefetchExpr prefetch, ExprBase inMemory) {
        assert(inMemory !is null && cast(Expr!T) inMemory !is null,
            "ProjectComputedExpr: the in-memory form must be an Expr!" ~ T.stringof);
        _queryNodeId = queryNodeId;
        _alias = alias_;
        _input = input;
        _prefetch = prefetch;
        _inMemory = inMemory;
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
        auto prefetch = cast(PrefetchExpr) _prefetch;
        auto inMemory = _inMemory;

        // Ensure data is prefetched, then evaluate input refs, then read
        return evalAs!(AnyRef[])(_prefetch, ctx).then((_) {
            return evalAs!AnyRef(input, ctx);
        }).then((AnyRef[] refs) {
            auto session = cast(RelationalSession) ctx.getSession(prefetch.node.dataSource);
            auto queryResult = session.getQueryResult(queryNodeId);

            if (session.computesColumns) {
                assert(queryResult !is null && queryResult.hasColumn(alias_),
                    "Computed column " ~ alias_ ~ " was not fetched");
                return resolve(session.getColumnValues!T(queryNodeId, alias_, refs));
            }
            return evalAs!T(inMemory, ctx);
        });
    }

    @property QueryNodeId queryNodeId() { return _queryNodeId; }
    @property string columnAlias() { return _alias; }
}


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
}

/// Extract WHERE clause SQL from a FilterByInfo by pattern-matching its predicate.
/// `dialect` is the dialect of the query (null if unknown, e.g. not a SQL
/// data source's): native SQL expressions (see `NativeSqlInfo`) are only
/// expressed in a dialect which has a native form of them. `plainFieldColumn`
/// (if not null) gives the columns of the plain fields of the filtered entity
/// (see `PlainFieldInfo`), so that conditions on them can be expressed too.
FilterWhereClause extractFilterWhereClause(FilterByInfo filterInfo, string table = null,
        SqlDialect dialect = null, string delegate(string) plainFieldColumn = null) {
    auto filterItem = filterInfo.filterItem;
    FilterWhereClause extract(Object expr) {
        if (auto binOp = cast(BinaryOpInfo) expr) {
            if (binOp.operator == "&&") {
                auto left = extract(binOp.left), right = extract(binOp.right);
                if (left.sql.isNull)
                    return FilterWhereClause(right.sql, false);
                if (right.sql.isNull)
                    return FilterWhereClause(left.sql, false);
                // (As extractWhereFromExpr renders a conjunction)
                auto l = left.sql.get, r = right.sql.get;
                return FilterWhereClause(Nullable!DialectSql((SqlDialect d) => "(" ~ l(d) ~ " AND " ~ r(d) ~ ")"),
                    left.complete && right.complete);
            }
        }
        auto sql = extractWhereFromExpr(expr, filterItem, table, dialect, plainFieldColumn);
        return FilterWhereClause(sql, !sql.isNull);
    }
    return extract(filterInfo.filterPredicate);
}

/// Recursively extract WHERE SQL from an expression tree: the condition the
/// predicate `expr` puts on the rows of `table` that `filterItem` stands for.
///
/// Besides conditions on the item's own columns, this covers conditions on
/// related rows: a condition on a belongs-to relationship becomes a condition
/// on the item's foreign key (`fk IN (SELECT pk FROM parent WHERE ...)`, also
/// through chains of relationships), and `some` over a to-many relationship
/// an `EXISTS` subquery over the child table. Native SQL expressions (see
/// `NativeSqlInfo`) on such operands are expressed in their native form if
/// `dialect` (the query's) has one: as conditions (of type `bool`), and as
/// operands of comparisons. Reads of the item's plain fields
/// (see `PlainFieldInfo`) are reads of their columns that `plainFieldColumn`
/// gives (if not null). A predicate with any part that cannot be expressed
/// this way gives null.
Nullable!DialectSql extractWhereFromExpr(Object expr, Object filterItem, string table = null,
        SqlDialect dialect = null, string delegate(string) plainFieldColumn = null) {
    auto context = WhereContext(dialect, 0, filterItem, plainFieldColumn);
    return context.extract(expr, filterItem, table);
}

/// The state of a WHERE clause extraction: the aliases of the subqueries it
/// renders.
private struct WhereContext {
    /// The dialect of the query (null if unknown).
    private SqlDialect dialect;
    private int aliases;

    /// The item of the filter extracted (not of the filters of collections
    /// within it), and the columns of its plain fields (null if unknown).
    private Object rootItem;
    private string delegate(string) rootPlainFieldColumn;

    /// A fresh table alias for a subquery.
    string newAlias() {
        return "_f" ~ (++aliases).to!string;
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
    /// and nullable unwrapping.
    static RowPath resolveRow(Object entity, Object filterItem) {
        while (true) {
            if (entity is null)
                return RowPath.init;
            if (entity is filterItem)
                return RowPath(true);
            if (auto entityCast = cast(EntityCastInfo) entity) {
                auto inner = entityCast.inputExpr;
                if (inner is entity) return RowPath.init;
                entity = inner;
                continue;
            }
            if (auto unwrap = cast(UnwrapNullableInfo) entity) {
                auto inner = unwrap.inputExpr;
                if (inner is entity) return RowPath.init;
                entity = inner;
                continue;
            }
            if (auto belongsTo = cast(BelongsToInfo) entity) {
                auto parentPk = belongsTo.parentPkColumns;
                if (parentPk.length != 1)
                    return RowPath.init;
                auto path = resolveRow(belongsTo.inputExpr, filterItem);
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
    DialectSql onRow(RowPath path, string table, DialectSql delegate(string rowTable) condition) {
        if (path.hops.length == 0)
            return condition(table);
        auto hop = path.hops[0];
        auto alias_ = newAlias();
        auto inner = onRow(RowPath(true, path.hops[1 .. $]), alias_, condition);
        auto fk = qualified(table, hop.fk);
        auto subquery = "SELECT " ~ alias_ ~ "." ~ hop.parentPk ~ " FROM " ~ hop.parentTable ~ " " ~ alias_ ~
            " WHERE ";
        return (SqlDialect d) => "(" ~ fk ~ " IN (" ~ subquery ~ inner(d) ~ "))";
    }

    static string qualified(string table, string column) {
        return (table.length ? table ~ "." : "") ~ column;
    }

    /// The column an operand reads, on the row it belongs to.
    bool resolveColumn(Object expr, Object filterItem, out RowPath path, out string column) {
        // A nullable column's values, unwrapped, or a column's values cast
        // (e.g. a value type's, to a plugin's wrapper of the type)
        while (true) {
            if (auto unwrap = cast(UnwrapNullableInfo) expr) {
                if (unwrap.inputExpr is expr) break;
                expr = unwrap.inputExpr;
            } else if (auto entityCast = cast(EntityCastInfo) expr) {
                if (entityCast.inputExpr is expr) break;
                expr = entityCast.inputExpr;
            } else if (auto valueCast = cast(ValueCastInfo) expr) {
                if (valueCast.valueCastInput is expr) break;
                expr = valueCast.valueCastInput;
            } else
                break;
        }
        // A plain field of the filter's own item, stored in a column
        if (auto plain = cast(PlainFieldInfo) expr) {
            if (filterItem !is rootItem || rootPlainFieldColumn is null)
                return false;
            path = resolveRow(plain.plainFieldOwner, filterItem);
            if (!path.valid || path.hops.length)
                return false;
            column = rootPlainFieldColumn(plain.plainFieldName);
            return column !is null;
        }
        auto colAccess = cast(ColumnAccessInfo) expr;
        if (colAccess is null) return false;
        path = resolveRow(colAccess.inputExpr, filterItem);
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

    /// The SQL of the value `expr`: a constant, a column of a row (see
    /// `resolveColumn`), or a native SQL expression (see `NativeSqlInfo`)
    /// having a native form in the dialect, on such values of one row.
    RowValue rowValue(Object expr, Object filterItem) {
        auto literal = extractConstant(expr);
        if (!literal.isNull) {
            auto sql = literal.get;
            return RowValue(true, true, false, RowPath(true), (string) => sql);
        }
        RowPath path;
        string column;
        if (resolveColumn(expr, filterItem, path, column))
            return RowValue(true, false, false, path, (string rowTable) => qualified(rowTable, column));
        // A native expression's values, unwrapped or cast (as a column's)
        while (true) {
            if (auto unwrap = cast(UnwrapNullableInfo) expr) {
                if (unwrap.inputExpr is expr) break;
                expr = unwrap.inputExpr;
            } else if (auto valueCast = cast(ValueCastInfo) expr) {
                if (valueCast.valueCastInput is expr) break;
                expr = valueCast.valueCastInput;
            } else
                break;
        }
        auto native = cast(NativeSqlInfo) expr;
        if (native is null || dialect is null || !native.hasNativeSql(dialect))
            return RowValue.init;
        auto operands = native.nativeOperands;
        auto values = new RowValue[operands.length];
        auto result = RowValue(true, true, true, RowPath(true));
        foreach (i, operand; operands) {
            values[i] = rowValue(operand, filterItem);
            if (!values[i].valid)
                return RowValue.init;
            if (values[i].constant)
                continue;
            if (!result.constant && values[i].path.hops != result.path.hops)
                return RowValue.init;
            result.constant = false;
            result.path = values[i].path;
        }
        auto queryDialect = dialect;
        result.render = (string rowTable) {
            auto operandSql = new string[values.length];
            foreach (i, value; values)
                operandSql[i] = value.render(rowTable);
            return native.nativeSql(queryDialect, operandSql);
        };
        return result;
    }

    Nullable!DialectSql extract(Object expr, Object filterItem, string table) {
        // Handle binary operators: AND, OR, comparison operators
        if (auto binOp = cast(BinaryOpInfo) expr) {
            string op = binOp.operator;

            // Logical operators: AND, OR
            if (op == "&&" || op == "||") {
                auto leftSql = extract(binOp.left, filterItem, table);
                auto rightSql = extract(binOp.right, filterItem, table);
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
                if (!rightConst.isNull && resolveColumn(binOp.left, filterItem, path, column)) {
                    value = rightConst.get;
                    isColumnOnLeft = true;
                } else if (!leftConst.isNull && resolveColumn(binOp.right, filterItem, path, column)) {
                    value = leftConst.get;
                    isColumnOnLeft = false;
                } else {
                    // Comparisons of native SQL expressions (with constants,
                    // columns or native expressions of the same row)
                    auto left = rowValue(binOp.left, filterItem);
                    auto right = rowValue(binOp.right, filterItem);
                    if (!left.valid || !right.valid || !(left.native || right.native) ||
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
                auto operandSql = extract(unaryOp.operand, filterItem, table);
                if (!operandSql.isNull) {
                    auto operand = operandSql.get;
                    return Nullable!DialectSql((SqlDialect d) => "NOT " ~ operand(d));
                }
            }
        }

        // Handle null checks of nullable columns and relationships
        if (auto isNullOp = cast(IsNullInfo) expr) {
            RowPath path;
            string column;
            if (!resolveColumn(isNullOp.operand, filterItem, path, column)) {
                // A nullable belongs-to relationship is null if its foreign key is.
                auto belongsTo = cast(BelongsToInfo) isNullOp.operand;
                if (belongsTo is null)
                    return Nullable!DialectSql.init;
                path = resolveRow(belongsTo.inputExpr, filterItem);
                column = belongsTo.fkColumn;
                if (!path.valid)
                    return Nullable!DialectSql.init;
            }
            return Nullable!DialectSql(onRow(path, table, (string rowTable) {
                auto sql = "(" ~ qualified(rowTable, column) ~ " IS NULL)";
                return (SqlDialect _) => sql;
            }));
        }

        // Handle `some` over a to-many relationship
        if (auto collPred = cast(CollectionPredicateInfo) expr) {
            // The collection, seen through element-wise entity casts
            Object collection = collPred.collection;
            while (true) {
                if (auto entityCast = cast(EntityCastInfo) collection) {
                    if (entityCast.inputExpr is collection) break;
                    collection = entityCast.inputExpr;
                } else if (auto map = cast(MapExprInfo) collection) {
                    if (map.collection is collection || !preservesElements(map)) break;
                    collection = map.collection;
                } else
                    break;
            }
            auto hasMany = cast(HasManyInfo) collection;
            if (hasMany is null || hasMany.parentPkColumns.length != 1)
                return Nullable!DialectSql.init;
            auto path = resolveRow(hasMany.inputExpr, filterItem);
            if (!path.valid)
                return Nullable!DialectSql.init;
            auto childAlias = newAlias();
            auto predicate = extract(collPred.predicate, collPred.itemPlaceholder, childAlias);
            if (predicate.isNull)
                return Nullable!DialectSql.init;
            auto pred = predicate.get;
            auto childTable = hasMany.childTable;
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
            string column;
            if (resolveColumn(membership.operand, filterItem, path, column)) {
                auto valueType = membership.valueType;
                auto values = membership.valuesAsStrings;
                if (values.length == 0)
                    return dialectAgnostic("1=0");
                return Nullable!DialectSql(onRow(path, table, (string rowTable) {
                    auto columnSql = qualified(rowTable, column);
                    return (SqlDialect d) => d.membershipOp(columnSql, valueType, values);
                }));
            }
        }

        // Handle native conditions, in a dialect which has a native form of
        // them, on values of one row (columns, constants, native expressions)
        if (auto native = cast(NativeSqlInfo) expr) {
            if ((cast(ExprBase) expr).resultType != typeid(bool))
                return Nullable!DialectSql.init;
            auto value = rowValue(expr, filterItem);
            if (!value.valid || value.constant)
                return Nullable!DialectSql.init;
            auto render = value.render;
            return Nullable!DialectSql(onRow(value.path, table, (string rowTable) {
                auto sql = render(rowTable);
                return (SqlDialect _) => sql;
            }));
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
            string column;
            if (resolveColumn(likeInfo.likeOperand, filterItem, path, column)) {
                // The pattern already has % and _ escaped as \% and \_ by
                // escapeLikePattern() (or is a LIKE pattern); the dialect
                // quotes it and picks the (case-sensitive or -insensitive)
                // matching operator.
                string escapedPattern = likeInfo.likePattern.replace("'", "''");
                bool caseInsensitive = likeInfo.caseInsensitive;
                return Nullable!DialectSql(onRow(path, table, (string rowTable) {
                    auto columnSql = qualified(rowTable, column);
                    return (SqlDialect d) => d.likeOp(columnSql, escapedPattern, caseInsensitive);
                }));
            }
        }

        return Nullable!DialectSql.init;
    }
}

/// The ORDER BY key of a sort (see `SortByInfo`) whose predicate compares a
/// native SQL expression (see `NativeSqlInfo`) of the two items compared,
/// `<` (ascending) or `>` (descending), with `dialect` (that of the query
/// of the rows sorted, a table reference to which is `table`) having a
/// native form of it: the expression's SQL, its result type, and the
/// direction; or null if the sort is not such a one.
Nullable!NativeSortKey extractNativeSortKey(SortByInfo sort, string table, SqlDialect dialect) {
    import dunamis.core.sorting : SortDirection;

    if (dialect is null)
        return Nullable!NativeSortKey.init;
    auto binOp = cast(BinaryOpInfo) sort.sortPredicate;
    if (binOp is null || (binOp.operator != "<" && binOp.operator != ">"))
        return Nullable!NativeSortKey.init;
    auto left = WhereContext(dialect, 0, sort.sortLeftItem).rowValue(binOp.left, sort.sortLeftItem);
    auto right = WhereContext(dialect, 0, sort.sortRightItem).rowValue(binOp.right, sort.sortRightItem);
    // (Both the same expression of the item itself)
    if (!left.valid || !right.valid || !left.native || left.constant || right.constant ||
            left.path.hops.length || right.path.hops.length)
        return Nullable!NativeSortKey.init;
    auto sql = left.render(table);
    if (sql != right.render(table))
        return Nullable!NativeSortKey.init;
    return Nullable!NativeSortKey(NativeSortKey(sql, binOp.left.resultType,
        binOp.operator == "<" ? SortDirection.ASC : SortDirection.DESC));
}

/// ditto
struct NativeSortKey {
    import dunamis.core.sorting : SortDirection;

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
    }
    auto optimizer = new SqlOptimizer(new TestDialect());
    assert(optimizer !is null);
}

unittest {
    // Test computed column detection
    // Create a mock expression tree: ProjectColumn + " " + ProjectColumn

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
    auto proj1 = new ProjectColumnExpr!string(QueryNodeId(0), "first_name", item, prefetch);
    auto proj2 = new ProjectColumnExpr!string(QueryNodeId(0), "last_name", item, prefetch);

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
    }
    auto ctx = new OptimizeContext();
    auto sqlOpt = new SqlOptimizer(new TestDialect());
    sqlOpt.optimize(wrapper, ctx);

    // Check that computed columns were created
    auto computed = node.computedColumns;
    assert(computed.length >= 1);
}

unittest {
    // Test ProjectComputedExpr
    static struct TestUser {
        import dunamis.relational.schema.attrs : PrimaryKey;
        @PrimaryKey string id;
    }

    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    auto prefetch = new PrefetchExpr(node);
    auto item = new EveryItemOfExpr!TestUser();
    auto proj = new ProjectComputedExpr!string(QueryNodeId(0), "computed_0", item, prefetch,
        constant("computed", item));
    assert(proj.queryNodeId == QueryNodeId(0));
    assert(proj.columnAlias == "computed_0");
    assert(proj.dependencies().length == 2);  // input and prefetch
}
