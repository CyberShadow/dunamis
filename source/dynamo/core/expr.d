module dynamo.core.expr;

import std.array;
import std.json;
import std.meta;
import std.range : iota;
import std.traits;
import std.typecons : Nullable, Tuple, tuple;
static import std.algorithm;

import ae.utils.promise;
import ae.net.asockets : socketManager;

import dynamo.core.types;
import dynamo.core.eval;
import dynamo.core.optimize;

// ============================================================================
// Type-Erased Base Class
// ============================================================================

/// Type-erased base class for all expressions.
/// Enables external tree traversal and optimization as a separate step.
abstract class ExprBase {
    import dynamo.core.optimize : ExprOptimizer;

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
///
/// Automatically memoizes: if the same expression is evaluated multiple times
/// (e.g., via parallel dependencies), returns the cached Promise instead of
/// re-evaluating. This is safe because expressions are pure/deterministic.
Promise!(T[]) evalAs(T)(ExprBase expr, EvalContext ctx) {
    // Check memoization cache first
    if (auto cached = ctx.getCachedEval(expr)) {
        return cast(Promise!(T[])) cached;
    }

    auto typed = cast(Expr!T) expr;
    assert(typed !is null, "Type mismatch in evalAs: expected " ~ T.stringof);

    auto promise = typed.eval(ctx);

    // Cache for future calls
    ctx.setCachedEval(expr, promise);
    return promise;
}

/// Interface for expressions that can be evaluated to AnyRef[].
/// Implemented by ref-producing expressions (EveryItemOfExpr, BelongsToAccessExpr, etc.)
/// to allow type-agnostic evaluation in internal code.
interface AnyRefEvaluable {
    /// Evaluate and return refs as AnyRef[] (for type-agnostic internal use)
    Promise!(AnyRef[]) evalAsAnyRef(EvalContext ctx);
}

/// Evaluate any ref-producing expression and return as AnyRef[].
/// Works with typed Expr!Entity expressions by using interface dispatch.
/// Used by projection expressions that need to evaluate input refs without
/// knowing the specific entity type at compile time.
Promise!(AnyRef[]) evalRefAsAnyRef(ExprBase expr, EvalContext ctx) {
    // Check memoization cache first
    if (auto cached = ctx.getCachedEval(expr)) {
        return cast(Promise!(AnyRef[])) cached;
    }

    // Check if it implements AnyRefEvaluable interface
    if (auto evaluable = cast(AnyRefEvaluable) expr) {
        auto promise = evaluable.evalAsAnyRef(ctx);
        ctx.setCachedEval(expr, promise);
        return promise;
    }

    // Fallback: try evalAs!AnyRef for expressions that actually return AnyRef
    auto typed = cast(Expr!AnyRef) expr;
    if (typed !is null) {
        auto promise = typed.eval(ctx);
        ctx.setCachedEval(expr, promise);
        return promise;
    }

    // Should not reach here - indicates a type mismatch
    assert(false, "Cannot evaluate expression as AnyRef: " ~ expr.classinfo.name);
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

    // =========================================================================
    // Boolean Logic Operators (only for Expr!bool)
    // =========================================================================

    static if (is(T == bool)) {
        /// Logical AND - combines two boolean expressions
        /// Note: D's && operator cannot be overloaded, so we use a method
        auto and(Expr!bool rhs) {
            return new BinaryOpExpr!(bool, "&&", bool)(this, rhs);
        }

        /// Logical AND with literal bool
        auto and(bool rhs) {
            return new BinaryOpExpr!(bool, "&&", bool)(this, constant(rhs, this));
        }

        /// Logical OR - combines two boolean expressions
        /// Note: D's || operator cannot be overloaded, so we use a method
        auto or(Expr!bool rhs) {
            return new BinaryOpExpr!(bool, "||", bool)(this, rhs);
        }

        /// Logical OR with literal bool
        auto or(bool rhs) {
            return new BinaryOpExpr!(bool, "||", bool)(this, constant(rhs, this));
        }

        /// Logical NOT - negates this boolean expression
        auto not() {
            return new UnaryOpExpr!(bool, "!")(this);
        }
    }

    // Null checks - only available on Expr!(Nullable!T)
    static if (is(T == Nullable!U, U)) {
        /// Check if this nullable value is null
        auto isNull() {
            return new IsNullExpr!U(this);
        }

        /// Check if this nullable value is not null (convenience for isNull().not())
        auto isNotNull() {
            return isNull().not();
        }
    }

    // =========================================================================
    // String-specific Operations (only for Expr!string)
    // =========================================================================

    static if (is(T == string)) {
        /// Check if this string contains the given substring.
        /// Generates SQL LIKE '%pattern%' ESCAPE '\'.
        auto contains(string pattern) {
            return new LikeExpr(this, "%" ~ escapeLikePattern(pattern) ~ "%");
        }

        /// Check if this string contains the given substring expression.
        auto contains(Expr!string pattern) {
            return new LikePatternExpr(this, pattern, LikePatternType.contains);
        }

        /// Check if this string starts with the given prefix.
        /// Generates SQL LIKE 'pattern%' ESCAPE '\'.
        auto startsWith(string prefix) {
            return new LikeExpr(this, escapeLikePattern(prefix) ~ "%");
        }

        /// Check if this string starts with the given prefix expression.
        auto startsWith(Expr!string prefix) {
            return new LikePatternExpr(this, prefix, LikePatternType.startsWith);
        }

        /// Check if this string ends with the given suffix.
        /// Generates SQL LIKE '%pattern' ESCAPE '\'.
        auto endsWith(string suffix) {
            return new LikeExpr(this, "%" ~ escapeLikePattern(suffix));
        }

        /// Check if this string ends with the given suffix expression.
        auto endsWith(Expr!string suffix) {
            return new LikePatternExpr(this, suffix, LikePatternType.endsWith);
        }

        /// Check if this string contains the given substring (case-insensitive).
        /// Generates SQL ILIKE '%pattern%' (PostgreSQL) or LOWER() wrapper (MySQL/SQLite).
        auto containsInsensitive(string pattern) {
            return new LikeExpr(this, "%" ~ escapeLikePattern(pattern) ~ "%", true);
        }

        /// Check if this string starts with the given prefix (case-insensitive).
        /// Generates SQL ILIKE 'pattern%' (PostgreSQL) or LOWER() wrapper (MySQL/SQLite).
        auto startsWithInsensitive(string prefix) {
            return new LikeExpr(this, escapeLikePattern(prefix) ~ "%", true);
        }

        /// Check if this string ends with the given suffix (case-insensitive).
        /// Generates SQL ILIKE '%pattern' (PostgreSQL) or LOWER() wrapper (MySQL/SQLite).
        auto endsWithInsensitive(string suffix) {
            return new LikeExpr(this, "%" ~ escapeLikePattern(suffix), true);
        }
    }

    // =========================================================================
    // Field Access via opDispatch
    // =========================================================================

    /// Enable property-like field access when T has a callable member.
    /// Allows: `user.firstName` instead of `User.firstName(user)`
    ///
    /// Uses design-by-introspection: if T has a member `name` that can be
    /// called with `Expr!T`, forward to it. Works for any type, not just entities.
    auto opDispatch(string name)()
        if (__traits(hasMember, T, name) && __traits(compiles, __traits(getMember, T, name)(this)))
    {
        return __traits(getMember, T, name)(this);
    }

    /// Enable property-like field access with arguments.
    /// Allows: `user.greeting("Hello", "!")` instead of `User.greeting(user, "Hello", "!")`
    ///
    /// Arguments are passed as concrete values (available at planning time).
    auto opDispatch(string name, Args...)(Args args)
        if (Args.length > 0 &&
            __traits(hasMember, T, name) &&
            __traits(compiles, __traits(getMember, T, name)(this, args)))
    {
        return __traits(getMember, T, name)(this, args);
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

/// Expression that returns a single constant value (singleton).
/// Used for root-level values like Query/Mutation instances where there's no parent.
class SingletonExpr(T) : Expr!T {
    private T _value;

    this(T value) {
        _value = value;
    }

    override ExprBase[] dependencies() {
        return [];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        return resolve([_value]);
    }

    @property T value() { return _value; }
}

/// Create a singleton expression - a single constant value with no dependencies.
/// Used for root-level values like Query/Mutation type instances.
auto singleton(T)(T value) {
    return new SingletonExpr!T(value);
}

// ============================================================================
// Entity Cast Expression
// ============================================================================

/// Expression that casts between compatible entity/struct types.
/// Used by plugin infrastructure to forward fields between schema types.
///
/// For entity types (with nodeId): copies the nodeId to construct the target type.
/// For non-entity types (Query, Mutation): uses default-initialized value.
///
/// Implements AnyRefEvaluable when To is an entity type (has nodeId).
class EntityCastExpr(To, From) : Expr!To, AnyRefEvaluable {
    private Expr!From _source;

    this(Expr!From source) {
        _source = source;
    }

    override ExprBase[] dependencies() {
        return [_source];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) {
            _source = cast(Expr!From) newDep;
        }
    }

    override Promise!(To[]) eval(EvalContext ctx) {
        return _source.eval(ctx).then((From[] items) {
            To[] result = new To[items.length];
            foreach (i, ref from; items) {
                static if (__traits(hasMember, From, "nodeId") && __traits(hasMember, To, "nodeId")) {
                    // Entity types - copy nodeId
                    result[i] = To(from.nodeId.id);
                    // Copy all instance fields that exist in both types
                    // Skip internal members (starting with _) and system members
                    static foreach (member; __traits(allMembers, From)) {{
                        static if (member.length > 0 && member[0] != '_' &&
                                   member != "nodeId" &&
                                   member != "toString" &&
                                   member != "toHash" &&
                                   member != "opEquals" &&
                                   member != "opCmp" &&
                                   member != "opAssign" &&
                                   member != "factory" &&
                                   member != "Monitor" &&
                                   __traits(hasMember, To, member)) {
                            // Check if it's an instance field (not a method/type/etc)
                            static if (__traits(compiles, __traits(getMember, from, member)) &&
                                       __traits(compiles, __traits(getMember, result[i], member) = __traits(getMember, from, member))) {
                                __traits(getMember, result[i], member) = __traits(getMember, from, member);
                            }
                        }
                    }}
                } else static if (is(From == struct) && is(To == struct)) {
                    // POD types (structs without nodeId) - copy all matching fields
                    result[i] = To.init;
                    static foreach (member; __traits(allMembers, From)) {{
                        static if (member.length > 0 && member[0] != '_' &&
                                   member != "toString" &&
                                   member != "toHash" &&
                                   member != "opEquals" &&
                                   member != "opCmp" &&
                                   member != "opAssign" &&
                                   member != "factory" &&
                                   member != "Monitor" &&
                                   __traits(hasMember, To, member)) {
                            // Check if it's an instance field (not a method/type/etc)
                            static if (__traits(compiles, __traits(getMember, from, member)) &&
                                       __traits(compiles, __traits(getMember, result[i], member) = __traits(getMember, from, member))) {
                                __traits(getMember, result[i], member) = __traits(getMember, from, member);
                            }
                        }
                    }}
                } else {
                    // Non-struct types (Query, Mutation) - use default init
                    result[i] = To.init;
                }
            }
            return result;
        });
    }

    override Expr!To optimize(OptimizeContext ctx) {
        auto optimizedSource = _source.optimize(ctx);
        if (optimizedSource !is _source) {
            return new EntityCastExpr!(To, From)(optimizedSource);
        }
        return this;
    }

    /// Access the source expression
    @property Expr!From source() { return _source; }

    /// AnyRefEvaluable implementation - converts To entities to AnyRef
    Promise!(AnyRef[]) evalAsAnyRef(EvalContext ctx) {
        import std.algorithm : map;
        import std.array : array;
        import dynamo.core.types : AnyRef;

        static if (__traits(hasMember, To, "nodeId")) {
            // To is an entity type with nodeId - extract .id for AnyRef
            return eval(ctx).then((To[] results) {
                return results.map!(r => AnyRef(r.nodeId.id)).array;
            });
        } else {
            // Non-entity types can't be converted to AnyRef
            assert(false, "EntityCastExpr.evalAsAnyRef called on non-entity type");
        }
    }
}

/// Cast an expression from one entity/struct type to another compatible type.
/// Used by plugin infrastructure to forward fields between schema types.
auto entityCast(To, From)(Expr!From source) {
    return new EntityCastExpr!(To, From)(source);
}

// ============================================================================
// Field Access Expression (Eager Fields)
// ============================================================================

/// Expression that accesses a field on an entity struct.
/// This is a core concept - just reads from populated struct fields.
/// Used for "eager" fields that are populated when entities are fetched.
class FieldAccessExpr(Entity, string fieldName) : Expr!(typeof(__traits(getMember, Entity.init, fieldName))) {
    alias T = typeof(__traits(getMember, Entity.init, fieldName));
    private ExprBase _input;

    this(Expr!Entity input) {
        _input = input;
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        _input = (cast(Expr!Entity) _input).optimize(ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        return evalAs!Entity(_input, ctx).then((Entity[] entities) {
            T[] result;
            foreach (ref e; entities) {
                result ~= __traits(getMember, e, fieldName);
            }
            return result;
        });
    }

    /// Access the input expression
    @property ExprBase input() { return _input; }
}

/// Factory function for field access on entity structs.
/// Creates an expression that reads a populated struct field.
auto fieldAccess(string fieldName, Entity)(Expr!Entity input) {
    return new FieldAccessExpr!(Entity, fieldName)(input);
}

// ============================================================================
// Method Call Expression (Plain Methods)
// ============================================================================

/// Expression that calls an instance method on an entity struct.
/// Used for "plain methods" - instance methods that operate on populated entities.
/// Unlike computed fields, plain methods return concrete values (not Expr!T).
class MethodCallExpr(Entity, string methodName) : Expr!(ReturnType!(__traits(getMember, Entity, methodName))) {
    import std.traits : ReturnType;

    alias T = ReturnType!(__traits(getMember, Entity, methodName));
    private ExprBase _input;

    this(Expr!Entity input) {
        _input = input;
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        _input = (cast(Expr!Entity) _input).optimize(ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        return evalAs!Entity(_input, ctx).then((Entity[] entities) {
            T[] result;
            foreach (ref e; entities) {
                result ~= __traits(getMember, e, methodName)();
            }
            return result;
        });
    }

    /// Access the input expression
    @property ExprBase input() { return _input; }
}

/// Factory function for method call on entity structs.
/// Creates an expression that calls an instance method.
auto methodCall(string methodName, Entity)(Expr!Entity input) {
    return new MethodCallExpr!(Entity, methodName)(input);
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
// Unary Operation Expression
// ============================================================================

/// Interface for unary operation expressions - allows optimizer to inspect and transform
interface UnaryOpInfo {
    /// The operator ("!" for NOT, "-" for negation)
    string operator();

    /// Operand (type-erased)
    ExprBase operand();
}

/// Expression representing a unary operation (logical NOT, negation).
/// Can be evaluated in D or pushed down to SQL.
class UnaryOpExpr(T, string op) : Expr!(typeof(mixin(op ~ "T.init"))), UnaryOpInfo {
    alias ResultT = typeof(mixin(op ~ "T.init"));

    private ExprBase _operand;

    this(Expr!T operand) {
        _operand = operand;
    }

    override ExprBase[] dependencies() {
        return [_operand];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _operand = newDep;
    }

    override Expr!ResultT optimize(OptimizeContext ctx) {
        _operand = cast(ExprBase) (cast(Expr!T) _operand).optimize(ctx);
        return this;
    }

    override Promise!(ResultT[]) eval(EvalContext ctx) {
        auto operand = _operand;

        return evalAs!T(operand, ctx).then((T[] vals) {
            ResultT[] result = new ResultT[vals.length];
            foreach (i, v; vals) {
                result[i] = mixin(op ~ "v");
            }
            return result;
        });
    }

    /// Generate SQL expression for this operation
    string toSqlExpr(string operandSql) const {
        if (op == "!") return "(NOT " ~ operandSql ~ ")";
        return "(" ~ op ~ operandSql ~ ")";
    }

    // UnaryOpInfo implementation
    override string operator() { return op; }
    override ExprBase operand() { return _operand; }
}

// ============================================================================
// IsNull Expression
// ============================================================================

/// Interface for IsNull expression pattern matching by optimizers
interface IsNullInfo {
    /// The operand being checked for null (type-erased)
    ExprBase operand();
}

/// Expression that checks if a Nullable!T value is null.
/// Returns Expr!bool - true if the value is null, false otherwise.
class IsNullExpr(T) : Expr!bool, IsNullInfo {
    private ExprBase _operand;

    this(Expr!(Nullable!T) operand) {
        _operand = operand;
    }

    override ExprBase[] dependencies() {
        return [_operand];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _operand = newDep;
    }

    override Promise!(bool[]) eval(EvalContext ctx) {
        auto operand = _operand;

        return evalAs!(Nullable!T)(operand, ctx).then((Nullable!T[] vals) {
            bool[] result = new bool[vals.length];
            foreach (i, v; vals) {
                result[i] = v.isNull;
            }
            return result;
        });
    }

    // IsNullInfo implementation
    override ExprBase operand() { return _operand; }
}

// ============================================================================
// LIKE Pattern Expressions (for string filtering)
// ============================================================================

/// Escape special characters in a LIKE pattern for SQL safety.
/// Escapes: % → \%, _ → \_, \ → \\
/// This allows literal matching of these characters in contains/startsWith/endsWith.
string escapeLikePattern(string input) {
    import std.array : appender;

    auto result = appender!string();
    result.reserve(input.length * 2);  // Worst case: every char escaped

    foreach (c; input) {
        switch (c) {
            case '\\': result ~= `\\`; break;
            case '%':  result ~= `\%`; break;
            case '_':  result ~= `\_`; break;
            default:   result ~= c; break;
        }
    }
    return result[];
}

/// Unescape a LIKE pattern for in-memory string matching.
/// Reverses the escaping done by escapeLikePattern.
string unescapeLikePattern(string pattern) {
    import std.array : appender;

    auto result = appender!string();
    result.reserve(pattern.length);

    for (size_t i = 0; i < pattern.length; i++) {
        if (pattern[i] == '\\' && i + 1 < pattern.length) {
            char next = pattern[i + 1];
            if (next == '\\' || next == '%' || next == '_') {
                result ~= next;
                i++;  // Skip the escaped character
                continue;
            }
        }
        result ~= pattern[i];
    }
    return result[];
}

unittest {
    // Test escapeLikePattern
    assert(escapeLikePattern("hello") == "hello");
    assert(escapeLikePattern("100%") == `100\%`);
    assert(escapeLikePattern("a_b") == `a\_b`);
    assert(escapeLikePattern(`a\b`) == `a\\b`);
    assert(escapeLikePattern(`50% off_sale\today`) == `50\% off\_sale\\today`);

    // Test unescapeLikePattern
    assert(unescapeLikePattern("hello") == "hello");
    assert(unescapeLikePattern(`100\%`) == "100%");
    assert(unescapeLikePattern(`a\_b`) == "a_b");
    assert(unescapeLikePattern(`a\\b`) == `a\b`);
    assert(unescapeLikePattern(`50\% off\_sale\\today`) == `50% off_sale\today`);

    // Round-trip
    string[] testCases = ["hello", "100%", "a_b", `a\b`, `50% off_sale\today`, "", "%_%"];
    foreach (tc; testCases) {
        assert(unescapeLikePattern(escapeLikePattern(tc)) == tc,
            "Round-trip failed for: " ~ tc);
    }
}

/// Interface for LIKE expressions - allows optimizer to inspect and transform
interface LikeInfo {
    /// The string expression being matched
    ExprBase likeOperand();

    /// The LIKE pattern (with SQL wildcards % and _)
    string likePattern();

    /// Whether this is a case-insensitive match (ILIKE in PostgreSQL)
    bool caseInsensitive();
}

/// Type of dynamic LIKE pattern
enum LikePatternType {
    contains,    // %pattern%
    startsWith,  // pattern%
    endsWith     // %pattern
}

/// Interface for dynamic LIKE expressions where pattern is an expression
interface LikePatternInfo {
    /// The string expression being matched
    ExprBase likeOperand();

    /// The pattern expression
    ExprBase patternExpr();

    /// The pattern type (contains, startsWith, endsWith)
    LikePatternType patternType();
}

/// Expression for SQL LIKE with a static pattern.
/// Used for contains, startsWith, endsWith operations.
/// Set caseInsensitive=true for case-insensitive matching (ILIKE in PostgreSQL).
class LikeExpr : Expr!bool, LikeInfo {
    private ExprBase _operand;
    private string _pattern;
    private bool _caseInsensitive;

    this(Expr!string operand, string pattern, bool caseInsensitive = false) {
        _operand = operand;
        _pattern = pattern;
        _caseInsensitive = caseInsensitive;
    }

    override ExprBase[] dependencies() {
        return [_operand];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _operand = newDep;
    }

    override Promise!(bool[]) eval(EvalContext ctx) {
        import std.string : indexOf;
        import std.algorithm : startsWith, endsWith;
        import std.uni : toLower;

        auto operand = _operand;
        auto pattern = _pattern;
        auto caseInsens = _caseInsensitive;

        return evalAs!string(operand, ctx).then((string[] vals) {
            bool[] result = new bool[vals.length];

            debug(filter) {
                import std.stdio : writefln;
                writefln("    LikeExpr: pattern='%s', caseInsensitive=%s, vals=%s", pattern, caseInsens, vals);
            }

            // Parse pattern to determine match type
            bool startsWild = pattern.length > 0 && pattern[0] == '%';
            bool endsWild = pattern.length > 0 && pattern[$-1] == '%';

            string searchStr;
            if (startsWild && endsWild && pattern.length >= 2) {
                // %pattern% - contains
                searchStr = unescapeLikePattern(pattern[1..$-1]);
                if (caseInsens) searchStr = toLower(searchStr);
                foreach (i, v; vals) {
                    string val = caseInsens ? toLower(v) : v;
                    result[i] = val.indexOf(searchStr) >= 0;
                }
            } else if (startsWild) {
                // %pattern - endsWith
                searchStr = unescapeLikePattern(pattern[1..$]);
                if (caseInsens) searchStr = toLower(searchStr);
                foreach (i, v; vals) {
                    string val = caseInsens ? toLower(v) : v;
                    result[i] = val.endsWith(searchStr);
                }
            } else if (endsWild) {
                // pattern% - startsWith
                searchStr = unescapeLikePattern(pattern[0..$-1]);
                if (caseInsens) searchStr = toLower(searchStr);
                foreach (i, v; vals) {
                    string val = caseInsens ? toLower(v) : v;
                    result[i] = val.startsWith(searchStr);
                }
            } else {
                // Exact match
                searchStr = unescapeLikePattern(pattern);
                if (caseInsens) searchStr = toLower(searchStr);
                foreach (i, v; vals) {
                    string val = caseInsens ? toLower(v) : v;
                    result[i] = val == searchStr;
                }
            }

            debug(filter) {
                import std.stdio : writefln;
                writefln("    LikeExpr result: %s", result);
            }

            return result;
        });
    }

    // LikeInfo implementation
    override ExprBase likeOperand() { return _operand; }
    override string likePattern() { return _pattern; }
    override bool caseInsensitive() { return _caseInsensitive; }
}

/// Expression for SQL LIKE with a dynamic pattern expression.
class LikePatternExpr : Expr!bool, LikePatternInfo {
    private ExprBase _operand;
    private ExprBase _pattern;
    private LikePatternType _patternType;

    this(Expr!string operand, Expr!string pattern, LikePatternType patternType) {
        _operand = operand;
        _pattern = pattern;
        _patternType = patternType;
    }

    override ExprBase[] dependencies() {
        return [_operand, _pattern];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _operand = newDep;
        else if (index == 1)
            _pattern = newDep;
    }

    override Promise!(bool[]) eval(EvalContext ctx) {
        import std.string : indexOf;
        import std.algorithm : startsWith, endsWith;

        auto operand = _operand;
        auto pattern = _pattern;
        auto patternType = _patternType;

        return evalAs!string(operand, ctx).then((string[] vals) {
            return evalAs!string(pattern, ctx).then((string[] patterns) {
                bool[] result = new bool[vals.length];
                foreach (i, v; vals) {
                    string p = i < patterns.length ? patterns[i] : (patterns.length > 0 ? patterns[0] : "");
                    final switch (patternType) {
                        case LikePatternType.contains:
                            result[i] = v.indexOf(p) >= 0;
                            break;
                        case LikePatternType.startsWith:
                            result[i] = v.startsWith(p);
                            break;
                        case LikePatternType.endsWith:
                            result[i] = v.endsWith(p);
                            break;
                    }
                }
                return result;
            });
        });
    }

    // LikePatternInfo implementation
    override ExprBase likeOperand() { return _operand; }
    override ExprBase patternExpr() { return _pattern; }
    override LikePatternType patternType() { return _patternType; }
}

// ============================================================================
// Ternary (Conditional) Expression
// ============================================================================

/// Interface for ternary (conditional) expressions - allows optimizer to inspect and transform
interface TernaryInfo {
    /// Condition expression (type-erased, returns bool)
    ExprBase condition();

    /// Expression evaluated when condition is true (type-erased)
    ExprBase trueExpr();

    /// Expression evaluated when condition is false (type-erased)
    ExprBase falseExpr();
}

/// Expression representing a ternary/conditional operation.
/// Evaluates to trueExpr when condition is true, falseExpr otherwise.
/// SQL: CASE WHEN condition THEN trueVal ELSE falseVal END
class TernaryExpr(T) : Expr!T, TernaryInfo {
    private ExprBase _condition;
    private ExprBase _trueExpr;
    private ExprBase _falseExpr;

    this(Expr!bool condition, Expr!T trueExpr, Expr!T falseExpr) {
        _condition = condition;
        _trueExpr = trueExpr;
        _falseExpr = falseExpr;
    }

    override ExprBase[] dependencies() {
        return [_condition, _trueExpr, _falseExpr];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _condition = newDep;
        else if (index == 1)
            _trueExpr = newDep;
        else if (index == 2)
            _falseExpr = newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        _condition = cast(ExprBase) (cast(Expr!bool) _condition).optimize(ctx);
        _trueExpr = cast(ExprBase) (cast(Expr!T) _trueExpr).optimize(ctx);
        _falseExpr = cast(ExprBase) (cast(Expr!T) _falseExpr).optimize(ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto condition = _condition;
        auto trueExpr = _trueExpr;
        auto falseExpr = _falseExpr;

        // Evaluate all three expressions, then combine based on condition
        return evalAs!bool(condition, ctx).then((bool[] conds) {
            return evalAs!T(trueExpr, ctx).then((T[] trueVals) {
                return evalAs!T(falseExpr, ctx).then((T[] falseVals) {
                    T[] result = new T[conds.length];
                    foreach (i, c; conds) {
                        result[i] = c ? trueVals[i] : falseVals[i];
                    }
                    return result;
                });
            });
        });
    }

    // TernaryInfo implementation
    override ExprBase condition() { return _condition; }
    override ExprBase trueExpr() { return _trueExpr; }
    override ExprBase falseExpr() { return _falseExpr; }
}

/// Create a ternary conditional expression.
/// Returns trueVal when condition is true, falseVal otherwise.
auto ternary(T)(Expr!bool condition, Expr!T trueVal, Expr!T falseVal) {
    return new TernaryExpr!T(condition, trueVal, falseVal);
}

/// Ternary with literal true value
auto ternary(T)(Expr!bool condition, T trueVal, Expr!T falseVal)
    if (!is(T : Expr!U, U))
{
    return new TernaryExpr!T(condition, constant(trueVal, condition), falseVal);
}

/// Ternary with literal false value
auto ternary(T)(Expr!bool condition, Expr!T trueVal, T falseVal)
    if (!is(T : Expr!U, U))
{
    return new TernaryExpr!T(condition, trueVal, constant(falseVal, condition));
}

/// Ternary with both literal values
auto ternary(T)(Expr!bool condition, T trueVal, T falseVal)
    if (!is(T : Expr!U, U))
{
    return new TernaryExpr!T(condition, constant(trueVal, condition), constant(falseVal, condition));
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
// EffectExpr: Deferred Side Effects
// ============================================================================

/// Expression that executes a side-effecting callable during evaluation.
/// Used for mutations and other operations that should be deferred.
/// The callable is called once per evaluation, regardless of batch size.
/// Implements AnyRefEvaluable when T is an entity type (has nodeId).
class EffectExpr(T, Fn) : Expr!T, AnyRefEvaluable {
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

    /// AnyRefEvaluable implementation - converts T to AnyRef
    Promise!(AnyRef[]) evalAsAnyRef(EvalContext ctx) {
        import std.algorithm : map;
        import std.array : array;

        static if (__traits(hasMember, T, "nodeId")) {
            // T is an entity type with nodeId - extract .id for AnyRef
            return eval(ctx).then((T[] results) {
                return results.map!(r => AnyRef(r.nodeId.id)).array;
            });
        } else static if (is(T == AnyRef)) {
            return eval(ctx);
        } else {
            // Non-entity types can't be converted to AnyRef
            // This should not be called for such types
            return resolve(cast(AnyRef[])[]);
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
/// Extends AnyRefEvaluable for type-agnostic evaluation.
interface EveryItemOfExprInfo : AnyRefEvaluable {
    /// Get the parent MapExpr (as Object)
    @property Object parentMap();
}

/// Check if a type is an entity (has nodeId from Entity mixin).
private template isEntityType(T) {
    enum isEntityType = __traits(hasMember, T, "nodeId");
}

/// Placeholder representing "current item" within a map iteration.
/// When MapExpr evaluates its body, it passes the flattened collection refs.
/// EveryItemOfExpr just returns those refs unchanged - it's a pass-through
/// that represents "the items being iterated over".
///
/// Typed with the Entity being iterated. Returns Entity with nodeId populated.
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
        import std.algorithm : map;
        static if (is(T == void)) {
            static assert(false, "EveryItemOfExpr!void should not be evaluated directly");
        } else static if (isEntityType!T) {
            // First try to get populated entities (preserves field data for naive mode)
            auto entities = ctx.getCurrentEntities!T(_parentMap);
            if (entities.length > 0) {
                return resolve(entities);
            }

            // Fallback to ref-based reconstruction (for optimized mode or when entities not stored)
            auto refs = ctx.getCurrentRefs(_parentMap);
            if (refs.length > 0) {
                return resolve(refs.map!(r => T(r.nodeId)).array);
            }
            auto singleRef = ctx.getPredicateItem(_parentMap);
            if (singleRef.isValid) {
                return resolve([T(singleRef.nodeId)]);
            }
            return resolve(cast(T[])[]);
        } else {
            // Scalar path - use typed SealedArray/SealedValue storage
            auto vals = ctx.getScalarRefs!T(_parentMap);
            if (vals.length > 0) {
                return resolve(vals);
            }
            if (ctx.hasScalarItem(_parentMap)) {
                return resolve([ctx.getScalarItem!T(_parentMap)]);
            }
            return resolve(cast(T[])[]);
        }
    }

    /// Evaluate and return as AnyRef[] (for type-agnostic internal use).
    /// Only valid for entity types.
    Promise!(AnyRef[]) evalAsAnyRef(EvalContext ctx) {
        static if (isEntityType!T) {
            auto refs = ctx.getCurrentRefs(_parentMap);
            if (refs.length > 0) {
                return resolve(refs);
            }
            auto singleRef = ctx.getPredicateItem(_parentMap);
            if (singleRef.isValid) {
                return resolve([singleRef]);
            }
        }
        return resolve(cast(AnyRef[])[]);
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
            AnyRef[] flatRefs;
            size_t[] lengths;
            foreach (group; collectionResults) {
                lengths ~= group.length;
                foreach (e; group) {
                    flatEntities ~= e;
                    flatRefs ~= AnyRef(e.nodeId.id);
                }
            }

            if (flatEntities.length == 0) {
                // No items to process - return empty array for each parent
                return resolve(std.algorithm.map!(_ => cast(R[])[])(iota(collectionResults.length)).array);
            }

            // 3. Set current entities AND refs for this MapExpr
            // Entities are stored for naive mode (preserves populated fields)
            // Refs are stored for backward compatibility with evalRefAsAnyRef
            ctx.setCurrentEntities!Entity(self, flatEntities);
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

/// Extract the Entity type from an Expr!(Entity[]) type
private template CollectionEntityType(Coll) {
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
// SomeExpr/EveryExpr: Collection Predicate Expressions
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

    /// true for every(), false for some()
    bool isEvery();
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

            // Store items based on type (entity vs scalar)
            static if (isEntityType!Entity) {
                // Entity path - use AnyRef storage
                AnyRef[] flatRefs;
                flatRefs.reserve(totalItems);
                foreach (group; collectionResults) {
                    foreach (e; group) {
                        flatRefs ~= AnyRef(e.nodeId.id);
                    }
                }
                debug(filter) {
                    import std.stdio : writefln;
                    import std.algorithm : map;
                    import std.array : array;
                    writefln("  SomeExpr.eval: %d groups, %d total items", collectionResults.length, flatRefs.length);
                    writefln("    groupLengths=%s, flatRefs=%s", groupLengths, flatRefs.map!(r => r.nodeId).array);
                }
                ctx.setCurrentRefs(self, flatRefs);
            } else {
                // Scalar path - use typed storage (no JSON serialization)
                Entity[] flatVals;
                flatVals.reserve(totalItems);
                foreach (group; collectionResults) {
                    foreach (v; group) {
                        flatVals ~= v;
                    }
                }
                debug(filter) {
                    import std.stdio : writefln;
                    writefln("  SomeExpr.eval (scalar): %d groups, %d total items", collectionResults.length, flatVals.length);
                }
                ctx.setScalarRefs(self, flatVals);
            }

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
    bool isEvery() { return false; }
}

/// Expression: returns true if ALL items in collection satisfy predicate.
/// Similar to JavaScript's Array.every() or SQL NOT EXISTS (... WHERE NOT ...).
///
/// Example:
///   every!((Expr!Post p) => p.isPublished)(user.posts)
///   // Returns true if all of user's posts are published
class EveryExpr(Entity, Body) : Expr!bool, CollectionPredicateInfo
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
                results[] = true;  // every() on empty = true (vacuous truth)
                return resolve(results);
            }

            // Store items based on type (entity vs scalar)
            static if (isEntityType!Entity) {
                // Entity path - use AnyRef storage
                AnyRef[] flatRefs;
                flatRefs.reserve(totalItems);
                foreach (group; collectionResults) {
                    foreach (e; group) {
                        flatRefs ~= AnyRef(e.nodeId.id);
                    }
                }
                ctx.setCurrentRefs(self, flatRefs);
            } else {
                // Scalar path - use typed storage (no JSON serialization)
                Entity[] flatVals;
                flatVals.reserve(totalItems);
                foreach (group; collectionResults) {
                    foreach (v; group) {
                        flatVals ~= v;
                    }
                }
                ctx.setScalarRefs(self, flatVals);
            }

            // Evaluate predicate for all items in batch
            return evalAs!bool(predicate, ctx).then((bool[] predicateResults) {
                // Reduce flat results back to per-group booleans
                bool[] results;
                results.length = groupLengths.length;

                size_t offset = 0;
                foreach (i, len; groupLengths) {
                    // Empty group: every() returns true (vacuous truth)
                    bool allTrue = true;
                    foreach (j; 0 .. len) {
                        if (!predicateResults[offset + j]) {
                            allTrue = false;
                            break;
                        }
                    }
                    results[i] = allTrue;
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
    bool isEvery() { return true; }
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
///
/// Example:
/// ---
/// auto allPublished = every!((Expr!Post p) => p.isPublished)(user.posts);
/// ---
auto every(alias pred, Coll)(Coll collection)
    if (is(Coll : Expr!(E[]), E))
{
    alias Entity = CollectionEntityType!Coll;

    // Create placeholder
    auto item = new EveryItemOfExpr!Entity();

    // Build predicate using placeholder
    auto predicate = pred(item);
    static assert(is(typeof(predicate) : Expr!bool),
        "every() predicate must return Expr!bool, got " ~ typeof(predicate).stringof);

    // Create EveryExpr and link
    auto expr = new EveryExpr!(Entity, typeof(predicate))(collection, item, predicate);
    item._parentMap = expr;  // Reuse _parentMap for predicate item lookup

    return expr;
}


// ============================================================================
// jsonObject Combinator (JSON construction)
// ============================================================================

/// Convert a D value to JSONValue
JSONValue toJsonValue(T)(T value) {
    import dynamo.core.types : isCustomScalar;
    import std.typecons : Nullable;

    static if (is(T == JSONValue)) {
        return value;
    } else static if (isCustomScalar!T) {
        // CustomScalar has its own toJson method
        return T.toJson(value.value);
    } else static if (is(T == Nullable!U, U)) {
        // Nullable types - return JSON null if null, otherwise convert inner value
        if (value.isNull) {
            return JSONValue(null);
        } else {
            return toJsonValue(value.get);
        }
    } else static if (is(T == enum)) {
        // D enum - convert to string using member name
        import std.conv : to;
        return JSONValue(value.to!string);
    } else static if (is(T == string)) {
        return JSONValue(value);
    } else static if (is(T == bool)) {
        return JSONValue(value);
    } else static if (isIntegral!T) {
        return JSONValue(value);
    } else static if (isFloatingPoint!T) {
        return JSONValue(value);
    } else static if (is(T == AnyRef)) {
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

/// Dynamic JSON object expression for runtime-determined field names.
/// Used by the GraphQL compiler when field names are only known at runtime.
///
/// This expression evaluates each field and converts results to JSON.
/// Field expressions can return any type - they're converted via toJsonValue.
class DynamicJsonObjectExpr : Expr!JSONValue {
    private string[] _names;
    private ExprBase[] _exprs;

    this(string[] names, ExprBase[] exprs) {
        assert(names.length == exprs.length, "Names and exprs must have same length");
        _names = names;
        _exprs = exprs;
    }

    override ExprBase[] dependencies() {
        return _exprs.dup;
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index < _exprs.length) {
            _exprs[index] = newDep;
        }
    }

    override Expr!JSONValue optimize(OptimizeContext ctx) {
        // Optimize all field expressions by calling their typed optimize
        foreach (ref expr; _exprs) {
            expr = optimizeExpr(expr, ctx);
        }
        return this;
    }

    override Promise!(JSONValue[]) eval(EvalContext ctx) {
        // Evaluate all field expressions and convert to JSON
        Promise!(JSONValue[])[] promises;
        foreach (expr; _exprs) {
            promises ~= evalToJson(expr, ctx);
        }

        auto names = _names;

        return all(promises).then((JSONValue[][] results) {
            // All field results should have the same length
            auto count = results.length > 0 ? results[0].length : 0;

            JSONValue[] jsonResults = new JSONValue[count];
            foreach (idx; 0 .. count) {
                jsonResults[idx] = JSONValue.emptyObject;
                foreach (i, name; names) {
                    jsonResults[idx][name] = results[i][idx];
                }
            }
            return jsonResults;
        });
    }
}

/// JSON object expression that evaluates fields sequentially (for mutations).
/// Unlike DynamicJsonObjectExpr which evaluates in parallel, this ensures
/// each field completes before the next starts - required for mutation semantics.
class SequentialJsonObjectExpr : Expr!JSONValue {
    private string[] _names;
    private ExprBase[] _exprs;

    this(string[] names, ExprBase[] exprs) {
        assert(names.length == exprs.length, "Names and exprs must have same length");
        _names = names;
        _exprs = exprs;
    }

    override ExprBase[] dependencies() {
        return _exprs.dup;
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index < _exprs.length) {
            _exprs[index] = newDep;
        }
    }

    override Expr!JSONValue optimize(OptimizeContext ctx) {
        foreach (ref expr; _exprs) {
            expr = optimizeExpr(expr, ctx);
        }
        return this;
    }

    override Promise!(JSONValue[]) eval(EvalContext ctx) {
        // Evaluate fields sequentially using recursive helper
        // (avoids D's closure variable capture issues with foreach loops)
        auto result = JSONValue.emptyObject;
        return evalFieldsSequentially(ctx, 0, result);
    }

    private Promise!(JSONValue[]) evalFieldsSequentially(EvalContext ctx, size_t idx, JSONValue result) {
        if (idx >= _exprs.length) {
            return resolve([result]);
        }

        auto fieldName = _names[idx];
        auto fieldExpr = _exprs[idx];

        return evalToJson(fieldExpr, ctx).then((JSONValue[] fieldVals) {
            result[fieldName] = fieldVals[0];
            return evalFieldsSequentially(ctx, idx + 1, result);
        });
    }
}

/// Optimize an ExprBase by dispatching to common result types.
private ExprBase optimizeExpr(ExprBase expr, OptimizeContext ctx) {
    // Try common types
    if (auto e = cast(Expr!string) expr) return e.optimize(ctx);
    if (auto e = cast(Expr!long) expr) return e.optimize(ctx);
    if (auto e = cast(Expr!bool) expr) return e.optimize(ctx);
    if (auto e = cast(Expr!double) expr) return e.optimize(ctx);
    if (auto e = cast(Expr!JSONValue) expr) return e.optimize(ctx);
    if (auto e = cast(Expr!(JSONValue[])) expr) return e.optimize(ctx);
    if (auto e = cast(Expr!(AnyRef[])) expr) return e.optimize(ctx);
    // Fallback - return as-is
    return expr;
}

/// Evaluate an expression and convert its result to JSONValue[].
private Promise!(JSONValue[]) evalToJson(ExprBase expr, EvalContext ctx) {
    import std.algorithm : stdMap = map;
    import std.array : array;

    // Try common types and convert to JSON
    if (auto e = cast(Expr!string) expr) {
        return e.eval(ctx).then((string[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) result[i] = JSONValue(v);
            return result;
        });
    }
    if (auto e = cast(Expr!long) expr) {
        return e.eval(ctx).then((long[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) result[i] = JSONValue(v);
            return result;
        });
    }
    if (auto e = cast(Expr!bool) expr) {
        return e.eval(ctx).then((bool[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) result[i] = JSONValue(v);
            return result;
        });
    }
    if (auto e = cast(Expr!double) expr) {
        return e.eval(ctx).then((double[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) result[i] = JSONValue(v);
            return result;
        });
    }
    if (auto e = cast(Expr!JSONValue) expr) {
        return e.eval(ctx);
    }
    if (auto e = cast(Expr!(JSONValue[])) expr) {
        return e.eval(ctx).then((JSONValue[][] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) result[i] = JSONValue(v);
            return result;
        });
    }

    // Fallback - return null values
    return resolve(cast(JSONValue[]) null);
}

// ============================================================================
// Tests
// ============================================================================

import ae.utils.promise.await : awaitSync;

/// Minimal EntityRef for testing (no db alias needed)
private struct TestEntityRef(string _typeName) {
    import std.string : indexOf;

    enum typeName = _typeName;
    string id;
    this(string id) { this.id = id; }
    string toString() const { return id; }

    string localId() const {
        auto sep = id.indexOf(':');
        return sep >= 0 ? id[sep + 1 .. $] : "";
    }
}

/// Dummy entity type for tests (with Entity-like structure)
private struct TestEntity {
    import std.string : indexOf;

    TestEntityRef!"Test" nodeId;
    this(string id) { nodeId = typeof(nodeId)(id); }
    string toString() const { return nodeId.toString(); }

    string localId() const { return nodeId.localId(); }

    // Runtime typeName extraction (from nodeId string, not compile-time)
    string typeName() const {
        auto sep = nodeId.id.indexOf(':');
        return sep >= 0 ? nodeId.id[0 .. sep] : nodeId.id;
    }
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
    // Test map with use combinator - extracts node IDs
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("Test:1"), TestEntity("Test:2")]);

    auto query = map!(
        (Expr!TestEntity item) => use((TestEntity e) => e.nodeId.id, item)
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["Test:1", "Test:2"]);
}

unittest {
    // Test map with jsonObject - builds structured output
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("User:1"), TestEntity("User:2")]);

    auto query = map!(
        (Expr!TestEntity item) => jsonObject(
            "id", use((TestEntity e) => e.nodeId.id, item),
            "type", use((TestEntity e) => e.typeName, item)
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
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("Test:1"), TestEntity("Test:2")]);

    auto query = map!(
        (Expr!TestEntity item) => use((TestEntity e) => e.typeName, item) ~ ":" ~ use((TestEntity e) => e.nodeId.id, item)
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
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("Test:1"), TestEntity("Test:2"), TestEntity("Test:3")]);

    auto query = map!(
        (Expr!TestEntity item) {
            // Use localId parsed to int for arithmetic test
            auto id = use((TestEntity e) => e.localId.to!long, item);
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
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("Test:5"), TestEntity("Test:10"), TestEntity("Test:15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.localId.to!long, item);
            return val.gt(7);  // 5 > 7 = false, 10 > 7 = true, 15 > 7 = true
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [false, true, true]);
}

unittest {
    import std.conv : to;

    // Test boolean AND operator
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("Test:5"), TestEntity("Test:10"), TestEntity("Test:15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.localId.to!long, item);
            return val.gt(5).and(val.lt(15));  // 5>5 && 5<15 = false, 10>5 && 10<15 = true, 15>5 && 15<15 = false
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [false, true, false]);
}

unittest {
    import std.conv : to;

    // Test boolean OR operator
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("Test:5"), TestEntity("Test:10"), TestEntity("Test:15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.localId.to!long, item);
            return val.lt(8).or(val.gt(12));  // 5<8 || 5>12 = true, 10<8 || 10>12 = false, 15<8 || 15>12 = true
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [true, false, true]);
}

unittest {
    import std.conv : to;

    // Test boolean NOT operator
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("Test:5"), TestEntity("Test:10"), TestEntity("Test:15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.localId.to!long, item);
            return val.gt(8).not();  // !(5>8) = true, !(10>8) = false, !(15>8) = false
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [true, false, false]);
}

unittest {
    import std.conv : to;

    // Test ternary expression
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("Test:5"), TestEntity("Test:15"), TestEntity("Test:25")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.localId.to!long, item);
            return ternary(val.ge(18), "adult", "minor");  // 5>=18 ? adult : minor, etc.
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["minor", "minor", "adult"]);
}

unittest {
    import std.conv : to;

    // Test nested ternary expression (chained conditions)
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("Test:5"), TestEntity("Test:15"), TestEntity("Test:25")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.localId.to!long, item);
            // age < 13 -> "child", age < 20 -> "teen", else "adult"
            return ternary(val.lt(13), "child", ternary(val.lt(20), "teen", "adult"));
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["child", "teen", "adult"]);
}

unittest {
    import std.conv : to;

    // Test combined boolean operators: (a AND b) OR c
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("Test:5"), TestEntity("Test:10"), TestEntity("Test:20")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.localId.to!long, item);
            // (val > 5 AND val < 15) OR val > 18
            // 5: (false AND true) OR false = false
            // 10: (true AND true) OR false = true
            // 20: (true AND false) OR true = true
            return val.gt(5).and(val.lt(15)).or(val.gt(18));
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setCurrentRefs(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [false, true, true]);
}

// ============================================================================
// Nullable Object Expression
// ============================================================================

/// Expression that handles nullable object types for selection sets.
/// For null values, returns JSON null; for non-null values, evaluates the inner expression.
///
/// This is used for nullable BelongsTo relationships where the FK can be null.
/// The selection set is compiled against the UnwrapNullableExpr, which forwards
/// to the actual nullable input during optimization so the chain can be traversed.
class NullableObjectExpr(T) : Expr!JSONValue {
    private ExprBase _nullableInput;  // Expr!(Nullable!T)
    private ExprBase _innerExpr;      // Expr!JSONValue (selection set compiled for T)
    private UnwrapNullableExpr!T _unwrapper;  // Projects Nullable!T -> T

    this(Expr!(Nullable!T) nullableInput, Expr!JSONValue innerExpr, UnwrapNullableExpr!T unwrapper) {
        _nullableInput = nullableInput;
        _innerExpr = innerExpr;
        _unwrapper = unwrapper;
    }

    override ExprBase[] dependencies() {
        return [_nullableInput, _innerExpr];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _nullableInput = newDep;
        else if (index == 1) _innerExpr = newDep;
    }

    override Expr!JSONValue optimize(OptimizeContext ctx) {
        _nullableInput = optimizeExpr(_nullableInput, ctx);
        _innerExpr = (cast(Expr!JSONValue) _innerExpr).optimize(ctx);
        return this;
    }

    override Promise!(JSONValue[]) eval(EvalContext ctx) {
        auto innerExpr = _innerExpr;
        auto unwrapper = _unwrapper;

        // Evaluate the nullable input to know which indices are null
        return evalAs!(Nullable!T)(_nullableInput, ctx).then((Nullable!T[] nullableVals) {
            // If all are null, return null JSONValues without evaluating inner
            bool anyNonNull = false;
            foreach (nval; nullableVals) {
                if (!nval.isNull) {
                    anyNonNull = true;
                    break;
                }
            }
            if (!anyNonNull) {
                JSONValue[] result = new JSONValue[nullableVals.length];
                foreach (ref r; result) r = JSONValue(null);
                return resolve(result);
            }

            // Set unwrapper values for ALL entities (using T.init for nulls)
            // The inner expression (ProjectJoinedColumnExpr) doesn't actually use
            // the unwrapper values - it uses the parent refs from baseInput.
            // But we set values in case any expression needs them.
            T[] allVals;
            allVals.length = nullableVals.length;
            foreach (i, nval; nullableVals) {
                if (!nval.isNull) {
                    allVals[i] = nval.get;
                }
                // else: keep T.init
            }
            unwrapper.setValues(allVals);

            // Evaluate inner expression for ALL entities
            // The optimized ProjectJoinedColumnExpr uses parent refs (e.g., Task refs)
            // and returns values for all of them (null/empty for null FK rows)
            return evalAs!JSONValue(innerExpr, ctx).then((JSONValue[] innerResults) {
                // Mask results: return JSON null where FK is null
                JSONValue[] result = new JSONValue[nullableVals.length];
                foreach (i, nval; nullableVals) {
                    if (nval.isNull) {
                        result[i] = JSONValue(null);
                    } else {
                        result[i] = innerResults[i];
                    }
                }
                return result;
            });
        });
    }
}

/// Helper expression that unwraps Nullable!T to T for selection set compilation.
/// This expression forwards to its nullable input during optimization so the
/// chain traversal (findMapExprFromChain) can reach the BelongsToAccessExpr.
///
/// At evaluation time, it returns values set by NullableObjectExpr.
/// For entity types (those with nodeId), also implements AnyRefEvaluable to
/// provide refs for projection expressions inside nullable selection sets.
class UnwrapNullableExpr(T) : Expr!T, UnwrapNullableInfo, AnyRefEvaluable {
    private ExprBase _nullableInput;  // The actual Expr!(Nullable!T) to forward to
    private T[] _values;  // Set by NullableObjectExpr during eval

    this(Expr!(Nullable!T) nullableInput) {
        _nullableInput = nullableInput;
    }

    void setValues(T[] values) {
        _values = values;
    }

    override ExprBase[] dependencies() {
        return [_nullableInput];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _nullableInput = newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        _nullableInput = optimizeExpr(_nullableInput, ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        return resolve(_values);
    }

    // UnwrapNullableInfo implementation - allows chain traversal to continue
    @property ExprBase inputExpr() { return _nullableInput; }

    // AnyRefEvaluable implementation - returns refs from stored entity values
    // This allows ProjectJoinedColumnExpr to get the filtered non-null refs
    Promise!(AnyRef[]) evalAsAnyRef(EvalContext ctx) {
        import dynamo.core.types : AnyRef;
        // For entity types, extract refs from nodeId
        static if (is(typeof(T.init.nodeId))) {
            return resolve(std.algorithm.map!(v => AnyRef(v.nodeId.id))(_values).array);
        } else {
            // Non-entity types - should not reach here for BelongsTo usage
            assert(false, "UnwrapNullableExpr.evalAsAnyRef called for non-entity type " ~ T.stringof);
        }
    }
}

/// Interface for UnwrapNullableExpr to allow chain traversal during optimization.
/// This lets findMapExprFromChain continue through nullable wrappers.
interface UnwrapNullableInfo {
    @property ExprBase inputExpr();
}

/// Finalize a nullable object expression after the selection set has been compiled.
NullableObjectExpr!T finalizeNullableObjectExpr(T)(
    Expr!(Nullable!T) nullableInput,
    UnwrapNullableExpr!T unwrapper,
    Expr!JSONValue innerExpr
) {
    return new NullableObjectExpr!T(nullableInput, innerExpr, unwrapper);
}
