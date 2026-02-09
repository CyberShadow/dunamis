module dunamis.core.expr.json;

import std.array;
import std.json;
import std.meta;
import std.traits;
import std.typecons : Nullable, Tuple;

import ae.utils.promise;

import dunamis.core.types;
import dunamis.core.eval;
import dunamis.core.optimize;
import dunamis.core.expr.base;

// ============================================================================
// jsonObject Combinator (JSON construction)
// ============================================================================

/// Convert a D value to JSONValue
JSONValue toJsonValue(T)(T value) {
    import dunamis.core.types : isCustomScalar;
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
        return JSONValue(value.id);
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

/// Generate AliasSeq!(0, 1, 2, ..., N-1) at compile time
private template staticIota(size_t N) {
    import std.meta : AliasSeq;
    static if (N == 0)
        alias staticIota = AliasSeq!();
    else
        alias staticIota = AliasSeq!(staticIota!(N - 1), N - 1);
}

/// Helper to convert T to Promise!(T[])
private template toPromiseArray(T) {
    alias toPromiseArray = Promise!(T[]);
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

/// Evaluate an expression and convert its result to JSONValue[].
Promise!(JSONValue[]) evalToJson(ExprBase expr, EvalContext ctx) {
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
// Nullable Object Expression
// ============================================================================

/// Interface for UnwrapNullableExpr to allow chain traversal during optimization.
/// This lets findMapExprFromChain continue through nullable wrappers.
interface UnwrapNullableInfo {
    @property ExprBase inputExpr();
}

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
class UnwrapNullableExpr(T) : Expr!T, UnwrapNullableInfo {
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

}

/// Finalize a nullable object expression after the selection set has been compiled.
NullableObjectExpr!T finalizeNullableObjectExpr(T)(
    Expr!(Nullable!T) nullableInput,
    UnwrapNullableExpr!T unwrapper,
    Expr!JSONValue innerExpr
) {
    return new NullableObjectExpr!T(nullableInput, innerExpr, unwrapper);
}
