/// Filtering expression nodes for WHERE clause support.
///
/// Provides predicate-based filtering that can be optimized to SQL WHERE:
/// - FilterByExpr: filters using a boolean predicate (item) => bool
/// - FilterItemExpr: placeholder for the item being tested
///
/// The optimizer pattern-matches predicates like `(e) => e.column.eq(value)`
/// and converts them to WHERE clauses for SQL push-down.
module dunamis.core.filtering;

import std.algorithm : filter, map;
import std.array : array;

import ae.utils.promise;
import ae.utils.promise.await : async;

import dunamis.core.expr : Expr, ExprBase, evalAs;
import dunamis.core.eval;
import dunamis.core.optimize;
import dunamis.core.types : AnyRef;

// ============================================================================
// Interfaces for filter detection
// ============================================================================

/// Interface for filter placeholder items (for detecting item in predicate).
interface FilterItemInfo {
    /// Get parent FilterByExpr
    @property Object parentFilter();
}

/// Interface for expressions that apply predicate-based filtering.
/// Used by optimizers to detect and pattern-match for SQL push-down.
interface FilterByInfo {
    /// Get the source collection expression
    ExprBase filterSource();

    /// Get the predicate expression (for optimizer analysis)
    ExprBase filterPredicate();

    /// Get the item placeholder
    Object filterItem();
}

// ============================================================================
// FilterItemExpr - Placeholder for filter predicate item
// ============================================================================

/// Placeholder representing the item being tested in a filter predicate.
/// Similar to SortItemExpr but for filtering (single item, not comparison).
///
/// When the predicate `(item) => item.field.eq(value)` is built,
/// `item` is a FilterItemExpr. The optimizer pattern-matches the predicate
/// to extract column conditions.
class FilterItemExpr(Entity) : Expr!Entity, FilterItemInfo {
    Object _parentFilter;

    @property Object parentFilter() { return _parentFilter; }

    override ExprBase[] dependencies() {
        return [];  // Leaf node (placeholder)
    }

    override void replaceDependency(size_t, ExprBase) {
        // No dependencies to replace
    }

    override Promise!(Entity[]) eval(EvalContext ctx) {
        // During naive path filtering, the predicate is evaluated per item.
        // Get the current filter item from context.
        auto vals = ctx.getValues!Entity(_parentFilter);
        if (vals.length > 0) {
            return resolve([vals[0]]);
        }
        throw new Exception("FilterItemExpr: no filter item in context - " ~
            "ensure FilterByExpr.eval() sets up filter item before predicate evaluation");
    }

}

// ============================================================================
// FilterByExpr - Predicate-based filtering
// ============================================================================

/// Filters a collection using a boolean predicate.
///
/// The predicate takes a placeholder expression and returns Expr!bool.
///
/// During optimization, the relational optimizer pattern-matches the predicate:
/// - `(e) => e.column.eq(value)` → WHERE column = value
/// - `(e) => e.col1.gt(x).and(e.col2.lt(y))` → WHERE col1 > x AND col2 < y
///
/// If pattern matching fails, falls back to in-memory filtering.
///
/// Example:
/// ---
/// auto filtered = filterBy!((e) => e.firstName.eq("Alice"))(users);
/// auto filtered = filterBy!((e) => e.age.gte(18).and(e.age.lt(65)))(users);
/// ---
class FilterByExpr(Entity) : Expr!(Entity[]), FilterByInfo {
    private ExprBase _source;
    FilterItemExpr!Entity _item;
    private ExprBase _predicate;  // Expr!bool

    this(Expr!(Entity[]) source, FilterItemExpr!Entity item, Expr!bool pred) {
        _source = source;
        _item = item;
        _predicate = pred;
    }

    // FilterByInfo implementation
    ExprBase filterSource() { return _source; }
    ExprBase filterPredicate() { return _predicate; }
    Object filterItem() { return _item; }

    /// Get the source expression (typed)
    @property Expr!(Entity[]) source() {
        return cast(Expr!(Entity[])) _source;
    }

    override ExprBase[] dependencies() {
        // Note: predicate is for analysis, not direct evaluation, so include only source
        return [_source];
    }

    override void replaceDependency(size_t i, ExprBase newDep) {
        if (i == 0) _source = newDep;
    }

    override Expr!(Entity[]) optimize(OptimizeContext ctx) {
        // Optimize source - pattern matching for SQL push-down happens
        // in the relational layer (schema.d), not here in core
        _source = source.optimize(ctx);
        return this;
    }

    override Promise!(Entity[][]) eval(EvalContext ctx) {
        import ae.utils.promise.await : await;

        // Naive path: in-memory filtering using predicate evaluation
        auto predicate = _predicate;
        auto self = this;

        return async({
            // Evaluate source to get entity groups
            Entity[][] groups = evalAs!(Entity[])(_source, ctx).await;

            debug(filter) {
                import std.stdio : writefln;
                writefln("FilterByExpr.eval: %d groups", groups.length);
                foreach (gi, g; groups) {
                    writefln("  group[%d]: %d items", gi, g.length);
                }
            }

            // Filter each group using predicate evaluation
            foreach (gi, ref group; groups) {
                Entity[] filtered;
                filtered.reserve(group.length);

                foreach (item; group) {
                    // Set current filter item in context
                    ctx.setValues!Entity(self, [item]);

                    // Clear ALL cached evaluations - the entire predicate tree depends on the
                    // filter item, including nested BinaryOpExpr, ConstantExpr, column access, etc.
                    // Each iteration has a new context (different filter item), so all caches are invalid.
                    ctx.clearAllCachedEvals();

                    // Evaluate predicate
                    bool[] results = evalAs!bool(predicate, ctx).await;
                    debug(filter) {
                        import std.stdio : writefln;
                        writefln("  predicate results=%s", results);
                    }
                    if (results.length > 0 && results[0]) {
                        filtered ~= item;
                    }
                }

                debug(filter) {
                    import std.stdio : writefln;
                    writefln("  group[%d] after filter: %d items", gi, filtered.length);
                }
                group = filtered;
            }

            return groups;
        });
    }
}

// ============================================================================
// Factory Functions
// ============================================================================

/// Filter a collection using a boolean predicate.
///
/// The predicate takes an Expr!Entity placeholder and returns Expr!bool.
///
/// The optimizer will pattern-match common predicates to emit SQL WHERE.
/// If pattern matching fails, falls back to in-memory filtering.
///
/// Example:
/// ---
/// // Filter by firstName equals "Alice"
/// auto filtered = filterBy!((e) => e.firstName.eq("Alice"))(users);
///
/// // Filter by age range
/// auto filtered = filterBy!((e) => e.age.gte(18).and(e.age.lt(65)))(users);
///
/// // Filter with OR condition
/// auto filtered = filterBy!((e) => e.status.eq("active").or(e.role.eq("admin")))(users);
/// ---
auto filterBy(alias pred, Coll)(Coll collection)
    if (is(Coll : Expr!(E[]), E))
{
    alias Entity = E;

    // Create placeholder for the item being filtered
    auto item = new FilterItemExpr!Entity();

    // Build predicate expression using placeholder
    auto predicate = pred(item);

    static assert(is(typeof(predicate) : Expr!bool),
        "Filter predicate must return Expr!bool, got " ~ typeof(predicate).stringof);

    // Create FilterByExpr
    auto filterExpr = new FilterByExpr!Entity(collection, item, predicate);

    // Link placeholder back to parent
    item._parentFilter = filterExpr;

    return filterExpr;
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // Test FilterByInfo interface - verify interface exists and is accessible
    FilterByInfo info = null;
    assert(info is null);  // Just verify the interface compiles
}

unittest {
    // Test FilterItemInfo interface - verify interface exists and is accessible
    FilterItemInfo info = null;
    assert(info is null);  // Just verify the interface compiles
}
