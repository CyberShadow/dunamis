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
// Core Expression Type
// ============================================================================

/// Base class for all expressions in the declarative model.
///
/// Expressions are written with per-element semantics — as if operating on
/// a single entity. Batching happens automatically during evaluation.
///
/// Batch semantics: eval() always returns T[] — one result per input ref.
abstract class Expr(T) {
    alias ResultType = T;

    /// Optimize this expression and its children.
    /// Returns: optimized expression (may be this or a replacement).
    Expr!T optimize(OptimizeContext ctx) {
        return this;  // Default: no optimization
    }

    /// Evaluate for a batch of entity references.
    /// Returns T[] with one result per input ref.
    abstract T[] eval(EvalContext ctx, Ref[] refs);

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
    auto opBinary(string op, R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, op, R)) {
        return new BinaryOpExpr!(T, op, R)(this, constant(rhs));
    }

    /// Binary operators: literal op expr
    auto opBinaryRight(string op, L)(L lhs) if (!is(L : Expr!U, U) && isValidBinaryOp!(L, op, T)) {
        return new BinaryOpExpr!(L, op, T)(constant(lhs), this);
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
        return new BinaryOpExpr!(T, "==", R)(this, constant(rhs));
    }
    auto ne(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, "!=", R)) {
        return new BinaryOpExpr!(T, "!=", R)(this, constant(rhs));
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
        return new BinaryOpExpr!(T, "<", R)(this, constant(rhs));
    }
    auto gt(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, ">", R)) {
        return new BinaryOpExpr!(T, ">", R)(this, constant(rhs));
    }
    auto le(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, "<=", R)) {
        return new BinaryOpExpr!(T, "<=", R)(this, constant(rhs));
    }
    auto ge(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, ">=", R)) {
        return new BinaryOpExpr!(T, ">=", R)(this, constant(rhs));
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

/// Expression that returns a constant value for all inputs
class ConstExpr(T) : Expr!T {
    private T _value;

    this(T value) {
        _value = value;
    }

    override T[] eval(EvalContext ctx, Ref[] refs) {
        // Return same value for each ref
        return std.algorithm.map!(_ => _value)(refs).array;
    }
}

/// Create a constant expression
auto constant(T)(T value) {
    return new ConstExpr!T(value);
}

// ============================================================================
// Binary Operation Expression
// ============================================================================

// TODO: Move SQL-related code (toSqlOp, toSqlExpr) to relational/optimize.d
//       when implementing SQL push-down for computed expressions.

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

/// Expression representing a binary operation (arithmetic, concatenation, comparison).
/// Supports mixed types (e.g., int + float -> float).
/// Can be evaluated in D or pushed down to SQL.
class BinaryOpExpr(L, string op, R = L) : Expr!(typeof(mixin("L.init " ~ op ~ " R.init"))) {
    alias ResultT = typeof(mixin("L.init " ~ op ~ " R.init"));

    private Expr!L _left;
    private Expr!R _right;

    this(Expr!L left, Expr!R right) {
        _left = left;
        _right = right;
    }

    override Expr!ResultT optimize(OptimizeContext ctx) {
        _left = _left.optimize(ctx);
        _right = _right.optimize(ctx);
        // Future: could return ProjectComputedExpr for SQL push-down
        return this;
    }

    override ResultT[] eval(EvalContext ctx, Ref[] refs) {
        auto lefts = _left.eval(ctx, refs);
        auto rights = _right.eval(ctx, refs);

        ResultT[] result = new ResultT[refs.length];
        foreach (i; 0 .. refs.length) {
            result[i] = mixin("lefts[i] " ~ op ~ " rights[i]");
        }
        return result;
    }

    /// Generate SQL expression for this operation
    string toSqlExpr(string leftSql, string rightSql) const {
        return "(" ~ leftSql ~ " " ~ toSqlOp(op) ~ " " ~ rightSql ~ ")";
    }

    @property Expr!L left() { return _left; }
    @property Expr!R right() { return _right; }
    @property string operator() { return op; }
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

    // Store as base Expr!T types to allow optimize() to return different concrete types
    alias GeneralizedExprs = GeneralizeExprs!Exprs;
    private Tuple!GeneralizedExprs _inputs;
    private Fn _fn;

    this(Exprs inputs, Fn fn) {
        static foreach (i; 0 .. Exprs.length) {
            _inputs[i] = inputs[i];  // Implicit upcast to Expr!T
        }
        _fn = fn;
    }

    override Expr!R optimize(OptimizeContext ctx) {
        // Optimize all children - no cast needed since slots are base Expr!T
        static foreach (i; 0 .. Exprs.length) {
            _inputs[i] = _inputs[i].optimize(ctx);
        }
        return this;
    }

    override R[] eval(EvalContext ctx, Ref[] refs) {
        // Evaluate all inputs with same refs
        EvaluatedArrays evaluated;
        static foreach (i; 0 .. Exprs.length) {
            evaluated[i] = _inputs[i].eval(ctx, refs);
        }

        // Apply function per-element
        R[] result = new R[refs.length];
        foreach (idx; 0 .. refs.length) {
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

    override Ref[] eval(EvalContext ctx, Ref[] refs) {
        // Pass through the refs unchanged - these are the items being iterated
        return refs;
    }
}

/// Interface to query collection type from MapExpr without knowing the template params.
/// Used by OptimizeContext to configure QueryNodes correctly.
interface MapExprInfo {
    /// Get the collection expression
    Object collection();

    /// Check if collection is a root expression with specific IDs
    bool isRootByIds(out Ref[] refs);

    /// Check if collection is a "get all" root expression
    bool isRootAll(out string typeName, out string table);

    /// Check if collection is a hasMany relationship.
    /// If true, returns the parent's input expression (to find parent MapExpr),
    /// the FK column, and child type name.
    bool isHasMany(out Expr!Ref parentInput, out string fk, out string childTypeName);
}

/// Interface for hasMany expressions to expose their metadata.
/// Implemented by HasManyAccessExpr in relational module.
interface HasManyInfo {
    /// The input expression (points to parent entity)
    Expr!Ref inputExpr();

    /// Foreign key column in child table
    string fkColumn();

    /// Child entity type name
    string childTypeName();

    /// Parent entity type name (for ref encoding)
    string parentTypeName();
}

/// Iteration over a collection. This IS the layer boundary.
/// MapExpr is data-source agnostic — it only knows about map semantics.
class MapExpr(Body) : Expr!(Body.ResultType[]), MapExprInfo
    if (is(Body : Expr!U, U))
{
    alias R = Body.ResultType;

    Expr!(Ref[]) _collection;  // what we're iterating over
    EveryItemOfExpr _item;     // mutable placeholder for "current item"
    Expr!R _body;              // expression built using _item (stored as base type)

    this(Expr!(Ref[]) collection, EveryItemOfExpr item, Body body_) {
        _collection = collection;
        _item = item;
        _body = body_;  // Implicit upcast to Expr!R
    }

    override Expr!(R[]) optimize(OptimizeContext ctx) {
        // Optimize children, but MapExpr itself stays unchanged
        // No casts needed - slots are base types
        _collection = _collection.optimize(ctx);
        _body = _body.optimize(ctx);
        return this;
    }

    /// Batched eval: evaluates all items at once.
    /// Works correctly for both naive and optimized paths.
    override R[][] eval(EvalContext ctx, Ref[] parentRefs) {
        // 1. Evaluate collection for each parent ref
        Ref[][] collectionResults = _collection.eval(ctx, parentRefs);

        // 2. Flatten for batch evaluation
        Ref[] flatRefs;
        size_t[] lengths;
        foreach (group; collectionResults) {
            lengths ~= group.length;
            flatRefs ~= group;
        }

        if (flatRefs.length == 0) {
            // No items to process
            return std.algorithm.map!(_ => cast(R[])[])(parentRefs).array;
        }

        // 3. Evaluate body with ALL refs at once
        R[] flatResults = _body.eval(ctx, flatRefs);

        // 4. Regroup to match input structure
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

    bool isRootByIds(out Ref[] refs) {
        if (auto rootExpr = cast(RootExprInfo) _collection) {
            if (rootExpr.filterType == FilterType.byIds) {
                refs = rootExpr.filterRefs;
                return true;
            }
        }
        return false;
    }

    bool isRootAll(out string typeName, out string table) {
        if (auto rootExpr = cast(RootExprInfo) _collection) {
            if (rootExpr.filterType == FilterType.all) {
                typeName = rootExpr.entityTypeName;
                table = rootExpr.entityTable;
                return true;
            }
        }
        return false;
    }

    bool isHasMany(out Expr!Ref parentInput, out string fk, out string childTypeName) {
        if (auto hasManyExpr = cast(HasManyInfo) _collection) {
            parentInput = hasManyExpr.inputExpr;
            fk = hasManyExpr.fkColumn;
            childTypeName = hasManyExpr.childTypeName;
            return true;
        }
        return false;
    }
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
// Root Expressions
// ============================================================================

/// Interface for root expressions (GetByIds, GetAll) to expose filter info.
/// Used by MapExpr to configure QueryNodes correctly.
interface RootExprInfo {
    /// The filter type (all, byIds)
    FilterType filterType();

    /// For byIds: the refs to filter by
    Ref[] filterRefs();

    /// Entity type name for the root query
    string entityTypeName();

    /// Entity table name for the root query
    string entityTable();
}

/// Root expression that returns specific entities by their IDs
class GetByIdsExpr(Entity) : Expr!(Ref[]), RootExprInfo {
    private Ref[] _refs;

    this(long[] ids) {
        _refs = std.algorithm.map!(id => makeRef(Entity._typeName, id))(ids).array;
    }

    this(Ref[] refs) {
        _refs = refs;
    }

    override Ref[][] eval(EvalContext ctx, Ref[] parentRefs) {
        // One result (the same ref array) per parent ref
        return std.algorithm.map!(_ => _refs)(parentRefs).array;
    }

    @property Ref[] refs() { return _refs; }

    // RootExprInfo implementation
    FilterType filterType() { return FilterType.byIds; }
    Ref[] filterRefs() { return _refs; }
    string entityTypeName() { return Entity._typeName; }
    string entityTable() { return Entity._table; }
}

/// Factory function to create GetByIdsExpr
auto getByIds(Entity)(long[] ids) {
    return new GetByIdsExpr!Entity(ids);
}

/// Root expression that fetches all entities of a type
class GetAllExpr(Entity) : Expr!(Ref[]), RootExprInfo {
    override Ref[][] eval(EvalContext ctx, Ref[] parentRefs) {
        // Fetch all IDs from data source, encode as refs
        auto ids = ctx.fetchAllIds(Entity._table);
        auto refs = std.algorithm.map!(id => makeRef(Entity._typeName, id))(ids).array;
        return std.algorithm.map!(_ => refs)(parentRefs).array;
    }

    // RootExprInfo implementation
    FilterType filterType() { return FilterType.all; }
    Ref[] filterRefs() { return []; }
    string entityTypeName() { return Entity._typeName; }
    string entityTable() { return Entity._table; }
}

/// Factory function to create GetAllExpr
auto getAll(Entity)() {
    return new GetAllExpr!Entity();
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
    // Store as base Expr!T types to allow optimize() to return different concrete types
    // String field names stay as strings, expressions become Expr!T
    alias GeneralizedArgs = GeneralizeExprs!Args;
    private Tuple!GeneralizedArgs _args;

    this(Args args) {
        static foreach (i; 0 .. Args.length) {
            _args[i] = args[i];  // Implicit upcast for expressions
        }
    }

    override Expr!JSONValue optimize(OptimizeContext ctx) {
        // Optimize the expression elements (odd indices: 1, 3, 5, ...)
        // No cast needed since slots are base Expr!T
        static foreach (i; 0 .. Args.length / 2) {{
            enum exprIdx = i * 2 + 1;
            _args[exprIdx] = _args[exprIdx].optimize(ctx);
        }}
        return this;
    }

    override JSONValue[] eval(EvalContext ctx, Ref[] refs) {
        auto count = refs.length;
        JSONValue[] results = new JSONValue[count];

        // Initialize empty objects
        foreach (ref r; results) {
            r = JSONValue.emptyObject;
        }

        // Process each name/expr pair
        static foreach (i; 0 .. Args.length / 2) {{
            enum nameIdx = i * 2;
            enum exprIdx = i * 2 + 1;

            string name = _args[nameIdx];
            auto values = _args[exprIdx].eval(ctx, refs);

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
    auto refs = [Ref("Test:1"), Ref("Test:2")];
    auto result = constExpr.eval(ctx, refs);
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
    auto refs = [Ref("Test:1"), Ref("Test:2"), Ref("Test:3")];
    auto result = combined.eval(ctx, refs);
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
    auto refs = [Ref("Test:1"), Ref("Test:2")];
    auto result = obj.eval(ctx, refs);

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
        override Ref[][] eval(EvalContext ctx, Ref[] parentRefs) {
            return std.algorithm.map!(_ => _refs)(parentRefs).array;
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

    // Evaluate for one parent
    auto result = mapExpr.eval(ctx, [queryRoot]);
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
    auto refs = [Ref("Test:1"), Ref("Test:2")];
    auto result = combined.eval(ctx, refs);
    assert(result == ["Hello World", "Hello World"]);
}

unittest {
    // Test arithmetic operators
    auto a = constant(10);
    auto b = constant(3);

    auto ctx = new EvalContext();
    auto refs = [Ref("Test:1")];

    assert((a + b).eval(ctx, refs) == [13]);
    assert((a - b).eval(ctx, refs) == [7]);
    assert((a * b).eval(ctx, refs) == [30]);
    assert((a / b).eval(ctx, refs) == [3]);

    // With literals
    assert((a + 5).eval(ctx, refs) == [15]);
    assert((5 + a).eval(ctx, refs) == [15]);
}

unittest {
    // Test comparison operators
    auto a = constant(10);
    auto b = constant(3);

    auto ctx = new EvalContext();
    auto refs = [Ref("Test:1")];

    assert(a.eq(10).eval(ctx, refs) == [true]);
    assert(a.eq(5).eval(ctx, refs) == [false]);
    assert(a.ne(5).eval(ctx, refs) == [true]);
    assert(a.lt(b).eval(ctx, refs) == [false]);
    assert(a.gt(b).eval(ctx, refs) == [true]);
    assert(a.le(10).eval(ctx, refs) == [true]);
    assert(a.ge(10).eval(ctx, refs) == [true]);
}
