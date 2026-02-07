module dunamis.relational.schema.patterns;

import std.algorithm;
import std.array;
import std.typecons : Nullable;

import dunamis.core.expr.base : ExprBase;
import dunamis.relational.schema.interfaces;

// ============================================================================
// Helper: Find MapExpr from _input chain
// ============================================================================

/// Walk _input chain to find the owning MapExpr and collect join info.
/// Returns the MapExpr (as Object) or null if not found.
/// Also returns the base input expression (the one that produces refs for the
/// query node's base table) via the baseInput out parameter.
/// When a belongsTo chain is found, baseInputAsAnyRef provides a pre-wrapped
/// Expr!AnyRef that converts the base entity to AnyRef with the correct type.
///
/// Accepts ExprBase to work with any Expr!Entity type.
Object findMapExprFromChain(ExprBase expr, ref JoinHop[] joinPath, out ExprBase baseInput, out ExprBase baseInputAsAnyRef) {
    import dunamis.core.expr : EveryItemOfExprInfo, UnwrapNullableInfo;

    // Track the first expression before any belongsTo chain starts
    // This produces refs for the query node's base table
    ExprBase lastBeforeBelongsTo = expr;
    ExprBase lastBeforeBelongsToAsAnyRef = null;
    bool inBelongsToChain = false;

    while (expr !is null) {
        // Check if we've reached EveryItemOfExpr (any instantiation)
        if (auto every = cast(EveryItemOfExprInfo) expr) {
            baseInput = inBelongsToChain ? lastBeforeBelongsTo : expr;
            baseInputAsAnyRef = inBelongsToChain ? lastBeforeBelongsToAsAnyRef : null;
            return every.parentMap;
        }

        // Walk through access expressions using interfaces
        if (auto col = cast(ColumnAccessInfo) expr) {
            expr = col.inputExpr;
            continue;
        }
        if (auto belongs = cast(BelongsToInfo) expr) {
            // Track the input that produces base entity refs for the query node.
            // Always update (not just first hop) so that for multi-hop chains
            // (e.g., c.post.author.firstName) we get the innermost input (Comment refs),
            // not an intermediate one (Post refs). Columns are keyed by root entity refs.
            lastBeforeBelongsTo = belongs.inputExpr;
            lastBeforeBelongsToAsAnyRef = belongs.inputAsAnyRefExpr;
            inBelongsToChain = true;
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
        // Unwrap nullable expressions - continue through to the nullable input
        if (auto unwrap = cast(UnwrapNullableInfo) expr) {
            expr = unwrap.inputExpr;
            continue;
        }
        // Unknown expression type
        break;
    }
    baseInput = null;
    baseInputAsAnyRef = null;
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
// Sorting Pattern Matching
// ============================================================================

/// Extract ORDER BY specs from a SortByInfo by pattern-matching its predicate.
OrderBySpec[] extractSortBySpecs(SortByInfo sortByInfo) {
    import dunamis.core.expr : BinaryOpInfo;
    import dunamis.core.sorting : SortItemInfo, SortDirection, OrderBySpec;

    auto predicate = sortByInfo.sortPredicate;
    auto leftItem = sortByInfo.sortLeftItem;
    auto rightItem = sortByInfo.sortRightItem;

    // Try to match: BinaryOp(<, ColumnAccess(left, col), ColumnAccess(right, col))
    //           or: BinaryOp(>, ColumnAccess(left, col), ColumnAccess(right, col))
    auto binOp = cast(BinaryOpInfo) predicate;
    if (binOp is null) return [];

    string op = binOp.operator;
    if (op != "<" && op != ">") return [];

    // Get left and right operands
    auto leftOp = binOp.left;
    auto rightOp = binOp.right;

    // Try to extract column info from each operand
    auto leftColInfo = extractSortColumnInfo(leftOp, leftItem, rightItem);
    auto rightColInfo = extractSortColumnInfo(rightOp, leftItem, rightItem);

    if (leftColInfo.column.length == 0 || rightColInfo.column.length == 0) return [];

    // Both must access the same column
    if (leftColInfo.column != rightColInfo.column) return [];

    // Verify left operand is on left item and right operand is on right item
    if (!leftColInfo.isLeftItem || rightColInfo.isLeftItem) return [];

    // Determine direction: < means ASC, > means DESC
    auto direction = (op == "<") ? SortDirection.ASC : SortDirection.DESC;

    return [OrderBySpec(leftColInfo.column, direction)];
}

/// Info about a column extracted from a sort predicate operand
private struct SortColumnInfo {
    string column;        // SQL column name, empty if not a column access
    bool isLeftItem;      // true if this accesses the left (a) sort item
}

/// Try to extract column info from a sort predicate operand.
private SortColumnInfo extractSortColumnInfo(Object expr, Object leftItem, Object rightItem) {
    import dunamis.core.sorting : SortItemInfo;

    // Check if this is a column access expression
    auto colAccess = cast(ColumnAccessInfo) expr;
    if (colAccess is null) return SortColumnInfo.init;

    // Get the input expression
    auto inputExpr = colAccess.inputExpr();

    // Check if input is one of the sort item placeholders
    if (inputExpr is leftItem) {
        return SortColumnInfo(colAccess.sqlColumn, true);
    } else if (inputExpr is rightItem) {
        return SortColumnInfo(colAccess.sqlColumn, false);
    }

    return SortColumnInfo.init;
}

// ============================================================================
// Filter Pattern Matching
// ============================================================================

/// Extract WHERE clause SQL from a FilterByInfo by pattern-matching its predicate.
Nullable!string extractFilterWhereClause(FilterByInfo filterInfo) {
    import dunamis.core.expr : BinaryOpInfo, UnaryOpInfo, ConstantInfo;
    import dunamis.core.filtering : FilterItemInfo;

    auto predicate = filterInfo.filterPredicate;
    auto filterItem = filterInfo.filterItem;

    return extractWhereFromExpr(predicate, filterItem);
}

/// Recursively extract WHERE SQL from an expression tree.
Nullable!string extractWhereFromExpr(Object expr, Object filterItem) {
    import dunamis.core.expr : BinaryOpInfo, UnaryOpInfo, ConstantInfo;

    // Handle binary operators: AND, OR, comparison operators
    if (auto binOp = cast(BinaryOpInfo) expr) {
        string op = binOp.operator;

        // Logical operators: AND, OR
        if (op == "&&" || op == "||") {
            auto leftSql = extractWhereFromExpr(binOp.left, filterItem);
            auto rightSql = extractWhereFromExpr(binOp.right, filterItem);
            if (!leftSql.isNull && !rightSql.isNull) {
                string sqlOp = (op == "&&") ? "AND" : "OR";
                return Nullable!string("(" ~ leftSql.get ~ " " ~ sqlOp ~ " " ~ rightSql.get ~ ")");
            }
            return Nullable!string.init;
        }

        // Comparison operators: ==, !=, <, <=, >, >=
        if (op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=") {
            // Try to match: column op constant or constant op column
            auto leftColInfo = extractFilterColumnInfo(binOp.left, filterItem);
            auto rightColInfo = extractFilterColumnInfo(binOp.right, filterItem);
            auto leftConst = extractConstant(binOp.left);
            auto rightConst = extractConstant(binOp.right);

            string column, value;
            bool isColumnOnLeft = false;

            if (!leftColInfo.isNull && !rightConst.isNull) {
                column = leftColInfo.get;
                value = rightConst.get;
                isColumnOnLeft = true;
            } else if (!rightColInfo.isNull && !leftConst.isNull) {
                column = rightColInfo.get;
                value = leftConst.get;
                isColumnOnLeft = false;
            } else {
                return Nullable!string.init;
            }

            string sqlOp = translateComparisonOp(op, isColumnOnLeft);
            return Nullable!string(column ~ " " ~ sqlOp ~ " " ~ value);
        }
    }

    // Handle unary NOT operator
    if (auto unaryOp = cast(UnaryOpInfo) expr) {
        if (unaryOp.operator == "!") {
            auto operandSql = extractWhereFromExpr(unaryOp.operand, filterItem);
            if (!operandSql.isNull) {
                return Nullable!string("NOT " ~ operandSql.get);
            }
        }
    }

    // Handle constant true/false
    if (auto constInfo = cast(ConstantInfo) expr) {
        if (constInfo.valueType == typeid(bool)) {
            bool val = constInfo.valueAsString == "true";
            return Nullable!string(val ? "1=1" : "1=0");
        }
    }

    // Handle LIKE expressions (contains, startsWith, endsWith)
    import dunamis.core.expr : LikeInfo;
    if (auto likeInfo = cast(LikeInfo) expr) {
        auto colInfo = extractFilterColumnInfo(likeInfo.likeOperand, filterItem);
        if (!colInfo.isNull) {
            // Escape single quotes in pattern and wrap in quotes
            // The pattern already has % and _ escaped as \% and \_ by escapeLikePattern()
            string escapedPattern = likeInfo.likePattern.replace("'", "''");
            if (likeInfo.caseInsensitive) {
                // Case-insensitive: use LOWER() on both sides (works on all databases)
                return Nullable!string("LOWER(" ~ colInfo.get ~ ") LIKE LOWER('" ~ escapedPattern ~ `') ESCAPE '\'`);
            } else {
                return Nullable!string(colInfo.get ~ " LIKE '" ~ escapedPattern ~ `' ESCAPE '\'`);
            }
        }
    }

    return Nullable!string.init;
}

/// Try to extract column name from an expression that should be a column access on the filter item.
private Nullable!string extractFilterColumnInfo(Object expr, Object filterItem) {
    // Check if this is a column access expression
    auto colAccess = cast(ColumnAccessInfo) expr;
    if (colAccess is null) return Nullable!string.init;

    // Get the input expression and check if it's the filter item placeholder
    auto inputExpr = colAccess.inputExpr();
    if (cast(Object) inputExpr is filterItem) {
        return Nullable!string(colAccess.sqlColumn);
    }

    return Nullable!string.init;
}

/// Extract SQL literal from a constant expression.
private Nullable!string extractConstant(Object expr) {
    import dunamis.core.expr : ConstantInfo;
    import dunamis.relational.sql_optimizer : constantToSqlLiteral;

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

// Import these interfaces from their modules for use in pattern matching
private import dunamis.core.sorting : SortByInfo, OrderBySpec, SortDirection;
private import dunamis.core.filtering : FilterByInfo;
