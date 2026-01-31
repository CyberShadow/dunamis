module graphqld2.relational.mutation;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

import ae.utils.promise;

import graphqld2.core.types;
import graphqld2.core.expr;
import graphqld2.core.eval;
import graphqld2.core.optimize : OptimizeContext;
import graphqld2.relational.eval_context;

// ============================================================================
// Mutation Input Types
// ============================================================================

/// Input for INSERT operations.
/// Maps column names to JSON values.
struct InsertInput {
    JSONValue[string] values;

    /// Get column names in consistent order
    @property string[] columns() const {
        return values.keys.dup;
    }

    /// Get values in same order as columns
    @property JSONValue[] orderedValues() const {
        auto cols = columns;
        JSONValue[] result;
        result.reserve(cols.length);
        foreach (c; cols) {
            result ~= values[c];
        }
        return result;
    }
}

/// Input for UPDATE operations.
/// Contains IDs to update and column values to set.
struct UpdateInput {
    long[] ids;
    JSONValue[string] values;

    /// Get column names in consistent order
    @property string[] columns() const {
        return values.keys.dup;
    }

    /// Get values in same order as columns
    @property JSONValue[] orderedValues() const {
        auto cols = columns;
        JSONValue[] result;
        result.reserve(cols.length);
        foreach (c; cols) {
            result ~= values[c];
        }
        return result;
    }
}

// ============================================================================
// Insert Expression
// ============================================================================

/// Expression that executes INSERT and returns the new entity.
/// Returns a single entity (Expr!Entity).
class InsertExpr(Entity) : Expr!Entity, AnyRefEvaluable {
    private InsertInput _input;
    private string _table;
    private string _typeName;

    this(InsertInput input) {
        _input = input;
        _table = Entity._table;
        _typeName = Entity._typeName;
    }

    override ExprBase[] dependencies() {
        return [];  // Mutations are leaf nodes
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies
    }

    override Expr!Entity optimize(OptimizeContext ctx) {
        return this;  // Mutations are not optimizable
    }

    override Promise!(Entity[]) eval(EvalContext ctx) {
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();

        // Ensure fetcher is available
        auto fetcher = Entity._db;
        if (fetcher is null) {
            return resolve(cast(Entity[])[]);
        }

        if (relCtx.fetcher is null) {
            relCtx.fetcher = fetcher;
        }

        // Execute INSERT via DataFetcher
        return relCtx.fetcher.executeInsert(_table, _typeName, _input)
            .then((QueryResult result) {
                // Store result for field access
                relCtx.storeMutationResult(_typeName, result);

                // Convert refs to entities
                auto refs = result.allRefs();
                return refs.map!(r => Entity(r.nodeId)).array;
            });
    }

    /// AnyRefEvaluable implementation
    Promise!(AnyRef[]) evalAsAnyRef(EvalContext ctx) {
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();

        auto fetcher = Entity._db;
        if (fetcher is null) {
            return resolve(cast(AnyRef[])[]);
        }

        if (relCtx.fetcher is null) {
            relCtx.fetcher = fetcher;
        }

        return relCtx.fetcher.executeInsert(_table, _typeName, _input)
            .then((QueryResult result) {
                // Store result for field access
                relCtx.storeMutationResult(_typeName, result);
                return result.allRefs();
            });
    }

    /// Access input for SQL generation
    @property InsertInput input() { return _input; }
    @property string table() { return _table; }
    @property string typeName() { return _typeName; }
}

// ============================================================================
// Update Expression
// ============================================================================

/// Expression that executes UPDATE and returns updated entities.
/// Returns an array of entities (Expr!(Entity[])).
class UpdateExpr(Entity) : Expr!(Entity[]) {
    private UpdateInput _input;
    private string _table;
    private string _typeName;

    this(UpdateInput input) {
        _input = input;
        _table = Entity._table;
        _typeName = Entity._typeName;
    }

    override ExprBase[] dependencies() {
        return [];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies
    }

    override Expr!(Entity[]) optimize(OptimizeContext ctx) {
        return this;
    }

    override Promise!(Entity[][]) eval(EvalContext ctx) {
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();

        auto fetcher = Entity._db;
        if (fetcher is null) {
            return resolve([cast(Entity[])[]]);
        }

        if (relCtx.fetcher is null) {
            relCtx.fetcher = fetcher;
        }

        // Execute UPDATE via DataFetcher
        return relCtx.fetcher.executeUpdate(_table, _typeName, _input)
            .then((QueryResult result) {
                auto refs = result.allRefs();
                auto entities = refs.map!(r => Entity(r.nodeId)).array;
                return [entities];
            });
    }

    /// Get single result (for updateUser returning single entity)
    auto single() {
        return new SingleExpr!Entity(this);
    }

    @property UpdateInput input() { return _input; }
    @property string table() { return _table; }
    @property string typeName() { return _typeName; }
}

// ============================================================================
// Delete Expression
// ============================================================================

/// Expression that executes DELETE and returns success.
/// Returns bool indicating if any rows were deleted.
class DeleteExpr(Entity) : Expr!bool {
    private long[] _ids;
    private string _table;
    private string _typeName;

    this(long[] ids) {
        _ids = ids;
        _table = Entity._table;
        _typeName = Entity._typeName;
    }

    override ExprBase[] dependencies() {
        return [];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies
    }

    override Expr!bool optimize(OptimizeContext ctx) {
        return this;
    }

    override Promise!(bool[]) eval(EvalContext ctx) {
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();

        auto fetcher = Entity._db;
        if (fetcher is null) {
            return resolve([false]);
        }

        if (relCtx.fetcher is null) {
            relCtx.fetcher = fetcher;
        }

        // Execute DELETE via DataFetcher
        return relCtx.fetcher.executeDelete(_table, _ids)
            .then((int count) {
                return [count > 0];
            });
    }

    @property long[] ids() { return _ids; }
    @property string table() { return _table; }
    @property string typeName() { return _typeName; }
}

// ============================================================================
// Single Expression (extract one from array)
// ============================================================================

/// Expression that extracts a single element from an array expression.
/// Used by UpdateExpr.single() to get a single entity from update results.
class SingleExpr(T) : Expr!T, AnyRefEvaluable {
    private Expr!(T[]) _source;

    this(Expr!(T[]) source) {
        _source = source;
    }

    override ExprBase[] dependencies() {
        return [_source];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) {
            _source = cast(Expr!(T[])) newDep;
        }
    }

    override Expr!T optimize(OptimizeContext ctx) {
        _source = _source.optimize(ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        return evalAs!(T[])(_source, ctx).then((T[][] results) {
            T[] singles;
            foreach (arr; results) {
                singles ~= arr.length > 0 ? arr[0] : T.init;
            }
            return singles;
        });
    }

    /// AnyRefEvaluable implementation (for entity types)
    Promise!(AnyRef[]) evalAsAnyRef(EvalContext ctx) {
        return evalAs!(T[])(_source, ctx).then((T[][] results) {
            AnyRef[] refs;
            foreach (arr; results) {
                if (arr.length > 0) {
                    // T must have nodeId (entity type)
                    static if (__traits(hasMember, T, "nodeId")) {
                        refs ~= AnyRef(arr[0].nodeId);
                    } else {
                        refs ~= AnyRef.init;
                    }
                } else {
                    refs ~= AnyRef.init;
                }
            }
            return refs;
        });
    }
}

// ============================================================================
// Factory Functions
// ============================================================================

/// Create an INSERT expression for an entity.
/// Returns Expr!Entity that executes INSERT during evaluation.
///
/// Example:
/// ---
/// return insert!User([
///     "first_name": JSONValue("Alice"),
///     "email": JSONValue("alice@example.com")
/// ]);
/// ---
auto insert(Entity)(JSONValue[string] values) {
    return new InsertExpr!Entity(InsertInput(values));
}

/// Create an UPDATE expression for an entity.
/// Returns Expr!(Entity[]) with all updated entities.
///
/// Example:
/// ---
/// return update!User([1, 2], [
///     "first_name": JSONValue("Bob")
/// ]);
/// ---
auto update(Entity)(long[] ids, JSONValue[string] values) {
    return new UpdateExpr!Entity(UpdateInput(ids, values));
}

/// Create a DELETE expression for an entity.
/// Returns Expr!bool indicating success.
///
/// Example:
/// ---
/// return delete_!User([1, 2, 3]);
/// ---
auto delete_(Entity)(long[] ids) {
    return new DeleteExpr!Entity(ids);
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // Test InsertInput
    auto input = InsertInput([
        "first_name": JSONValue("Alice"),
        "email": JSONValue("alice@test.com")
    ]);

    assert(input.columns.length == 2);
    assert(input.orderedValues.length == 2);
}

unittest {
    // Test UpdateInput
    auto input = UpdateInput(
        [1, 2, 3],
        ["first_name": JSONValue("Bob")]
    );

    assert(input.ids == [1, 2, 3]);
    assert(input.columns.length == 1);
    assert(input.columns[0] == "first_name");
}
