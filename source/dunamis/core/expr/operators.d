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

/// A binary boolean operation whose SQL operator is supplied at runtime.
/// This is useful for database-native predicates (for example PostgreSQL
/// range operators) which are not D operators and therefore cannot use the
/// compile-time `BinaryOpExpr` template.
class SqlBinaryBoolExpr(L, R) : Expr!bool, BinaryOpInfo {
    private ExprBase _left;
    private ExprBase _right;
    private string _operator;
    private bool delegate(L, R) _fallback;

    this(Expr!L left, string operator, Expr!R right,
            bool delegate(L, R) fallback = null) {
        _left = left;
        _right = right;
        _operator = operator;
        _fallback = fallback;
    }

    override ExprBase[] dependencies() { return [_left, _right]; }
    override void replaceDependency(size_t index, ExprBase value) {
        if (index == 0) _left = value; else _right = value;
    }
    override Expr!bool optimize(OptimizeContext ctx) {
        _left = cast(ExprBase)(cast(Expr!L)_left).optimize(ctx);
        _right = cast(ExprBase)(cast(Expr!R)_right).optimize(ctx);
        return this;
    }
    override Promise!(bool[]) eval(EvalContext ctx) {
        return joinAll(evalAs!L(_left, ctx), evalAs!R(_right, ctx))
            .dmd21804workaround.then((values) {
                bool[] result = new bool[values[0].length];
                foreach (i; 0 .. result.length)
                    result[i] = _fallback is null ? false :
                        _fallback(values[0][i], values[1][i]);
                return result;
            });
    }
    override string operator() { return _operator; }
    override ExprBase left() { return _left; }
    override ExprBase right() { return _right; }
}

Expr!bool sqlBinaryBool(L, R)(Expr!L left, string operator, Expr!R right,
        bool delegate(L, R) fallback = null) {
    return new SqlBinaryBoolExpr!(L, R)(left, operator, right, fallback);
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
