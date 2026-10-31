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

import dunamis.core.expr : CollectionEntityType, Expr, ExprBase, evalAs;
import dunamis.core.elements : analyzeBinders, BinderInfo, evalBound, Flattened, PlaceholderInfo, ScopeAnalysis;
import dunamis.core.eval;
import dunamis.core.optimize;
import dunamis.core.types : AnyRef;

// ============================================================================
// Interfaces for filter detection
// ============================================================================

/// Interface for filter placeholder items (for detecting item in predicate).
interface FilterItemInfo : PlaceholderInfo {
    /// Get parent FilterByExpr (its binder)
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
    @property Object binder() { return _parentFilter; }

    override ExprBase[] dependencies() {
        return [];  // Leaf node (placeholder)
    }

    override void replaceDependency(size_t, ExprBase) {
        // No dependencies to replace
    }

    override Promise!(Entity[]) eval(EvalContext ctx) {
        // The items the predicate is evaluated for: those of the batch
        // FilterByExpr.eval binds (all the items it filters, or one).
        Entity[] vals;
        if (ctx.tryGetValues!Entity(_parentFilter, vals))
            return resolve(vals);
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
class FilterByExpr(Entity) : Expr!(Entity[]), FilterByInfo, BinderInfo {
    private ExprBase _source;
    FilterItemExpr!Entity _item;
    private ExprBase _predicate;  // Expr!bool
    /// What the predicate reads (whether it must be evaluated for one item
    /// at a time, see `ScopeAnalysis`).
    private ScopeAnalysis _analysis;

    this(Expr!(Entity[]) source, FilterItemExpr!Entity item, Expr!bool pred) {
        _source = source;
        _item = item;
        _predicate = pred;
        item._parentFilter = this;
        analyzeBinders(this);
    }

    // BinderInfo implementation
    ExprBase[] scopedParts() { return [_predicate]; }
    Object[] placeholders() { return [_item]; }
    @property ScopeAnalysis scopeAnalysis() { return _analysis; }
    void setScopeAnalysis(ScopeAnalysis analysis) { _analysis = analysis; }

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
        // Optimize the predicate, for its in-memory evaluation (data sources
        // may read the values it needs with those of the rows filtered, see
        // OptimizeContext.elementOwner). First, as a map optimizes its body
        // before its collection: what the predicate reads may make the rows
        // a query of their own (into which the filter is then pushed), which
        // the source's root reads its rows from.
        _predicate = (cast(Expr!bool) _predicate).optimize(ctx);
        // Optimize source - pattern matching for SQL push-down happens
        // in the relational layer (schema.d), not here in core
        _source = source.optimize(ctx);
        return this;
    }

    /// In-memory filtering: the predicate is evaluated once, for all the
    /// items of all the groups (like a map's body), in a scope of its own
    /// binding the items (see `evalBound`). A predicate referring to the item
    /// from within a nested scope (e.g. a nested filter's predicate comparing
    /// with it), or to the placeholder of an enclosing construct, is
    /// evaluated for each item (see `ScopeAnalysis.perElement`).
    override Promise!(Entity[][]) eval(EvalContext ctx) {
        auto predicate = _predicate;
        auto self = this;
        auto perItem = _analysis.perElement;

        return evalAs!(Entity[])(_source, ctx).then((Entity[][] groups) {
            auto batch = Flattened!Entity(groups);
            auto items = batch.elements;
            if (items.length == 0)
                return resolve(groups);

            Promise!(bool[]) results;
            if (perItem)
                results = evalPerItem(predicate, ctx, self, items);
            else
                results = evalBound!bool(predicate, ctx, [binding(self, items)], items.length,
                    construct, "predicate", "items");
            return results.then((bool[] keep) {
                auto result = new Entity[][](groups.length);
                foreach (gi, group; batch.regroup(keep))
                    foreach (j, k; group)
                        if (k)
                            result[gi] ~= groups[gi][j];
                return result;
            });
        });
    }

    private enum construct = "filter of " ~ Entity.stringof;

    /// The predicate's value for each item, evaluated for one at a time.
    private static Promise!(bool[]) evalPerItem(ExprBase predicate, EvalContext ctx, Object self, Entity[] items) {
        import dunamis.core.awaiting : await;
        return async({
            bool[] results;
            results.reserve(items.length);
            foreach (item; items)
                results ~= evalBound!bool(predicate, ctx, [binding(self, [item])], 1,
                    construct, "predicate", "item").await[0];
            return results;
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
    alias Entity = CollectionEntityType!Coll;

    // Create placeholder for the item being filtered
    auto item = new FilterItemExpr!Entity();

    // Build predicate expression using placeholder
    auto predicate = pred(item);

    static assert(is(typeof(predicate) : Expr!bool),
        "Filter predicate must return Expr!bool, got " ~ typeof(predicate).stringof);

    // Create FilterByExpr (which links the placeholder to itself)
    return new FilterByExpr!Entity(collection, item, predicate);
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

unittest {
    struct TestEntity {
        int id;
    }

    static class TestCollectionExpr : Expr!(TestEntity[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}
        override Promise!(TestEntity[][]) eval(EvalContext) {
            return resolve([TestEntity[].init]);
        }
    }

    // Regression test: the entity type must remain available in the factory
    // body after template-constraint deduction.
    auto filtered = filterBy!((item) => item.eq(item))(new TestCollectionExpr());
    static assert(is(typeof(filtered) == FilterByExpr!TestEntity));
}

// Evaluating a filter predicate in memory must not disturb the memoized
// evaluations of the rest of the request (expressions with side effects,
// such as mutations, rely on being evaluated once).
unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.expr : use;

    static struct TestEntity { int id; }

    static class TestCollectionExpr : Expr!(TestEntity[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}
        override Promise!(TestEntity[][]) eval(EvalContext) {
            return resolve([[TestEntity(1), TestEntity(2)]]);
        }
    }

    static class CountingExpr : Expr!int {
        int evaluations;
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}
        override Promise!(int[]) eval(EvalContext) {
            evaluations++;
            return resolve([1]);
        }
    }

    // Evaluates its input only after the filter has started evaluating its
    // predicate.
    static class LaterExpr : Expr!int {
        ExprBase input;
        this(ExprBase input) { this.input = input; }
        override ExprBase[] dependencies() { return [input]; }
        override void replaceDependency(size_t, ExprBase dep) { input = dep; }
        override Promise!(int[]) eval(EvalContext ctx) {
            auto p = resolve();
            foreach (_; 0 .. 20)
                p = p.then(() {});
            return p.then(() => evalAs!int(input, ctx));
        }
    }

    auto counted = new CountingExpr();
    auto filtered = filterBy!((item) => item.eq(item))(new TestCollectionExpr());
    auto query = use((int a, TestEntity[] items, int b) => a + cast(int) items.length + b,
        counted, filtered, new LaterExpr(counted));

    assert(awaitSync(evalAs!int(query, new EvalContext())) == [4]);
    assert(counted.evaluations == 1);
}

// The predicate is evaluated once, for the items of all the groups
unittest {
    import std.algorithm : map;
    import std.array : array;
    import ae.utils.promise.await : awaitSync;

    static struct Item { int id; }

    static class Groups : Expr!(Item[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}
        override Promise!(Item[][]) eval(EvalContext) {
            return resolve([[Item(1), Item(2)], [Item(3)], [], [Item(4)]]);
        }
    }

    static class IsEven : Expr!bool {
        ExprBase item;
        int* evaluations;
        this(ExprBase item, int* evaluations) { this.item = item; this.evaluations = evaluations; }
        override ExprBase[] dependencies() { return [item]; }
        override void replaceDependency(size_t, ExprBase dep) { item = dep; }
        override Promise!(bool[]) eval(EvalContext ctx) {
            (*evaluations)++;
            return evalAs!Item(item, ctx).then((Item[] items) => items.map!(i => i.id % 2 == 0).array);
        }
    }

    int evaluations;
    auto filtered = filterBy!((Expr!Item i) => cast(Expr!bool) new IsEven(i, &evaluations))(new Groups());
    import std.conv : to;
    auto got = awaitSync(evalAs!(Item[])(filtered, new EvalContext()));
    assert(got.to!string == "[[Item(2)], [], [], [Item(4)]]", got.to!string);
    assert(evaluations == 1, "evaluations: " ~ evaluations.to!string);
}

// A predicate referring to its item from within a nested filter's predicate
// is evaluated for each item (its batches would not line up otherwise)
unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.expr : use;

    static struct Item { int id; }

    static class Items : Expr!(Item[]) {
        ExprBase lengthSource;
        this(ExprBase lengthSource) { this.lengthSource = lengthSource; }
        override ExprBase[] dependencies() { return lengthSource ? [lengthSource] : []; }
        override void replaceDependency(size_t, ExprBase dep) { lengthSource = dep; }
        override Promise!(Item[][]) eval(EvalContext ctx) {
            auto all = [Item(1), Item(2), Item(3)];
            if (lengthSource is null)
                return resolve([all]);
            return lengthSource.evalResultLength(ctx).then((size_t n) {
                auto groups = new Item[][](n);
                foreach (ref g; groups)
                    g = all;
                return groups;
            });
        }
    }

    static class SameId : Expr!bool {
        ExprBase a, b;
        this(ExprBase a, ExprBase b) { this.a = a; this.b = b; }
        override ExprBase[] dependencies() { return [a, b]; }
        override void replaceDependency(size_t i, ExprBase dep) { if (i == 0) a = dep; else b = dep; }
        override Promise!(bool[]) eval(EvalContext ctx) {
            return evalAs!Item(a, ctx).then((Item[] as) => evalAs!Item(b, ctx).then((Item[] bs) {
                // (Batches of one item of the outer filter: see above)
                bool[] r;
                foreach (x; as)
                    r ~= x.id == bs[0].id;
                return r;
            }));
        }
    }

    // The items from 2 on, as a nested filter finds each among all items
    auto filtered = filterBy!((Expr!Item outer) => use((Item[] same) => same.length == 1 && same[0].id >= 2,
        filterBy!((Expr!Item inner) => cast(Expr!bool) new SameId(inner, outer))(new Items(outer))))(
        new Items(null));
    import std.conv : to;
    auto got = awaitSync(evalAs!(Item[])(filtered, new EvalContext()));
    assert(got.to!string == "[[Item(2), Item(3)]]", got.to!string);
}
