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
        // The items compared: those SortByExpr.eval binds to this side of
        // the comparisons it evaluates (one comparison, or a batch of them).
        Entity[] vals;
        if (ctx.tryGetValues!Entity(this, vals))
            return resolve(vals);
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
    /// Whether comparisons must be evaluated one at a time (see
    /// `evaluatesPerItem`).
    private bool _perItem;

    this(Expr!(Entity[]) source, SortItemExpr!Entity a, SortItemExpr!Entity b, Pred pred) {
        import dunamis.core.elements : evaluatesPerItem;
        _source = source;
        _itemA = a;
        _itemB = b;
        _predicate = pred;
        _perItem = evaluatesPerItem(pred, a, b);
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
        import dunamis.core.elements : evaluatesPerItem;

        // Optimize the predicate (first: see FilterByExpr.optimize), for its
        // in-memory evaluation
        _predicate = (cast(Pred) _predicate).optimize(ctx);
        _perItem = evaluatesPerItem(_predicate, _itemA, _itemB);
        // Optimize source - pattern matching for SQL push-down happens
        // in the relational layer (schema.d), not here in core
        _source = source.optimize(ctx);
        return this;
    }

    /// The most comparisons evaluated as one batch (see eval).
    enum size_t maxBatchedComparisons = 1 << 20;

    /// In-memory sorting (stable). The comparisons of all the pairs of items
    /// of each group are evaluated at once, as one batch of the predicate
    /// (in a scope binding the items, see FilterByExpr.eval), unless there
    /// are more than `maxBatchedComparisons` of them, or the predicate must
    /// be evaluated one pair at a time (see `evaluatesPerItem`): then the
    /// comparisons the sort needs are evaluated one at a time.
    override Promise!(Entity[][]) eval(EvalContext ctx) {
        auto self = this;
        return evalAs!(Entity[])(_source, ctx).then((Entity[][] groups) {
            size_t pairs;
            foreach (group; groups)
                pairs += group.length > 1 ? group.length * (group.length - 1) : 0;
            if (pairs == 0)
                return resolve(groups);
            if (_perItem || pairs > maxBatchedComparisons)
                return self.sortComparingEach(ctx, groups);
            return self.sortComparingAll(ctx, groups, pairs);
        });
    }

    /// Whether a comparison result means "less than".
    private static bool isLess(R)(R r) {
        static if (is(R == bool)) return r;
        else return r < 0;
    }

    private alias PredResult = Pred.ResultType;

    private Promise!(Entity[][]) sortComparingAll(EvalContext ctx, Entity[][] groups, size_t pairs) {
        import std.algorithm.sorting : sort;
        import std.algorithm.mutation : SwapStrategy;
        import std.conv : to;

        Entity[] lefts, rights;
        lefts.reserve(pairs);
        rights.reserve(pairs);
        foreach (group; groups)
            if (group.length > 1)
                foreach (i, a; group)
                    foreach (j, b; group)
                        if (i != j) {
                            lefts ~= a;
                            rights ~= b;
                        }
        auto pairCtx = ctx.createScope();
        pairCtx.setValues!Entity(_itemA, lefts);
        pairCtx.setValues!Entity(_itemB, rights);
        return evalAs!PredResult(_predicate, pairCtx).then((PredResult[] results) {
            if (results.length != pairs)
                throw new Exception("Batch size mismatch in sort of " ~ Entity.stringof ~
                    ": its predicate produced " ~ results.length.to!string ~ " results for " ~
                    pairs.to!string ~ " comparisons (use broadcast() to replicate a single value " ~
                    "across a batch)");
            auto sorted = new Entity[][](groups.length);
            size_t offset;
            foreach (gi, group; groups) {
                auto n = group.length;
                if (n <= 1) {
                    sorted[gi] = group;
                    continue;
                }
                auto base = offset;
                // (The comparison of i with j: pair i*(n-1) + j - (j > i).)
                bool less(size_t i, size_t j) {
                    return i != j && isLess(results[base + i * (n - 1) + j - (j > i ? 1 : 0)]);
                }
                auto order = new size_t[n];
                foreach (i; 0 .. n)
                    order[i] = i;
                order.sort!(less, SwapStrategy.stable);
                foreach (i; order)
                    sorted[gi] ~= group[i];
                offset += n * (n - 1);
            }
            return sorted;
        });
    }

    private Promise!(Entity[][]) sortComparingEach(EvalContext ctx, Entity[][] groups) {
        import std.algorithm.sorting : sort;
        import std.algorithm.mutation : SwapStrategy;
        import dunamis.core.awaiting : await;

        auto predicate = _predicate;
        auto itemA = _itemA, itemB = _itemB;
        return async({
            foreach (ref group; groups) {
                if (group.length <= 1) continue;
                auto items = group;
                bool less(size_t i, size_t j) {
                    if (i == j) return false;
                    // Evaluated in a scope of its own (see FilterByExpr)
                    auto pairCtx = ctx.createScope();
                    pairCtx.setValues!Entity(itemA, [items[i]]);
                    pairCtx.setValues!Entity(itemB, [items[j]]);
                    PredResult[] results = evalAs!PredResult(predicate, pairCtx).await;
                    return results.length > 0 && isLess(results[0]);
                }
                auto order = new size_t[items.length];
                foreach (i; 0 .. items.length)
                    order[i] = i;
                order.sort!(less, SwapStrategy.stable);
                Entity[] sorted;
                sorted.reserve(items.length);
                foreach (i; order)
                    sorted ~= items[i];
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
/// Sort `source` by the field `member` of its elements, in direction `dir`
/// (an ordering of the SortingPlugin's `orderBy` arguments).
///
/// The `orderBy` argument of every list field with elements of type `E`
/// sorts through this one instance per field of `E` and direction, rather
/// than through comparison functions of its own.
Expr!(E[]) sortByField(string member, SortDirection dir, E)(Expr!(E[]) source) {
    static if (dir == SortDirection.ASC)
        return sortBy!((a, b) => mixin("a." ~ member ~ ".lt(b." ~ member ~ ")"))(source);
    else
        return sortBy!((a, b) => mixin("a." ~ member ~ ".gt(b." ~ member ~ ")"))(source);
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

// The comparisons of all the pairs of each group are evaluated at once; the
// sort is stable
unittest {
    import ae.utils.promise.await : awaitSync;

    static struct Item { int id; int key; }

    static class Groups : Expr!(Item[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}
        override Promise!(Item[][]) eval(EvalContext) {
            return resolve([[Item(1, 3), Item(2, 1), Item(3, 3), Item(4, 2)], [Item(5, 0)], []]);
        }
    }

    static class KeyLess : Expr!bool {
        ExprBase a, b;
        int* evaluations;
        this(ExprBase a, ExprBase b, int* evaluations) { this.a = a; this.b = b; this.evaluations = evaluations; }
        override ExprBase[] dependencies() { return [a, b]; }
        override void replaceDependency(size_t i, ExprBase dep) { if (i == 0) a = dep; else b = dep; }
        override Promise!(bool[]) eval(EvalContext ctx) {
            (*evaluations)++;
            return evalAs!Item(a, ctx).then((Item[] as) => evalAs!Item(b, ctx).then((Item[] bs) {
                bool[] r;
                foreach (i, x; as)
                    r ~= x.key < bs[i].key;
                return r;
            }));
        }
    }

    int evaluations;
    auto sorted = sortBy!((Expr!Item a, Expr!Item b) => cast(Expr!bool) new KeyLess(a, b, &evaluations))(new Groups());
    import std.conv : to;
    auto got = awaitSync(evalAs!(Item[])(sorted, new EvalContext())) ;
    assert(got.to!string == "[[Item(2, 1), Item(4, 2), Item(1, 3), Item(3, 3)], [Item(5, 0)], []]", got.to!string);
    assert(evaluations == 1, "evaluations: " ~ evaluations.to!string);
}
