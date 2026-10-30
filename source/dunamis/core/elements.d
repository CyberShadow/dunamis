/// The elements of collections, as their placeholders (the items of maps,
/// filter predicates, sort comparisons) see them: which map's elements a
/// placeholder ranges over, and whether an expression refers to a
/// placeholder from within a scope of its own (correlation).
module dunamis.core.elements;

import dunamis.core.expr.base : ExprBase;
import dunamis.core.expr.combinators : CollectionPredicateInfo, MapExprInfo, OnlyIfInfo, preservesElements;
import dunamis.core.expr.primitives : EntityCastInfo;
import dunamis.core.filtering : FilterByInfo;
import dunamis.core.optimize : OptimizeContext;
import dunamis.core.pagination : LimitInfo, OffsetInfo;
import dunamis.core.sorting : SortByInfo;

/// Record, in `ctx`, that the placeholders of the filters and sorts
/// `map`'s collection applies to its rows (before mapping them) range over
/// rows of `map`'s collection: the chain from the collection down through
/// wrappers which keep (a subset of) their source's rows — filters, sorts,
/// limits, offsets, conditional collections, entity casts and maps yielding
/// their elements (`preservesElements`). Optimizers may then read the values
/// these placeholders' expressions need from what they fetch for `map`'s
/// elements (see `OptimizeContext.elementOwner`).
///
/// The outermost map's registration wins: the rows of an inner map of the
/// chain are rows of the outer one's collection too.
void registerElementOwner(OptimizeContext ctx, Object map, ExprBase collection) {
    Object link = collection;
    while (link !is null) {
        Object next;
        if (auto f = cast(FilterByInfo) link) {
            ctx.setElementOwner(f.filterItem, map);
            next = f.filterSource;
        } else if (auto s = cast(SortByInfo) link) {
            ctx.setElementOwner(s.sortLeftItem, map);
            ctx.setElementOwner(s.sortRightItem, map);
            next = s.sortSource;
        } else if (auto l = cast(LimitInfo) link) next = l.limitSource;
        else if (auto o = cast(OffsetInfo) link) next = o.offsetSource;
        else if (auto m = cast(MapExprInfo) link) {
            if (preservesElements(m)) next = m.collection;
        }
        else if (auto c = cast(EntityCastInfo) link) next = c.inputExpr;
        else if (auto g = cast(OnlyIfInfo) link) next = g.onlyIfSource;
        if (next is link)
            break;
        link = next;
    }
}

/// The parts of `expr` which it evaluates in a scope of its own: a map's
/// body, the predicate of a filter, a sort or a collection predicate.
ExprBase[] scopedParts(ExprBase expr) {
    if (auto m = cast(MapExprInfo) expr) return [m.bodyExpr];
    if (auto f = cast(FilterByInfo) expr) return [f.filterPredicate];
    if (auto s = cast(SortByInfo) expr) return [s.sortPredicate];
    if (auto p = cast(CollectionPredicateInfo) expr) return [p.predicate];
    return null;
}

/// The subexpressions of `expr`: its dependencies, and the parts it
/// evaluates in a scope of its own (see `scopedParts`), which are not all
/// among them (a filter's or a sort's predicate is not). Analyses of what a
/// tree reads (its placeholders, data sources, ...) must walk these.
ExprBase[] subexpressions(ExprBase expr) {
    auto result = expr.dependencies().dup;
    foreach (part; scopedParts(expr)) {
        bool listed;
        foreach (dep; result)
            if (dep is part)
                listed = true;
        if (!listed && part !is null)
            result ~= part;
    }
    return result;
}

/// Whether the predicate `predicate` of a filter or sort, over the
/// placeholders `items` (its item, or its two compared items), must be
/// evaluated for one item (or pair) at a time, rather than for a batch of
/// all of them at once: whether it refers to
/// - one of `items` from within a scope of its own: the body of a map, or
///   the predicate of a filter, sort or some/every, whose batch is that
///   construct's elements, not the items' (correlation); or
/// - the placeholder of a construct it is not part of (e.g. an enclosing
///   map's item, or an enclosing filter's), whose batch is not the items'
///   either.
/// For one item at a time, such references see batches of one, which line
/// up with one item (as evaluating for each item always did).
bool evaluatesPerItem(ExprBase predicate, Object[] items...) {
    import dunamis.core.expr.combinators : EveryItemOfExprInfo;
    import dunamis.core.filtering : FilterItemInfo;
    import dunamis.core.sorting : SortItemInfo;

    bool[void*] refs;     // memo: does a subtree refer to one of the items?
    bool[void*] visited;  // the constructs (and other expressions) reached
    Object[] owners;      // the constructs of the placeholders reached
    bool correlated;

    static bool isOneOf(Object o, Object[] list) {
        foreach (x; list)
            if (x is o)
                return true;
        return false;
    }

    bool visit(ExprBase expr) {
        if (expr is null)
            return false;
        Object o = expr;
        if (isOneOf(o, items))
            return true;
        auto key = cast(void*) o;
        if (auto p = key in refs)
            return *p;
        refs[key] = false;  // (cycles)
        visited[key] = true;
        if (auto e = cast(EveryItemOfExprInfo) o) owners ~= e.parentMap;
        else if (auto f = cast(FilterItemInfo) o) owners ~= f.parentFilter;
        else if (auto s = cast(SortItemInfo) o) owners ~= s.parentSort;
        bool result;
        auto scoped = scopedParts(expr);
        foreach (dep; expr.dependencies()) {
            bool isScoped;
            foreach (part; scoped)
                if (part is dep)
                    isScoped = true;
            if (!isScoped && visit(dep))
                result = true;
        }
        foreach (part; scoped)
            if (visit(part)) {
                correlated = true;
                result = true;
            }
        refs[key] = result;
        return result;
    }

    visit(predicate);
    if (correlated)
        return true;
    foreach (owner; owners)
        if (owner !is null && (cast(void*) owner) !in visited)
            return true;
    return false;
}
