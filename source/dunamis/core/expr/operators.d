module dunamis.core.expr.operators;

import std.typecons : Nullable;

import ae.utils.promise;

import dunamis.core.eval;
import dunamis.core.optimize;
import dunamis.core.expr.base;
import dunamis.core.join : joinAll;

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

        // Evaluate both operands in parallel, then combine
        return joinAll(evalAs!L(left, ctx), evalAs!R(right, ctx))
            .dmd21804workaround
            .then((results) {
                auto lefts = results[0];
                auto rights = results[1];
                auto count = lefts.length;
                ResultT[] result = new ResultT[count];
                foreach (i; 0 .. count) {
                    result[i] = mixin("lefts[i] " ~ op ~ " rights[i]");
                }
                return result;
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
// Membership Expression
// ============================================================================

/// Interface for membership expressions (`isAmong`) - allows optimizers to
/// render them, e.g. as `operand = ANY(<array>)` in SQL.
interface MembershipInfo {
    /// The operand whose values are looked up (type-erased)
    ExprBase operand();

    /// The type of the values
    TypeInfo valueType();

    /// The values (as ConstantInfo.valueAsString represents them), in order
    string[] valuesAsStrings();
}

/// Expression which is true for the values of an operand that are among a
/// list of values (constant data, fixed when the expression is built).
class IsAmongExpr(T) : Expr!bool, MembershipInfo {
    private ExprBase _operand;
    private const(T)[] _values;

    this(Expr!T operand, const(T)[] values) {
        _operand = operand;
        _values = values.dup;
    }

    override ExprBase[] dependencies() {
        return [_operand];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _operand = newDep;
    }

    override Expr!bool optimize(OptimizeContext ctx) {
        _operand = cast(ExprBase) (cast(Expr!T) _operand).optimize(ctx);
        return this;
    }

    override Promise!(bool[]) eval(EvalContext ctx) {
        auto values = _values;
        return evalAs!T(_operand, ctx).then((T[] vals) {
            bool[] result = new bool[vals.length];
            static if (__traits(compiles, { bool[T] set; set[T.init] = true; })) {
                bool[T] set;
                foreach (v; values)
                    set[v] = true;
                foreach (i, v; vals)
                    result[i] = (v in set) !is null;
            } else {
                import std.algorithm.searching : canFind;
                foreach (i, v; vals)
                    result[i] = values.canFind(v);
            }
            return result;
        });
    }

    // MembershipInfo implementation
    override ExprBase operand() { return _operand; }
    override TypeInfo valueType() { return typeid(T); }
    override string[] valuesAsStrings() {
        import dunamis.core.expr.primitives : constantValueString;
        string[] strings;
        foreach (v; _values)
            strings ~= constantValueString(v);
        return strings;
    }
}

/// Whether each value of `operand` is among `values` (constant data). Data
/// sources can evaluate this where the operand is (e.g. as SQL
/// `operand = ANY(...)` in a WHERE clause), unlike a chain of `||`-ed
/// equalities or an opaque function.
Expr!bool isAmong(T)(Expr!T operand, const(T)[] values) {
    return new IsAmongExpr!T(operand, values);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    static class Values(T) : Expr!T {
        T[] values;
        this(T[] values) { this.values = values; }
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}
        override Promise!(T[]) eval(EvalContext ctx) { return resolve(values); }
    }
    auto ctx = new EvalContext();
    assert(isAmong(new Values!int([1, 2, 3, 4]), [4, 2]).eval(ctx).awaitSync == [false, true, false, true]);
    assert(isAmong(new Values!int([1]), cast(int[]) null).eval(ctx).awaitSync == [false]);
    auto names = isAmong(new Values!string(["a", "b"]), ["b", "c"]);
    assert(names.eval(ctx).awaitSync == [false, true]);
    auto info = cast(MembershipInfo) names;
    assert(info.valueType == typeid(string) && info.valuesAsStrings == ["b", "c"]);
}

// ============================================================================
// Array Predicate Expressions
// ============================================================================

/// A predicate on arrays (e.g. array columns) and constant operands, with
/// PostgreSQL's array operators' semantics (null elements match nothing).
enum ArrayPredicate {
    /// The array contains all the operand's elements (`array @> operand`)
    contains,
    /// All the array's elements are among the operand's (`array <@ operand`)
    containedBy,
    /// The array and the operand have an element in common (`array && operand`)
    overlaps,
    /// An element of the array is equal to the operand (`operand = ANY(array)`)
    anyEqualTo,
    /// An element of the array is not equal to the operand (`operand <> ANY(array)`)
    anyNotEqualTo,
}

/// Interface for array predicates (`arrayPredicate`) - allows optimizers to
/// render them, e.g. as `array @> '{...}'` in PostgreSQL.
interface ArrayPredicateInfo {
    /// The array (type-erased)
    ExprBase operand();

    /// The predicate
    ArrayPredicate predicate();

    /// The type of the elements (without Nullable)
    TypeInfo valueType();

    /// The operand's elements (as ConstantInfo.valueAsString represents
    /// them; null for null elements), in order: one for the `any*`
    /// predicates
    Nullable!string[] valuesAsStrings();
}

/// Expression testing the predicate `predicate` on the values of `operand`
/// (arrays of elements of type `E`, possibly nullable) and the constant
/// operand `values` (one value for the `any*` predicates).
class ArrayPredicateExpr(E) : Expr!bool, ArrayPredicateInfo {
    static if (is(E == Nullable!V, V))
        alias Value = V;
    else
        alias Value = E;

    private ExprBase _operand;
    private ArrayPredicate _predicate;
    private Nullable!Value[] _values;

    this(Expr!(E[]) operand, ArrayPredicate predicate, Nullable!Value[] values) {
        assert(predicate < ArrayPredicate.anyEqualTo || values.length == 1, "ArrayPredicateExpr: one value expected");
        _operand = operand;
        _predicate = predicate;
        _values = values.dup;
    }

    override ExprBase[] dependencies() {
        return [_operand];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _operand = newDep;
    }

    override Expr!bool optimize(OptimizeContext ctx) {
        _operand = cast(ExprBase) (cast(Expr!(E[])) _operand).optimize(ctx);
        return this;
    }

    override Promise!(bool[]) eval(EvalContext ctx) {
        auto predicate = _predicate;
        auto values = _values;
        return evalAs!(E[])(_operand, ctx).then((E[][] arrays) {
            auto result = new bool[arrays.length];
            foreach (i, array; arrays)
                result[i] = arrayPredicateHolds(predicate, array, values);
            return result;
        });
    }

    // ArrayPredicateInfo implementation
    override ExprBase operand() { return _operand; }
    override ArrayPredicate predicate() { return _predicate; }
    override TypeInfo valueType() { return typeid(Value); }
    override Nullable!string[] valuesAsStrings() {
        import dunamis.core.expr.primitives : constantValueString;
        Nullable!string[] strings;
        foreach (v; _values)
            strings ~= v.isNull ? Nullable!string.init : Nullable!string(constantValueString(v.get));
        return strings;
    }
}

/// Whether the array predicate `predicate` holds for the array `array` and
/// the operand `values`, as PostgreSQL's operators have it: null elements
/// (of either) are equal to nothing.
bool arrayPredicateHolds(E, V)(ArrayPredicate predicate, E[] array, Nullable!V[] values) {
    static bool isNullElement(T)(ref T e) {
        static if (is(T == Nullable!U, U))
            return e.isNull;
        else
            return false;
    }
    static V valueOf(T)(ref T e) {
        static if (is(T == Nullable!U, U))
            return e.get;
        else
            return e;
    }
    // Whether the array has an element equal to `v`, or (`notEqual`) one
    // not equal to it
    bool hasElement(Nullable!V v, bool notEqual = false) {
        if (v.isNull)
            return false;
        foreach (ref e; array)
            if (!isNullElement(e) && (valueOf(e) == v.get) != notEqual)
                return true;
        return false;
    }
    final switch (predicate) {
        case ArrayPredicate.contains:
            foreach (v; values)
                if (!hasElement(v))
                    return false;
            return true;
        case ArrayPredicate.containedBy:
            foreach (ref e; array) {
                if (isNullElement(e))
                    return false;
                bool found;
                foreach (v; values)
                    found = found || (!v.isNull && v.get == valueOf(e));
                if (!found)
                    return false;
            }
            return true;
        case ArrayPredicate.overlaps:
            foreach (v; values)
                if (hasElement(v))
                    return true;
            return false;
        case ArrayPredicate.anyEqualTo:
            return hasElement(values[0]);
        case ArrayPredicate.anyNotEqualTo:
            return hasElement(values[0], true);
    }
}

/// Whether the predicate `predicate` holds for each array of `operand` and
/// the operand `values` (one value for the `any*` predicates), with
/// PostgreSQL's array operators' semantics: data sources can evaluate it
/// where the arrays are (e.g. as `array @> '{...}'` in PostgreSQL queries).
Expr!bool arrayPredicate(E, V)(Expr!(E[]) operand, ArrayPredicate predicate, Nullable!V[] values) {
    return new ArrayPredicateExpr!E(operand, predicate, values);
}

unittest {
    alias N = Nullable!int;
    N[] a = [N(1), N(2), N()];
    with (ArrayPredicate) {
        assert(arrayPredicateHolds(contains, a, [N(1), N(2)]));
        assert(!arrayPredicateHolds(contains, a, [N(1), N(3)]));
        assert(!arrayPredicateHolds(contains, a, [N()]));  // (NULL matches nothing)
        assert(arrayPredicateHolds(contains, a, cast(N[]) []));
        assert(!arrayPredicateHolds(containedBy, a, [N(1), N(2), N(3)]));  // (its NULL is in nothing)
        assert(arrayPredicateHolds(containedBy, [N(1), N(2)], [N(1), N(2), N(3)]));
        assert(arrayPredicateHolds(containedBy, cast(N[]) [], [N(1)]));
        assert(arrayPredicateHolds(overlaps, a, [N(5), N(2)]));
        assert(!arrayPredicateHolds(overlaps, a, [N(5), N()]));
        assert(arrayPredicateHolds(anyEqualTo, a, [N(2)]) && !arrayPredicateHolds(anyEqualTo, a, [N(3)]));
        assert(arrayPredicateHolds(anyNotEqualTo, a, [N(1)]) && !arrayPredicateHolds(anyNotEqualTo, [N(1), N()], [N(1)]));
        // Arrays of non-nullable elements
        assert(arrayPredicateHolds(contains, [1, 2], [N(2)]));
    }
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

/// Whether `value` matches the SQL LIKE `pattern`, in which `%` matches any
/// (possibly empty) sequence of characters, `_` any one character, and `\`
/// makes the next character match itself (the `ESCAPE '\'` used when LIKE
/// patterns are rendered to SQL).
bool likeMatch(string value, string pattern) {
    import std.utf : decode;

    // Positions to resume from when the last `%` has to match more.
    size_t starPattern = size_t.max, starValue;
    size_t p, v;
    while (v < value.length) {
        if (p < pattern.length && pattern[p] == '%') {
            starPattern = ++p;
            starValue = v;
            continue;
        }
        if (p < pattern.length) {
            size_t nextP = p;
            bool any = pattern[p] == '_';
            if (pattern[p] == '\\' && p + 1 < pattern.length)
                nextP++;
            size_t vEnd = v;
            dchar vc = decode(value, vEnd);
            size_t pEnd = nextP;
            dchar pc = decode(pattern, pEnd);
            if (any || pc == vc) {
                p = pEnd;
                v = vEnd;
                continue;
            }
        }
        if (starPattern == size_t.max)
            return false;
        // Let the last `%` match one more character.
        decode(value, starValue);
        v = starValue;
        p = starPattern;
    }
    while (p < pattern.length && pattern[p] == '%')
        p++;
    return p == pattern.length;
}

unittest {
    assert(likeMatch("Widgets", "Widgets"));
    assert(!likeMatch("Widgets", "widgets"));
    assert(likeMatch("Widgets", "W%"));
    assert(likeMatch("Widgets", "%gets"));
    assert(likeMatch("Widgets", "%dg%"));
    assert(likeMatch("Widgets", "W_dg_ts"));
    assert(!likeMatch("Widgets", "W_dg_t"));
    assert(likeMatch("", "%"));
    assert(!likeMatch("", "_"));
    assert(likeMatch("a%b", `a\%b`));
    assert(!likeMatch("axb", `a\%b`));
    assert(likeMatch("a_b", `a\_b`));
    assert(likeMatch(`a\b`, `a\\b`));
    assert(likeMatch("abcabd", "%ab_"));
    assert(likeMatch("ab", "%%b"));
    assert(likeMatch("éclair", "_clair"));
    assert(likeMatch("ABC-001-X", "ABC-%-_"));
    assert(!likeMatch("ABC-001", "ABC-%-_"));
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

            auto lowerPattern = caseInsens ? toLower(pattern) : pattern;
            foreach (i, v; vals)
                result[i] = likeMatch(caseInsens ? toLower(v) : v, lowerPattern);

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
    import dunamis.core.expr.primitives : constant;
    return new TernaryExpr!T(condition, constant(trueVal, condition), falseVal);
}

/// Ternary with literal false value
auto ternary(T)(Expr!bool condition, Expr!T trueVal, T falseVal)
    if (!is(T : Expr!U, U))
{
    import dunamis.core.expr.primitives : constant;
    return new TernaryExpr!T(condition, trueVal, constant(falseVal, condition));
}

/// Ternary with both literal values
auto ternary(T)(Expr!bool condition, T trueVal, T falseVal)
    if (!is(T : Expr!U, U))
{
    import dunamis.core.expr.primitives : constant;
    return new TernaryExpr!T(condition, constant(trueVal, condition), constant(falseVal, condition));
}
