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
import dunamis.core.optimize : OptimizeContext, ExprOptimizer;
import dunamis.relational.eval_context : RelationalEvalContext, QueryResult;
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
    private ComputedColumn[][QueryNodeId] _computedColumns;

    /// Next computed column alias counter
    private int _nextComputedAlias = 0;

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
        }
    }

    /// Check if an expression tree contains any ProjectJoinedColumnExpr
    private bool hasJoinedColumnExpr(ExprBase expr) {
        if (expr is null) return false;

        // Check if this is a joined column
        if (cast(ProjectJoinedColumnInfo) expr !is null) {
            return true;
        }

        // Recurse into binary ops
        if (auto binOp = cast(BinaryOpInfo) expr) {
            return hasJoinedColumnExpr(binOp.left) || hasJoinedColumnExpr(binOp.right);
        }

        // Recurse into unary ops
        if (auto unaryOp = cast(UnaryOpInfo) expr) {
            return hasJoinedColumnExpr(unaryOp.operand);
        }

        // Recurse into ternary ops
        if (auto ternaryOp = cast(TernaryInfo) expr) {
            return hasJoinedColumnExpr(ternaryOp.condition) ||
                   hasJoinedColumnExpr(ternaryOp.trueExpr) ||
                   hasJoinedColumnExpr(ternaryOp.falseExpr);
        }

        // Recurse into isNull ops
        if (auto isNullOp = cast(IsNullInfo) expr) {
            return hasJoinedColumnExpr(isNullOp.operand);
        }

        // Constants don't have joined columns
        if (cast(ConstantInfo) expr !is null) {
            return false;
        }

        // Check dependencies
        foreach (dep; expr.dependencies()) {
            if (hasJoinedColumnExpr(dep)) {
                return true;
            }
        }

        return false;
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

        // Create computed column alias
        auto alias_ = "computed_" ~ (_nextComputedAlias++).to!string;

        // Register the computed column
        if (queryNodeId !in _computedColumns) {
            _computedColumns[queryNodeId] = [];
        }
        _computedColumns[queryNodeId] ~= ComputedColumn(alias_, sqlExpr, typeid(bool));

        // Create and return projection for computed column
        return createProjectComputedExpr(queryNodeId, alias_, typeid(bool), input, prefetch);
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

        // Create computed column alias
        auto alias_ = "computed_" ~ (_nextComputedAlias++).to!string;

        // Register the computed column on the parent QueryNode
        if (parentNode.id !in _computedColumns) {
            _computedColumns[parentNode.id] = [];
        }
        _computedColumns[parentNode.id] ~= ComputedColumn(alias_, sqlExpr, typeid(bool));

        // Get the input expression that provides parent entity refs as AnyRef
        // HasManyInfo knows the Parent type at compile time and creates the wrapper
        auto input = hasManyInfo.inputAsAnyRefExpr;
        if (input is null) {
            return null;
        }

        // Create and return projection for computed column
        return createProjectComputedExpr(parentNode.id, alias_, typeid(bool), input, prefetch);
    }

    /// Try to convert a predicate expression to SQL for use in EXISTS subquery.
    /// The predicate operates on child entities, so column accesses on the placeholder
    /// are converted to references to the child table.
    private Nullable!string tryGetPredicateSql(ExprBase predicate, Object itemPlaceholder, string childTable) {
        // Check if it's a column access on the placeholder
        if (auto colAccess = cast(ColumnAccessInfo) predicate) {
            // Check if the input is the placeholder (or reaches it through the chain)
            if (isPlaceholderAccess(colAccess.inputExpr, itemPlaceholder)) {
                return Nullable!string(childTable ~ "." ~ colAccess.sqlColumn);
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

    /// Extract input expression from a chain (for computed column lookup).
    private ExprBase extractInputFromChain(ExprBase expr) {
        // Walk through the chain to find EveryItemOfExpr
        while (expr !is null) {
            if (cast(EveryItemOfExprInfo) expr !is null) {
                return expr;
            }
            if (auto colAccess = cast(ColumnAccessInfo) expr) {
                expr = colAccess.inputExpr;
                continue;
            }
            if (auto hasManyAccess = cast(HasManyInfo) expr) {
                expr = hasManyAccess.inputExpr;
                continue;
            }
            if (auto belongsTo = cast(BelongsToInfo) expr) {
                expr = belongsTo.inputExpr;
                continue;
            }
            break;
        }
        return expr;
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

        return Nullable!string.init;
    }

    /// Create a ProjectComputedExpr for the given result type.
    /// Since we need to create a typed expression but only have TypeInfo at runtime,
    /// we use a factory approach with common types.
    private ExprBase createProjectComputedExpr(QueryNodeId queryNodeId, string alias_, TypeInfo type, ExprBase input, PrefetchExpr prefetch) {
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
    ComputedColumn[] getComputedColumns(QueryNodeId queryNodeId) {
        return _computedColumns.get(queryNodeId, []);
    }

    /// Check if a QueryNode has any computed columns
    bool hasComputedColumns(QueryNodeId queryNodeId) {
        return queryNodeId in _computedColumns && _computedColumns[queryNodeId].length > 0;
    }

    /// Get all computed columns keyed by QueryNode ID
    const(ComputedColumn[][QueryNodeId]) allComputedColumns() {
        return _computedColumns;
    }
}

// ============================================================================
// Capturing SQL Optimizer (for MockDB compatibility)
// ============================================================================

/// SQL optimizer that captures original expressions before replacing them.
/// Used by DebugSqlDB to enable SQL push-down while still being able
/// to evaluate computed columns using the original D expressions.
///
/// Production data sources should use plain SqlOptimizer (no capture overhead).
class CapturingSqlOptimizer : SqlOptimizer {
    /// Original expressions keyed by computed column alias
    private ExprBase[string] _originalExprs;

    /// Create a CapturingSqlOptimizer with a specific dialect
    this(SqlDialect dialect) {
        super(dialect);
    }

    /// Override to capture original expression before replacement
    override protected ExprBase tryPushDownBinaryOp(ExprBase expr, BinaryOpInfo binOp, OptimizeContext ctx) {
        auto replacement = super.tryPushDownBinaryOp(expr, binOp, ctx);
        if (replacement !is null && replacement !is expr) {
            // Capture the original expression
            if (auto projComputed = cast(ProjectComputedInfo) replacement) {
                _originalExprs[projComputed.columnAlias] = expr;
            }
        }
        return replacement;
    }

    /// Override to capture original expression before replacement (for some/every)
    override protected ExprBase tryPushDownCollectionPredicate(ExprBase expr, CollectionPredicateInfo collPred, OptimizeContext ctx) {
        auto replacement = super.tryPushDownCollectionPredicate(expr, collPred, ctx);
        if (replacement !is null && replacement !is expr) {
            // Capture the original expression
            if (auto projComputed = cast(ProjectComputedInfo) replacement) {
                _originalExprs[projComputed.columnAlias] = expr;
            }
        }
        return replacement;
    }

    /// Get the original expression for a computed column alias
    ExprBase getOriginalExpr(string alias_) {
        return _originalExprs.get(alias_, null);
    }

    /// Get all captured original expressions
    const(ExprBase[string]) allOriginalExprs() {
        return _originalExprs;
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

    /// Accepts ExprBase to work with both typed Expr!Entity and untyped Expr!AnyRef
    this(QueryNodeId queryNodeId, string alias_, ExprBase input, PrefetchExpr prefetch) {
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

        // Ensure data is prefetched, then evaluate input refs, then read
        return evalAs!(AnyRef[])(_prefetch, ctx).then((_) {
            return evalAs!AnyRef(input, ctx);
        }).then((AnyRef[] refs) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext();
            auto queryResult = relCtx.getQueryResult(queryNodeId);

            // Fast path: computed column exists in QueryResult (real DB)
            if (queryResult !is null && queryResult.hasColumn(alias_)) {
                return resolve(relCtx.getColumnValues!T(queryNodeId, alias_, refs));
            }

            // Fallback path: evaluate original expression (MockDB)
            auto originalExpr = relCtx.fetcher.getOriginalExpr(alias_);
            if (originalExpr !is null) {
                return evalAs!T(originalExpr, ctx);
            }

            // No column and no fallback - return defaults
            return resolve(refs.map!(_ => T.init).array);
        });
    }

    @property QueryNodeId queryNodeId() { return _queryNodeId; }
    @property string columnAlias() { return _alias; }
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
        override string likeOp(string operandSql, string pattern, bool caseInsensitive) {
            if (caseInsensitive) {
                return "(LOWER(" ~ operandSql ~ ") LIKE LOWER('" ~ pattern ~ `') ESCAPE '\')`;
            }
            return "(" ~ operandSql ~ " LIKE '" ~ pattern ~ `' ESCAPE '\')`;
        }
        override string name() { return "Test"; }
        override string escapeSqlString(string s) { return "'" ~ s ~ "'"; }
        override string jsonToSqlLiteral(JSONValue) { return "NULL"; }
        override string rootIdFilter(string table) { return table ~ ".id = ANY($1)"; }
        override string jsonObjectFunc() { return "json_build_object"; }
        override string rowJsonFunc() { return ""; }
        override string emptyJsonArray() { return "'[]'::json"; }
        override string aggregateLayerJson(int, string) { return ""; }
    }
    auto optimizer = new SqlOptimizer(new TestDialect());
    assert(optimizer !is null);
    assert(!optimizer.hasComputedColumns(QueryNodeId(0)));
}

unittest {
    // Test computed column detection
    // Create a mock expression tree: ProjectColumn + " " + ProjectColumn

    // Minimal entity for testing
    static struct TestUser {
        import dunamis.core.types : PrimaryKeyAttr;
        @PrimaryKeyAttr string id;
    }

    // Create mock QueryNode and PrefetchExpr
    auto node = new QueryNode(QueryNodeId(0), "User", "users");
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
        override string likeOp(string operandSql, string pattern, bool caseInsensitive) {
            if (caseInsensitive) {
                return "(LOWER(" ~ operandSql ~ ") LIKE LOWER('" ~ pattern ~ `') ESCAPE '\')`;
            }
            return "(" ~ operandSql ~ " LIKE '" ~ pattern ~ `' ESCAPE '\')`;
        }
        override string name() { return "Test"; }
        override string escapeSqlString(string s) { return "'" ~ s ~ "'"; }
        override string jsonToSqlLiteral(JSONValue) { return "NULL"; }
        override string rootIdFilter(string table) { return table ~ ".id = ANY($1)"; }
        override string jsonObjectFunc() { return "json_build_object"; }
        override string rowJsonFunc() { return ""; }
        override string emptyJsonArray() { return "'[]'::json"; }
        override string aggregateLayerJson(int, string) { return ""; }
    }
    auto ctx = new OptimizeContext();
    auto sqlOpt = new SqlOptimizer(new TestDialect());
    sqlOpt.optimize(wrapper, ctx);

    // Check that computed columns were created
    assert(sqlOpt.hasComputedColumns(QueryNodeId(0)));
    auto computed = sqlOpt.getComputedColumns(QueryNodeId(0));
    assert(computed.length >= 1);
}

unittest {
    // Test ProjectComputedExpr
    static struct TestUser {
        import dunamis.core.types : PrimaryKeyAttr;
        @PrimaryKeyAttr string id;
    }

    auto node = new QueryNode(QueryNodeId(0), "User", "users");
    auto prefetch = new PrefetchExpr(node);
    auto item = new EveryItemOfExpr!TestUser();
    auto proj = new ProjectComputedExpr!string(QueryNodeId(0), "computed_0", item, prefetch);
    assert(proj.queryNodeId == QueryNodeId(0));
    assert(proj.columnAlias == "computed_0");
    assert(proj.dependencies().length == 2);  // input and prefetch
}

