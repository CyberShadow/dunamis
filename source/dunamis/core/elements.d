/// The elements of collections, as the expressions binding them (binders:
/// maps, filters, sorts, collection predicates) and their placeholders see
/// them: which binder a placeholder stands for the values of, which binders
/// the parts of a tree read the placeholders of (correlation), and the
/// evaluation of a binder's part for a batch of elements.
module dunamis.core.elements;

import ae.utils.promise : Promise;

import dunamis.core.eval : Binding, EvalContext;
import dunamis.core.expr.base : ExprBase, evalAs;
import dunamis.core.expr.combinators : MapExprInfo;
import dunamis.core.optimize : OptimizeContext;

// ============================================================================
// Binders and placeholders
// ============================================================================

/// A placeholder: an expression standing, within the parts of its binder
/// which the binder evaluates in a scope of its own (see `BinderInfo`), for
/// the values the binder binds there (e.g. a map's item, for the elements of
/// the map's batch).
interface PlaceholderInfo {
    /// The expression binding the placeholder's values (set when the binder
    /// is built: null until then).
    @property Object binder();
}

/// A binder: an expression evaluating parts of itself (its scoped parts:
/// a map's body, the predicate of a filter, a sort or a collection
/// predicate) for the elements of collections, in a scope of its own binding
/// its placeholders to these elements (see `evalBound`).
interface BinderInfo {
    /// The parts it evaluates in a scope of its own.
    ExprBase[] scopedParts();

    /// The placeholders it binds there.
    Object[] placeholders();

    /// The analysis of its scoped parts (see `analyzeBinders`).
    @property ScopeAnalysis scopeAnalysis();

    /// Record the analysis of its scoped parts.
    void setScopeAnalysis(ScopeAnalysis analysis);
}

/// What a binder's scoped parts read, beyond the values the binder binds
/// for them (see `analyzeBinders`).
struct ScopeAnalysis {
    /// Whether they read the placeholders of other binders than the binder
    /// itself and those within them (e.g. an enclosing map's item), whose
    /// values are of other batches than the binder's elements.
    bool readsEnclosing;

    /// Whether they read the binder's own placeholders from within the
    /// scope of a binder within them (e.g. a nested filter's predicate
    /// comparing with the item; correlation), whose batch is that binder's
    /// elements, not the binder's.
    bool correlated;

    /// Whether the scoped parts must be evaluated for one element (or one
    /// pair of compared elements) at a time, rather than for a batch of all
    /// of them at once: then references to other batches see batches of one,
    /// which line up with the element.
    @property bool perElement() const { return readsEnclosing || correlated; }

    /// Whether the scoped parts are a function of the elements the binder
    /// binds only, so that equal elements give equal results.
    @property bool readsOwnElementsOnly() const { return !readsEnclosing; }
}

/// The subexpressions of `expr`: its dependencies, and the parts it
/// evaluates in a scope of its own (see `BinderInfo`), which are not all
/// among them (a filter's or a sort's predicate is not). Analyses of what a
/// tree reads (its placeholders, data sources, ...) must walk these.
ExprBase[] subexpressions(ExprBase expr) {
    auto result = expr.dependencies().dup;
    if (auto binder = cast(BinderInfo) expr)
        foreach (part; binder.scopedParts()) {
            bool listed;
            foreach (dep; result)
                if (dep is part)
                    listed = true;
            if (!listed && part !is null)
                result ~= part;
        }
    return result;
}

/// Analyze the binders of the tree `root` (`root` itself, if it is one,
/// and the binders within it): record, in each, which placeholders its
/// scoped parts read (see `ScopeAnalysis`). The one analysis of what binders'
/// parts read: binders analyze their own subtree when they are built (for
/// evaluations of trees which are not optimized), and the executor analyzes
/// the whole tree once it is optimized (see `Executor.optimize`), after the
/// optimizers have rewritten it.
///
/// The free binders of a subtree are those whose placeholders it reads,
/// other than the binders within it (whose placeholders are bound by them);
/// a placeholder of no binder yet (of one being built around it) is free.
void analyzeBinders(ExprBase root) {
    Object[][void*] freeOf;   // memo: the free binders of a subtree
    bool[void*] correlated;   // binders whose placeholders a nested scope reads

    static void add(ref Object[] set, Object binder) {
        foreach (b; set)
            if (b is binder)
                return;
        set ~= binder;
    }

    Object[] visit(ExprBase expr) {
        if (expr is null)
            return null;
        auto key = cast(void*) cast(Object) expr;
        if (auto p = key in freeOf)
            return *p;
        freeOf[key] = null;  // (cycles)

        Object[] free;
        if (auto placeholder = cast(PlaceholderInfo) expr) {
            auto binder = placeholder.binder;
            add(free, binder !is null ? binder : cast(Object) expr);
        }
        auto binder = cast(BinderInfo) expr;
        auto scoped = binder !is null ? binder.scopedParts() : null;
        Object[] scopeFree;
        foreach (part; subexpressions(expr)) {
            bool isScoped;
            foreach (s; scoped)
                if (s is part)
                    isScoped = true;
            foreach (b; visit(part))
                add(isScoped ? scopeFree : free, b);
        }
        if (binder !is null) {
            Object self = cast(Object) expr;
            ScopeAnalysis analysis;
            foreach (b; scopeFree)
                if (b !is self) {
                    analysis.readsEnclosing = true;
                    // (b's placeholders are read from within this scope)
                    correlated[cast(void*) b] = true;
                }
            // (The binders within the scoped parts were visited: their
            // scopes' references to this one's placeholders are recorded.)
            analysis.correlated = (cast(void*) self) in correlated ? true : false;
            binder.setScopeAnalysis(analysis);
            foreach (b; scopeFree)
                if (b !is self)
                    add(free, b);
            free = removeBinder(free, self);
        }
        freeOf[key] = free;
        return free;
    }

    visit(root);
}

private Object[] removeBinder(Object[] set, Object binder) {
    Object[] result;
    foreach (b; set)
        if (b !is binder)
            result ~= b;
    return result;
}

// ============================================================================
// Element owners
// ============================================================================

/// Record, in `ctx`, that the placeholders of the filters and sorts
/// `map`'s collection applies to its rows (before mapping them) range over
/// rows of `map`'s collection: the chain from the collection down through
/// wrappers which keep (a subset of) their source's rows (`Transparent.rows`:
/// filters, sorts, limits, offsets, conditional collections, entity casts and
/// maps yielding their elements). Optimizers may then read the values
/// these placeholders' expressions need from what they fetch for `map`'s
/// elements (see `OptimizeContext.elementOwner`).
///
/// The outermost map's registration wins: the rows of an inner map of the
/// chain are rows of the outer one's collection too.
void registerElementOwner(OptimizeContext ctx, Object map, ExprBase collection) {
    import dunamis.core.transparency : Transparent, wrappersOf;

    Object base;
    foreach (link; wrappersOf(collection, Transparent.rows, base))
        // (A map's item ranges over its own collection's elements)
        if (cast(MapExprInfo) link is null)
            if (auto binder = cast(BinderInfo) link)
                foreach (placeholder; binder.placeholders())
                    ctx.setElementOwner(placeholder, map);
}

// ============================================================================
// Batches
// ============================================================================

/// The elements of a batch's groups (e.g. the collections a map's
/// collection evaluates to, one per element of the map's own batch),
/// flattened into one batch, which a binder evaluates its scoped part for
/// (see `evalBound`).
struct Flattened(E) {
    /// The elements of all the groups, in order.
    E[] elements;
    /// The number of elements of each group.
    size_t[] lengths;

    this(E[][] groups) {
        size_t total;
        lengths = new size_t[groups.length];
        foreach (i, group; groups) {
            lengths[i] = group.length;
            total += group.length;
        }
        elements.reserve(total);
        foreach (group; groups)
            elements ~= group;
    }

    /// Each element's index in its group.
    size_t[] localIndices() const {
        size_t[] result;
        result.reserve(elements.length);
        foreach (len; lengths)
            foreach (j; 0 .. len)
                result ~= j;
        return result;
    }

    /// Each element's group.
    size_t[] groupIndices() const {
        size_t[] result;
        result.reserve(elements.length);
        foreach (g, len; lengths)
            foreach (j; 0 .. len)
                result ~= g;
        return result;
    }

    /// `results` (one per element) split into the groups.
    R[][] regroup(R)(R[] results) const {
        assert(results.length == elements.length);
        auto result = new R[][](lengths.length);
        size_t offset;
        foreach (g, len; lengths) {
            result[g] = results[offset .. offset + len];
            offset += len;
        }
        return result;
    }
}

/// Evaluate the scoped part `part` (an `Expr!R`) of a binder for a batch of
/// `count` elements, in a scope of `ctx` binding `bindings` (the binder's
/// placeholders, ...) before anything is evaluated in it: its results, one
/// per element. Fails if the part produces another number of results (an
/// expression producing one value for a whole batch must be aligned to it
/// with broadcast()); `construct`, `partName` and `elementsName` describe
/// the batch for the error (e.g. "map over User", "body", "elements").
Promise!(R[]) evalBound(R)(ExprBase part, EvalContext ctx, Binding[] bindings, size_t count,
    string construct, string partName, string elementsName)
{
    return evalAs!R(part, ctx.createScope(bindings)).then((R[] results) {
        checkBatch(results.length, count, construct, partName, elementsName);
        return results;
    });
}

/// Fail unless a part of an expression (see `evalBound`) produced
/// `expected` results.
void checkBatch(size_t produced, size_t expected, string construct, string partName, string elementsName) {
    import std.conv : to;
    if (produced != expected)
        throw new Exception("Batch size mismatch in " ~ construct ~ ": its " ~ partName ~ " produced " ~
            produced.to!string ~ " results for " ~ expected.to!string ~ " " ~ elementsName ~
            " (use broadcast() to replicate a single value across a batch)");
}

// ============================================================================
// Tests
// ============================================================================

version (unittest) private struct TestItem { int id; }

// What the scoped parts of binders read
unittest {
    import dunamis.core.expr : Expr, map, some, singleton, use;
    import dunamis.core.filtering : FilterByExpr, filterBy;

    static auto items(Expr!TestItem item) {
        return use((TestItem i) => [i, TestItem(i.id + 1)], item);
    }
    auto roots = singleton([TestItem(1), TestItem(2)]);

    // A predicate reading its own item only: evaluated for all at once
    FilterByExpr!TestItem plain;
    map!((Expr!TestItem outer) {
        plain = cast(FilterByExpr!TestItem) filterBy!((Expr!TestItem i) => use((TestItem x) => x.id > 1, i))(
            items(outer));
        return plain;
    })(roots);
    assert(!plain.scopeAnalysis.readsEnclosing && !plain.scopeAnalysis.correlated && !plain.scopeAnalysis.perElement);

    // Reading an enclosing map's item: for each item (also before the map
    // is built around it, when the item has no binder yet)
    FilterByExpr!TestItem enclosing;
    map!((Expr!TestItem outer) {
        enclosing = cast(FilterByExpr!TestItem) filterBy!((Expr!TestItem i) =>
            use((TestItem x, TestItem o) => x.id > o.id, i, outer))(items(outer));
        assert(enclosing.scopeAnalysis.readsEnclosing);
        return enclosing;
    })(roots);
    assert(enclosing.scopeAnalysis.readsEnclosing && !enclosing.scopeAnalysis.correlated);
    analyzeBinders(enclosing);
    assert(enclosing.scopeAnalysis.perElement);

    // Reading the item from within a nested binder's scope (correlation)
    auto correlated = cast(FilterByExpr!TestItem) filterBy!((Expr!TestItem i) =>
        some!((Expr!TestItem c) => use((TestItem x, TestItem y) => x.id == y.id, c, i))(items(i)))(
        singleton([TestItem(1)]));
    assert(correlated.scopeAnalysis.correlated && !correlated.scopeAnalysis.readsEnclosing);
}

// The scoped parts of binders produce one result per element, or fail
unittest {
    import std.algorithm.searching : canFind;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.expr : Expr, broadcast, map, some, singleton;
    import dunamis.core.filtering : filterBy;

    auto collection = singleton([TestItem(1), TestItem(2), TestItem(3)]);
    // (One value for the whole batch: not aligned with it)
    auto single = singleton(true);

    static string failure(E)(E expr) {
        try
            awaitSync(evalAs!(E.ResultType)(expr, new EvalContext()));
        catch (Exception e)
            return e.msg;
        return null;
    }
    assert(failure(some!((Expr!TestItem i) => single)(collection)).canFind(
        "Batch size mismatch in some over TestItem: its predicate produced 1 results for 3 elements"));
    assert(failure(filterBy!((Expr!TestItem i) => single)(collection)).canFind(
        "Batch size mismatch in filter of TestItem: its predicate produced 1 results for 3 items"));
    assert(failure(map!((Expr!TestItem i) => single)(collection)).canFind(
        "Batch size mismatch in map over TestItem: its body produced 1 results for 3 elements"));
    assert(failure(some!((Expr!TestItem i) => broadcast(single, i))(collection)) is null);
}

// A binder's part is evaluated in a scope of its own binding its elements:
// its evaluations are memoized there, not in the context it is evaluated in
unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.expr : Expr, map, singleton, use;

    Expr!int body_;
    auto query = map!((Expr!TestItem i) => body_ = use((TestItem x) => x.id * 10, i))(
        singleton([TestItem(1), TestItem(2)]));
    auto ctx = new EvalContext();
    assert(awaitSync(evalAs!(int[])(query, ctx)) == [[10, 20]]);
    assert(ctx.getCachedEval!(int[])(query) !is null);
    assert(ctx.getCachedEval!int(body_) is null);
}
