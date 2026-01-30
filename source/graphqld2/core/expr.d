module graphqld2.core.expr;

import std.array;
import std.json;
import std.meta;
import std.range : iota;
import std.traits;
import std.typecons : Nullable, Tuple, tuple;
static import std.algorithm;

import ae.utils.promise;
import ae.net.asockets : socketManager;

import graphqld2.core.types;
import graphqld2.core.eval;
import graphqld2.core.optimize;

// ============================================================================
// Type-Erased Base Class
// ============================================================================

/// Type-erased base class for all expressions.
/// Enables external tree traversal and optimization as a separate step.
abstract class ExprBase {
    import graphqld2.core.optimize : ExprOptimizer;

    /// Get all child expressions (for tree traversal).
    /// Returns empty array for leaf expressions.
    abstract ExprBase[] dependencies();

    /// Replace a child expression at the given index.
    /// Used by external optimizers to transform the tree.
    abstract void replaceDependency(size_t index, ExprBase newDep);

    /// Get the result type of this expression.
    abstract TypeInfo resultType();

    /// Evaluate and return result length (type-erased).
    /// Used by ConstExpr to derive batch size from another expression.
    abstract Promise!size_t evalResultLength(EvalContext ctx);

    /// Get optimizers this expression needs.
    /// Override in expressions tied to specific data sources.
    /// Executor walks the tree and collects these.
    ExprOptimizer[] requestedOptimizers() {
        return [];
    }
}

/// Helper to evaluate an ExprBase with a known type.
/// Returns a Promise that resolves to T[].
/// Asserts if the runtime type doesn't match.
Promise!(T[]) evalAs(T)(ExprBase expr, EvalContext ctx) {
    auto typed = cast(Expr!T) expr;
    assert(typed !is null, "Type mismatch in evalAs: expected " ~ T.stringof);
    return typed.eval(ctx);
}

// ============================================================================
// Typed Expression Class
// ============================================================================

/// Typed expression base - adds typed evaluation to ExprBase.
/// User-facing code works with Expr!T for compile-time type safety.
///
/// Expressions are written with per-element semantics — as if operating on
/// a single entity. Batching happens automatically during evaluation.
///
/// Batch semantics: eval() returns Promise!(T[]) — one result per input ref.
abstract class Expr(T) : ExprBase {
    alias ResultType = T;

    override TypeInfo resultType() {
        return typeid(T);
    }

    /// Optimize this expression and its children.
    /// Returns: optimized expression (may be this or a replacement).
    Expr!T optimize(OptimizeContext ctx) {
        return this;  // Default: no optimization
    }

    /// Evaluate for the current batch of entity references.
    /// Returns Promise!(T[]) with one result per ref in ctx.currentRefs.
    /// The batch refs are set by MapExpr before evaluating its body.
    abstract Promise!(T[]) eval(EvalContext ctx);

    /// Evaluate and return result length.
    override Promise!size_t evalResultLength(EvalContext ctx) {
        return eval(ctx).then((T[] results) => results.length);
    }

    // =========================================================================
    // Operator Overloading
    // =========================================================================

    /// Check if binary operator `op` is valid between types L and R
    private template isValidBinaryOp(L, string op, R) {
        enum isValidBinaryOp = is(typeof(mixin("L.init " ~ op ~ " R.init")));
    }

    /// Binary operators: expr op expr (potentially different types)
    auto opBinary(string op, R)(Expr!R rhs) if (isValidBinaryOp!(T, op, R)) {
        return new BinaryOpExpr!(T, op, R)(this, rhs);
    }

    /// Binary operators: expr op literal
    /// The literal is wrapped in a ConstExpr that derives its batch size from this expression.
    auto opBinary(string op, R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, op, R)) {
        return new BinaryOpExpr!(T, op, R)(this, constant(rhs, this));
    }

    /// Binary operators: literal op expr
    /// The literal is wrapped in a ConstExpr that derives its batch size from this expression.
    auto opBinaryRight(string op, L)(L lhs) if (!is(L : Expr!U, U) && isValidBinaryOp!(L, op, T)) {
        return new BinaryOpExpr!(L, op, T)(constant(lhs, this), this);
    }

    /// Comparison methods that return Expr!bool
    /// Note: Can't override opEquals/opCmp as they conflict with Object methods
    auto eq(R)(Expr!R rhs) if (isValidBinaryOp!(T, "==", R)) {
        return new BinaryOpExpr!(T, "==", R)(this, rhs);
    }
    auto ne(R)(Expr!R rhs) if (isValidBinaryOp!(T, "!=", R)) {
        return new BinaryOpExpr!(T, "!=", R)(this, rhs);
    }
    auto eq(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, "==", R)) {
        return new BinaryOpExpr!(T, "==", R)(this, constant(rhs, this));
    }
    auto ne(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, "!=", R)) {
        return new BinaryOpExpr!(T, "!=", R)(this, constant(rhs, this));
    }

    auto lt(R)(Expr!R rhs) if (isValidBinaryOp!(T, "<", R)) {
        return new BinaryOpExpr!(T, "<", R)(this, rhs);
    }
    auto gt(R)(Expr!R rhs) if (isValidBinaryOp!(T, ">", R)) {
        return new BinaryOpExpr!(T, ">", R)(this, rhs);
    }
    auto le(R)(Expr!R rhs) if (isValidBinaryOp!(T, "<=", R)) {
        return new BinaryOpExpr!(T, "<=", R)(this, rhs);
    }
    auto ge(R)(Expr!R rhs) if (isValidBinaryOp!(T, ">=", R)) {
        return new BinaryOpExpr!(T, ">=", R)(this, rhs);
    }

    auto lt(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, "<", R)) {
        return new BinaryOpExpr!(T, "<", R)(this, constant(rhs, this));
    }
    auto gt(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, ">", R)) {
        return new BinaryOpExpr!(T, ">", R)(this, constant(rhs, this));
    }
    auto le(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, "<=", R)) {
        return new BinaryOpExpr!(T, "<=", R)(this, constant(rhs, this));
    }
    auto ge(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, ">=", R)) {
        return new BinaryOpExpr!(T, ">=", R)(this, constant(rhs, this));
    }
}

// ============================================================================
// Helper Templates
// ============================================================================

/// Extract result type from an Expr
template ExprResultType(E) {
    static if (is(E : Expr!T, T))
        alias ExprResultType = T;
    else
        static assert(false, "Not an Expr type: " ~ E.stringof);
}

/// Check if something is an Expr
template isExpr(T) {
    enum isExpr = is(T : Expr!U, U);
}

/// Generalize an expression type to its base Expr!T form.
/// Non-expression types are kept as-is.
template GeneralizeExpr(T) {
    static if (is(T : Expr!U, U))
        alias GeneralizeExpr = Expr!U;
    else
        alias GeneralizeExpr = T;
}

/// Generalize all types in a type list.
/// Expression types become Expr!T, others stay unchanged.
template GeneralizeExprs(Args...) {
    import std.meta : staticMap;
    alias GeneralizeExprs = staticMap!(GeneralizeExpr, Args);
}

private template toArray(T) {
    alias toArray = T[];
}

// ============================================================================
// Constant Expression
// ============================================================================

/// Interface for constant expressions - allows optimizer to extract values
/// without knowing the compile-time type.
interface ConstantInfo {
    /// Get the constant value type
    TypeInfo valueType();

    /// Get the value as a string representation (for SQL literals, debugging, etc.)
    string valueAsString();
}

/// Expression that returns a constant value for all inputs.
/// Batch size is derived from the length source expression.
class ConstExpr(T) : Expr!T, ConstantInfo {
    private T _value;
    private ExprBase _lengthSource;

    this(T value, ExprBase lengthSource) {
        _value = value;
        _lengthSource = lengthSource;
        assert(_lengthSource !is null, "ConstExpr requires a length source");
    }

    override ExprBase[] dependencies() {
        return [_lengthSource];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _lengthSource = newDep;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto value = _value;
        return _lengthSource.evalResultLength(ctx).then((size_t count) {
            return std.algorithm.map!(_ => value)(iota(count)).array;
        });
    }

    /// Get the constant value (for optimizer inspection)
    @property T value() { return _value; }

    // ConstantInfo implementation
    override TypeInfo valueType() { return typeid(T); }

    override string valueAsString() {
        import std.conv : to;
        static if (is(T == string)) {
            return _value;
        } else {
            return _value.to!string;
        }
    }
}

/// Create a constant expression with a length source.
/// The length source is evaluated to determine how many copies of the constant to produce.
auto constant(T)(T value, ExprBase lengthSource) {
    return new ConstExpr!T(value, lengthSource);
}

// ============================================================================
// Binary Operation Expression
// ============================================================================

/// Maps D operators to SQL operators
string toSqlOp(string op) {
    switch (op) {
        case "~": return "||";   // String concatenation
        case "==": return "=";   // Equality
        case "!=": return "<>";  // Inequality
        case "&&": return "AND"; // Logical and
        case "||": return "OR";  // Logical or (note: conflicts with concat in some DBs)
        case "%": return "%";    // Modulo
        default: return op;      // +, -, *, /, <, >, <=, >= are the same
    }
}

/// Interface for binary operation expressions - allows optimizer to inspect and transform
interface BinaryOpInfo {
    /// The operator ("+", "~", "==", etc.)
    string operator();

    /// Left operand (type-erased)
    ExprBase left();

    /// Right operand (type-erased)
    ExprBase right();
}

/// Expression representing a binary operation (arithmetic, concatenation, comparison).
/// Supports mixed types (e.g., int + float -> float).
/// Can be evaluated in D or pushed down to SQL.
class BinaryOpExpr(L, string op, R = L) : Expr!(typeof(mixin("L.init " ~ op ~ " R.init"))), BinaryOpInfo {
    alias ResultT = typeof(mixin("L.init " ~ op ~ " R.init"));

    private ExprBase _left;
    private ExprBase _right;

    this(Expr!L left, Expr!R right) {
        _left = left;
        _right = right;
    }

    override ExprBase[] dependencies() {
        return [_left, _right];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _left = newDep;
        else if (index == 1)
            _right = newDep;
    }

    override Expr!ResultT optimize(OptimizeContext ctx) {
        _left = cast(ExprBase) (cast(Expr!L) _left).optimize(ctx);
        _right = cast(ExprBase) (cast(Expr!R) _right).optimize(ctx);
        // Future: could return ProjectComputedExpr for SQL push-down
        return this;
    }

    override Promise!(ResultT[]) eval(EvalContext ctx) {
        auto left = _left;
        auto right = _right;

        // Evaluate both operands sequentially, then combine
        return evalAs!L(left, ctx).then((lefts) {
            return evalAs!R(right, ctx).then((rights) {
                auto count = lefts.length;
                ResultT[] result = new ResultT[count];
                foreach (i; 0 .. count) {
                    result[i] = mixin("lefts[i] " ~ op ~ " rights[i]");
                }
                return result;
            });
        });
    }

    /// Generate SQL expression for this operation
    string toSqlExpr(string leftSql, string rightSql) const {
        return "(" ~ leftSql ~ " " ~ toSqlOp(op) ~ " " ~ rightSql ~ ")";
    }

    // BinaryOpInfo implementation
    override string operator() { return op; }
    override ExprBase left() { return _left; }
    override ExprBase right() { return _right; }
}

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
// MapExpr: Explicit Iteration Boundary
// ============================================================================

/// Placeholder representing "current item" within a map iteration.
/// When MapExpr evaluates its body, it passes the flattened collection refs.
/// EveryItemOfExpr just returns those refs unchanged - it's a pass-through
/// that represents "the items being iterated over".
class EveryItemOfExpr : Expr!Ref {
    /// Back-reference to owning MapExpr (set at construction)
    Object _parentMap;  // Use Object to avoid template instantiation issues

    override ExprBase[] dependencies() {
        return [];  // Leaf node (back-reference to parent is not a dependency)
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies to replace
    }

    override Promise!(Ref[]) eval(EvalContext ctx) {
        // Return the refs set by our parent MapExpr
        return resolve(ctx.getCurrentRefs(_parentMap).dup);
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
class MapExpr(Body) : Expr!(Body.ResultType[]), MapExprInfo
    if (is(Body : Expr!U, U))
{
    alias R = Body.ResultType;

    private ExprBase _collection;  // what we're iterating over (type-erased)
    EveryItemOfExpr _item;         // mutable placeholder for "current item"
    private ExprBase _body;        // expression built using _item (type-erased)

    this(Expr!(Ref[]) collection, EveryItemOfExpr item, Body body_) {
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
        // Optimize children, but MapExpr itself stays unchanged
        _collection = (cast(Expr!(Ref[])) _collection).optimize(ctx);
        _body = (cast(Expr!R) _body).optimize(ctx);
        return this;
    }

    /// Batched eval: evaluates all items at once.
    /// Works correctly for both naive and optimized paths.
    override Promise!(R[][]) eval(EvalContext ctx) {
        // Capture for use in closures
        auto bodyExpr = _body;
        auto self = this;  // Key for refs map

        // 1. Evaluate collection for each parent ref
        return evalAs!(Ref[])(_collection, ctx).then((Ref[][] collectionResults) {
            // 2. Flatten for batch evaluation
            Ref[] flatRefs;
            size_t[] lengths;
            foreach (group; collectionResults) {
                lengths ~= group.length;
                flatRefs ~= group;
            }

            if (flatRefs.length == 0) {
                // No items to process - return empty array for each parent
                return resolve(std.algorithm.map!(_ => cast(R[])[])(iota(collectionResults.length)).array);
            }

            // 3. Set current refs for this MapExpr (keyed by identity)
            ctx.setCurrentRefs(self, flatRefs);

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

/// Factory function wires up the MapExpr <-> EveryItemOfExpr linkage
auto map(alias fn, Coll)(Coll collection)
    if (is(Coll : Expr!(Ref[])))
{
    // 1. Create the placeholder
    auto item = new EveryItemOfExpr();

    // 2. Build body expression using placeholder as input
    auto body_ = fn(item);

    // 3. Create MapExpr with both
    auto mapExpr = new MapExpr!(typeof(body_))(collection, item, body_);

    // 4. Link placeholder back to MapExpr
    item._parentMap = mapExpr;

    return mapExpr;
}


// ============================================================================
// jsonObject Combinator (JSON construction)
// ============================================================================

/// Convert a D value to JSONValue
private JSONValue toJsonValue(T)(T value) {
    static if (is(T == JSONValue)) {
        return value;
    } else static if (is(T == string)) {
        return JSONValue(value);
    } else static if (is(T == bool)) {
        return JSONValue(value);
    } else static if (isIntegral!T) {
        return JSONValue(value);
    } else static if (isFloatingPoint!T) {
        return JSONValue(value);
    } else static if (is(T == Ref)) {
        return JSONValue(value.nodeId);
    } else static if (isArray!T && !is(T == string)) {
        JSONValue arr = JSONValue.emptyArray;
        foreach (elem; value) {
            arr.array ~= toJsonValue(elem);
        }
        return arr;
    } else {
        static assert(false, "Cannot convert " ~ T.stringof ~ " to JSONValue");
    }
}

/// Expression that constructs a JSON object from named expressions.
/// Args should alternate: string, Expr, string, Expr, ...
class JsonObjectExpr(Args...) : Expr!JSONValue
    if (Args.length >= 2 && Args.length % 2 == 0)
{
    // Extract expression types at even positions (1, 3, 5, ...)
    private template ExprTypeAt(size_t i) {
        alias ExprTypeAt = ExprResultType!(Args[i * 2 + 1]);
    }

    // String names at even indices (0, 2, 4, ...)
    private string[Args.length / 2] _names;
    // Expression values at odd indices, stored as ExprBase
    private ExprBase[Args.length / 2] _exprs;

    this(Args args) {
        static foreach (i; 0 .. Args.length / 2) {{
            _names[i] = args[i * 2];
            _exprs[i] = args[i * 2 + 1];
        }}
    }

    override ExprBase[] dependencies() {
        return _exprs[];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index < _exprs.length)
            _exprs[index] = newDep;
    }

    override Expr!JSONValue optimize(OptimizeContext ctx) {
        // Optimize the expression elements
        static foreach (i; 0 .. Args.length / 2) {{
            alias ET = ExprTypeAt!i;
            _exprs[i] = (cast(Expr!ET) _exprs[i]).optimize(ctx);
        }}
        return this;
    }

    // Tuple type for all field results
    private alias FieldArrayTypes = staticMap!(toArray, staticMap!(ExprTypeAt, staticIota!(Args.length / 2)));

    override Promise!(JSONValue[]) eval(EvalContext ctx) {
        auto exprs = _exprs;
        auto names = _names;

        // Build tuple of promises for all fields
        alias PromiseTypes = staticMap!(toPromiseArray, staticMap!(ExprTypeAt, staticIota!(Args.length / 2)));
        Tuple!PromiseTypes promises;
        static foreach (i; 0 .. Args.length / 2) {
            promises[i] = evalAs!(ExprTypeAt!i)(exprs[i], ctx);
        }

        // Wait for all fields, then build JSON objects
        return all(promises.expand).then((Tuple!FieldArrayTypes results) {
            auto count = results[0].length;
            JSONValue[] jsonResults = new JSONValue[count];

            foreach (idx; 0 .. count) {
                jsonResults[idx] = JSONValue.emptyObject;
                static foreach (i; 0 .. Args.length / 2) {
                    jsonResults[idx][names[i]] = toJsonValue(results[i][idx]);
                }
            }
            return jsonResults;
        });
    }
}

/// Create a JSON object expression from alternating name/expression pairs.
/// Example: jsonObject("firstName", User.firstName(user), "lastName", User.lastName(user))
auto jsonObject(Args...)(Args args)
    if (Args.length >= 2 && Args.length % 2 == 0)
{
    return new JsonObjectExpr!Args(args);
}

// ============================================================================
// Tests
// ============================================================================

import ae.utils.promise.await : awaitSync;

/// Helper: expression that returns a fixed array of refs.
/// Used as a collection source in tests.
private class MockCollectionExpr : Expr!(Ref[]) {
    Ref[] _refs;
    this(Ref[] refs) { _refs = refs; }

    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t index, ExprBase newDep) {}

    override Promise!(Ref[][]) eval(EvalContext ctx) {
        return resolve([_refs]);
    }
}

unittest {
    // Test map with use combinator - extracts node IDs
    auto collection = new MockCollectionExpr([Ref("Test:1"), Ref("Test:2")]);

    auto query = map!(
        (Expr!Ref item) => use((Ref r) => r.nodeId, item)
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["Test:1", "Test:2"]);
}

unittest {
    // Test map with jsonObject - builds structured output
    auto collection = new MockCollectionExpr([Ref("User:1"), Ref("User:2")]);

    auto query = map!(
        (Expr!Ref item) => jsonObject(
            "id", use((Ref r) => r.nodeId, item),
            "type", use((Ref r) => r.typeName, item)
        )
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0].length == 2);
    assert(result[0][0]["id"].str == "User:1");
    assert(result[0][0]["type"].str == "User");
    assert(result[0][1]["id"].str == "User:2");
}

unittest {
    // Test string concatenation with literals inside map
    auto collection = new MockCollectionExpr([Ref("Test:1"), Ref("Test:2")]);

    auto query = map!(
        (Expr!Ref item) => use((Ref r) => r.typeName, item) ~ ":" ~ use((Ref r) => r.nodeId, item)
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["Test:Test:1", "Test:Test:2"]);
}

unittest {
    import std.conv : to;

    // Test arithmetic operators with literals inside map
    auto collection = new MockCollectionExpr([Ref("Test:1"), Ref("Test:2"), Ref("Test:3")]);

    auto query = map!(
        (Expr!Ref item) {
            // Use localId parsed to int for arithmetic test
            auto id = use((Ref r) => r.localId.to!long, item);
            return id * 10 + 5;
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [15, 25, 35]);  // (1*10+5), (2*10+5), (3*10+5)
}

unittest {
    import std.conv : to;

    // Test comparison operators inside map
    auto collection = new MockCollectionExpr([Ref("Test:5"), Ref("Test:10"), Ref("Test:15")]);

    auto query = map!(
        (Expr!Ref item) {
            auto val = use((Ref r) => r.localId.to!long, item);
            return val.gt(7);  // 5 > 7 = false, 10 > 7 = true, 15 > 7 = true
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [false, true, true]);
}
