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
    import dunamis.core.expr : EveryItemOfExprInfo, UnwrapNullableInfo, EntityCastInfo;

    // Track the first expression before any belongsTo chain starts
    // This produces refs for the query node's base table
    ExprBase lastBeforeBelongsTo = expr;
    ExprBase lastBeforeBelongsToAsAnyRef = null;
    bool inBelongsToChain = false;

    // Save initial expression for non-belongsTo baseInput.
    // With plugins, the initial expression is an EntityCastExpr that properly converts
    // plugin-wrapped entity types (e.g., SortedUser → User). Using this instead of the
    // EveryItemOfExpr (which may be typed for the wrapper) ensures EntityToAnyRefExpr
    // gets the correct entity type.
    ExprBase initialExpr = expr;

    while (expr !is null) {
        // Check if we've reached EveryItemOfExpr (any instantiation)
        if (auto every = cast(EveryItemOfExprInfo) expr) {
            baseInput = inBelongsToChain ? lastBeforeBelongsTo : initialExpr;
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
                belongs.fkColumn,
                belongs.parentPkColumns
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
        // Walk through entity cast expressions (plugin forwarding inserts these)
        if (auto castInfo = cast(EntityCastInfo) expr) {
            expr = castInfo.inputExpr;
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
    string sourceTable;       // e.g., "posts"
    string targetTable;       // e.g., "users"
    string targetType;        // e.g., "User"
    string fk;                // e.g., "author_id"
    string[] targetPkColumns; // e.g., ["id"] — SQL column names of target's PK
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
    string column;        // Column name, empty if not a column access
    bool isLeftItem;      // true if this accesses the left (a) sort item
}

/// Try to extract column info from a sort predicate operand.
private SortColumnInfo extractSortColumnInfo(Object expr, Object leftItem, Object rightItem) {
    import dunamis.core.sorting : SortItemInfo;
    import dunamis.core.expr : EntityCastInfo;

    // Check if this is a column access expression
    auto colAccess = cast(ColumnAccessInfo) expr;
    if (colAccess is null) return SortColumnInfo.init;

    // Get the input expression, walking through EntityCast wrappers
    // (plugin forwarded fields insert EntityCast between the sort item and column access)
    Object inputExpr = colAccess.inputExpr();
    while (inputExpr !is null) {
        if (inputExpr is leftItem) {
            return SortColumnInfo(colAccess.column, true);
        } else if (inputExpr is rightItem) {
            return SortColumnInfo(colAccess.column, false);
        }
        // Walk through EntityCast
        if (auto castInfo = cast(EntityCastInfo) inputExpr) {
            inputExpr = castInfo.inputExpr();
        } else {
            break;
        }
    }

    return SortColumnInfo.init;
}

// Import these interfaces from their modules for use in pattern matching
private import dunamis.core.sorting : SortByInfo, OrderBySpec, SortDirection;
