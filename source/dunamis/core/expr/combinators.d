module dunamis.core.expr.combinators;

import std.array;
import std.conv : to;
import std.meta;
import std.range : iota;
import std.traits;
import std.typecons : Tuple;
static import std.algorithm;

import ae.utils.promise;

import dunamis.core.types;
import dunamis.core.eval;
import dunamis.core.optimize;
import dunamis.core.expr.base;
import dunamis.core.join : joinAll;

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

        static if (Exprs.length == 1) {
            // A single input needs no joining. (Joining compiles promise,
            // result and tuple types of its own for each input type: for
            // each `use` of a schema type, e.g. each plugin's cast of a
            // nullable object.)
            return evalAs!(InputTypes[0])(_inputs[0], ctx).then((InputTypes[0][] values) {
                R[] result = new R[values.length];
                foreach (idx; 0 .. values.length)
                    result[idx] = fn(values[idx]);
                return result;
            });
        } else {
            // Build tuple of promises for all inputs
            alias PromiseTypes = staticMap!(toPromiseArray, InputTypes);
            Tuple!PromiseTypes promises;
            static foreach (i; 0 .. Exprs.length) {
                promises[i] = evalAs!(InputTypes[i])(_inputs[i], ctx);
            }

            // Wait for all, then combine results
            return joinAll(promises.expand).then((EvaluatedArrays results) {
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

/// Interface for the reads of a plain field (a field stored in the entity
/// struct itself, e.g. its primary key) of entities, for optimizers to
/// recognize: a data source storing the field (e.g. as a column) can read it
/// itself, e.g. to push down a filter on it.
interface PlainFieldInfo {
    /// The name of the field (of the entity type the owner's elements wrap).
    string plainFieldName();

    /// The entities whose field is read (type-erased Expr!Entity).
    ExprBase plainFieldOwner();
}

/// The plain field `name` of each element of `owner`, which `fn` reads (see
/// `plainField`).
class PlainFieldExpr(Fn, E) : UseExpr!(Fn, E), PlainFieldInfo {
    private string _name;

    this(E owner, Fn fn, string name) {
        super(owner, fn);
        _name = name;
    }

    string plainFieldName() { return _name; }

    ExprBase plainFieldOwner() { return dependencies()[0]; }
}

/// `use(fn, owner)`, where `fn` reads the plain field `name` of an entity:
/// marked as such (see PlainFieldInfo).
auto plainField(string name, Fn, E)(Fn fn, E owner)
    if (isExpr!E)
{
    return new PlainFieldExpr!(Fn, E)(owner, fn, name);
}

// ============================================================================
// TryUse Combinator (per-element error catching)
// ============================================================================

/// Like UseExpr, but catches exceptions per-element and wraps results
/// in GqlResult. Successful elements get GqlResult.ok(value), failed
/// elements get GqlResult.err(exception.msg).
///
/// This allows expressions that may throw for individual elements to
/// produce partial results instead of failing the entire batch.
class TryUseExpr(Fn, Exprs...) : Expr!(GqlResult!(ReturnType!Fn))
    if (Exprs.length >= 1 && allSatisfy!(isExpr, Exprs))
{
    alias R = ReturnType!Fn;
    alias InputTypes = staticMap!(ExprResultType, Exprs);
    alias EvaluatedArrays = Tuple!(staticMap!(toArray, InputTypes));

    private ExprBase[Exprs.length] _inputs;
    private Fn _fn;

    this(Exprs inputs, Fn fn) {
        static foreach (i; 0 .. Exprs.length) {
            _inputs[i] = inputs[i];
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

    override Expr!(GqlResult!R) optimize(OptimizeContext ctx) {
        static foreach (i; 0 .. Exprs.length) {
            _inputs[i] = (cast(Expr!(InputTypes[i])) _inputs[i]).optimize(ctx);
        }
        return this;
    }

    override Promise!(GqlResult!R[]) eval(EvalContext ctx) {
        auto fn = _fn;

        alias PromiseTypes = staticMap!(toPromiseArray, InputTypes);
        Tuple!PromiseTypes promises;
        static foreach (i; 0 .. Exprs.length) {
            promises[i] = evalAs!(InputTypes[i])(_inputs[i], ctx);
        }

        return joinAll(promises.expand).then((EvaluatedArrays results) {
            GqlResult!R[] result = new GqlResult!R[results[0].length];
            foreach (idx; 0 .. results[0].length) {
                Tuple!InputTypes args;
                static foreach (i; 0 .. Exprs.length) {
                    args[i] = results[i][idx];
                }
                try {
                    result[idx] = GqlResult!R.ok(fn(args.expand));
                } catch (Exception e) {
                    result[idx] = GqlResult!R.err(e.msg);
                }
            }
            return result;
        });
    }
}

/// Like `use`, but catches exceptions per-element and wraps results in GqlResult.
/// Successful elements get GqlResult.ok(value), failed elements get GqlResult.err(msg).
auto tryUse(Fn, Exprs...)(Fn fn, Exprs exprs)
    if (Exprs.length >= 1 && allSatisfy!(isExpr, Exprs))
{
    return new TryUseExpr!(Fn, Exprs)(exprs, fn);
}

// ============================================================================
// Broadcast Combinator (cross-collection access)
// ============================================================================

/// Replicates a single-batch expression result to match another expression's
/// batch size. Used when a computed field needs data from an unrelated
/// collection (e.g., a global holidays table accessed from a User field).
///
/// Similar to ConstExpr (which replicates a literal value), but for
/// expression-derived values. The source expression is evaluated once,
/// and its single result is replicated for each element in the target batch.
///
/// Example:
/// ---
/// static auto availability(Expr!User u) {
///     return use(
///         (string name, Holiday[] allHolidays) => ...,
///         u.firstName,                                    // batch size N
///         Query().singleton().holidays().broadcast(u)     // replicated to N
///     );
/// }
/// ---
class BroadcastExpr(T) : Expr!T {
    private Expr!T _source;
    private ExprBase _sizeReference;

    this(Expr!T source, ExprBase sizeReference) {
        _source = source;
        _sizeReference = sizeReference;
    }

    override ExprBase[] dependencies() {
        return [cast(ExprBase) _source, _sizeReference];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _source = cast(Expr!T) newDep;
        else if (index == 1) _sizeReference = newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        _source = _source.optimize(ctx);
        _sizeReference = optimizeExpr(_sizeReference, ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        alias ResultTuple = Tuple!(T[], size_t);
        return joinAll(
            _source.eval(ctx),
            _sizeReference.evalResultLength(ctx)
        ).then((ResultTuple results) {
            auto sourceResults = results[0];
            auto targetSize = results[1];
            assert(sourceResults.length >= 1,
                "broadcast source must produce at least 1 result");
            auto value = sourceResults[0];
            return std.algorithm.map!(_ => value)(iota(targetSize)).array;
        });
    }
}

/// Replicate a single-batch expression to match another expression's batch size.
/// Use this when a computed field needs data from an unrelated collection.
auto broadcast(T)(Expr!T source, ExprBase sizeReference) {
    return new BroadcastExpr!T(source, sizeReference);
}

// ============================================================================
// OnlyIfExpr: Conditional Collections
// ============================================================================

/// Interface of a conditional collection (see `onlyIf`), for optimizers.
interface OnlyIfInfo {
    /// The collection (type-erased), of which the conditional collection is
    /// either all or none of the elements.
    ExprBase onlyIfSource();
}

/// The collection `source` where `condition` holds, else an empty list (see
/// `onlyIf`).
///
/// It is either all of the source's elements or none of them, so it
/// commutes with filters, sorts and windows over it: an optimizer may see
/// through it (pushing a filter over it into the source's query), as it does
/// through entity casts.
class OnlyIfExpr(T) : Expr!(T[]), OnlyIfInfo {
    private ExprBase _source;     // Expr!(T[]), dependency 0 (the collection)
    private ExprBase _condition;  // Expr!bool

    this(Expr!(T[]) source, Expr!bool condition) {
        _source = source;
        _condition = condition;
    }

    ExprBase onlyIfSource() { return _source; }

    override ExprBase[] dependencies() {
        return [_source, _condition];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _source = newDep;
        else if (index == 1) _condition = newDep;
    }

    override Expr!(T[]) optimize(OptimizeContext ctx) {
        _source = (cast(Expr!(T[])) _source).optimize(ctx);
        _condition = (cast(Expr!bool) _condition).optimize(ctx);
        return this;
    }

    override Promise!(T[][]) eval(EvalContext ctx) {
        auto source = cast(Expr!(T[])) _source;
        return (cast(Expr!bool) _condition).eval(ctx).then((bool[] conditions) {
            bool any;
            foreach (c; conditions)
                any = any || c;
            if (!any)  // (The source is not evaluated.)
                return resolve(new T[][](conditions.length));
            return source.eval(ctx).then((T[][] lists) {
                // (A source of a batch of one, e.g. a root collection, is
                // the same for every item.)
                assert(lists.length == conditions.length || lists.length == 1,
                    "onlyIf: the source's batch is neither the condition's nor of one");
                auto result = new T[][](conditions.length);
                foreach (i, c; conditions)
                    if (c)
                        result[i] = lists[lists.length == 1 ? 0 : i];
                return result;
            });
        });
    }
}

/// The collection `source` if `condition` holds, else an empty list, for
/// each item of the batch (`condition`'s): e.g. a root collection, depending
/// on a value of the object of a field. The source is evaluated only if the
/// condition holds for some item. Filters, sorts and windows applied to the
/// result apply to the source as they would to the source itself (so that,
/// for a root collection, they are pushed into its SQL query alike).
auto onlyIf(T)(Expr!bool condition, Expr!(T[]) source) {
    return new OnlyIfExpr!T(source, condition);
}

// ============================================================================
// ContextExpr: Request Context Access
// ============================================================================

/// Expression that reads a request context value from EvalContext and
/// replicates it across the batch. Used to pass request-scoped data
/// (e.g., authenticated user, tenant ID, locale) into computed fields.
///
/// Example:
/// ---
/// static auto greeting(Expr!User u) {
///     return use(
///         (string firstName, TenantCtx tenant) =>
///             tenant.locale == "fr" ? "Bonjour " ~ firstName : "Hello " ~ firstName,
///         u.firstName,
///         context!TenantCtx(u)
///     );
/// }
/// ---
class ContextExpr(T) : Expr!T if (is(T == struct)) {
    private ExprBase _batchRef;

    this(ExprBase batchRef) {
        _batchRef = batchRef;
    }

    override ExprBase[] dependencies() {
        return [_batchRef];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _batchRef = newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        // Context values are runtime data; the batch is the reference's
        _batchRef = optimizeExpr(_batchRef, ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto value = ctx.getRequestContext!T();
        return _batchRef.evalResultLength(ctx).then((size_t count) {
            T[] results = new T[count];
            results[] = value;
            return results;
        });
    }
}

/// Create a context expression that reads request-scoped data of type T.
/// The batchRef determines the batch size (typically pass the entity expression).
///
/// Example:
/// ---
/// auto tenantCtx = context!TenantCtx(u);  // u is Expr!User
/// ---
auto context(T)(ExprBase batchRef) if (is(T == struct)) {
    return new ContextExpr!T(batchRef);
}

// ============================================================================
// EventSourceExpr: Subscription Event Delivery
// ============================================================================

/// Expression that reads event data from the EvalContext.
/// Used as the root expression for subscription fields. The subscription
/// executor delivers event data via deliver() before evaluating the tree.
///
/// Always produces a batch of size 1 (one event per evaluation).
///
/// Example (subscription executor loop):
/// ---
/// auto expr = eventSource!ChangeEvent();
/// // ... compile and optimize expression tree once ...
///
/// while (true) {
///     auto event = waitForEvent();
///     auto ctx = new EvalContext();
///     expr.deliver(ctx, event);
///     auto result = awaitSync(tree.eval(ctx));
///     sendToClient(result);
/// }
/// ---
class EventSourceExpr(T) : Expr!T {
    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t, ExprBase) {}
    override Expr!T optimize(OptimizeContext ctx) { return this; }

    /// Deliver event data into the given eval context.
    /// Call this before evaluating the expression tree.
    void deliver(EvalContext ctx, T value) {
        ctx.setValues!T(this, [value]);
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto values = ctx.getValues!T(this);
        if (values.length == 0) {
            throw new Exception("EventSourceExpr: no event data delivered");
        }
        return resolve(values);
    }
}

/// Create an event source expression.
/// The expression reads event data from the EvalContext at eval time.
auto eventSource(T)() {
    return new EventSourceExpr!T();
}

// ============================================================================
// SubscriptionResultExpr: Subscription Operation Marker
// ============================================================================

/// Wraps a subscription query's result expression to mark it as a subscription
/// operation. Analogous to how SequentialJsonObjectExpr marks mutations —
/// the expression type itself carries the operation semantics.
///
/// Servers use `cast(SubscriptionResultExpr)` to detect subscription operations
/// and route them to SubscriptionExecutor instead of direct execution.
class SubscriptionResultExpr : ForwardingExpr!(_JSONValue) {
    this(Expr!_JSONValue inner) { super(inner); }
}

// ============================================================================
// EffectExpr: Deferred Side Effects
// ============================================================================

/// Expression that executes a side-effecting callable during evaluation.
/// Used for mutations and other operations that should be deferred.
/// The callable is called once per evaluation, regardless of batch size.
class EffectExpr(T, Fn) : Expr!T {
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
interface EveryItemOfExprInfo {
    /// Get the parent MapExpr (as Object)
    @property Object parentMap();
}

/// Placeholder representing "current item" within a map iteration.
/// When MapExpr evaluates its body, it passes the flattened collection refs.
/// EveryItemOfExpr just returns those refs unchanged - it's a pass-through
/// that represents "the items being iterated over".
///
/// Typed with the Entity being iterated. Returns Entity with PK populated.
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
        // Retrieve values from generic storage
        auto vals = ctx.getValues!T(_parentMap);
        if (vals.length > 0) {
            return resolve(vals);
        }
        return resolve(cast(T[])[]);
    }

}

/// Interface to query collection type from MapExpr without knowing the template params.
/// Used by data-source-specific optimizers to configure query nodes.
interface MapExprInfo {
    /// Get the collection expression (type-erased).
    /// Optimizer can cast this to data-source-specific interfaces
    /// (e.g., HasManyInfo, RootExprInfo) to extract metadata.
    Object collection();

    /// Get the body expression (type-erased).
    /// Used by linkIndexSources to traverse into nested MapExprs.
    ExprBase bodyExpr();
}

/// Whether a map yields each element of its collection itself, possibly
/// through entity casts (as plugin layers do).  Such a map preserves its
/// collection's rows and their order, so optimizers may see through it; any
/// other map yields different values, which are not its collection's rows.
bool preservesElements(MapExprInfo map) {
    import dunamis.core.expr.primitives : EntityCastInfo;

    Object item = map.bodyExpr;
    while (auto entityCast = cast(EntityCastInfo) item) {
        if (entityCast.inputExpr is item) return false;
        item = entityCast.inputExpr;
    }
    auto every = cast(EveryItemOfExprInfo) item;
    return every !is null && every.parentMap is cast(Object) map;
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
    private Object _indexKey;            // key for local element index storage
    private Object _groupIndexKey;       // key for group (parent) index storage

    this(Expr!(Entity[]) collection, EveryItemOfExpr!Entity item, Body body_) {
        _collection = collection;
        _item = item;
        _body = body_;  // Implicit upcast to ExprBase
        _indexKey = new Object();
        _groupIndexKey = new Object();
    }

    /// Key used to look up element indices from EvalContext.
    /// Each element gets its local index within its parent's collection.
    @property Object indexKey() { return _indexKey; }

    /// Key used to look up group indices from EvalContext.
    /// Each element maps to its parent group's position in the outer batch.
    @property Object groupIndexKey() { return _groupIndexKey; }

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
        import dunamis.core.elements : registerElementOwner;

        // The items of the filters and sorts of the collection range over
        // rows of it, as this map's own item does
        registerElementOwner(ctx, this, _collection);

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
        auto indexKey = _indexKey;
        auto groupIndexKey = _groupIndexKey;

        // 1. Evaluate collection for each parent ref
        return evalAs!(Entity[])(_collection, ctx).then((Entity[][] collectionResults) {
            // 2. Flatten for batch evaluation
            Entity[] flatEntities;
            size_t[] lengths;
            size_t[] localIndices;
            size_t[] groupIndices;
            foreach (groupIdx, group; collectionResults) {
                lengths ~= group.length;
                foreach (j, e; group) {
                    flatEntities ~= e;
                    localIndices ~= j;
                    groupIndices ~= groupIdx;
                }
            }

            if (flatEntities.length == 0) {
                // No items to process - return empty array for each parent
                return resolve(std.algorithm.map!(_ => cast(R[])[])(iota(collectionResults.length)).array);
            }

            // 3. Store values for EveryItemOfExpr to retrieve
            ctx.setValues!Entity(self, flatEntities);

            // 4. Store indices for error path tracking (separate keys)
            ctx.setValues!size_t(indexKey, localIndices);
            ctx.setValues!size_t(groupIndexKey, groupIndices);

            // 5. Evaluate body with ALL refs at once
            return evalAs!R(bodyExpr, ctx).then((R[] flatResults) {
                // The body yields one result per element. One result for a
                // whole batch is not replicated: an expression producing a
                // single value (e.g. reaching a root collection) must be
                // aligned to the batch with broadcast().
                if (flatResults.length != flatEntities.length)
                    throw new Exception("Batch size mismatch in map over " ~ Entity.stringof ~
                        ": its body produced " ~ flatResults.length.to!string ~ " results for " ~
                        flatEntities.length.to!string ~ " elements (use broadcast() to replicate " ~
                        "a single value across a batch)");
                // 6. Regroup to match input structure
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
    ExprBase bodyExpr() { return _body; }
}

/// Extract the Entity type from an Expr!(Entity[]) type
template CollectionEntityType(Coll) {
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

    // 5. Auto-link index sources for error path tracking
    linkIndexSources(body_, IndexLevel(mapExpr.indexKey, mapExpr.groupIndexKey));

    return mapExpr;
}

/// Walk the expression tree and link any IndexSourceConsumer to the given
/// index level. Traverses into nested MapExpr bodies (but not their
/// collections) so that outer map indices reach inner consumers.
private void linkIndexSources(ExprBase root, IndexLevel level) {
    if (auto consumer = cast(IndexSourceConsumer) root) {
        consumer.addIndexSource(level);
    }
    foreach (dep; root.dependencies()) {
        if (auto mapInfo = cast(MapExprInfo) dep) {
            // For nested MapExprs, only traverse the body (not the collection)
            // to avoid interfering with the collection's own index sources
            auto body_ = mapInfo.bodyExpr();
            if (body_ !is null)
                linkIndexSources(body_, level);
        } else {
            linkIndexSources(dep, level);
        }
    }
}

// ============================================================================
// SomeExpr: Collection Predicate Expression
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

            // Store all items in unified value storage
            Entity[] flatVals;
            flatVals.reserve(totalItems);
            foreach (group; collectionResults) {
                foreach (v; group) {
                    flatVals ~= v;
                }
            }
            debug(filter) {
                import std.stdio : writefln;
                writefln("  SomeExpr.eval: %d groups, %d total items", collectionResults.length, flatVals.length);
            }
            ctx.setValues!Entity(self, flatVals);

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
/// Implemented as not(some(not(pred))) - De Morgan's law.
///
/// Example:
/// ---
/// auto allPublished = every!((Expr!Post p) => p.isPublished)(user.posts);
/// ---
auto every(alias pred, Coll)(Coll collection)
    if (is(Coll : Expr!(E[]), E))
{
    // every(pred) = not(some(not(pred)))
    return some!((item) => pred(item).not())(collection).not();
}


// ============================================================================
// Tests
// ============================================================================

import ae.utils.promise.await : awaitSync;
import dunamis.core.expr.primitives : FieldAccessExpr;

/// Dummy entity type for tests
private struct TestEntity {
    string id;
    string typeName;                // Extra field for test assertions
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
    // Test map with use combinator - extracts primary key
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1", "Test"), TestEntity("2", "Test")]);

    auto query = map!(
        (Expr!TestEntity item) => use((TestEntity e) => e.id, item)
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["1", "2"]);
}

unittest {
    // Test map with jsonObject - builds structured output
    import dunamis.core.expr.json : jsonObject;

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1", "User"), TestEntity("2", "User")]);

    auto query = map!(
        (Expr!TestEntity item) => jsonObject(
            "id", use((TestEntity e) => e.id, item),
            "type", use((TestEntity e) => e.typeName, item)
        )
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0].length == 2);
    assert(result[0][0]["id"].str == "1");
    assert(result[0][0]["type"].str == "User");
    assert(result[0][1]["id"].str == "2");
}

unittest {
    // Test string concatenation with literals inside map
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1", "Test"), TestEntity("2", "Test")]);

    auto query = map!(
        (Expr!TestEntity item) => use((TestEntity e) => e.typeName, item) ~ ":" ~ use((TestEntity e) => e.id, item)
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["Test:1", "Test:2"]);
}

unittest {
    import std.conv : to;

    // Test arithmetic operators with literals inside map
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1"), TestEntity("2"), TestEntity("3")]);

    auto query = map!(
        (Expr!TestEntity item) {
            // Use id parsed to int for arithmetic test
            auto id = use((TestEntity e) => e.id.to!long, item);
            return id * 10 + 5;
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [15, 25, 35]);  // (1*10+5), (2*10+5), (3*10+5)
}

unittest {
    import std.conv : to;

    // Test comparison operators inside map
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("10"), TestEntity("15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            return val.gt(7);  // 5 > 7 = false, 10 > 7 = true, 15 > 7 = true
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [false, true, true]);
}

unittest {
    import std.conv : to;

    // Test boolean AND operator
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("10"), TestEntity("15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            return val.gt(5).and(val.lt(15));  // 5>5 && 5<15 = false, 10>5 && 10<15 = true, 15>5 && 15<15 = false
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [false, true, false]);
}

unittest {
    import std.conv : to;

    // Test boolean OR operator
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("10"), TestEntity("15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            return val.lt(8).or(val.gt(12));  // 5<8 || 5>12 = true, 10<8 || 10>12 = false, 15<8 || 15>12 = true
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [true, false, true]);
}

unittest {
    import std.conv : to;

    // Test boolean NOT operator
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("10"), TestEntity("15")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            return val.gt(8).not();  // !(5>8) = true, !(10>8) = false, !(15>8) = false
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [true, false, false]);
}

unittest {
    import std.conv : to;

    // Test ternary expression
    import dunamis.core.expr.operators : ternary;

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("15"), TestEntity("25")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            return ternary(val.ge(18), "adult", "minor");  // 5>=18 ? adult : minor, etc.
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["minor", "minor", "adult"]);
}

unittest {
    import std.conv : to;

    // Test nested ternary expression (chained conditions)
    import dunamis.core.expr.operators : ternary;

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("15"), TestEntity("25")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            // age < 13 -> "child", age < 20 -> "teen", else "adult"
            return ternary(val.lt(13), "child", ternary(val.lt(20), "teen", "adult"));
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == ["child", "teen", "adult"]);
}

unittest {
    import std.conv : to;

    // Test combined boolean operators: (a AND b) OR c
    auto collection = new MockCollectionExpr!TestEntity([TestEntity("5"), TestEntity("10"), TestEntity("20")]);

    auto query = map!(
        (Expr!TestEntity item) {
            auto val = use((TestEntity e) => e.id.to!long, item);
            // (val > 5 AND val < 15) OR val > 18
            // 5: (false AND true) OR false = false
            // 10: (true AND true) OR false = true
            // 20: (true AND false) OR true = true
            return val.gt(5).and(val.lt(15)).or(val.gt(18));
        }
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == [false, true, true]);
}

// Test POD struct in map context
unittest {
    import std.conv : to;

    // POD struct
    static struct Stats {
        int count;
        int total;
    }

    // Custom Expr returning POD struct array
    static class ConstStatsExpr : Expr!(Stats[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t index, ExprBase newDep) {}
        override Expr!(Stats[]) optimize(OptimizeContext ctx) { return this; }

        override Promise!(Stats[][]) eval(EvalContext ctx) {
            // Return one group with two Stats items
            return resolve([[Stats(10, 100), Stats(20, 200)]]);
        }
    }

    // Map over POD structs and extract a field
    auto statsExpr = new ConstStatsExpr();
    auto query = map!(
        (Expr!Stats s) => new FieldAccessExpr!(Stats, "count")(s)
    )(statsExpr);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1, "Expected 1 group");
    assert(result[0].length == 2, "Expected 2 items in group");
    assert(result[0] == [10, 20], "Expected counts [10, 20], got " ~ result[0].to!string);
}

// Test ContextExpr with use combinator
unittest {
    static struct TenantCtx {
        string tenantId;
        string locale;
    }

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1"), TestEntity("2"), TestEntity("3")]);

    auto query = map!(
        (Expr!TestEntity item) => use(
            (string id, TenantCtx tenant) => id ~ ":" ~ tenant.locale,
            use((TestEntity e) => e.id, item),
            context!TenantCtx(item)
        )
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    ctx.setRequestContext(TenantCtx("t1", "fr"));

    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1, "Expected 1 group");
    assert(result[0] == ["1:fr", "2:fr", "3:fr"],
        "Expected context value replicated across batch");
}

// ============================================================================
// Abstract Type Expressions (Unions / Interfaces)
// ============================================================================

/// Interface for runtime member key lookup on union/abstract type expressions.
/// Decouples compile-time member types (known to the compiler) from runtime
/// storage keys (created by UnionExpr at construction time).
///
/// The compiler creates SubsetExpr at compile time for each concrete member type.
/// SubsetExpr needs the runtime Object key to retrieve that member's elements
/// from EvalContext. UnionExprInfo bridges this gap.
interface UnionExprInfo {
    /// Get the EvalContext storage key for a specific member type.
    /// Returns null if the type is not a member of this union.
    Object memberKeyForType(TypeInfo ti);

    /// Trigger evaluation of this union expression.
    /// Must be called before reading member data from EvalContext.
    /// Uses evalAs caching internally — safe to call multiple times.
    Promise!void triggerEval(EvalContext ctx);
}

/// Concatenates heterogeneous arrays from multiple sources into a single
/// abstract/union type batch, storing per-member results in EvalContext.
///
/// Each member source is evaluated sequentially. Results are stored under
/// per-type Object keys in EvalContext, accessible via UnionExprInfo.
/// The expression returns a size_t[] "index array" where each element's
/// value encodes which member type it belongs to and its position within
/// that member's batch.
///
/// Usage (via unionOf factory):
/// ---
/// auto searchResults = unionOf!SearchResult(Query.users(), Query.posts());
/// ---
class UnionExpr(AbstractT, Members...) : Expr!(AbstractT[]), UnionExprInfo {
    private ExprBase[] _sources;
    private Object[Members.length] _memberKeys;
    private TypeInfo[Members.length] _memberTypeIds;

    this(staticMap!(toArrayExpr, Members) sources) {
        static foreach (i; 0 .. Members.length) {
            _sources ~= sources[i];
            _memberKeys[i] = new Object();
            _memberTypeIds[i] = typeid(Members[i]);
        }
    }

    /// UnionExprInfo: get the storage key for a member type
    Object memberKeyForType(TypeInfo ti) {
        static foreach (i; 0 .. Members.length) {
            if (ti == _memberTypeIds[i])
                return _memberKeys[i];
        }
        return null;
    }

    /// UnionExprInfo: trigger evaluation (relies on evalAs caching for dedup)
    Promise!void triggerEval(EvalContext ctx) {
        return evalAs!(AbstractT[])(cast(ExprBase) this, ctx).then((AbstractT[][] _) {});
    }

    override ExprBase[] dependencies() {
        return _sources.dup;
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        _sources[index] = newDep;
    }

    override Expr!(AbstractT[]) optimize(OptimizeContext ctx) {
        foreach (i, ref src; _sources) {
            static foreach (j; 0 .. Members.length) {
                if (i == j) {
                    src = (cast(Expr!(Members[j][])) src).optimize(ctx);
                }
            }
        }
        return this;
    }

    override Promise!(AbstractT[][]) eval(EvalContext ctx) {
        // Evaluate all member sources, store results in EvalContext,
        // return dummy AbstractT[] (SubsetExpr reads from EvalContext, not this)
        return _evalMemberSources(ctx).then((size_t[][] countArr) {
            auto count = cast(size_t) countArr[0][0];
            return [new AbstractT[](count)];
        });
    }

    // Evaluate member sources sequentially, store in EvalContext, track total count
    private Promise!(size_t[][]) _evalMemberSources(EvalContext ctx) {
        auto p = resolve(cast(size_t[][]) [[cast(size_t) 0]]);

        static foreach (i; 0 .. Members.length) {{
            auto key = _memberKeys[i];
            auto src = _sources[i];

            p = p.then((size_t[][] prev) {
                return evalAs!(Members[i][])(src, ctx).then((Members[i][][] memberResults) {
                    // Flatten member results and store in context
                    Members[i][] flat;
                    foreach (group; memberResults) {
                        flat ~= group;
                    }
                    ctx.setValues!(Members[i])(key, flat);

                    return [[prev[0][0] + flat.length]];
                });
            });
        }}

        return p;
    }
}

/// Helper: map a type to Expr!(T[])
private template toArrayExpr(T) {
    alias toArrayExpr = Expr!(T[]);
}

/// Extracts elements of a single concrete type from a union expression's stored results.
/// Used by the compiler to process one member type's fields at a time.
class SubsetExpr(Member) : Expr!(Member[]) {
    private ExprBase _unionExpr;  // must implement UnionExprInfo
    private Object _memberKey;    // resolved from UnionExprInfo at construction/optimization

    this(ExprBase unionExpr) {
        _unionExpr = unionExpr;
        resolveMemberKey();
    }

    /// Construct with explicit key (for cases where UnionExprInfo isn't directly available)
    this(ExprBase unionExpr, Object memberKey) {
        _unionExpr = unionExpr;
        _memberKey = memberKey;
    }

    override ExprBase[] dependencies() {
        return [_unionExpr];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) {
            _unionExpr = newDep;
            resolveMemberKey();
        }
    }

    override Expr!(Member[]) optimize(OptimizeContext ctx) {
        // Optimize the parent union expression.
        // Multiple SubsetExprs may share the same UnionExpr parent;
        // optimizeExpr is idempotent after the first pass.
        _unionExpr = optimizeExpr(_unionExpr, ctx);
        resolveMemberKey();
        return this;
    }

    /// Resolve the member key from the union expression, if not known yet.
    /// Only done while the tree is built or optimized, never during evaluation.
    private void resolveMemberKey() {
        if (_memberKey is null)
            if (auto info = cast(UnionExprInfo) _unionExpr)
                _memberKey = info.memberKeyForType(typeid(Member));
    }

    override Promise!(Member[][]) eval(EvalContext ctx) {
        assert(_memberKey !is null, "SubsetExpr: no member key for " ~ Member.stringof);

        auto key = _memberKey;
        // Ensure parent union is evaluated first (stores member data in EvalContext).
        // Uses evalAs caching — safe when multiple SubsetExprs share one UnionExpr.
        auto info = cast(UnionExprInfo) _unionExpr;
        assert(info !is null, "SubsetExpr: parent must implement UnionExprInfo");
        return info.triggerEval(ctx).then(() {
            return [ctx.getValues!Member(key)];
        });
    }
}

// Module-level alias for JSONValue to use in class declarations
private import std.json : _JSONValue = JSONValue;

/// Concatenates multiple JSONValue[] results into a single JSONValue[].
/// Used by the compiler to merge per-type-condition JSON arrays from
/// union/interface compilation.
class ConcatArrayExpr : Expr!(_JSONValue[]) {
    private ExprBase[] _sources;

    this(ExprBase[] sources...) {
        _sources = sources.dup;
    }

    override ExprBase[] dependencies() {
        return _sources.dup;
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        _sources[index] = newDep;
    }

    override Expr!(_JSONValue[]) optimize(OptimizeContext ctx) {
        foreach (ref src; _sources) {
            src = optimizeExpr(src, ctx);
        }
        return this;
    }

    override Promise!(_JSONValue[][]) eval(EvalContext ctx) {
        // Build the chain using indexed access to avoid D closure capture issues.
        // D's foreach loop variables are captured by reference, so all closures
        // would see the last iteration's value. Using array indexing is safe.
        auto sources = _sources;
        auto p = resolve(cast(_JSONValue[][]) [cast(_JSONValue[])[]]);

        foreach (i; 0 .. sources.length) {
            p = _chainSource(p, sources[i], ctx);
        }
        return p;
    }

    private static Promise!(_JSONValue[][]) _chainSource(
        Promise!(_JSONValue[][]) prev, ExprBase src, EvalContext ctx)
    {
        return prev.then((_JSONValue[][] prevArr) {
            return evalAs!(_JSONValue[])(src, ctx).then((_JSONValue[][] srcResults) {
                _JSONValue[] merged = prevArr[0];
                foreach (group; srcResults) {
                    merged ~= group;
                }
                return [merged];
            });
        });
    }
}

/// Factory function: create a UnionExpr from multiple member array sources.
///
/// Example:
/// ---
/// auto results = unionOf!SearchResult(Query.users(), Query.posts());
/// ---
auto unionOf(AbstractT, Sources...)(Sources sources)
    if (Sources.length >= 1)
{
    // Extract member types from source expression types
    alias MemberTypes = staticMap!(ArrayElementType, staticMap!(ExprResultType, Sources));
    return new UnionExpr!(AbstractT, MemberTypes)(sources);
}

/// Helper: extract T from T[]
private template ArrayElementType(T) {
    static if (is(T == E[], E)) {
        alias ArrayElementType = E;
    } else {
        static assert(false, "Expected array type, got " ~ T.stringof);
    }
}

unittest {
    // Test tryUse - catches per-element exceptions and wraps in GqlResult
    import std.conv : to, ConvException;

    auto collection = new MockCollectionExpr!TestEntity([
        TestEntity("10"), TestEntity("bad"), TestEntity("5"),
    ]);

    auto query = map!(
        (Expr!TestEntity item) => tryUse(
            (string id) => id.to!int * 2,  // throws ConvException for "bad"
            use((TestEntity e) => e.id, item),
        )
    )(collection);

    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    auto result = awaitSync(query.eval(ctx));

    assert(result.length == 1);
    assert(result[0].length == 3);
    assert(!result[0][0].isError && result[0][0].value == 20);
    assert(result[0][1].isError);  // "bad" can't be converted to int
    assert(!result[0][2].isError && result[0][2].value == 10);
}

unittest {
    // Test EventSourceExpr - basic event delivery
    static struct TestEvent {
        string table;
        int count;
    }

    auto expr = eventSource!TestEvent();
    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);

    expr.deliver(ctx, TestEvent("users", 3));
    auto result = awaitSync(expr.eval(ctx));
    assert(result.length == 1);
    assert(result[0].table == "users");
    assert(result[0].count == 3);
}

unittest {
    // Test EventSourceExpr with downstream use()
    auto expr = eventSource!int();
    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);

    auto doubled = use((int n) => n * 2, expr);

    expr.deliver(ctx, 42);
    auto result = awaitSync(doubled.eval(ctx));
    assert(result == [84]);
}

unittest {
    // Test EventSourceExpr with ChangeEvent (class type)
    import dunamis.core.datasource : ChangeEvent;

    auto expr = eventSource!ChangeEvent();
    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);

    auto event = new ChangeEvent();
    event.table = "users";
    event.kind = ChangeEvent.Kind.created;
    event.ids = ["1", "2", "3"];

    expr.deliver(ctx, event);
    auto result = awaitSync(expr.eval(ctx));
    assert(result.length == 1);
    assert(result[0].table == "users");
    assert(result[0].kind == ChangeEvent.Kind.created);
    assert(result[0].ids == ["1", "2", "3"]);
}

unittest {
    // Test EventSourceExpr - re-evaluation with fresh context
    auto expr = eventSource!int();

    // First event
    auto ctx1 = new EvalContext();
    ctx1.setValues!AnyRef(null, [queryRoot]);
    expr.deliver(ctx1, 10);
    assert(awaitSync(expr.eval(ctx1)) == [10]);

    // Second event with fresh context
    auto ctx2 = new EvalContext();
    ctx2.setValues!AnyRef(null, [queryRoot]);
    expr.deliver(ctx2, 20);
    assert(awaitSync(expr.eval(ctx2)) == [20]);
}
