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
import dunamis.core.join : joinAll;

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
    } else static if (isGqlResult!T) {
        // GqlResult — error becomes null, ok becomes converted value
        if (value.isError) {
            return JSONValue(null);
        } else {
            return toJsonValue(value.value);
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
    } else static if (is(T == struct)) {
        import std.traits : FieldNameTuple;
        // (Of its public fields: others are internal state, as for the
        // plain fields of entities, see isPlainField.)
        JSONValue object = JSONValue.emptyObject;
        static foreach (fieldName; FieldNameTuple!T)
            static if (__traits(getVisibility, __traits(getMember, T, fieldName)) == "public")
                object[fieldName] = toJsonValue(__traits(getMember, value, fieldName));
        return object;
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
        return joinAll(promises.expand).then((Tuple!FieldArrayTypes results) {
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
/// Supports field-level error catching: if a field expression fails,
/// the field is set to null and the error is recorded on the EvalContext.
class DynamicJsonObjectExpr : Expr!JSONValue {
    private string[] _names;
    private ExprBase[] _exprs;
    private JSONValue[] _pathPrefix;
    private bool[] _nonNullFields;
    private bool[] _nonNullItemFields;
    private ExprBase _lengthSource;

    /// nonNullFields[i]: field i has a non-null type; a null value in it
    /// makes the whole object null (null bubbling).
    /// nonNullItemFields[i]: field i is a list with non-null items; a null
    /// item makes the whole list null (which may then bubble further).
    /// lengthSource: the objects' batch (e.g. the entities they are built
    /// for), whose length is the number of objects even if every field
    /// fails; without one, fields that all fail make one object.
    /// Every successful field must produce one value per object.
    this(string[] names, ExprBase[] exprs, JSONValue[] pathPrefix = [], bool[] nonNullFields = [],
        bool[] nonNullItemFields = [], ExprBase lengthSource = null) {
        assert(names.length == exprs.length, "Names and exprs must have same length");
        _names = names;
        _exprs = exprs;
        _pathPrefix = pathPrefix;
        _nonNullFields = nonNullFields;
        _nonNullItemFields = nonNullItemFields;
        _lengthSource = lengthSource;
    }

    override ExprBase[] dependencies() {
        return _lengthSource is null ? _exprs.dup : _exprs ~ _lengthSource;
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index < _exprs.length) {
            _exprs[index] = newDep;
        } else if (index == _exprs.length && _lengthSource !is null) {
            _lengthSource = newDep;
        }
    }

    override Expr!JSONValue optimize(OptimizeContext ctx) {
        // Optimize all field expressions by calling their typed optimize
        foreach (ref expr; _exprs) {
            expr = optimizeExpr(expr, ctx);
        }
        if (_lengthSource !is null)
            _lengthSource = optimizeExpr(_lengthSource, ctx);
        return this;
    }

    override Promise!(JSONValue[]) eval(EvalContext ctx) {
        import ae.utils.promise : Result, toResult;
        import std.conv : to;

        Result!(JSONValue[])[] results;
        Promise!void evaluateFields() {
            Promise!(Result!(JSONValue[]))[] promises;
            foreach (expr; _exprs)
                promises ~= evalToJson(expr, ctx).toResult();
            return all(promises).then((Result!(JSONValue[])[] values) {
                results = values;
            });
        }

        auto names = _names;
        auto pathPrefix = _pathPrefix;
        auto nonNullFields = _nonNullFields;
        auto nonNullItemFields = _nonNullItemFields;
        auto lengthSource = _lengthSource;

        Promise!size_t batchLength() {
            if (lengthSource !is null)
                return lengthSource.evalResultLength(ctx);
            // The first successful field's, or one object (e.g. at the root)
            foreach (r; results)
                if (r.error is null)
                    return resolve(r.value[0].length);
            return resolve(size_t(1));
        }

        return evaluateFields().then(() => batchLength()).then((size_t count) {
            foreach (i, r; results)
                if (r.error is null && r.value[0].length != count)
                    throw new Exception("Batch size mismatch in object field '" ~ names[i] ~
                        "': it produced " ~ r.value[0].length.to!string ~ " values for " ~
                        count.to!string ~ " objects (use broadcast() to replicate a single " ~
                        "value across a batch)");

            JSONValue[] jsonResults = new JSONValue[count];
            foreach (idx; 0 .. count) {
                jsonResults[idx] = JSONValue.emptyObject;
                bool hasNonNullViolation = false;
                foreach (i, name; names) {
                    if (results[i].error is null) {
                        auto val = results[i].value[0][idx];
                        // Null bubbling through lists: a null item in a list
                        // of non-null items makes the list itself null
                        if (i < nonNullItemFields.length && nonNullItemFields[i] &&
                            val.type == JSONType.array)
                            foreach (item; val.array)
                                if (item.isNull) {
                                    val = JSONValue(null);
                                    break;
                                }
                        jsonResults[idx][name] = val;
                        // Check non-null violation: field is non-null but value is null
                        if (i < nonNullFields.length && nonNullFields[i] && val.isNull)
                            hasNonNullViolation = true;
                    } else {
                        jsonResults[idx][name] = JSONValue(null);
                        // Record error once per field (at first entity)
                        if (results[i].error !is null && idx == 0) {
                            JSONValue[] errorPath = pathPrefix.dup;
                            errorPath ~= JSONValue(name);
                            ctx.addError(results[i].error.msg, errorPath);
                        }
                        // Non-null field failed → violation
                        if (i < nonNullFields.length && nonNullFields[i])
                            hasNonNullViolation = true;
                    }
                }
                // Null bubbling: if any non-null field is null, the entire object becomes null
                if (hasNonNullViolation)
                    jsonResults[idx] = JSONValue(null);
            }
            return jsonResults;
        });
    }
}

/// JSON object expression that evaluates fields sequentially (for mutations).
/// Unlike DynamicJsonObjectExpr which evaluates in parallel, this ensures
/// each field completes before the next starts - required for mutation semantics.
/// Supports field-level error catching: if a field expression fails,
/// the field is set to null and the error is recorded on the EvalContext.
/// Null bubbling is as for DynamicJsonObjectExpr: a null in a non-null field
/// (nonNullFields), or a null item in a list of non-null items
/// (nonNullItemFields), makes the whole object null. The fields after such a
/// field are then not evaluated (their results could not be returned).
///
/// Each field is atomic: its evaluation is an atomic section of the
/// request's sessions (see DataSession.beginAtomic), whose work is undone if
/// the field fails, i.e. if its evaluation fails or it is null with errors
/// recorded while evaluating it (such as a field of its value which is
/// non-null and failed). Other errors of its value (of nullable fields) do
/// not undo its work.
class SequentialJsonObjectExpr : Expr!JSONValue {
    private string[] _names;
    private ExprBase[] _exprs;
    private JSONValue[] _pathPrefix;
    private bool[] _nonNullFields;
    private bool[] _nonNullItemFields;

    this(string[] names, ExprBase[] exprs, JSONValue[] pathPrefix = [], bool[] nonNullFields = [],
        bool[] nonNullItemFields = []) {
        assert(names.length == exprs.length, "Names and exprs must have same length");
        _names = names;
        _exprs = exprs;
        _pathPrefix = pathPrefix;
        _nonNullFields = nonNullFields;
        _nonNullItemFields = nonNullItemFields;
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
        auto pathPrefix = _pathPrefix;
        bool nonNull = idx < _nonNullFields.length && _nonNullFields[idx];
        bool nonNullItems = idx < _nonNullItemFields.length && _nonNullItemFields[idx];

        Promise!(JSONValue[]) next(JSONValue value) {
            if (nonNullItems && value.type == JSONType.array)
                foreach (item; value.array)
                    if (item.isNull) {
                        value = JSONValue(null);
                        break;
                    }
            if (nonNull && value.isNull)
                return resolve([JSONValue(null)]);
            result[fieldName] = value;
            return evalFieldsSequentially(ctx, idx + 1, result);
        }

        import ae.utils.promise : Result, toResult;
        import dunamis.core.datasource : DataSession;

        auto sessions = ctx.allSessions;
        ulong[] tokens;
        Promise!void beginAtomic(size_t i) {
            if (i == sessions.length) return resolve();
            return sessions[i].beginAtomic().then((ulong token) {
                tokens ~= token;
                return beginAtomic(i + 1);
            });
        }
        Promise!void endAtomic(size_t i, bool success) {
            if (i == sessions.length) return resolve();
            return sessions[i].endAtomic(tokens[i], success).then(() => endAtomic(i + 1, success));
        }

        size_t errorsBefore;
        return beginAtomic(0).then(() {
            errorsBefore = ctx.errors.length;
            // (An expression may also fail before returning its promise.)
            Promise!(JSONValue[]) evaluated;
            try {
                evaluated = evalToJson(fieldExpr, ctx);
            } catch (Exception e) {
                evaluated = new Promise!(JSONValue[]);
                evaluated.reject(e);
            }
            return evaluated.toResult();
        }).then((Result!(JSONValue[]) r) {
            JSONValue value;
            if (r.error is null)
                value = r.value[0][0];
            else {
                // Field failed — null, with the error recorded at the field's path
                JSONValue[] errorPath = pathPrefix.dup;
                errorPath ~= JSONValue(fieldName);
                ctx.addError(r.error.msg, errorPath);
                value = JSONValue(null);
            }
            bool failed = r.error !is null || (value.isNull && ctx.errors.length > errorsBefore);
            return endAtomic(0, !failed).then(() => next(value));
        });
    }
}

/// Evaluate an expression and convert its result to JSONValue[].
Promise!(JSONValue[]) evalToJson(ExprBase expr, EvalContext ctx) {
    import std.algorithm : stdMap = map;
    import std.array : array;

    // GqlResult types — per-element error handling
    // Errors are recorded with empty path as fallback; use MaterializeGqlResultExpr for proper paths.
    if (auto e = cast(Expr!(GqlResult!string)) expr) {
        return e.eval(ctx).then((GqlResult!string[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) {
                if (v.isError) {
                    result[i] = JSONValue(null);
                    ctx.addError(v.error, []);
                } else {
                    result[i] = JSONValue(v.value);
                }
            }
            return result;
        });
    }
    if (auto e = cast(Expr!(GqlResult!long)) expr) {
        return e.eval(ctx).then((GqlResult!long[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) {
                if (v.isError) {
                    result[i] = JSONValue(null);
                    ctx.addError(v.error, []);
                } else {
                    result[i] = JSONValue(v.value);
                }
            }
            return result;
        });
    }
    if (auto e = cast(Expr!(GqlResult!double)) expr) {
        return e.eval(ctx).then((GqlResult!double[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) {
                if (v.isError) {
                    result[i] = JSONValue(null);
                    ctx.addError(v.error, []);
                } else {
                    result[i] = JSONValue(v.value);
                }
            }
            return result;
        });
    }
    if (auto e = cast(Expr!(GqlResult!bool)) expr) {
        return e.eval(ctx).then((GqlResult!bool[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) {
                if (v.isError) {
                    result[i] = JSONValue(null);
                    ctx.addError(v.error, []);
                } else {
                    result[i] = JSONValue(v.value);
                }
            }
            return result;
        });
    }

    // Nullable types
    if (auto e = cast(Expr!(Nullable!string)) expr) {
        return e.eval(ctx).then((Nullable!string[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) result[i] = toJsonValue(v);
            return result;
        });
    }
    if (auto e = cast(Expr!(Nullable!long)) expr) {
        return e.eval(ctx).then((Nullable!long[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) result[i] = toJsonValue(v);
            return result;
        });
    }
    if (auto e = cast(Expr!(Nullable!double)) expr) {
        return e.eval(ctx).then((Nullable!double[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) result[i] = toJsonValue(v);
            return result;
        });
    }
    if (auto e = cast(Expr!(Nullable!bool)) expr) {
        return e.eval(ctx).then((Nullable!bool[] vals) {
            JSONValue[] result = new JSONValue[vals.length];
            foreach (i, v; vals) result[i] = toJsonValue(v);
            return result;
        });
    }

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

    assert(false, "evalToJson: unsupported result type " ~ expr.resultType.toString());
}

// ============================================================================
// GqlResult Materialization
// ============================================================================

/// Transform expression that converts GqlResult!T to Nullable!T,
/// recording per-element errors in the EvalContext.
///
/// This is where error "bubbling" materializes into concrete null values.
/// Each error element becomes Nullable.null with the error recorded at the
/// given path. Success elements become Nullable(value).
///
/// When an index source is set (via `setIndexSource`), the element's local
/// index within its parent collection is included in the error path.
/// For example, path `["users", "name"]` becomes `["users", 0, "name"]`.
///
/// Use `materializeResult()` to create instances.
class MaterializeGqlResultExpr(T) : Expr!(Nullable!T), IndexSourceConsumer {
    private ExprBase _input;  // Expr!(GqlResult!T)
    private JSONValue[] _errorPath;
    private IndexLevel[] _indexSources;  // Outermost first

    this(Expr!(GqlResult!T) input, JSONValue[] errorPath = []) {
        _input = input;
        _errorPath = errorPath;
    }

    /// Add an index source level. Called automatically by `map!`.
    /// Outer levels call this after inner levels, so prepend to maintain
    /// outermost-first order.
    void addIndexSource(IndexLevel level) {
        _indexSources = [level] ~ _indexSources;
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _input = newDep;
    }

    override Expr!(Nullable!T) optimize(OptimizeContext ctx) {
        _input = optimizeExpr(_input, ctx);
        return this;
    }

    override Promise!(Nullable!T[]) eval(EvalContext ctx) {
        auto errorPath = _errorPath;
        auto indexSources = _indexSources;

        return evalAs!(GqlResult!T)(_input, ctx).then((GqlResult!T[] vals) {
            // Collect index arrays from each nesting level
            size_t[][] allLocalIndices;
            size_t[][] allGroupIndices;
            MapDedup[] dedups;  // (per level; empty `occurrences` if none)
            bool anyDedup;
            foreach (level; indexSources) {
                allLocalIndices ~= ctx.getValues!size_t(level.localKey);
                allGroupIndices ~= ctx.getValues!size_t(level.groupKey);
                auto dedup = level.dedupKey is null ? null : ctx.getValues!MapDedup(level.dedupKey);
                dedups ~= dedup.length ? dedup[0] : MapDedup.init;
                anyDedup |= dedup.length > 0;
            }

            Nullable!T[] result = new Nullable!T[vals.length];
            IndexedPath[] errors;
            foreach (i, v; vals) {
                if (v.isError) {
                    result[i] = Nullable!T.init;
                    if (anyDedup)
                        errors ~= buildIndexedPaths(errorPath, i, allLocalIndices, allGroupIndices, dedups, v.error);
                    else
                        ctx.addError(v.error,
                            buildIndexedPath(errorPath, i, allLocalIndices, allGroupIndices));
                } else {
                    result[i] = Nullable!T(v.value);
                }
            }
            // An element of a deduplicated batch stands for all the elements
            // equal to it: its error is theirs too, in the order of the
            // elements as a batch without deduplication would have them.
            if (errors.length) {
                import std.algorithm.sorting : sort;
                errors.sort!((a, b) => a.order < b.order);
                foreach (e; errors)
                    ctx.addError(e.message, e.path);
            }
            return result;
        });
    }
}

/// Convert a GqlResult expression to a Nullable expression,
/// recording errors in the EvalContext at the given path.
auto materializeResult(T)(Expr!(GqlResult!T) input, JSONValue[] errorPath = []) {
    return new MaterializeGqlResultExpr!T(input, errorPath);
}

/// Build an error path with array indices interleaved at each nesting level.
///
/// Given basePath ["users", "posts", "title"] and index sources for 2 levels,
/// produces ["users", userIdx, "posts", postIdx, "title"].
///
/// Chains from innermost to outermost: inner group indices map to positions
/// in the next outer batch, where outer local indices give the outer index.
private JSONValue[] buildIndexedPath(JSONValue[] basePath, size_t elementIdx,
    size_t[][] allLocalIndices, size_t[][] allGroupIndices)
{
    if (allLocalIndices.length == 0 || basePath.length == 0) {
        return basePath;
    }

    size_t numLevels = allLocalIndices.length;
    size_t[] levelIndices = new size_t[numLevels];

    // Chain from innermost to outermost to resolve each level's local index.
    // Index sources are ordered outermost first, so level $-1 is innermost.
    size_t batchIdx = elementIdx;
    for (size_t lvl = numLevels; lvl > 0; lvl--) {
        size_t level = lvl - 1;
        if (batchIdx < allLocalIndices[level].length)
            levelIndices[level] = allLocalIndices[level][batchIdx];
        // Use group indices to find position in the next outer level's batch
        if (level > 0 && batchIdx < allGroupIndices[level].length)
            batchIdx = allGroupIndices[level][batchIdx];
    }

    // Interleave: ["a", idx0, "b", idx1, ..., "field"]
    size_t numInserts = numLevels < basePath.length ? numLevels : basePath.length - 1;
    JSONValue[] result;
    foreach (j; 0 .. basePath.length) {
        result ~= basePath[j];
        if (j < numInserts)
            result ~= JSONValue(cast(long) levelIndices[j]);
    }
    return result;
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
        // The selection set first, while chain traversal through the
        // unwrapper still sees the input as compiled (as with ObjectExpr).
        _innerExpr = (cast(Expr!JSONValue) _innerExpr).optimize(ctx);
        _nullableInput = optimizeExpr(_nullableInput, ctx);
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
            unwrapper.bind(ctx, unwrapNullables(nullableVals));

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

/// A value that an enclosing expression evaluates once and binds for the
/// sub-expression compiled against this placeholder (e.g. the object whose
/// selection set is being evaluated).
///
/// The binding is per evaluation: it is stored in the EvalContext, keyed by
/// this node, so that the expression tree itself stays immutable after
/// optimization and can be evaluated by several requests concurrently.
/// If nothing has bound values in the current context (e.g. the placeholder
/// was used outside of its binding expression), the input is evaluated.
///
/// During optimization the placeholder forwards to its input, so that chain
/// traversal (findMapExprFromChain) can continue through it.
abstract class BoundValueExpr(T) : Expr!T, UnwrapNullableInfo {
    protected ExprBase _input;

    this(ExprBase input) {
        _input = input;
    }

    /// Bind the values this placeholder evaluates to in `ctx`.
    final void bind(EvalContext ctx, T[] values) {
        ctx.setValues!T(this, values);
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _input = newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        _input = optimizeExpr(_input, ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        T[] values;
        if (ctx.tryGetValues!T(this, values))
            return resolve(values);
        return evalUnbound(ctx);
    }

    /// Evaluate the placeholder's values from its input.
    protected abstract Promise!(T[]) evalUnbound(EvalContext ctx);

    // UnwrapNullableInfo implementation - allows chain traversal to continue
    @property ExprBase inputExpr() { return _input; }
}

/// Unwrap nullable values, using T.init for nulls.
private T[] unwrapNullables(T)(Nullable!T[] nullableVals) {
    T[] values = new T[nullableVals.length];
    foreach (i, nval; nullableVals)
        if (!nval.isNull)
            values[i] = nval.get;
    return values;
}

/// Helper expression that unwraps Nullable!T to T for selection set compilation.
/// At evaluation time, it returns the values bound by NullableObjectExpr
/// (T.init where the input is null); unbound, it unwraps its input itself.
class UnwrapNullableExpr(T) : BoundValueExpr!T {
    this(Expr!(Nullable!T) nullableInput) {
        super(nullableInput);
    }

    protected override Promise!(T[]) evalUnbound(EvalContext ctx) {
        return evalAs!(Nullable!T)(_input, ctx).then((Nullable!T[] nullableVals) =>
            unwrapNullables(nullableVals));
    }
}

/// Finalize a nullable object expression after the selection set has been compiled.
NullableObjectExpr!T finalizeNullableObjectExpr(T)(
    Expr!(Nullable!T) nullableInput,
    UnwrapNullableExpr!T unwrapper,
    Expr!JSONValue innerExpr
) {
    return new NullableObjectExpr!T(nullableInput, innerExpr, unwrapper);
}

// ============================================================================
// Object Expression
// ============================================================================

/// Expression for the selection set of a non-null object field.
/// Like NullableObjectExpr, it evaluates the object once and binds it for the
/// selection set, so that the object is not recomputed for each selected field,
/// and a failure to produce it is reported once, at the object field.
///
/// If, after optimization, no selected field needs the bound object any more
/// (e.g. all of them were pushed into a join), the selection set is used as is.
class ObjectExpr(T) : Expr!JSONValue {
    private ExprBase _input;      // Expr!T
    private ExprBase _innerExpr;  // Expr!JSONValue (selection set compiled against _bound)
    private BoundObjectExpr!T _bound;

    this(Expr!T input, Expr!JSONValue innerExpr, BoundObjectExpr!T bound) {
        _input = input;
        _innerExpr = innerExpr;
        _bound = bound;
    }

    override ExprBase[] dependencies() {
        return [_input, _innerExpr];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _input = newDep;
        else if (index == 1) _innerExpr = newDep;
    }

    override Expr!JSONValue optimize(OptimizeContext ctx) {
        _innerExpr = (cast(Expr!JSONValue) _innerExpr).optimize(ctx);
        if (!dependsOn(_innerExpr, _bound))
            return cast(Expr!JSONValue) _innerExpr;
        _input = optimizeExpr(_input, ctx);
        return this;
    }

    override Promise!(JSONValue[]) eval(EvalContext ctx) {
        auto innerExpr = _innerExpr;
        auto bound = _bound;
        return evalAs!T(_input, ctx).then((T[] values) {
            bound.bind(ctx, values);
            return evalAs!JSONValue(innerExpr, ctx);
        });
    }

    private static bool dependsOn(ExprBase expr, ExprBase target) {
        bool[ExprBase] visited;
        bool visit(ExprBase e) {
            if (e is target) return true;
            if (e is null || e in visited) return false;
            visited[e] = true;
            foreach (dependency; e.dependencies)
                if (visit(dependency)) return true;
            return false;
        }
        return visit(expr);
    }
}

/// The object bound by an ObjectExpr, for compiling its selection set.
/// Returns the values bound by the ObjectExpr in the current evaluation, or
/// evaluates the object's expression directly if none were bound.
class BoundObjectExpr(T) : BoundValueExpr!T {
    this(Expr!T input) {
        super(input);
    }

    protected override Promise!(T[]) evalUnbound(EvalContext ctx) {
        return evalAs!T(_input, ctx);
    }
}

/// An error at the path of an element, and the element's position in the
/// order of a batch without deduplication (see buildIndexedPaths).
private struct IndexedPath {
    size_t[] order;
    string message;
    JSONValue[] path;
}

/// `buildIndexedPath` for the element `elementIdx` of a batch some of whose
/// levels were deduplicated (see MapDedup; `dedups[level].occurrences` is
/// empty for a level that was not): one path for each element of the
/// batches without deduplication that the element stands for, with its
/// position in their order (the outermost level's position in its batch,
/// then the local indices of the levels within it, compared
/// lexicographically: the order in which batches flatten their groups).
private IndexedPath[] buildIndexedPaths(JSONValue[] basePath, size_t elementIdx,
    size_t[][] allLocalIndices, size_t[][] allGroupIndices, MapDedup[] dedups, string message)
{
    size_t numLevels = allLocalIndices.length;
    if (numLevels == 0 || basePath.length == 0)
        return [IndexedPath([], message, basePath)];

    IndexedPath[] result;
    size_t[] levelIndices = new size_t[numLevels];

    // Resolve the levels from the innermost outwards, branching at each
    // deduplicated level into the elements its element stands for
    void resolveLevel(size_t level, size_t batchIdx) {
        void visit(size_t localIdx, size_t groupIdx, bool hasGroup) {
            levelIndices[level] = localIdx;
            if (level > 0)
                resolveLevel(level - 1, hasGroup ? groupIdx : batchIdx);
            else {
                size_t numInserts = numLevels < basePath.length ? numLevels : basePath.length - 1;
                JSONValue[] path;
                foreach (j; 0 .. basePath.length) {
                    path ~= basePath[j];
                    if (j < numInserts)
                        path ~= JSONValue(cast(long) levelIndices[j]);
                }
                result ~= IndexedPath(batchIdx ~ levelIndices[1 .. $].dup, message, path);
            }
        }

        auto dedup = dedups[level];
        if (dedup.occurrences.length && batchIdx < dedup.occurrences.length) {
            foreach (position; dedup.occurrences[batchIdx]) {
                auto savedBatchIdx = batchIdx;
                batchIdx = position;  // (the outermost level's order is its position)
                visit(dedup.localIndices[position], position < dedup.groupIndices.length ?
                    dedup.groupIndices[position] : 0, position < dedup.groupIndices.length);
                batchIdx = savedBatchIdx;
            }
        } else {
            visit(batchIdx < allLocalIndices[level].length ? allLocalIndices[level][batchIdx] : levelIndices[level],
                batchIdx < allGroupIndices[level].length ? allGroupIndices[level][batchIdx] : 0,
                batchIdx < allGroupIndices[level].length);
        }
    }
    resolveLevel(numLevels - 1, elementIdx);
    return result;
}

// ============================================================================
// Tests: helpers and field-level error catching
// ============================================================================

/// Expression that returns fixed values of any type (for testing)
private class FixedExpr(T) : Expr!T {
    T[] _values;
    this(T[] values) { _values = values; }
    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t index, ExprBase newDep) {}
    override Promise!(T[]) eval(EvalContext ctx) {
        return resolve(_values);
    }
}

/// Expression that always fails (for testing error handling)
private class FailingExpr : Expr!JSONValue {
    string _message;

    this(string message) {
        _message = message;
    }

    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t index, ExprBase newDep) {}

    override Promise!(JSONValue[]) eval(EvalContext ctx) {
        auto p = new Promise!(JSONValue[]);
        p.reject(new Exception(_message));
        return p;
    }
}

// A struct's JSON value has its public fields (not its internal state)
unittest {
    static struct Value {
        int a;
        string b;
        package bool internal;
        private int hidden;
    }
    auto json = toJsonValue(Value(1, "x", true, 2));
    assert(json.toString() == `{"a":1,"b":"x"}`, json.toString());
}

/// Expression that returns fixed values (for testing)
private class FixedJsonExpr : Expr!JSONValue {
    JSONValue[] _values;
    this(JSONValue[] values) { _values = values; }
    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t index, ExprBase newDep) {}
    override Promise!(JSONValue[]) eval(EvalContext ctx) {
        return resolve(_values);
    }
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test DynamicJsonObjectExpr: one field fails, others succeed
    auto ctx = new EvalContext();
    auto goodField = new FixedJsonExpr([JSONValue("Alice"), JSONValue("Bob")]);
    auto badField = new FailingExpr("field failed");

    auto expr = new DynamicJsonObjectExpr(
        ["name", "broken"],
        [cast(ExprBase) goodField, cast(ExprBase) badField],
        [JSONValue("users")],
    );

    auto result = awaitSync(expr.eval(ctx));

    // Should have 2 results (batch size from successful field)
    assert(result.length == 2);
    assert(result[0]["name"].str == "Alice");
    assert(result[0]["broken"].isNull);
    assert(result[1]["name"].str == "Bob");
    assert(result[1]["broken"].isNull);

    // Error should be recorded
    assert(ctx.hasErrors);
    assert(ctx.errors.length == 1);
    assert(ctx.errors[0].message == "field failed");
    assert(ctx.errors[0].path == [JSONValue("users"), JSONValue("broken")]);
}

unittest {
    import ae.utils.promise.await : awaitSync;
    import std.algorithm : canFind;
    import std.conv : to;

    // Test DynamicJsonObjectExpr: the length source gives the number of
    // objects, even when every field fails
    auto ctx = new EvalContext();
    auto batch = new FixedJsonExpr([JSONValue(1), JSONValue(2), JSONValue(3)]);
    auto expr = new DynamicJsonObjectExpr(["broken"], [cast(ExprBase) new FailingExpr("field failed")],
        [JSONValue("users")], [], [], batch);
    auto result = awaitSync(expr.eval(ctx));
    assert(result.length == 3, result.to!string);
    foreach (object; result)
        assert(object["broken"].isNull);
    assert(ctx.errors.length == 1 && ctx.errors[0].message == "field failed");

    // A field with one value for a batch of three is an error, not replicated
    auto single = new DynamicJsonObjectExpr(["name"], [cast(ExprBase) new FixedJsonExpr([JSONValue("a")])],
        [], [], [], batch);
    try {
        awaitSync(single.eval(new EvalContext()));
        assert(false, "Expected a batch size mismatch");
    } catch (Exception e)
        assert(e.msg.canFind("Batch size mismatch in object field 'name'"), e.msg);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test DynamicJsonObjectExpr: null bubbling through lists of non-null items
    auto ctx = new EvalContext();
    auto name = new FixedJsonExpr([JSONValue("a"), JSONValue("b")]);
    JSONValue withNull = JSONValue([JSONValue(1), JSONValue(null)]);
    JSONValue withoutNull = JSONValue([JSONValue(1), JSONValue(2)]);
    // [T!]! - a null item nulls the list, which nulls the object
    auto strict = new FixedJsonExpr([withoutNull, withNull]);
    // [T!] - a null item nulls the list only
    auto nullableList = new FixedJsonExpr([withNull, withoutNull]);
    // [T]! - null items are allowed
    auto nullableItems = new FixedJsonExpr([withNull, withNull]);

    auto expr = new DynamicJsonObjectExpr(
        ["name", "strict", "nullableList", "nullableItems"],
        [cast(ExprBase) name, cast(ExprBase) strict, cast(ExprBase) nullableList,
            cast(ExprBase) nullableItems],
        [],
        [false, true, false, true],
        [false, true, true, false],
    );

    auto result = awaitSync(expr.eval(ctx));
    assert(result.length == 2);
    assert(result[0]["name"].str == "a");
    assert(result[0]["strict"] == withoutNull);
    assert(result[0]["nullableList"].isNull);
    assert(result[0]["nullableItems"] == withNull);
    assert(result[1].isNull);
    assert(!ctx.hasErrors);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test DynamicJsonObjectExpr: all fields succeed, no errors
    auto ctx = new EvalContext();
    auto field1 = new FixedJsonExpr([JSONValue("a")]);
    auto field2 = new FixedJsonExpr([JSONValue(42)]);

    auto expr = new DynamicJsonObjectExpr(
        ["x", "y"],
        [cast(ExprBase) field1, cast(ExprBase) field2],
    );

    auto result = awaitSync(expr.eval(ctx));
    assert(result.length == 1);
    assert(result[0]["x"].str == "a");
    assert(result[0]["y"].integer == 42);
    assert(!ctx.hasErrors);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test SequentialJsonObjectExpr: one field fails, others succeed
    auto ctx = new EvalContext();
    auto goodField = new FixedJsonExpr([JSONValue("ok")]);
    auto badField = new FailingExpr("mutation failed");
    auto goodField2 = new FixedJsonExpr([JSONValue(true)]);

    auto expr = new SequentialJsonObjectExpr(
        ["first", "broken", "third"],
        [cast(ExprBase) goodField, cast(ExprBase) badField, cast(ExprBase) goodField2],
        [JSONValue("mutation")],
    );

    auto result = awaitSync(expr.eval(ctx));

    // Should have 1 result (mutations produce single object)
    assert(result.length == 1);
    assert(result[0]["first"].str == "ok");
    assert(result[0]["broken"].isNull);
    assert(result[0]["third"].type == JSONType.true_); // Subsequent fields still execute
    assert(ctx.hasErrors);
    assert(ctx.errors[0].path == [JSONValue("mutation"), JSONValue("broken")]);
}

// ============================================================================
// Tests: GqlResult and MaterializeGqlResultExpr
// ============================================================================

/// Expression that returns fixed GqlResult values (for testing)
private class FixedGqlResultExpr(T) : Expr!(GqlResult!T) {
    GqlResult!T[] _values;
    this(GqlResult!T[] values) { _values = values; }
    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t index, ExprBase newDep) {}
    override Promise!(GqlResult!T[]) eval(EvalContext ctx) {
        return resolve(_values);
    }
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test MaterializeGqlResultExpr: mixed ok/error elements
    auto ctx = new EvalContext();
    auto input = new FixedGqlResultExpr!string([
        GqlResult!string.ok("Alice"),
        GqlResult!string.err("name missing"),
        GqlResult!string.ok("Charlie"),
    ]);

    auto expr = materializeResult!string(input, [JSONValue("users"), JSONValue("name")]);
    auto result = awaitSync(expr.eval(ctx));

    // Check materialized values
    assert(result.length == 3);
    assert(!result[0].isNull && result[0].get == "Alice");
    assert(result[1].isNull);  // Error → null
    assert(!result[2].isNull && result[2].get == "Charlie");

    // Check errors recorded
    assert(ctx.hasErrors);
    assert(ctx.errors.length == 1);
    assert(ctx.errors[0].message == "name missing");
    assert(ctx.errors[0].path == [JSONValue("users"), JSONValue("name")]);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test evalToJson with GqlResult — errors recorded with empty path
    auto ctx = new EvalContext();
    auto input = new FixedGqlResultExpr!string([
        GqlResult!string.ok("hello"),
        GqlResult!string.err("bad value"),
    ]);

    auto result = awaitSync(evalToJson(input, ctx));

    assert(result.length == 2);
    assert(result[0].str == "hello");
    assert(result[1].isNull);
    assert(ctx.hasErrors);
    assert(ctx.errors[0].message == "bad value");
    assert(ctx.errors[0].path == []);  // No path for unmaterialized GqlResult
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test MaterializeGqlResultExpr through DynamicJsonObjectExpr
    auto ctx = new EvalContext();

    // One field is a materialized GqlResult, the other is a plain field
    auto gqlField = new FixedGqlResultExpr!string([
        GqlResult!string.ok("valid"),
        GqlResult!string.err("invalid name"),
    ]);
    auto materialized = materializeResult!string(gqlField,
        [JSONValue("users"), JSONValue("name")]);
    auto plainField = new FixedJsonExpr([JSONValue(1), JSONValue(2)]);

    auto expr = new DynamicJsonObjectExpr(
        ["name", "id"],
        [cast(ExprBase) materialized, cast(ExprBase) plainField],
        [JSONValue("users")],
    );

    auto result = awaitSync(expr.eval(ctx));

    assert(result.length == 2);
    // First element: name is "valid", id is 1
    assert(result[0]["id"].integer == 1);
    // Second element: name is null (error materialized), id is 2
    assert(result[1]["id"].integer == 2);

    // Error should be recorded from materialization (with specific path)
    assert(ctx.hasErrors);
    assert(ctx.errors.length == 1);
    assert(ctx.errors[0].message == "invalid name");
    assert(ctx.errors[0].path == [JSONValue("users"), JSONValue("name")]);
}

unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.expr.combinators : map;

    // Test MaterializeGqlResultExpr with index source from MapExpr.
    // Verifies error paths include element array indices.
    static struct TestEntity { int id; }
    auto ctx = new EvalContext();

    // Create a collection: parent 0 has 3 entities, parent 1 has 2
    auto collection = new FixedExpr!(TestEntity[])([
        [TestEntity(1), TestEntity(2), TestEntity(3)],
        [TestEntity(4), TestEntity(5)],
    ]);

    // Build a map expression where the body materializes a GqlResult.
    // map! auto-links the MaterializeGqlResultExpr to the MapExpr's index key.
    auto mapExpr = map!((Expr!TestEntity entity) {
        auto gqlField = new FixedGqlResultExpr!string([
            GqlResult!string.ok("ok-1"),
            GqlResult!string.err("bad at index 1"),
            GqlResult!string.ok("ok-3"),
            GqlResult!string.ok("ok-4"),
            GqlResult!string.err("bad at index 1 again"),
        ]);
        return materializeResult!string(gqlField,
            [JSONValue("users"), JSONValue("name")]);
    })(collection);

    // No manual linking needed — map! auto-links index sources
    auto result = awaitSync(mapExpr.eval(ctx));

    // Should have 2 groups (one per parent)
    assert(result.length == 2);
    assert(result[0].length == 3);  // Parent 0: 3 entities
    assert(result[1].length == 2);  // Parent 1: 2 entities

    // Check values: ok elements are non-null, error elements are null
    assert(!result[0][0].isNull);   // ok-1
    assert(result[0][1].isNull);    // error at index 1
    assert(!result[0][2].isNull);   // ok-3
    assert(!result[1][0].isNull);   // ok-4
    assert(result[1][1].isNull);    // error at index 1

    // Check errors include array indices in paths
    assert(ctx.errors.length == 2);
    // First error: entity at local index 1 within parent 0
    assert(ctx.errors[0].message == "bad at index 1");
    assert(ctx.errors[0].path == [JSONValue("users"), JSONValue(1), JSONValue("name")]);
    // Second error: entity at local index 1 within parent 1
    assert(ctx.errors[1].message == "bad at index 1 again");
    assert(ctx.errors[1].path == [JSONValue("users"), JSONValue(1), JSONValue("name")]);
}

unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.expr.combinators : map;

    // Test nested MapExpr: indices at every nesting level.
    // Structure: 2 users, user0 has 2 posts, user1 has 1 post = 3 posts total.
    // Error on post at (user=0, post=1) — path should be ["users", 0, "posts", 1, "title"].
    static struct User { int id; }
    static struct Post { int id; }
    auto ctx = new EvalContext();

    // One group of 2 users
    auto users = new FixedExpr!(User[])([[User(1), User(2)]]);

    auto outerMap = map!((Expr!User user) {
        // User0 has 2 posts, User1 has 1 post
        auto posts = new FixedExpr!(Post[])([
            [Post(10), Post(11)],
            [Post(20)],
        ]);

        return map!((Expr!Post post) {
            auto gqlField = new FixedGqlResultExpr!string([
                GqlResult!string.ok("title-10"),
                GqlResult!string.err("bad title"),  // post 11, user0 index 1
                GqlResult!string.ok("title-20"),
            ]);
            return materializeResult!string(gqlField,
                [JSONValue("users"), JSONValue("posts"), JSONValue("title")]);
        })(posts);
    })(users);

    auto result = awaitSync(outerMap.eval(ctx));

    // Outer: 1 group of 2 users → result has 1 element (array of user results)
    assert(result.length == 1);
    auto userResults = result[0];
    assert(userResults.length == 2);

    // User 0: 2 posts
    assert(userResults[0].length == 2);
    assert(!userResults[0][0].isNull);  // title-10
    assert(userResults[0][1].isNull);   // error

    // User 1: 1 post
    assert(userResults[1].length == 1);
    assert(!userResults[1][0].isNull);  // title-20

    // Error path should include BOTH user and post indices
    assert(ctx.errors.length == 1);
    assert(ctx.errors[0].message == "bad title");
    assert(ctx.errors[0].path == [
        JSONValue("users"), JSONValue(0),     // user index 0
        JSONValue("posts"), JSONValue(1),     // post index 1
        JSONValue("title"),
    ]);
}
