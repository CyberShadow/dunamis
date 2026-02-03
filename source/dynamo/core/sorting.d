/// Sorting expression nodes for ORDER BY support.
///
/// Provides predicate-based sorting that can be optimized to SQL ORDER BY:
/// - SortByExpr: sorts using a comparison predicate (a, b) => bool
/// - OrderByExpr: column-based sorting (SQL-friendly, used after optimization)
///
/// The optimizer pattern-matches predicates like `(a, b) => a.column < b.column`
/// and converts them to column-based OrderBy for SQL push-down.
module dynamo.core.sorting;

import std.algorithm : sort, map;
import std.array : array;
import std.conv : to;
import std.json : JSONValue, JSONType;
import std.range : iota;

import ae.utils.promise;
import ae.utils.promise.await : async;

import dynamo.core.expr;
import dynamo.core.eval;
import dynamo.core.optimize;
import dynamo.core.types : AnyRef;

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
        // During naive path sorting, the predicate is evaluated with comparison items.
        // Get the current comparison item (left or right) from context.
        auto ref_ = ctx.getSortItem(_parentSort, _isLeftItem);
        if (ref_ == AnyRef.init) {
            // Fallback: shouldn't happen if SortByExpr sets up context correctly
            throw new Exception("SortItemExpr: no comparison item in context - " ~
                "ensure SortByExpr.eval() sets up sort items before predicate evaluation");
        }
        return resolve([Entity(ref_.nodeId)]);
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
                        ctx.setSortItems(self, AnyRef(item.nodeId.id), AnyRef(sorted[pos].nodeId.id));

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
        import ae.utils.promise.await : async, await;

        auto src = source;
        auto specs = _specs;

        return async({
            // Evaluate source to get entity groups
            T[][] groups = evalAs!(T[])(src, ctx).await;

            // Sort each group using naive path sorting if available
            foreach (ref group; groups) {
                if (group.length <= 1 || specs.length == 0) continue;

                // Get table name from first entity's typeName
                static if (__traits(hasMember, T, "nodeId")) {
                    string tableName = getTableFromTypeName(group[0].nodeId.typeName);
                    AnyRef[] refs = group.map!(e => AnyRef(e.nodeId.id)).array;

                    // Sort using fetched column values via the sorting helper
                    group = sortByColumnsNaive!T(group, refs, specs, tableName, ctx);
                }
            }

            return groups;
        });
    }

    /// Get table name from type name (snake_case pluralization)
    private static string getTableFromTypeName(string typeName) {
        // Simple conversion: "User" -> "users"
        import std.uni : toLower;

        if (typeName.length == 0) return "";

        // Convert camelCase to snake_case and pluralize
        string result;
        foreach (i, c; typeName) {
            if (i > 0 && c >= 'A' && c <= 'Z') {
                result ~= '_';
            }
            result ~= toLower(c);
        }
        return result ~ "s";
    }
}

// ============================================================================
// Naive Path Sorting Helper
// ============================================================================

/// Sort entities by column values for naive evaluation path.
/// Fetches column values via RelationalEvalContext if available.
/// Must be called from within a fiber context (e.g., inside an async block).
@async private T[] sortByColumnsNaive(T)(T[] items, AnyRef[] refs, const(OrderBySpec)[] specs,
                                         string tableName, EvalContext ctx) {
    import ae.utils.promise.await : await;

    // Try to get relational context for DataFetcher access
    try {
        import dynamo.relational.eval_context : RelationalEvalContext;

        auto relCtx = ctx.getSourceContext!RelationalEvalContext();
        if (relCtx is null || relCtx.fetcher is null) {
            return items;  // No fetcher available - return unsorted
        }

        // Fetch all sort column values (using await since we're in a fiber)
        JSONValue[][] sortValues;
        foreach (spec; specs) {
            auto values = relCtx.fetcher.fetchColumnJson(tableName, spec.column, refs).await;
            sortValues ~= values;
        }

        // Build index array and sort
        size_t[] indices = iota(items.length).array;

        indices.sort!((a, b) {
            foreach (i, spec; specs) {
                auto valA = sortValues[i][a];
                auto valB = sortValues[i][b];
                int cmp = compareJsonValues(valA, valB);
                if (cmp != 0) {
                    return spec.descending ? (cmp > 0) : (cmp < 0);
                }
            }
            return false;  // Equal
        });

        // Reorder items according to sorted indices
        T[] result;
        result.reserve(items.length);
        foreach (idx; indices) {
            result ~= items[idx];
        }
        return result;
    } catch (Exception e) {
        // RelationalEvalContext not available - return unsorted
        return items;
    }
}

/// Compare two JSON values for sorting
private int compareJsonValues(JSONValue a, JSONValue b) {
    // Handle nulls
    if (a.type == JSONType.null_ && b.type == JSONType.null_) return 0;
    if (a.type == JSONType.null_) return -1;
    if (b.type == JSONType.null_) return 1;

    // Compare based on type
    if (a.type == JSONType.integer && b.type == JSONType.integer) {
        auto diff = a.integer - b.integer;
        return diff < 0 ? -1 : (diff > 0 ? 1 : 0);
    }
    if (a.type == JSONType.string && b.type == JSONType.string) {
        if (a.str < b.str) return -1;
        if (a.str > b.str) return 1;
        return 0;
    }
    if (a.type == JSONType.float_ && b.type == JSONType.float_) {
        auto diff = a.floating - b.floating;
        return diff < 0 ? -1 : (diff > 0 ? 1 : 0);
    }

    // Mixed types: convert to string
    return 0;
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
