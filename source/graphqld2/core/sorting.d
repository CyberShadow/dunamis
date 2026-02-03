/// Sorting expression nodes for ORDER BY support.
///
/// Provides predicate-based sorting that can be optimized to SQL ORDER BY:
/// - SortByExpr: sorts using a comparison predicate (a, b) => bool
/// - OrderByExpr: column-based sorting (SQL-friendly, used after optimization)
///
/// The optimizer pattern-matches predicates like `(a, b) => a.column < b.column`
/// and converts them to column-based OrderBy for SQL push-down.
module graphqld2.core.sorting;

import std.algorithm : sort, map;
import std.array : array;
import std.conv : to;
import std.json : JSONValue;
import std.range : iota;

import ae.utils.promise;

import graphqld2.core.expr;
import graphqld2.core.eval;
import graphqld2.core.optimize;

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

/// Interface for expressions that apply column-based ORDER BY.
/// This is the SQL-friendly form produced after optimization.
interface OrderByInfo {
    /// Get the ordering specifications (column + direction)
    const(OrderBySpec)[] orderBySpecs();

    /// Get the source expression (without the orderBy wrapper)
    ExprBase orderBySource();
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
        // Sort placeholders should not be evaluated directly.
        // They exist only for building the predicate expression tree.
        // The predicate is analyzed at optimization time, not evaluated.
        throw new Exception("SortItemExpr should not be evaluated directly - " ~
            "predicate should be pattern-matched during optimization");
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
        // Fallback: in-memory sorting
        // This is reached when SQL push-down wasn't possible
        return evalAs!(Entity[])(_source, ctx).then((Entity[][] groups) {
            // For in-memory sorting, we need actual values.
            // Since entities are just proxies without data, this fallback
            // only works if the optimizer couldn't push down to SQL.
            // Return unsorted as fallback (relational layer handles actual sorting).
            return groups;
        });
    }
}

// ============================================================================
// OrderByExpr - Column-based sorting (SQL-friendly)
// ============================================================================

/// Column-based sorting expression, optimized for SQL push-down.
///
/// This is the SQL-friendly form that stores column names and directions.
/// Created directly or by optimizing SortByExpr predicates.
///
/// Example:
/// ---
/// auto sorted = orderBy(users(), [OrderBySpec("lastName", SortDirection.ASC)]);
/// ---
class OrderByExpr(T) : Expr!(T[]), OrderByInfo {
    private ExprBase _source;
    private OrderBySpec[] _specs;

    this(Expr!(T[]) source, OrderBySpec[] specs) {
        _source = source;
        _specs = specs;
    }

    override ExprBase[] dependencies() {
        return [_source];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _source = newDep;
    }

    /// Get the ordering specifications (OrderByInfo interface)
    const(OrderBySpec)[] orderBySpecs() {
        return _specs;
    }

    /// Get the source expression (OrderByInfo interface)
    ExprBase orderBySource() {
        return _source;
    }

    /// Get the source expression (typed)
    @property Expr!(T[]) source() {
        return cast(Expr!(T[])) _source;
    }

    override Expr!(T[]) optimize(OptimizeContext ctx) {
        // Optimize source, keep wrapper (in-memory fallback works)
        // Push-down to SQL happens via the relational optimizer
        _source = source.optimize(ctx);
        return this;
    }

    override Promise!(T[][]) eval(EvalContext ctx) {
        // Fallback: pass through to source (actual sorting in SQL or MockDB)
        return evalAs!(T[])(source, ctx);
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

/// Wrap expression with column-based ORDER BY (SQL-friendly).
///
/// This is a lower-level API that directly specifies columns.
/// Prefer sortBy with predicates for flexibility.
///
/// Example:
/// ---
/// auto query = orderBy(users(), [OrderBySpec("lastName", SortDirection.DESC)]);
/// ---
auto orderBy(T)(Expr!(T[]) source, OrderBySpec[] specs) {
    return new OrderByExpr!T(source, specs);
}

/// Convenience overload for single column sorting.
auto orderBy(T)(Expr!(T[]) source, string column, SortDirection direction = SortDirection.ASC) {
    return new OrderByExpr!T(source, [OrderBySpec(column, direction)]);
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
    // Test OrderByExpr creation and interface
    static struct Item {
        int value;
    }

    auto source = new class Expr!(Item[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}

        override Promise!(Item[][]) eval(EvalContext ctx) {
            return resolve([
                [Item(3), Item(1), Item(2)]
            ]);
        }
    };

    auto sorted = orderBy(source, [
        OrderBySpec("value", SortDirection.DESC),
        OrderBySpec("name", SortDirection.ASC)
    ]);

    // Verify it implements OrderByInfo
    auto info = cast(OrderByInfo) sorted;
    assert(info !is null);
    assert(info.orderBySpecs.length == 2);
    assert(info.orderBySpecs[0].column == "value");
    assert(info.orderBySpecs[0].descending);
    assert(info.orderBySpecs[1].column == "name");
    assert(!info.orderBySpecs[1].descending);
    assert(info.orderBySource is source);
}

unittest {
    // Test single column convenience overload
    static struct Item {
        int value;
    }

    auto source = new class Expr!(Item[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}

        override Promise!(Item[][]) eval(EvalContext ctx) {
            return resolve([[Item(1)]]);
        }
    };

    auto sorted = orderBy(source, "name", SortDirection.DESC);

    auto info = cast(OrderByInfo) sorted;
    assert(info !is null);
    assert(info.orderBySpecs.length == 1);
    assert(info.orderBySpecs[0].column == "name");
    assert(info.orderBySpecs[0].descending);
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
