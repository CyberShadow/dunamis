module dunamis.core.expr.primitives;

import std.array;
import std.range : iota;
import std.traits;
import std.typecons : Nullable;
static import std.algorithm;

import ae.utils.promise;

import dunamis.core.types;
import dunamis.core.eval;
import dunamis.core.optimize;
import dunamis.core.expr.base;

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

/// Interface for EntityCastExpr to allow chain traversal during optimization.
/// This lets findMapExprFromChain continue through entity cast wrappers.
interface EntityCastInfo {
    @property ExprBase inputExpr();
}

/// Expression that casts between compatible entity/struct types.
/// Used by plugin infrastructure to forward fields between schema types.
///
/// For entity types (with nodeId): copies the nodeId to construct the target type.
/// For non-entity types (Query, Mutation): uses default-initialized value.
///
class EntityCastExpr(To, From) : Expr!To, EntityCastInfo {
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
                // Carry _normalizedSource through the wrapper chain
                static if (__traits(hasMember, To, "_normalizedSource")) {
                    static if (is(typeof(To._normalizedSource) == From)) {
                        // Direct: From → NormalizedFrom (store original)
                        result[i]._normalizedSource = from;
                    } else static if (__traits(hasMember, From, "_normalizedSource") &&
                                      is(typeof(From._normalizedSource) == typeof(To._normalizedSource))) {
                        // Transitive: NormalizedFrom → PluginWrapped (copy through chain)
                        result[i]._normalizedSource = from._normalizedSource;
                    }
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

    /// EntityCastInfo implementation - allows chain traversal through casts
    @property ExprBase inputExpr() { return _source; }

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
