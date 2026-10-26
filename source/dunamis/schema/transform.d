/// Recursive type transformation infrastructure.
///
/// This module provides building blocks for plugins that transform ALL types
/// in a schema, including handling circular type references (User → Post → User).
///
/// ## Key Insight: Use `.TypeMap` for Recursive Transforms
///
/// When passing a TypeMap template to another template, use the dot prefix
/// to pass the template itself rather than an instantiation:
///
/// ```d
/// // WRONG - causes recursive template expansion:
/// alias TypeMap = WrapType!(Entity, TypeMap);
///
/// // CORRECT - passes template for lazy instantiation:
/// alias TypeMap = WrapType!(Entity, .TypeMap);
/// ```
///
/// ## Usage Example
///
/// ```d
/// // Define a TypeMap that wraps all entity types
/// template TypeMap(T) {
///     static if (isTypeInList!(T, AllEntityTypes)) {
///         alias TypeMap = TransformedType!(T, .TypeMap);
///     } else {
///         alias TypeMap = T;
///     }
/// }
///
/// // Use ReplaceTypeRefs to transform field return types
/// alias TransformedReturn = ReplaceTypeRefs!(OriginalReturn, TypeMap);
/// ```
module dunamis.schema.transform;

import std.traits : Parameters, ReturnType, isSomeString;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.core.expr.combinators : UnionExprInfo;
import dunamis.core.discovery : isObjectType;
import dunamis.core.types : isInternalMember, isAbstractType, isCustomScalar,
    getImplementedByMembers;

// ============================================================================
// Type Reference Substitution
// ============================================================================

/// Replace entity type references with their transformed versions.
/// Recursively handles arrays and Nullable.
///
/// Example:
///   ReplaceTypeRefs!(Post[], TypeMap) → TypeMap!Post[]
///   ReplaceTypeRefs!(Nullable!User, TypeMap) → Nullable!(TypeMap!User)
///   ReplaceTypeRefs!(string, TypeMap) → string (unchanged)
template ReplaceTypeRefs(T, alias TypeMap) {
    static if (is(T == E[], E) && !isSomeString!T) {
        // Array (but not string): transform element type
        alias ReplaceTypeRefs = ReplaceTypeRefs!(E, TypeMap)[];
    } else static if (is(T == Nullable!U, U)) {
        // Nullable: transform inner type
        alias ReplaceTypeRefs = Nullable!(ReplaceTypeRefs!(U, TypeMap));
    } else static if (isCustomScalar!T) {
        // Custom scalars are GraphQL leaves even though their D
        // representation is a struct.
        alias ReplaceTypeRefs = T;
    } else static if (isAbstractType!T) {
        // Abstract type (union/interface): apply TypeMap
        alias ReplaceTypeRefs = TypeMap!T;
    } else static if (isObjectType!T) {
        // Entity/object type: apply TypeMap
        alias ReplaceTypeRefs = TypeMap!T;
    } else {
        // Scalar, enum, etc. - pass through unchanged
        alias ReplaceTypeRefs = T;
    }
}

// ============================================================================
// Type List Utilities
// ============================================================================

/// Check if type T is in the Types list
template isTypeInList(T, Types...) {
    static if (Types.length == 0) {
        enum isTypeInList = false;
    } else static if (is(T == Types[0])) {
        enum isTypeInList = true;
    } else {
        enum isTypeInList = isTypeInList!(T, Types[1..$]);
    }
}

// ============================================================================
// Field Transformation Helpers
// ============================================================================

/// Information about a field for transformation purposes
struct TransformFieldInfo {
    string name;
    bool isArray;
    string elementType;  // For arrays, the element type name
}

/// Extract field info from an entity type
template getTransformFieldInfo(Entity) {
    enum getTransformFieldInfo = () {
        TransformFieldInfo[] fields;

        static foreach (member; __traits(allMembers, Entity)) {
            static if (!isInternalMember!member) {
                static if (__traits(compiles, __traits(getMember, Entity, member)) &&
                           is(typeof(__traits(getMember, Entity, member)) == function)) {
                    {
                        alias fn = __traits(getMember, Entity, member);
                        alias Params = Parameters!fn;

                        static if (Params.length >= 1 && is(Params[0] : Expr!E, E) && is(E == Entity)) {
                            alias Return = ReturnType!fn;
                            static if (isExpr!Return) {
                                alias ResultT = ExprResultType!Return;

                                static if (is(ResultT == R[], R) && !isSomeString!ResultT) {
                                    fields ~= TransformFieldInfo(member, true, R.stringof);
                                } else {
                                    fields ~= TransformFieldInfo(member, false, "");
                                }
                            }
                        }
                    }
                }
            }
        }

        return fields;
    }();
}

// IdentityTypeMap is defined in dunamis.schema.plugin and re-exported
// via the module-level import above.

// ============================================================================
// Abstract Type Casting
// ============================================================================

/// Expression wrapper that remaps an abstract type (union/interface) through
/// a plugin's TypeMap. Implements UnionExprInfo by delegating to the inner
/// expression with member type remapping.
///
/// When a plugin wraps entity types, abstract type fields like `search()` still
/// return `Expr!(RawSearchResult[])` from the original field method. This wrapper
/// converts that to `Expr!(NormalizedSearchResult[])` and bridges the member type
/// lookup: when the compiler creates `SubsetExpr!NormalizedUser`, it calls
/// `memberKeyForType(typeid(NormalizedUser))` on this wrapper, which maps it
/// to the inner expression's raw member key and entity-casts the data.
class AbstractTypeCastExpr(ToAbstract, FromAbstract, alias TypeMap, FromMembers...)
    : Expr!(ToAbstract[]), UnionExprInfo
{
    import dunamis.core.eval : EvalContext;
    import dunamis.core.optimize : OptimizeContext;
    import dunamis.core.expr.base : ExprBase, evalAs, optimizeExpr;
    import dunamis.core.expr.combinators : UnionExprInfo;
    import ae.utils.promise : Promise;

    private ExprBase _inner;
    private Object[FromMembers.length] _castKeys;

    this(Expr!(FromAbstract[]) inner) {
        _inner = inner;
        static foreach (i; 0 .. FromMembers.length) {
            _castKeys[i] = new Object();
        }
    }

    override ExprBase[] dependencies() {
        return [_inner];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _inner = newDep;
    }

    override Expr!(ToAbstract[]) optimize(OptimizeContext ctx) {
        _inner = optimizeExpr(_inner, ctx);
        return this;
    }

    /// UnionExprInfo: map normalized member TypeInfo to our cast key.
    Object memberKeyForType(TypeInfo ti) {
        static foreach (i; 0 .. FromMembers.length) {
            if (ti == typeid(TypeMap!(FromMembers[i])))
                return _castKeys[i];
        }
        return null;
    }

    /// UnionExprInfo: trigger evaluation via evalAs caching (safe for multiple SubsetExprs).
    Promise!void triggerEval(EvalContext ctx) {
        return evalAs!(ToAbstract[])(cast(ExprBase) this, ctx)
            .then((ToAbstract[][] _) {});
    }

    override Promise!(ToAbstract[][]) eval(EvalContext ctx) {
        auto innerInfo = cast(UnionExprInfo) _inner;
        assert(innerInfo !is null,
            "AbstractTypeCastExpr: inner expression must implement UnionExprInfo");

        auto castKeys = _castKeys;

        return innerInfo.triggerEval(ctx).then(() {
            _doEntityCast(innerInfo, ctx, castKeys);
            return [cast(ToAbstract[]) []];
        });
    }

    /// Entity-cast each member's stored data from raw to normalized types.
    /// Static method to avoid D closure capture issues.
    private static void _doEntityCast(
        UnionExprInfo innerInfo, EvalContext ctx,
        ref Object[FromMembers.length] castKeys)
    {
        import dunamis.schema.entity_cast : entityCastValue;

        static foreach (i; 0 .. FromMembers.length) {{
            alias RawMember = FromMembers[i];
            alias CastMember = TypeMap!RawMember;

            auto rawKey = innerInfo.memberKeyForType(typeid(RawMember));
            if (rawKey !is null) {
                auto rawData = ctx.getValues!RawMember(rawKey);
                CastMember[] castData = new CastMember[rawData.length];
                foreach (j; 0 .. rawData.length) {
                    castData[j] = entityCastValue!(CastMember, RawMember)(rawData[j]);
                }
                ctx.setValues!CastMember(castKeys[i], castData);
            }
        }}
    }
}

// ============================================================================
// Entity Result Wrapping
// ============================================================================

/// Wrap an expression result to map entity types through TypeMap via entityCast.
/// Handles arrays of entities, single entities, nullable entities, and scalars.
///
/// - Expr!(Entity[]) → map each element via entityCast → Expr!(MappedEntity[])
/// - Expr!Entity → entityCast → Expr!MappedEntity
/// - Expr!(Nullable!Entity) → use with value-level cast → Expr!(Nullable!MappedEntity)
/// - Expr!scalar → pass through unchanged
auto wrapEntityResult(alias TypeMap, R)(R result)
    if (isExpr!R)
{
    import dunamis.core.expr : ExprResultType, map, use, Expr;
    import dunamis.schema.entity_cast : pluginEntityCast;

    alias ResultT = ExprResultType!R;

    static if (isCustomScalar!ResultT) {
        return result;
    } else static if (is(ResultT == E[], E) && !isSomeString!ResultT) {
        static if (isAbstractType!E) {
            alias MappedE = TypeMap!E;
            static if (is(MappedE == E)) {
                return result;
            } else {
                // Wrap abstract type expression, preserving UnionExprInfo
                // for SubsetExpr to interact with at eval time.
                alias RawMembers = getImplementedByMembers!E;
                return new AbstractTypeCastExpr!(MappedE, E, TypeMap, RawMembers)(result);
            }
        } else static if (isObjectType!E) {
            alias MappedE = TypeMap!E;
            static if (is(MappedE == E)) {
                return result;
            } else {
                return map!((Expr!E e) => pluginEntityCast!MappedE(e))(result);
            }
        } else {
            return result;
        }
    } else static if (is(ResultT == Nullable!UCustom, UCustom) && isCustomScalar!UCustom) {
        return result;
    } else static if (is(ResultT == Nullable!(EObject[]), EObject) && isObjectType!EObject && !isAbstractType!EObject) {
        alias MappedE = TypeMap!EObject;
        static if (is(MappedE == EObject)) {
            return result;
        } else {
            return use(&nullableArrayEntityCastValue!(MappedE, EObject), result);
        }
    } else static if (is(ResultT == Nullable!UObject, UObject) && isObjectType!UObject) {
        alias MappedU = TypeMap!UObject;
        static if (is(MappedU == UObject)) {
            return result;
        } else {
            return use(&nullableEntityCastValue!(MappedU, UObject), result);
        }
    } else static if (isObjectType!ResultT) {
        alias MappedT = TypeMap!ResultT;
        static if (is(MappedT == ResultT)) {
            return result;
        } else {
            return pluginEntityCast!MappedT(result);
        }
    } else {
        return result;
    }
}

/// Value-level entity cast for Nullable wrapping in wrapEntityResult.
/// Converts Nullable!From to Nullable!To by copying matching fields.
Nullable!To nullableEntityCastValue(To, From)(Nullable!From val) {
    import dunamis.schema.entity_cast : entityCastValue;
    if (val.isNull) return Nullable!To.init;
    return Nullable!To(entityCastValue!(To, From)(val.get));
}


// ============================================================================
// Unit Tests
// ============================================================================
/// Value-level entity cast of a nullable list, element by element.
Nullable!(To[]) nullableArrayEntityCastValue(To, From)(Nullable!(From[]) val) {
    import dunamis.schema.entity_cast : entityCastValue;
    if (val.isNull) return Nullable!(To[]).init;
    auto result = new To[val.get.length];
    foreach (i, item; val.get)
        result[i] = entityCastValue!(To, From)(item);
    return Nullable!(To[])(result);
}

version (unittest) {
    import dunamis.relational.schema : Entity, Col, HasMany, BelongsTo, ForeignKey, Table, PrimaryKey;
    import dunamis.relational.demo : MockDB;

    static MockDB!() _testDb;

    // Test types with circular references (Post must be before Author for HasMany)
    @Entity!(_testDb, "posts", "TestPost")
    struct TestPost {
        @PrimaryKey int id;
        mixin Col!("title", string);
        mixin Col!("authorId", ForeignKey!TestAuthor);
        mixin BelongsTo!("author", "authorId");
    }

    @Entity!(_testDb, "authors", "TestAuthor")
    struct TestAuthor {
        @PrimaryKey int id;
        mixin Col!("name", string);
        mixin HasMany!("posts", TestPost, "author_id");
    }

    struct TestQuery {
        mixin Table!(TestAuthor, "authors");
        mixin Table!(TestPost, "posts");
    }
}

// Test ReplaceTypeRefs
unittest {
    import dunamis.schema.plugin : IdentityTypeMap;
    static assert(is(ReplaceTypeRefs!(int, IdentityTypeMap) == int));
    static assert(is(ReplaceTypeRefs!(string, IdentityTypeMap) == string));
    static assert(is(ReplaceTypeRefs!(int[], IdentityTypeMap) == int[]));
    static assert(is(ReplaceTypeRefs!(Nullable!int, IdentityTypeMap) == Nullable!int));

    // Test with custom type map
    template SwapMap(T) {
        static if (is(T == TestAuthor)) {
            alias SwapMap = TestPost;
        } else static if (is(T == TestPost)) {
            alias SwapMap = TestAuthor;
        } else {
            alias SwapMap = T;
        }
    }

    static assert(is(ReplaceTypeRefs!(TestAuthor[], SwapMap) == TestPost[]));
    static assert(is(ReplaceTypeRefs!(Nullable!TestPost, SwapMap) == Nullable!TestAuthor));
    static assert(is(ReplaceTypeRefs!(string, SwapMap) == string));
}

// Test isTypeInList
unittest {
    static assert(isTypeInList!(int, int, string, bool));
    static assert(isTypeInList!(string, int, string, bool));
    static assert(!isTypeInList!(float, int, string, bool));
    static assert(!isTypeInList!(int));
}

// Test getTransformFieldInfo
unittest {
    enum fields = getTransformFieldInfo!TestAuthor;

    bool foundName, foundPosts;
    foreach (f; fields) {
        if (f.name == "name") { foundName = true; assert(!f.isArray); }
        if (f.name == "posts") { foundPosts = true; assert(f.isArray); }
    }
    assert(foundName && foundPosts);
}

// Test ForwardField with TypeMap (unified - replaces ForwardFieldWithTypeMap)
unittest {
    import dunamis.graphql.schema : Schema;
    import dunamis.schema.plugin : ForwardField, IdentityTypeMap;

    static struct ForwardedQuery {
        mixin ForwardField!(TestQuery, "authors", IdentityTypeMap);
    }

    static assert(__traits(hasMember, ForwardedQuery, "authors"));
    static assert(is(typeof(ForwardedQuery.authors) == function));
}

// Test with circular references
unittest {
    import dunamis.graphql.schema : Schema, getAllObjectTypes;

    alias BaseSchema = Schema!TestQuery;
    alias AllTypes = getAllObjectTypes!TestQuery;

    static assert(AllTypes.length == 2);
    static assert(isTypeInList!(TestAuthor, AllTypes));
    static assert(isTypeInList!(TestPost, AllTypes));
}

// Test _normalizedSource in entityCastValue with entities
unittest {
    import dunamis.schema.entity_cast : entityCastValue;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;

    static MockDB!() db;

    @DemoEntity!(db, "originals")
    static struct Original {
        mixin DemoId;
        string name;
        int age;
    }

    // Normalized wrapper with _normalizedSource
    @DemoEntity!(db, "originals")
    static struct Normalized {
        mixin DemoId;
        Original _normalizedSource;
    }

    // Plugin wrapper — per-layer: stores Normalized (not Original)
    @DemoEntity!(db, "originals")
    static struct PluginWrapped {
        mixin DemoId;
        Normalized _normalizedSource;
    }

    // Wrap: Original → Normalized (stores Original in _normalizedSource)
    Original orig;
    orig.name = "Alice";
    orig.age = 30;
    auto norm = entityCastValue!(Normalized, Original)(orig);
    assert(norm._normalizedSource.name == "Alice");
    assert(norm._normalizedSource.age == 30);

    // Per-layer wrap: Normalized → PluginWrapped (stores Normalized, not Original)
    auto wrapped = entityCastValue!(PluginWrapped, Normalized)(norm);
    assert(wrapped._normalizedSource._normalizedSource.name == "Alice");
    assert(wrapped._normalizedSource._normalizedSource.age == 30);

    // Unwrap: PluginWrapped → Normalized (extracts _normalizedSource)
    auto unwrapped = entityCastValue!(Normalized, PluginWrapped)(wrapped);
    assert(unwrapped._normalizedSource.name == "Alice");
}

// Test _normalizedSource with POD types (no @PrimaryKey)
unittest {
    import dunamis.schema.entity_cast : entityCastValue;
    static struct POD {
        int x;
        string y;
    }

    static struct NormalizedPOD {
        POD _normalizedSource;
    }

    auto pod = POD(42, "hello");
    auto norm = entityCastValue!(NormalizedPOD, POD)(pod);
    assert(norm._normalizedSource.x == 42);
    assert(norm._normalizedSource.y == "hello");
}

// Test entityCastValue between unrelated chains still only copies matching fields
unittest {
    import dunamis.schema.entity_cast : entityCastValue;

    static struct RawA { int id; string name; }
    static struct WrappedA { int id; RawA _normalizedSource; }
    static struct RawB { int id; string name; }
    static struct WrappedB { int id; RawB _normalizedSource; }

    auto a = entityCastValue!(WrappedA, RawA)(RawA(3, "x"));
    auto b = entityCastValue!(WrappedB, WrappedA)(a);
    assert(b.id == 3);
    assert(b._normalizedSource == RawB.init);
    auto rb = entityCastValue!(RawB, WrappedA)(a);
    assert(rb.id == 3 && rb.name is null);
}
