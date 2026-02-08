module dunamis.core.expr.combinators;

import std.array;
import std.meta;
import std.range : iota;
import std.traits;
import std.typecons : Tuple;
static import std.algorithm;

import ae.utils.promise;

import dunamis.core.types;
import dunamis.core.eval;
import dunamis.core.optimize;
import dunamis.core.expr.base;

// ============================================================================
// Use Combinator (computed fields)
// ============================================================================

/// Computed field expression using the `use` combinator.
/// Applies a pure function per-element to combine child expression results.
class UseExpr(Fn, Exprs...) : Expr!(ReturnType!Fn)
    if (Exprs.length >= 1 && allSatisfy!(isExpr, Exprs))
{
    alias R = ReturnType!Fn;
    alias InputTypes = staticMap!(ExprResultType, Exprs);
    alias EvaluatedArrays = Tuple!(staticMap!(toArray, InputTypes));

    // Store as ExprBase for type-erased traversal
    private ExprBase[Exprs.length] _inputs;
    private Fn _fn;

    this(Exprs inputs, Fn fn) {
        static foreach (i; 0 .. Exprs.length) {
            _inputs[i] = inputs[i];  // Implicit upcast to ExprBase
        }
        _fn = fn;
    }

    override ExprBase[] dependencies() {
        return _inputs[];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index < _inputs.length)
            _inputs[index] = newDep;
    }

    override Expr!R optimize(OptimizeContext ctx) {
        // Optimize all children
        static foreach (i; 0 .. Exprs.length) {
            _inputs[i] = (cast(Expr!(InputTypes[i])) _inputs[i]).optimize(ctx);
        }
        return this;
    }

    override Promise!(R[]) eval(EvalContext ctx) {
        auto fn = _fn;

        // Build tuple of promises for all inputs
        alias PromiseTypes = staticMap!(toPromiseArray, InputTypes);
        Tuple!PromiseTypes promises;
        static foreach (i; 0 .. Exprs.length) {
            promises[i] = evalAs!(InputTypes[i])(_inputs[i], ctx);
        }

        // Wait for all, then combine results
        return all(promises.expand).then((EvaluatedArrays results) {
            R[] result = new R[results[0].length];
            foreach (idx; 0 .. results[0].length) {
                // Build argument tuple and call fn
                Tuple!InputTypes args;
                static foreach (i; 0 .. Exprs.length) {
                    args[i] = results[i][idx];
                }
                result[idx] = fn(args.expand);
            }
            return result;
        });
    }
}

/// Helper to convert T to Promise!(T[])
private template toPromiseArray(T) {
    alias toPromiseArray = Promise!(T[]);
}

/// Generate AliasSeq!(0, 1, 2, ..., N-1) at compile time
private template staticIota(size_t N) {
    import std.meta : AliasSeq;
    static if (N == 0)
        alias staticIota = AliasSeq!();
    else
        alias staticIota = AliasSeq!(staticIota!(N - 1), N - 1);
}

/// Create a use expression from a callable and expressions
auto use(Fn, Exprs...)(Fn fn, Exprs exprs)
    if (Exprs.length >= 1 && allSatisfy!(isExpr, Exprs))
{
    return new UseExpr!(Fn, Exprs)(exprs, fn);
}

// ============================================================================
// EffectExpr: Deferred Side Effects
// ============================================================================

/// Expression that executes a side-effecting callable during evaluation.
/// Used for mutations and other operations that should be deferred.
/// The callable is called once per evaluation, regardless of batch size.
class EffectExpr(T, Fn) : Expr!T {
    private Fn _effect;
    private ExprBase _lengthSource;

    this(Fn effect, ExprBase lengthSource) {
        _effect = effect;
        _lengthSource = lengthSource;
    }

    override ExprBase[] dependencies() {
        return _lengthSource !is null ? [_lengthSource] : [];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0 && _lengthSource !is null) {
            _lengthSource = newDep;
        }
    }

    override Expr!T optimize(OptimizeContext ctx) {
        return this;  // Effects are not optimizable
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        // Execute the effect
        auto result = _effect();

        // Determine result count from length source or default to 1
        if (_lengthSource !is null) {
            return _lengthSource.evalResultLength(ctx).then((size_t count) {
                T[] results = new T[count];
                results[] = result;
                return results;
            });
        } else {
            return resolve([result]);
        }
    }

}

/// Create an effect expression - a deferred side-effecting operation.
/// The callable is executed during eval(), not during expression construction.
///
/// Example:
/// ---
/// // In a mutation:
/// static Expr!User createUser(Expr!Mutation parent, CreateUserInput input) {
///     return effect(() => db.insert!User(input), parent);
/// }
/// ---
auto effect(Fn)(Fn fn, ExprBase lengthSource = null)
    if (is(ReturnType!Fn))
{
    alias T = ReturnType!Fn;
    return new EffectExpr!(T, Fn)(fn, lengthSource);
}

// ============================================================================
// MapExpr: Explicit Iteration Boundary
// ============================================================================

/// Interface to identify any EveryItemOfExpr regardless of Entity type.
/// Used by optimizers to find the MapExpr boundary.
interface EveryItemOfExprInfo {
    /// Get the parent MapExpr (as Object)
    @property Object parentMap();
}

/// Check if a type is an entity (has @PrimaryKey field).
template isEntityType(T) {
    import dunamis.core.types : hasPrimaryKey;
    enum isEntityType = hasPrimaryKey!T;
}

/// Placeholder representing "current item" within a map iteration.
/// When MapExpr evaluates its body, it passes the flattened collection refs.
/// EveryItemOfExpr just returns those refs unchanged - it's a pass-through
/// that represents "the items being iterated over".
///
/// Typed with the Entity being iterated. Returns Entity with PK populated.
class EveryItemOfExpr(T) : Expr!T, EveryItemOfExprInfo {
    /// Back-reference to owning MapExpr (set at construction)
    Object _parentMap;  // Use Object to avoid template instantiation issues

    @property Object parentMap() { return _parentMap; }

    override ExprBase[] dependencies() {
        return [];  // Leaf node (back-reference to parent is not a dependency)
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies to replace
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        // Retrieve values from generic storage
        auto vals = ctx.getValues!T(_parentMap);
        if (vals.length > 0) {
            return resolve(vals);
        }
        return resolve(cast(T[])[]);
    }

}

/// Interface to query collection type from MapExpr without knowing the template params.
/// Used by data-source-specific optimizers to configure query nodes.
interface MapExprInfo {
    /// Get the collection expression (type-erased).
    /// Optimizer can cast this to data-source-specific interfaces
    /// (e.g., HasManyInfo, RootExprInfo) to extract metadata.
    Object collection();
}

/// Iteration over a collection. This IS the layer boundary.
/// MapExpr is data-source agnostic — it only knows about map semantics.
///
/// Entity is the type of items in the collection (e.g., User, Post).
/// Body is the expression type produced by the mapping function.
class MapExpr(Entity, Body) : Expr!(Body.ResultType[]), MapExprInfo
    if (is(Body : Expr!U, U))
{
    alias R = Body.ResultType;

    private ExprBase _collection;        // what we're iterating over (type-erased)
    EveryItemOfExpr!Entity _item;        // mutable placeholder for "current item"
    private ExprBase _body;              // expression built using _item (type-erased)

    this(Expr!(Entity[]) collection, EveryItemOfExpr!Entity item, Body body_) {
        _collection = collection;
        _item = item;
        _body = body_;  // Implicit upcast to ExprBase
    }

    override ExprBase[] dependencies() {
        return [_collection, _body];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _collection = newDep;
        else if (index == 1)
            _body = newDep;
    }

    override Expr!(R[]) optimize(OptimizeContext ctx) {
        // Optimize body FIRST - this creates QueryNodes for column access
        // Then optimize collection - it can find and use the same QueryNode
        _body = (cast(Expr!R) _body).optimize(ctx);
        _collection = (cast(Expr!(Entity[])) _collection).optimize(ctx);
        return this;
    }

    /// Batched eval: evaluates all items at once.
    /// Works correctly for both naive and optimized paths.
    override Promise!(R[][]) eval(EvalContext ctx) {
        // Capture for use in closures
        auto bodyExpr = _body;
        auto self = this;  // Key for refs map

        // 1. Evaluate collection for each parent ref
        return evalAs!(Entity[])(_collection, ctx).then((Entity[][] collectionResults) {
            // 2. Flatten for batch evaluation
            Entity[] flatEntities;
            size_t[] lengths;
            foreach (group; collectionResults) {
                lengths ~= group.length;
                foreach (e; group) {
                    flatEntities ~= e;
                }
            }

            if (flatEntities.length == 0) {
                // No items to process - return empty array for each parent
                return resolve(std.algorithm.map!(_ => cast(R[])[])(iota(collectionResults.length)).array);
            }

            // 3. Store values for EveryItemOfExpr to retrieve
            ctx.setValues!Entity(self, flatEntities);

            // 4. Evaluate body with ALL refs at once
            return evalAs!R(bodyExpr, ctx).then((R[] flatResults) {
                // 5. Regroup to match input structure
                R[][] result;
                size_t offset = 0;
                foreach (len; lengths) {
                    result ~= flatResults[offset .. offset + len];
                    offset += len;
                }
                return result;
            });
        });
    }

    // MapExprInfo implementation
    Object collection() { return _collection; }
}

/// Extract the Entity type from an Expr!(Entity[]) type
template CollectionEntityType(Coll) {
    static if (is(Coll : Expr!(E[]), E)) {
        alias CollectionEntityType = E;
    } else {
        static assert(false, "Expected Expr!(Entity[]), got " ~ Coll.stringof);
    }
}

/// Factory function wires up the MapExpr <-> EveryItemOfExpr linkage
auto map(alias fn, Coll)(Coll collection)
    if (is(Coll : Expr!(E[]), E))
{
    alias Entity = CollectionEntityType!Coll;

    // 1. Create the placeholder (typed with Entity)
    auto item = new EveryItemOfExpr!Entity();

    // 2. Build body expression using placeholder as input
    auto body_ = fn(item);

    // 3. Create MapExpr with both (Entity type flows through)
    auto mapExpr = new MapExpr!(Entity, typeof(body_))(collection, item, body_);

    // 4. Link placeholder back to MapExpr
    item._parentMap = mapExpr;

    return mapExpr;
}

// ============================================================================
// SomeExpr: Collection Predicate Expression
// ============================================================================

/// Interface for some/every expressions (for optimizer pattern matching).
/// Used by SqlOptimizer to detect and push down collection predicates.
interface CollectionPredicateInfo {
    /// Get the collection being tested (type-erased Expr!(Entity[]))
    ExprBase collection();

    /// Get the predicate expression (Expr!bool)
    ExprBase predicate();

    /// Get the item placeholder (EveryItemOfExpr)
    Object itemPlaceholder();
}

/// Expression: returns true if ANY item in collection satisfies predicate.
/// Similar to JavaScript's Array.some() or SQL EXISTS.
///
/// Example:
///   some!((Expr!Post p) => p.isPublished)(user.posts)
///   // Returns true if user has at least one published post
class SomeExpr(Entity, Body) : Expr!bool, CollectionPredicateInfo
    if (is(Body : Expr!bool))
{
    private ExprBase _collection;           // Expr!(Entity[])
    private EveryItemOfExpr!Entity _item;   // Placeholder
    private ExprBase _predicate;            // Expr!bool

    this(Expr!(Entity[]) collection, EveryItemOfExpr!Entity item, Body predicate) {
        _collection = collection;
        _item = item;
        _predicate = predicate;
    }

    override ExprBase[] dependencies() {
        return [_collection, _predicate];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _collection = newDep;
        else if (index == 1)
            _predicate = newDep;
    }

    override Expr!bool optimize(OptimizeContext ctx) {
        // Optimize collection (creates QueryNodes for nested hasMany)
        _collection = optimizeExpr(_collection, ctx);
        // Don't optimize predicate - it will be analyzed for SQL pushdown
        return this;
    }

    override Promise!(bool[]) eval(EvalContext ctx) {
        debug(filter) {
            import std.stdio : writefln, stdout;
            writefln("  >>SomeExpr.eval CALLED<<");
            stdout.flush();
        }

        auto predicate = cast(Expr!bool) _predicate;
        auto self = this;  // Key for refs map (EveryItemOfExpr._parentMap points to this)

        // Evaluate collection for each parent ref
        return evalAs!(Entity[])(_collection, ctx).then((Entity[][] collectionResults) {
            // Flatten all items for batch evaluation
            size_t[] groupLengths;
            size_t totalItems = 0;
            foreach (group; collectionResults) {
                groupLengths ~= group.length;
                totalItems += group.length;
            }

            // Handle empty case
            if (totalItems == 0) {
                bool[] results;
                results.length = collectionResults.length;
                results[] = false;  // some() on empty = false
                return resolve(results);
            }

            // Store all items in unified value storage
            Entity[] flatVals;
            flatVals.reserve(totalItems);
            foreach (group; collectionResults) {
                foreach (v; group) {
                    flatVals ~= v;
                }
            }
            debug(filter) {
                import std.stdio : writefln;
                writefln("  SomeExpr.eval: %d groups, %d total items", collectionResults.length, flatVals.length);
            }
            ctx.setValues!Entity(self, flatVals);

            // Evaluate predicate for all items in batch
            return evalAs!bool(predicate, ctx).then((bool[] predicateResults) {
                debug(filter) {
                    import std.stdio : writefln;
                    writefln("    predicate results=%s", predicateResults);
                }

                // Reduce flat results back to per-group booleans
                bool[] results;
                results.length = groupLengths.length;

                size_t offset = 0;
                foreach (i, len; groupLengths) {
                    bool anyTrue = false;
                    foreach (j; 0 .. len) {
                        if (predicateResults[offset + j]) {
                            anyTrue = true;
                            break;
                        }
                    }
                    results[i] = anyTrue;
                    offset += len;
                }

                return results;
            });
        });
    }

    // CollectionPredicateInfo implementation
    ExprBase collection() { return _collection; }
    ExprBase predicate() { return _predicate; }
    Object itemPlaceholder() { return _item; }
}

/// Test if ANY item in collection satisfies the predicate.
///
/// Example:
/// ---
/// auto hasPublished = some!((Expr!Post p) => p.isPublished)(user.posts);
/// ---
auto some(alias pred, Coll)(Coll collection)
    if (is(Coll : Expr!(E[]), E))
{
    alias Entity = CollectionEntityType!Coll;

    // Create placeholder (shares type with collection items)
    auto item = new EveryItemOfExpr!Entity();

    // Build predicate using placeholder
    auto predicate = pred(item);
    static assert(is(typeof(predicate) : Expr!bool),
        "some() predicate must return Expr!bool, got " ~ typeof(predicate).stringof);

    // Create SomeExpr and link
    auto expr = new SomeExpr!(Entity, typeof(predicate))(collection, item, predicate);
    item._parentMap = expr;  // Reuse _parentMap for predicate item lookup

    return expr;
}

/// Test if ALL items in collection satisfy the predicate.
/// Implemented as not(some(not(pred))) - De Morgan's law.
///
/// Example:
/// ---
/// auto allPublished = every!((Expr!Post p) => p.isPublished)(user.posts);
/// ---
auto every(alias pred, Coll)(Coll collection)
    if (is(Coll : Expr!(E[]), E))
{
    // every(pred) = not(some(not(pred)))
    return some!((item) => pred(item).not())(collection).not();
}


// ============================================================================
// Tests
// ============================================================================

import ae.utils.promise.await : awaitSync;
import dunamis.core.expr.primitives : FieldAccessExpr;

/// Dummy entity type for tests (with @PrimaryKey field)
private struct TestEntity {
    import dunamis.core.types : PrimaryKeyAttr;

    @PrimaryKeyAttr string id;      // Primary key
    string typeName;                // Extra field for test assertions
}

/// Helper: expression that returns a fixed array of entities.
/// Used as a collection source in tests.
private class MockCollectionExpr(Entity) : Expr!(Entity[]) {
    Entity[] _entities;
    this(Entity[] entities) { _entities = entities; }

    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t index, ExprBase newDep) {}

    override Promise!(Entity[][]) eval(EvalContext ctx) {
        return resolve([_entities]);
    }
}

unittest {
    // Test map with use combinator - extracts primary key
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1", "Test"), TestEntity("2", "Test")]);

    auto query = map!(
        (Expr!TestEntity item) => use((TestEntity e) => e.id, item)
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["1", "2"]);
}

unittest {
    // Test map with jsonObject - builds structured output
    import dunamis.core.expr.json : jsonObject;

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1", "User"), TestEntity("2", "User")]);

    auto query = map!(
        (Expr!TestEntity item) => jsonObject(
            "id", use((TestEntity e) => e.id, item),
            "type", use((TestEntity e) => e.typeName, item)
        )
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0].length == 2);
    assert(result[0][0]["id"].str == "1");
    assert(result[0][0]["type"].str == "User");
    assert(result[0][1]["id"].str == "2");
}

unittest {
    // Test string concatenation with literals inside map
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1", "Test"), TestEntity("2", "Test")]);

    auto query = map!(
        (Expr!TestEntity item) => use((TestEntity e) => e.typeName, item) ~ ":" ~ use((TestEntity e) => e.id, item)
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["Test:1", "Test:2"]);
}

unittest {
    import std.conv : to;

    // Test arithmetic operators with literals inside map
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1"), TestEntity("2"), TestEntity("3")]);

    auto query = map!(
        (Expr!TestEntity item) {
            // Use id parsed to int for arithmetic test
            auto id = use((TestEntity e) => e.id.to!long, item);
            return id * 10 + 5;
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [15, 25, 35]);  // (1*10+5), (2*10+5), (3*10+5)
}

unittest {
    import std.conv : to;

    // Test comparison operators inside map
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("10"), TestEntity("15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            return val.gt(7);  // 5 > 7 = false, 10 > 7 = true, 15 > 7 = true
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [false, true, true]);
}

unittest {
    import std.conv : to;

    // Test boolean AND operator
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("10"), TestEntity("15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            return val.gt(5).and(val.lt(15));  // 5>5 && 5<15 = false, 10>5 && 10<15 = true, 15>5 && 15<15 = false
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [false, true, false]);
}

unittest {
    import std.conv : to;

    // Test boolean OR operator
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("10"), TestEntity("15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            return val.lt(8).or(val.gt(12));  // 5<8 || 5>12 = true, 10<8 || 10>12 = false, 15<8 || 15>12 = true
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [true, false, true]);
}

unittest {
    import std.conv : to;

    // Test boolean NOT operator
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("10"), TestEntity("15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            return val.gt(8).not();  // !(5>8) = true, !(10>8) = false, !(15>8) = false
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [true, false, false]);
}

unittest {
    import std.conv : to;

    // Test ternary expression
    import dunamis.core.expr.operators : ternary;

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("15"), TestEntity("25")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            return ternary(val.ge(18), "adult", "minor");  // 5>=18 ? adult : minor, etc.
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["minor", "minor", "adult"]);
}

unittest {
    import std.conv : to;

    // Test nested ternary expression (chained conditions)
    import dunamis.core.expr.operators : ternary;

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("15"), TestEntity("25")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            // age < 13 -> "child", age < 20 -> "teen", else "adult"
            return ternary(val.lt(13), "child", ternary(val.lt(20), "teen", "adult"));
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["child", "teen", "adult"]);
}

unittest {
    import std.conv : to;

    // Test combined boolean operators: (a AND b) OR c
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("10"), TestEntity("20")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            // (val > 5 AND val < 15) OR val > 18
            // 5: (false AND true) OR false = false
            // 10: (true AND true) OR false = true
            // 20: (true AND false) OR true = true
            return val.gt(5).and(val.lt(15)).or(val.gt(18));
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [false, true, true]);
}

// Test POD struct in map context
unittest {
    import std.conv : to;

    // POD struct without @PrimaryKey
    static struct Stats {
        int count;
        int total;
    }

    // Custom Expr returning POD struct array
    static class ConstStatsExpr : Expr!(Stats[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t index, ExprBase newDep) {}
        override Expr!(Stats[]) optimize(OptimizeContext ctx) { return this; }

        override Promise!(Stats[][]) eval(EvalContext ctx) {
            // Return one group with two Stats items
            return resolve([[Stats(10, 100), Stats(20, 200)]]);
        }
    }

    // Map over POD structs and extract a field
    auto statsExpr = new ConstStatsExpr();
    auto query = map!(
        (Expr!Stats s) => new FieldAccessExpr!(Stats, "count")(s)
    )(statsExpr);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1, "Expected 1 group");
    assert(result[0].length == 2, "Expected 2 items in group");
    assert(result[0] == [10, 20], "Expected counts [10, 20], got " ~ result[0].to!string);
}
