module dunamis.relational.schema.patterns;

import std.algorithm;
import std.array;
import std.typecons : Nullable;

import dunamis.core.expr.base : ExprBase;
import dunamis.core.optimize : OptimizeContext;
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
///
/// The items of filter predicates and sort comparisons are rows of the map
/// whose collection they filter or sort, if `ctx` records one (see
/// `OptimizeContext.elementOwner`): for them, that map is returned.
Object findMapExprFromChain(ExprBase expr, ref JoinHop[] joinPath, out ExprBase baseInput, out ExprBase baseInputAsAnyRef,
        OptimizeContext ctx = null) {
    import dunamis.core.expr : EveryItemOfExprInfo;
    import dunamis.core.filtering : FilterItemInfo;
    import dunamis.core.transparency : Transparent, wrapped;
    import dunamis.core.sorting : SortItemInfo;

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
        if (cast(FilterItemInfo) expr || cast(SortItemInfo) expr) {
            auto owner = ctx is null ? null : ctx.elementOwner(expr);
            if (owner is null)
                break;
            baseInput = inBelongsToChain ? lastBeforeBelongsTo : initialExpr;
            baseInputAsAnyRef = inBelongsToChain ? lastBeforeBelongsToAsAnyRef : null;
            return owner;
        }

        // Walk through access expressions using interfaces
        if (auto col = cast(ColumnAccessInfo) expr) {
            expr = col.inputExpr;
            continue;
        }
        if (auto belongs = cast(BelongsToInfo) expr) {
            // (A JOIN by the foreign key column, of a single-column key; the
            // parents of a composite key are read on the naive path)
            if (belongs.parentPkColumns.length != 1)
                break;
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
                belongs.childTypeName,
                belongs.childPkColumns,
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
        // Through unwrapped nullables and entity casts (plugin forwarding
        // inserts these)
        if (auto inner = cast(ExprBase) wrapped(expr, Transparent.entity)) {
            expr = inner;
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
    string sourceType;
    string[] sourcePkColumns;
    string targetTable;       // e.g., "users"
    string targetType;        // e.g., "User"
    string fk;                // e.g., "author_id"
    string[] targetPkColumns; // e.g., ["id"] — SQL column names of target's PK
}
