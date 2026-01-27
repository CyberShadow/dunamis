module graphqld2.expr;

import std.traits;
import std.meta;
import std.range;
import std.algorithm;
import std.array;
import std.typecons : Tuple, tuple;
import std.functional : toDelegate;

/// Opaque ID type parameterized by entity
struct Id(T) {
    long value;
    alias Entity = T;
}

/// Context passed during evaluation
/// Each context represents one "row" being processed
struct Context {
    /// The entity ID for this context (type-erased)
    long entityId;

    /// Type tag for runtime checking
    TypeInfo entityType;

    /// Create a context for an entity
    static Context forEntity(T)(Id!T id) {
        Context ctx;
        ctx.entityId = id.value;
        ctx.entityType = typeid(T);
        return ctx;
    }

    /// Get the ID as a typed Id
    Id!T getId(T)() const {
        assert(entityType is typeid(T), "Context type mismatch");
        return Id!T(entityId);
    }
}

/// Base class for all expressions
/// T is the result type for a single parent context
abstract class Expr(T) {
    alias ResultType = T;

    /// Phase 2: evaluate for a batch of parent contexts
    /// Returns one T per context
    abstract T[] evalBatch(Context[] contexts);

    // TODO: Phase 1 dependency collection
    // abstract Dependency[] dependencies();

    // Operator overloads - defined via UFCS-style free functions below
}

/// Constant expression - same value for all contexts
class ConstExpr(T) : Expr!T {
    private T _value;

    this(T value) {
        _value = value;
    }

    override T[] evalBatch(Context[] contexts) {
        auto result = new T[contexts.length];
        result[] = _value;
        return result;
    }
}

/// Helper to create const expression
Expr!T constant(T)(T value) {
    return new ConstExpr!T(value);
}

/// Expression that reads the entity ID from context
class ContextIdExpr(T) : Expr!(Id!T) {
    override Id!T[] evalBatch(Context[] contexts) {
        return contexts.map!(ctx => ctx.getId!T()).array;
    }
}

/// Helper to get the current context's entity ID
Expr!(Id!T) contextId(T)() {
    return new ContextIdExpr!T();
}

// ------------------------------------------------------------------
// Binary operations
// ------------------------------------------------------------------

/// Binary operation expression
class BinaryOpExpr(string op, L, R) : Expr!(BinaryOpResult!(op, L, R)) {
    alias ResultT = BinaryOpResult!(op, L, R);

    private Expr!L _left;
    private Expr!R _right;

    this(Expr!L left, Expr!R right) {
        _left = left;
        _right = right;
    }

    override ResultT[] evalBatch(Context[] contexts) {
        auto lefts = _left.evalBatch(contexts);
        auto rights = _right.evalBatch(contexts);

        return zip(lefts, rights)
            .map!(pair => mixin("pair[0] " ~ op ~ " pair[1]"))
            .array;
    }
}

/// Compute result type of binary operation
template BinaryOpResult(string op, L, R) {
    static if (op == "~" && isSomeString!L && isSomeString!R)
        alias BinaryOpResult = L;
    else static if (op == "~" && isArray!L)
        alias BinaryOpResult = L;
    else static if (op.among("+", "-", "*", "/", "%"))
        alias BinaryOpResult = CommonType!(L, R);
    else static if (op.among("==", "!=", "<", ">", "<=", ">="))
        alias BinaryOpResult = bool;
    else static if (op.among("&&", "||"))
        alias BinaryOpResult = bool;
    else
        static assert(false, "Unsupported operator: " ~ op);
}

// Operator overloads as free functions (UFCS)
// String concatenation
auto opBinary(string op : "~", T)(Expr!T lhs, Expr!T rhs) if (isSomeString!T) {
    return new BinaryOpExpr!("~", T, T)(lhs, rhs);
}

auto opBinary(string op : "~", T)(Expr!T lhs, T rhs) if (isSomeString!T) {
    return new BinaryOpExpr!("~", T, T)(lhs, constant(rhs));
}

// Arithmetic operations
static foreach (op; ["+", "-", "*", "/"]) {
    auto opBinary(string s : op, L, R)(Expr!L lhs, Expr!R rhs)
        if (isNumeric!L && isNumeric!R)
    {
        return new BinaryOpExpr!(op, L, R)(lhs, rhs);
    }

    auto opBinary(string s : op, L, R)(Expr!L lhs, R rhs)
        if (isNumeric!L && isNumeric!R)
    {
        return new BinaryOpExpr!(op, L, R)(lhs, constant(rhs));
    }
}

// Comparison operations
static foreach (op; ["==", "!=", "<", ">", "<=", ">="]) {
    auto opBinary(string s : op, L, R)(Expr!L lhs, Expr!R rhs) {
        return new BinaryOpExpr!(op, L, R)(lhs, rhs);
    }

    auto opBinary(string s : op, L, R)(Expr!L lhs, R rhs) {
        return new BinaryOpExpr!(op, L, R)(lhs, constant(rhs));
    }
}

// ------------------------------------------------------------------
// Variadic `use` combinator
// ------------------------------------------------------------------

/// Extract result types from a tuple of Expr types
template ExprResultTypes(Exprs...) {
    alias ExprResultTypes = staticMap!(ExprResultType, Exprs);
}

template ExprResultType(E) {
    static if (is(E : Expr!T, T))
        alias ExprResultType = T;
    else
        static assert(false, "Not an Expr type: " ~ E.stringof);
}

/// Helper to evaluate all inputs and return tuple of arrays
private auto evalAllInputs(Exprs...)(Exprs inputs, Context[] contexts) {
    alias ResultTypes = ExprResultTypes!Exprs;
    Tuple!(staticMap!(toArray, ResultTypes)) results;

    static foreach (i; 0 .. Exprs.length) {
        results[i] = inputs[i].evalBatch(contexts);
    }

    return results;
}

private template toArray(T) {
    alias toArray = T[];
}

/// The use expression - applies a function per-element
class UseExpr(R, Exprs...) : Expr!R
    if (Exprs.length >= 1 && allSatisfy!(isExpr, Exprs))
{
    alias InputTypes = ExprResultTypes!Exprs;

    private Tuple!Exprs _inputs;
    private R delegate(InputTypes) _fn;

    this(Exprs inputs, R delegate(InputTypes) fn) {
        static foreach (i; 0 .. Exprs.length)
            _inputs[i] = inputs[i];
        _fn = fn;
    }

    override R[] evalBatch(Context[] contexts) {
        // Evaluate each input expression
        auto evaluated = evalInputs(contexts);

        // Apply function per-element
        auto result = new R[contexts.length];
        foreach (i; 0 .. contexts.length) {
            result[i] = callWithIndex(evaluated, i);
        }
        return result;
    }

    private auto evalInputs(Context[] contexts) {
        Tuple!(staticMap!(toArray, InputTypes)) results;
        static foreach (i; 0 .. Exprs.length) {
            results[i] = _inputs[i].evalBatch(contexts);
        }
        return results;
    }

    private R callWithIndex(T)(T evaluated, size_t idx) {
        // Build tuple of values at index idx
        Tuple!InputTypes args;
        static foreach (i; 0 .. InputTypes.length) {
            args[i] = evaluated[i][idx];
        }
        return _fn(args.expand);
    }
}

private template isExpr(T) {
    enum isExpr = is(T : Expr!U, U);
}

/// Create a use expression from inputs and a function
/// Usage: use((A a, B b) => result, expr1, expr2)
auto use(Fn, Exprs...)(Fn fn, Exprs exprs)
    if (Exprs.length >= 1 && allSatisfy!(isExpr, Exprs))
{
    alias R = ReturnType!Fn;
    return new UseExpr!(R, Exprs)(exprs, toDelegate(fn));
}

// ------------------------------------------------------------------
// Variadic `useAll` combinator
// ------------------------------------------------------------------

/// The useAll expression - applies a function to all elements at once
class UseAllExpr(R, Exprs...) : Expr!R
    if (Exprs.length >= 1 && allSatisfy!(isExpr, Exprs))
{
    alias InputTypes = ExprResultTypes!Exprs;
    alias ArrayInputTypes = staticMap!(toArray, InputTypes);

    private Tuple!Exprs _inputs;
    private R[] delegate(ArrayInputTypes) _fn;

    this(Exprs inputs, R[] delegate(ArrayInputTypes) fn) {
        static foreach (i; 0 .. Exprs.length)
            _inputs[i] = inputs[i];
        _fn = fn;
    }

    override R[] evalBatch(Context[] contexts) {
        auto evaluated = evalInputs(contexts);
        return _fn(evaluated.expand);
    }

    private auto evalInputs(Context[] contexts) {
        Tuple!ArrayInputTypes results;
        static foreach (i; 0 .. Exprs.length) {
            results[i] = _inputs[i].evalBatch(contexts);
        }
        return results;
    }
}

/// Create a useAll expression
/// Usage: useAll((A[] as, B[] bs) => results, expr1, expr2)
auto useAll(Fn, Exprs...)(Fn fn, Exprs exprs)
    if (Exprs.length >= 1 && allSatisfy!(isExpr, Exprs))
{
    alias R = ElementType!(ReturnType!Fn);
    return new UseAllExpr!(R, Exprs)(exprs, toDelegate(fn));
}

// ------------------------------------------------------------------
// Unit tests
// ------------------------------------------------------------------

unittest {
    // Test constant expression
    auto c = constant(42);
    auto contexts = new Context[3];
    assert(c.evalBatch(contexts) == [42, 42, 42]);
}

unittest {
    // Test constant string
    auto hello = constant("hello");
    auto contexts = new Context[2];
    assert(hello.evalBatch(contexts) == ["hello", "hello"]);
}

unittest {
    // Test use combinator with single input
    auto nums = constant(10);
    auto doubled = use((int x) => x * 2, nums);
    auto contexts = new Context[3];
    assert(doubled.evalBatch(contexts) == [20, 20, 20]);
}

unittest {
    // Test use combinator with multiple inputs
    auto a = constant(10);
    auto b = constant(3);
    auto sum = use((int x, int y) => x + y, a, b);
    auto contexts = new Context[2];
    assert(sum.evalBatch(contexts) == [13, 13]);
}

unittest {
    // Test use with strings
    auto first = constant("Hello");
    auto second = constant("World");
    auto combined = use((string a, string b) => a ~ " " ~ b, first, second);
    auto contexts = new Context[2];
    assert(combined.evalBatch(contexts) == ["Hello World", "Hello World"]);
}

unittest {
    // Test useAll combinator - batch computation
    auto nums = constant(5);
    // Batch operation: given all inputs, produce all outputs
    // Here we double each value, but could do cross-element computation
    auto doubled = useAll((int[] xs) => xs.map!(x => x * 2).array, nums);
    auto contexts = new Context[4];
    assert(doubled.evalBatch(contexts) == [10, 10, 10, 10]);
}

unittest {
    // Test useAll - transform all values at once
    auto nums = constant(10);
    auto transformed = useAll(
        (int[] xs) => xs.map!(x => x * 2).array,
        nums
    );
    auto contexts = new Context[3];
    assert(transformed.evalBatch(contexts) == [20, 20, 20]);
}

unittest {
    // Test useAll with multiple inputs
    auto a = constant(2);
    auto b = constant(3);
    auto products = useAll(
        (int[] xs, int[] ys) {
            // Element-wise product
            return zip(xs, ys).map!(t => t[0] * t[1]).array;
        },
        a, b
    );
    auto contexts = new Context[3];
    assert(products.evalBatch(contexts) == [6, 6, 6]);
}
