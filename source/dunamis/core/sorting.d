/// Sorting expression nodes for ORDER BY support.
///
/// Provides predicate-based sorting that can be optimized to SQL ORDER BY.
/// SortByExpr sorts using a comparison predicate (a, b) => bool.
///
/// The optimizer pattern-matches predicates like `(a, b) => a.column < b.column`
/// and converts them to SQL ORDER BY clauses.
module dunamis.core.sorting;

import ae.utils.promise;
import ae.utils.promise.await : async;

import dunamis.core.expr;
import dunamis.core.eval;
import dunamis.core.optimize;

// ============================================================================
// Types
// ============================================================================

/// Sort direction
enum SortDirection {
    ASC,
    DESC
}

/// Specification for a single ORDER BY clause (column-based, SQL-friendly)
struct OrderBySpec {
    string column;
    SortDirection direction = SortDirection.ASC;

    @property bool descending() const {
        return direction == SortDirection.DESC;
    }
}

// ============================================================================
// Interfaces for sorting detection
// ============================================================================

/// Interface for sort placeholder items (for detecting a vs b in predicate)
interface SortItemInfo {
    /// Is this the "left" (a) item in comparison?
    @property bool isLeftItem();
    /// Get parent SortByExpr
    @property Object parentSort();
}

/// Interface for expressions that apply predicate-based sorting.
/// Used by optimizers to detect and pattern-match for SQL push-down.
interface SortByInfo {
    /// Get the source collection expression
    ExprBase sortSource();

    /// Get the predicate expression (for optimizer analysis)
    ExprBase sortPredicate();

    /// Get the left item placeholder (a)
    Object sortLeftItem();

    /// Get the right item placeholder (b)
    Object sortRightItem();
}

// ============================================================================
// SortItemExpr - Placeholder for sort predicate items
// ============================================================================

/// Placeholder representing one of the items being compared in a sort predicate.
/// Similar to EveryItemOfExpr but for sort comparisons (a vs b).
///
/// When the predicate `(a, b) => a.field < b.field` is built, both `a` and `b`
/// are SortItemExpr instances. The optimizer can then pattern-match the predicate
/// to extract column names and directions.
class SortItemExpr(Entity) : Expr!Entity, SortItemInfo {
    Object _parentSort;
    private bool _isLeftItem;  // true = a (left), false = b (right)

    this(bool isLeft) {
        _isLeftItem = isLeft;
    }

    @property bool isLeftItem() { return _isLeftItem; }
    @property Object parentSort() { return _parentSort; }

    override ExprBase[] dependencies() {
        return [];  // Leaf node (placeholder)
    }

    override void replaceDependency(size_t, ExprBase) {
        // No dependencies to replace
    }

    override Promise!(Entity[]) eval(EvalContext ctx) {
        // During naive path sorting, the predicate is evaluated with comparison items.
        // Get the current comparison item (left or right) from context.
        auto vals = ctx.getValues!Entity(_parentSort);
        if (vals.length >= 2) {
            return resolve([vals[_isLeftItem ? 0 : 1]]);
        }
        throw new Exception("SortItemExpr: no comparison items in context - " ~
            "ensure SortByExpr.eval() sets up sort items before predicate evaluation");
    }
}

// ============================================================================
// SortByExpr - Predicate-based sorting
// ============================================================================

/// Sorts a collection using a comparison predicate.
///
/// The predicate takes two placeholder expressions and returns Expr!bool
/// (true if a < b, like std.algorithm.sort) or Expr!int (opCmp convention: -1/0/+1).
///
/// During optimization, the relational optimizer pattern-matches the predicate:
/// - `(a, b) => a.column < b.column` → ORDER BY column ASC
/// - `(a, b) => a.column > b.column` → ORDER BY column DESC
///
/// If pattern matching fails, falls back to in-memory sorting.
///
/// Example:
/// ---
/// auto sorted = sortBy!((a, b) => a.firstName < b.firstName)(users);
/// ---
class SortByExpr(Entity, Pred) : Expr!(Entity[]), SortByInfo
    if (is(Pred : Expr!bool) || is(Pred : Expr!int))
{
    private ExprBase _source;
    SortItemExpr!Entity _itemA;  // Left item (a)
    SortItemExpr!Entity _itemB;  // Right item (b)
    private ExprBase _predicate;

    this(Expr!(Entity[]) source, SortItemExpr!Entity a, SortItemExpr!Entity b, Pred pred) {
        _source = source;
        _itemA = a;
        _itemB = b;
        _predicate = pred;
    }

    // SortByInfo implementation
    ExprBase sortSource() { return _source; }
    ExprBase sortPredicate() { return _predicate; }
    Object sortLeftItem() { return _itemA; }
    Object sortRightItem() { return _itemB; }

    /// Get the source expression (typed)
    @property Expr!(Entity[]) source() {
        return cast(Expr!(Entity[])) _source;
    }

    override ExprBase[] dependencies() {
        // Note: predicate is for analysis, not evaluation, so include only source
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
        import ae.utils.promise.await : async, await;

        // Naive path: in-memory sorting using predicate evaluation
        // Uses fibers via async/await for clean sequential code
        auto predicate = _predicate;
        auto self = this;

        return async({
            // Evaluate source to get entity groups
            Entity[][] groups = evalAs!(Entity[])(_source, ctx).await;

            // Sort each group using insertion sort with async comparisons
            foreach (ref group; groups) {
                if (group.length <= 1) continue;

                // Insertion sort with async predicate evaluation
                Entity[] sorted;
                sorted.reserve(group.length);
                sorted ~= group[0];

                foreach (item; group[1 .. $]) {
                    // Find insertion position
                    size_t pos = 0;
                    while (pos < sorted.length) {
                        // Compare: is item < sorted[pos]?
                        // Clear expression cache since context values changed
                        ctx.clearAllCachedEvals();
                        ctx.setValues!Entity(self, [item, sorted[pos]]);

                        bool itemIsLess;
                        static if (is(Pred : Expr!bool)) {
                            bool[] results = evalAs!bool(predicate, ctx).await;
                            itemIsLess = results.length > 0 ? results[0] : false;
                        } else static if (is(Pred : Expr!int)) {
                            int[] results = evalAs!int(predicate, ctx).await;
                            itemIsLess = results.length > 0 ? results[0] < 0 : false;
                        }

                        if (itemIsLess) break;
                        pos++;
                    }

                    // Insert at position
                    Entity[] newSorted;
                    newSorted.reserve(sorted.length + 1);
                    newSorted ~= sorted[0 .. pos];
                    newSorted ~= item;
                    newSorted ~= sorted[pos .. $];
                    sorted = newSorted;
                }

                group = sorted;
            }

            return groups;
        });
    }
}

// ============================================================================
// Factory Functions
// ============================================================================

/// Sort a collection using a comparison predicate.
///
/// The predicate takes two Expr!Entity placeholders and returns Expr!bool
/// (true if a < b) or Expr!int (negative if a < b, 0 if equal, positive if a > b).
///
/// The optimizer will pattern-match common predicates to emit SQL ORDER BY.
/// If pattern matching fails, falls back to in-memory sorting.
///
/// Example:
/// ---
/// // Sort by firstName ascending
/// auto sorted = sortBy!((a, b) => a.firstName < b.firstName)(users);
///
/// // Sort by lastName descending
/// auto sorted = sortBy!((a, b) => a.lastName > b.lastName)(users);
/// ---
auto sortBy(alias pred, Coll)(Coll collection)
    if (is(Coll : Expr!(E[]), E))
{
    alias Entity = CollectionEntityType!Coll;

    // Create placeholders for the two items being compared
    auto itemA = new SortItemExpr!Entity(true);   // left (a)
    auto itemB = new SortItemExpr!Entity(false);  // right (b)

    // Build predicate expression using placeholders
    auto predicate = pred(itemA, itemB);

    // Create SortByExpr
    auto sortExpr = new SortByExpr!(Entity, typeof(predicate))(collection, itemA, itemB, predicate);

    // Link placeholders back to parent
    itemA._parentSort = sortExpr;
    itemB._parentSort = sortExpr;

    return sortExpr;
}

/// Extract the Entity type from an Expr!(Entity[]) type
private template CollectionEntityType(Coll) {
    static if (is(Coll : Expr!(E[]), E)) {
        alias CollectionEntityType = E;
    } else {
        static assert(false, "Expected Expr!(Entity[]), got " ~ Coll.stringof);
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // Test OrderBySpec
    auto spec1 = OrderBySpec("name", SortDirection.ASC);
    assert(spec1.column == "name");
    assert(spec1.direction == SortDirection.ASC);
    assert(!spec1.descending);

    auto spec2 = OrderBySpec("age", SortDirection.DESC);
    assert(spec2.column == "age");
    assert(spec2.direction == SortDirection.DESC);
    assert(spec2.descending);
}

unittest {
    // Test SortItemExpr placeholder
    static struct User {
        string id;
    }

    auto itemA = new SortItemExpr!User(true);
    auto itemB = new SortItemExpr!User(false);

    assert(itemA.isLeftItem == true);
    assert(itemB.isLeftItem == false);

    // Placeholders should have no dependencies
    assert(itemA.dependencies.length == 0);
    assert(itemB.dependencies.length == 0);
}
