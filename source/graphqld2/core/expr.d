module graphqld2.core.expr;

import std.array;
import std.json;
import std.meta;
import std.range : iota;
import std.traits;
import std.typecons : Nullable, Tuple, tuple;
static import std.algorithm;

import graphqld2.core.types;
import graphqld2.core.eval;
import graphqld2.core.optimize;

// ============================================================================
// Type-Erased Base Class
// ============================================================================

/// Type-erased base class for all expressions.
/// Enables external tree traversal and optimization as a separate step.
abstract class ExprBase {
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
    abstract size_t evalResultLength(EvalContext ctx);
}

/// Helper to evaluate an ExprBase with a known type.
/// Asserts if the runtime type doesn't match.
T[] evalAs(T)(ExprBase expr, EvalContext ctx) {
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
/// Batch semantics: eval() always returns T[] — one result per input ref.
abstract class Expr(T) : ExprBase {
    alias ResultType = T;

    override TypeInfo resultType() {
        return typeid(T);
    }

    override size_t evalResultLength(EvalContext ctx) {
        return eval(ctx).length;
    }

    /// Optimize this expression and its children.
    /// Returns: optimized expression (may be this or a replacement).
    Expr!T optimize(OptimizeContext ctx) {
        return this;  // Default: no optimization
    }

    /// Evaluate for the current batch of entity references.
    /// Returns T[] with one result per ref in ctx.currentRefs.
    /// The batch refs are set by MapExpr before evaluating its body.
    abstract T[] eval(EvalContext ctx);

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
/// When used with a length source (e.g., from opBinary), derives batch size
/// from that expression. Otherwise falls back to ctx.currentRefs.length.
class ConstExpr(T) : Expr!T, ConstantInfo {
    private T _value;
    private ExprBase _lengthSource;  // Expression to derive batch size from

    this(T value) {
        _value = value;
    }

    this(T value, ExprBase lengthSource) {
        _value = value;
        _lengthSource = lengthSource;
    }

    override ExprBase[] dependencies() {
        // Length source is a dependency for tree traversal
        return _lengthSource !is null ? [_lengthSource] : [];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0 && _lengthSource !is null)
            _lengthSource = newDep;
    }

    override T[] eval(EvalContext ctx) {
        // Derive batch size from length source if available
        size_t count;
        if (_lengthSource !is null) {
            count = _lengthSource.evalResultLength(ctx);
        } else {
            count = ctx.currentRefs.length;
        }
        return std.algorithm.map!(_ => _value)(iota(count)).array;
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

/// Create a constant expression
auto constant(T)(T value) {
    return new ConstExpr!T(value);
}

/// Create a constant expression that derives its batch size from another expression
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

    override ResultT[] eval(EvalContext ctx) {
        auto lefts = evalAs!L(_left, ctx);
        auto rights = evalAs!R(_right, ctx);

        auto count = ctx.currentRefs.length;
        ResultT[] result = new ResultT[count];
        foreach (i; 0 .. count) {
            result[i] = mixin("lefts[i] " ~ op ~ " rights[i]");
        }
        return result;
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

    override R[] eval(EvalContext ctx) {
        // Evaluate all inputs with known types
        EvaluatedArrays evaluated;
        static foreach (i; 0 .. Exprs.length) {
            evaluated[i] = evalAs!(InputTypes[i])(_inputs[i], ctx);
        }

        // Apply function per-element
        auto count = ctx.currentRefs.length;
        R[] result = new R[count];
        foreach (idx; 0 .. count) {
            // Build args tuple for this index
            Tuple!InputTypes args;
            static foreach (i; 0 .. Exprs.length) {
                args[i] = evaluated[i][idx];
            }
            result[idx] = _fn(args.expand);
        }
        return result;
    }
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

    override Ref[] eval(EvalContext ctx) {
        // Return the current batch refs set by MapExpr
        return ctx.currentRefs;
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
    override R[][] eval(EvalContext ctx) {
        // 1. Evaluate collection for each parent ref
        Ref[][] collectionResults = evalAs!(Ref[])(_collection, ctx);

        // 2. Flatten for batch evaluation
        Ref[] flatRefs;
        size_t[] lengths;
        foreach (group; collectionResults) {
            lengths ~= group.length;
            flatRefs ~= group;
        }

        if (flatRefs.length == 0) {
            // No items to process - return empty array for each parent
            auto parentCount = ctx.currentRefs.length;
            return std.algorithm.map!(_ => cast(R[])[])(iota(parentCount)).array;
        }

        // 3. Save parent refs and set current refs to the flattened collection
        auto savedRefs = ctx.currentRefs;
        ctx.currentRefs = flatRefs;

        // 4. Evaluate body with ALL refs at once
        R[] flatResults = evalAs!R(_body, ctx);

        // 5. Restore parent refs
        ctx.currentRefs = savedRefs;

        // 6. Regroup to match input structure
        R[][] result;
        size_t offset = 0;
        foreach (len; lengths) {
            result ~= flatResults[offset .. offset + len];
            offset += len;
        }
        return result;
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

    override JSONValue[] eval(EvalContext ctx) {
        auto count = ctx.currentRefs.length;
        JSONValue[] results = new JSONValue[count];

        // Initialize empty objects
        foreach (ref r; results) {
            r = JSONValue.emptyObject;
        }

        // Process each name/expr pair
        static foreach (i; 0 .. Args.length / 2) {{
            alias ET = ExprTypeAt!i;
            string name = _names[i];
            auto values = evalAs!ET(_exprs[i], ctx);

            foreach (idx; 0 .. count) {
                results[idx][name] = toJsonValue(values[idx]);
            }
        }}

        return results;
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

unittest {
    // Test ConstExpr
    auto constExpr = constant(42);
    auto ctx = new EvalContext();
    ctx.currentRefs = [Ref("Test:1"), Ref("Test:2")];
    auto result = constExpr.eval(ctx);
    assert(result == [42, 42]);
}

unittest {
    // Test UseExpr with mock expressions
    auto expr1 = constant("Hello");
    auto expr2 = constant("World");

    auto combined = use(
        (string a, string b) => a ~ " " ~ b,
        expr1,
        expr2
    );

    auto ctx = new EvalContext();
    ctx.currentRefs = [Ref("Test:1"), Ref("Test:2"), Ref("Test:3")];
    auto result = combined.eval(ctx);
    assert(result == ["Hello World", "Hello World", "Hello World"]);
}

unittest {
    // Test jsonObject combinator
    auto nameExpr = constant("Alice");
    auto ageExpr = constant(30);

    auto obj = jsonObject(
        "name", nameExpr,
        "age", ageExpr
    );

    auto ctx = new EvalContext();
    ctx.currentRefs = [Ref("Test:1"), Ref("Test:2")];
    auto result = obj.eval(ctx);

    assert(result.length == 2);
    assert(result[0]["name"].str == "Alice");
    assert(result[0]["age"].integer == 30);
    assert(result[1]["name"].str == "Alice");
    assert(result[1]["age"].integer == 30);
}

unittest {
    // Test MapExpr with constant collection
    class ConstRefArrayExpr : Expr!(Ref[]) {
        Ref[] _refs;
        this(Ref[] refs) { _refs = refs; }

        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t index, ExprBase newDep) {}

        override Ref[][] eval(EvalContext ctx) {
            // Return the same refs for each parent in currentRefs
            auto parentCount = ctx.currentRefs.length;
            return std.algorithm.map!(_ => _refs)(iota(parentCount)).array;
        }
    }

    // Create a mock entity for GetByIdsExpr
    struct TestEntity {
        enum _typeName = "Test";
        enum _table = "tests";
    }

    auto collection = new ConstRefArrayExpr([Ref("Test:1"), Ref("Test:2")]);

    // Map that extracts the node ID as a string
    auto mapExpr = map!(
        (Expr!Ref item) => use(
            (Ref r) => r.nodeId,
            item
        )
    )(collection);

    auto ctx = new EvalContext();
    ctx.currentRefs = [queryRoot];  // Set the parent context

    // Evaluate for one parent
    auto result = mapExpr.eval(ctx);
    assert(result.length == 1);  // One result per parent
    assert(result[0] == ["Test:1", "Test:2"]);  // Array of node IDs
}

unittest {
    // Test string concatenation operator
    auto first = constant("Hello");
    auto second = constant("World");

    // expr ~ expr
    auto combined = first ~ " " ~ second;

    auto ctx = new EvalContext();
    ctx.currentRefs = [Ref("Test:1"), Ref("Test:2")];
    auto result = combined.eval(ctx);
    assert(result == ["Hello World", "Hello World"]);
}

unittest {
    // Test arithmetic operators
    auto a = constant(10);
    auto b = constant(3);

    auto ctx = new EvalContext();
    ctx.currentRefs = [Ref("Test:1")];

    assert((a + b).eval(ctx) == [13]);
    assert((a - b).eval(ctx) == [7]);
    assert((a * b).eval(ctx) == [30]);
    assert((a / b).eval(ctx) == [3]);

    // With literals
    assert((a + 5).eval(ctx) == [15]);
    assert((5 + a).eval(ctx) == [15]);
}

unittest {
    // Test comparison operators
    auto a = constant(10);
    auto b = constant(3);

    auto ctx = new EvalContext();
    ctx.currentRefs = [Ref("Test:1")];

    assert(a.eq(10).eval(ctx) == [true]);
    assert(a.eq(5).eval(ctx) == [false]);
    assert(a.ne(5).eval(ctx) == [true]);
    assert(a.lt(b).eval(ctx) == [false]);
    assert(a.gt(b).eval(ctx) == [true]);
    assert(a.le(10).eval(ctx) == [true]);
    assert(a.ge(10).eval(ctx) == [true]);
}
