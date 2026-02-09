module dunamis.relational.mutation;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

import ae.utils.promise;

import dunamis.core.types;
import dunamis.core.expr;
import dunamis.core.eval;
import dunamis.core.optimize : OptimizeContext;
import dunamis.relational.eval_context;
import dunamis.relational.schema : EntityID;

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
    string[] ids;
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
class InsertExpr(Entity) : Expr!Entity {
    import dunamis.relational.schema.attrs : getPkSqlColumns;

    private InsertInput _input;
    private string _table;
    private string _typeName;
    private enum string[] _pkColumns = getPkSqlColumns!Entity;

    this(InsertInput input) {
        _input = input;
        _table = EntityID!Entity.table;
        _typeName = EntityID!Entity.typeName;
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
        // Memoization: mutations should only execute once even when eval() is called
        // multiple times (e.g., when multiple ColumnAccessExpr share the same InsertExpr)
        if (auto cached = ctx.getCachedEval!Entity(this))
            return cached;

        auto relCtx = ctx.getSourceContext!RelationalEvalContext();

        // Ensure fetcher is available
        auto fetcher = EntityID!Entity.db;
        if (fetcher is null) {
            return resolve(cast(Entity[])[]);
        }

        if (relCtx.fetcher is null) {
            relCtx.fetcher = fetcher;
        }

        // Execute INSERT via DataFetcher
        auto promise = relCtx.fetcher.executeInsert(_table, _typeName, _input, _pkColumns)
            .then((QueryResult result) {
                // Store result for field access
                relCtx.storeMutationResult(_typeName, result);

                // Convert refs to entities
                auto refs = result.allRefs();
                import dunamis.relational.schema : makeEntityFromRef, entityToRef;
                auto entities = refs.map!(r => makeEntityFromRef!Entity(r)).array;

                // Populate plain fields from the mutation result
                // (makeEntityFromRef only sets PK fields; plain fields like
                // description need to be read from the QueryResult)
                _populatePlainFields(entities, refs, result);

                return entities;
            });

        // Cache for future calls
        ctx.setCachedEval!Entity(this, promise);
        return promise;
    }

    /// Populate plain non-PK fields on entities from a QueryResult.
    private static void _populatePlainFields(ref Entity[] entities, AnyRef[] refs, QueryResult result) {
        import dunamis.core.types : getPlainFieldNames, hasPrimaryKeyAttr;
        import dunamis.relational.schema.attrs : getPlainFieldColumnName;

        static foreach (fieldName; getPlainFieldNames!Entity) {{
            static if (!hasPrimaryKeyAttr!(Entity, fieldName)) {
                enum columnName = getPlainFieldColumnName!(Entity, fieldName);
                alias FieldType = typeof(__traits(getMember, Entity.init, fieldName));
                auto values = result.getColumn!FieldType(columnName, refs);
                foreach (i, ref e; entities) {
                    __traits(getMember, e, fieldName) = values[i];
                }
            }
        }}
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
    import dunamis.relational.schema.attrs : getPkSqlColumns;

    private UpdateInput _input;
    private string _table;
    private string _typeName;
    private enum string[] _pkColumns = getPkSqlColumns!Entity;

    this(UpdateInput input) {
        _input = input;
        _table = EntityID!Entity.table;
        _typeName = EntityID!Entity.typeName;
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

        auto fetcher = EntityID!Entity.db;
        if (fetcher is null) {
            return resolve([cast(Entity[])[]]);
        }

        if (relCtx.fetcher is null) {
            relCtx.fetcher = fetcher;
        }

        // Execute UPDATE via DataFetcher
        return relCtx.fetcher.executeUpdate(_table, _typeName, _input, _pkColumns)
            .then((QueryResult result) {
                auto refs = result.allRefs();
                import dunamis.relational.schema : makeEntityFromRef;
                auto entities = refs.map!(r => makeEntityFromRef!Entity(r)).array;
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
    import dunamis.relational.schema.attrs : getPkSqlColumns;

    private string[] _ids;
    private string _table;
    private string _typeName;
    private enum string[] _pkColumns = getPkSqlColumns!Entity;

    this(string[] ids) {
        _ids = ids;
        _table = EntityID!Entity.table;
        _typeName = EntityID!Entity.typeName;
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

        auto fetcher = EntityID!Entity.db;
        if (fetcher is null) {
            return resolve([false]);
        }

        if (relCtx.fetcher is null) {
            relCtx.fetcher = fetcher;
        }

        // Execute DELETE via DataFetcher
        return relCtx.fetcher.executeDelete(_table, _ids, _pkColumns)
            .then((int count) {
                return [count > 0];
            });
    }

    @property string[] ids() { return _ids; }
    @property string table() { return _table; }
    @property string typeName() { return _typeName; }
}

// ============================================================================
// Single Expression (extract one from array)
// ============================================================================

/// Expression that extracts a single element from an array expression.
/// Used by UpdateExpr.single() to get a single entity from update results.
class SingleExpr(T) : Expr!T {
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
/// return update!User(["1", "2"], [
///     "first_name": JSONValue("Bob")
/// ]);
/// ---
auto update(Entity)(string[] ids, JSONValue[string] values) {
    return new UpdateExpr!Entity(UpdateInput(ids, values));
}

/// Create a DELETE expression for an entity.
/// Returns Expr!bool indicating success.
///
/// Example:
/// ---
/// return delete_!User(["1", "2", "3"]);
/// ---
auto delete_(Entity)(string[] ids) {
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
        ["1", "2", "3"],
        ["first_name": JSONValue("Bob")]
    );

    assert(input.ids == ["1", "2", "3"]);
    assert(input.columns.length == 1);
    assert(input.columns[0] == "first_name");
}
