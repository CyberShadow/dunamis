/// Seeing through wrappers: expressions which stand for their input's values
/// or rows (e.g. a plugin's entity cast, a filter of a collection), which
/// optimizers looking for what an expression reads (a column, the rows of a
/// root collection, a map's items) look beneath. Each optimizer sees through
/// the kinds of wrappers it may, as one `Transparent` set says, rather than
/// through its own list of them.
module dunamis.core.transparency;

import dunamis.core.expr.combinators : MapExprInfo, OnlyIfInfo, preservesElements;
import dunamis.core.expr.json : UnwrapNullableInfo;
import dunamis.core.expr.primitives : EntityCastInfo, ValueCastInfo;
import dunamis.core.filtering : FilterByInfo;
import dunamis.core.pagination : LimitInfo, OffsetInfo;
import dunamis.core.sorting : SortByInfo;

/// Kinds of wrappers (flags; see the sets below).
enum Transparent : uint {
    /// Entity casts (`EntityCastInfo`): the same entities (rows), as
    /// another entity type (e.g. a plugin's wrapper of the type).
    entityCasts = 1 << 0,
    /// Unwrapped nullable values or entities (`UnwrapNullableInfo`).
    nullables = 1 << 1,
    /// Value casts (`ValueCastInfo`): the same values, as another type.
    valueCasts = 1 << 2,
    /// Maps yielding each element of their collection itself
    /// (`preservesElements`): the same elements, in the same order.
    elementMaps = 1 << 3,
    /// Filters, sorts, limits, offsets and conditional collections
    /// (`OnlyIfInfo`): some of their source's rows, possibly reordered.
    rowSubsets = 1 << 4,

    /// The same entity, or its unwrapped nullable form.
    entity = entityCasts | nullables,
    /// The same values (of a column, say), unwrapped or cast.
    value = entity | valueCasts,
    /// The same elements of a collection, in the same order.
    elements = entityCasts | elementMaps,
    /// Rows of the same collection: the wrappers between a map and the
    /// root collection (or relationship) whose rows it maps.
    rows = elements | rowSubsets,
}

/// The expression the wrapper `expr` wraps, if it is a wrapper of one of the
/// `kinds`; otherwise (or if it wraps nothing) null.
Object wrapped(Object expr, Transparent kinds) {
    Object inner;
    if (auto c = cast(EntityCastInfo) expr) {
        if (kinds & Transparent.entityCasts) inner = c.inputExpr;
    } else if (auto n = cast(UnwrapNullableInfo) expr) {
        if (kinds & Transparent.nullables) inner = n.inputExpr;
    } else if (auto v = cast(ValueCastInfo) expr) {
        if (kinds & Transparent.valueCasts) inner = v.valueCastInput;
    } else if (auto m = cast(MapExprInfo) expr) {
        if ((kinds & Transparent.elementMaps) && preservesElements(m)) inner = m.collection;
    } else if (kinds & Transparent.rowSubsets) {
        if (auto f = cast(FilterByInfo) expr) inner = f.filterSource;
        else if (auto s = cast(SortByInfo) expr) inner = s.sortSource;
        else if (auto l = cast(LimitInfo) expr) inner = l.limitSource;
        else if (auto o = cast(OffsetInfo) expr) inner = o.offsetSource;
        else if (auto g = cast(OnlyIfInfo) expr) inner = g.onlyIfSource;
    }
    return inner is expr ? null : inner;
}

/// The expression beneath the wrappers of `kinds` around `expr` (`expr`
/// itself if it is not one).
Object seeThrough(Object expr, Transparent kinds) {
    while (expr !is null)
        if (auto inner = wrapped(expr, kinds))
            expr = inner;
        else
            break;
    return expr;
}

/// The wrappers of `kinds` around `expr`, outermost first (beginning with
/// `expr` itself, if it is one); `base` is what they wrap (see seeThrough).
Object[] wrappersOf(Object expr, Transparent kinds, out Object base) {
    Object[] links;
    while (expr !is null) {
        auto inner = wrapped(expr, kinds);
        if (inner is null)
            break;
        links ~= expr;
        expr = inner;
    }
    base = expr;
    return links;
}

unittest {
    import dunamis.core.expr : singleton, EntityCastExpr;

    static struct A { int id; }
    static struct B { int id; }
    auto base = singleton(A(1));
    auto cast1 = new EntityCastExpr!(B, A)(base);
    auto cast2 = new EntityCastExpr!(A, B)(cast1);
    assert(seeThrough(cast2, Transparent.entityCasts) is base);
    assert(seeThrough(cast2, Transparent.valueCasts) is cast2);
    Object found;
    assert(wrappersOf(cast2, Transparent.entity, found) == [cast(Object) cast2, cast1]);
    assert(found is base);
    assert(wrapped(base, Transparent.rows) is null);
}
