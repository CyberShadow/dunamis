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
module dunamis.graphql.transform;

import std.traits : Parameters, ReturnType, isSomeString;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.graphql.schema : isObjectType, isInternalMember;
import dunamis.graphql.plugin : IdentityTypeMap;

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

// IdentityTypeMap is defined in dunamis.graphql.plugin and re-exported
// via the module-level import above.

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
    import dunamis.core.expr : ExprResultType, entityCast, map, use, Expr;

    alias ResultT = ExprResultType!R;

    static if (is(ResultT == E[], E) && !isSomeString!ResultT) {
        static if (isObjectType!E) {
            alias MappedE = TypeMap!E;
            static if (is(MappedE == E)) {
                return result;
            } else {
                return map!((Expr!E e) => entityCast!MappedE(e))(result);
            }
        } else {
            return result;
        }
    } else static if (is(ResultT == Nullable!U, U) && isObjectType!U) {
        alias MappedU = TypeMap!U;
        static if (is(MappedU == U)) {
            return result;
        } else {
            return use(&nullableEntityCastValue!(MappedU, U), result);
        }
    } else static if (isObjectType!ResultT) {
        alias MappedT = TypeMap!ResultT;
        static if (is(MappedT == ResultT)) {
            return result;
        } else {
            return entityCast!MappedT(result);
        }
    } else {
        return result;
    }
}

/// Value-level entity cast for Nullable wrapping in wrapEntityResult.
/// Converts Nullable!From to Nullable!To by copying nodeId and matching fields.
Nullable!To nullableEntityCastValue(To, From)(Nullable!From val) {
    if (val.isNull) return Nullable!To.init;
    return Nullable!To(entityCastValue!(To, From)(val.get));
}

/// Value-level entity cast. Copies nodeId and matching instance fields from From to To.
///
/// Special handling for `_normalizedSource`: if To has a `_normalizedSource` field,
/// it is populated to carry original entity data through the plugin wrapper chain.
/// - If `_normalizedSource` type matches From: store From directly (normalization cast)
/// - If both From and To have `_normalizedSource` of the same type: copy transitively (plugin chain)
To entityCastValue(To, From)(From from) {
    To to;
    static if (__traits(hasMember, From, "nodeId") && __traits(hasMember, To, "nodeId")) {
        to = To(from.nodeId.id);
        static foreach (member; __traits(allMembers, From)) {{
            static if (member.length > 0 && member[0] != '_' &&
                       member != "nodeId" &&
                       member != "toString" && member != "toHash" &&
                       member != "opEquals" && member != "opCmp" &&
                       member != "opAssign" && member != "factory" &&
                       member != "Monitor" &&
                       __traits(hasMember, To, member)) {
                static if (__traits(compiles, __traits(getMember, from, member)) &&
                           __traits(compiles, __traits(getMember, to, member) = __traits(getMember, from, member))) {
                    __traits(getMember, to, member) = __traits(getMember, from, member);
                }
            }
        }}
    } else static if (is(From == struct) && is(To == struct)) {
        static foreach (member; __traits(allMembers, From)) {{
            static if (member.length > 0 && member[0] != '_' &&
                       member != "toString" && member != "toHash" &&
                       member != "opEquals" && member != "opCmp" &&
                       member != "opAssign" && member != "factory" &&
                       member != "Monitor" &&
                       __traits(hasMember, To, member)) {
                static if (__traits(compiles, __traits(getMember, from, member)) &&
                           __traits(compiles, __traits(getMember, to, member) = __traits(getMember, from, member))) {
                    __traits(getMember, to, member) = __traits(getMember, from, member);
                }
            }
        }}
    }
    // Carry _normalizedSource through the wrapper chain
    static if (__traits(hasMember, To, "_normalizedSource")) {
        static if (is(typeof(To._normalizedSource) == From)) {
            // Direct: From → NormalizedFrom (store original)
            to._normalizedSource = from;
        } else static if (__traits(hasMember, From, "_normalizedSource") &&
                          is(typeof(From._normalizedSource) == typeof(To._normalizedSource))) {
            // Transitive: NormalizedFrom → PluginWrapped (copy through chain)
            to._normalizedSource = from._normalizedSource;
        }
    }
    return to;
}


// ============================================================================
// Unit Tests
// ============================================================================

version (unittest) {
    import dunamis.relational.schema : Entity, Col, HasMany, BelongsTo, ForeignKey, Table;
    import dunamis.relational.demo : MockDB;

    static MockDB!() _testDb;

    // Test types with circular references (Post must be before Author for HasMany)
    struct TestPost {
        mixin Entity!(_testDb, "posts", "TestPost");
        mixin Col!("id", int);
        mixin Col!("title", string);
        mixin Col!("authorId", ForeignKey!TestAuthor);
        mixin BelongsTo!("author", "authorId");
    }

    struct TestAuthor {
        mixin Entity!(_testDb, "authors", "TestAuthor");
        mixin Col!("id", int);
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

    bool foundId, foundName, foundPosts;
    foreach (f; fields) {
        if (f.name == "id") { foundId = true; assert(!f.isArray); }
        if (f.name == "name") { foundName = true; assert(!f.isArray); }
        if (f.name == "posts") { foundPosts = true; assert(f.isArray); }
    }
    assert(foundId && foundName && foundPosts);
}

// Test ForwardField with TypeMap (unified - replaces ForwardFieldWithTypeMap)
unittest {
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.plugin : ForwardField;

    static struct ForwardedQuery {
        mixin ForwardField!(TestQuery, "authors", IdentityTypeMap);
    }

    static assert(__traits(hasMember, ForwardedQuery, "authors"));
    static assert(is(typeof(ForwardedQuery.authors) == function));
}

// Test with circular references
unittest {
    import dunamis.graphql.schema : Schema, getAllEntityTypes;

    alias BaseSchema = Schema!TestQuery;
    alias AllTypes = getAllEntityTypes!TestQuery;

    static assert(AllTypes.length == 2);
    static assert(isTypeInList!(TestAuthor, AllTypes));
    static assert(isTypeInList!(TestPost, AllTypes));
}

// Test _normalizedSource in entityCastValue with entities
unittest {
    import dunamis.relational.demo : DemoEntity, MockDB;

    static MockDB!() db;

    static struct Original {
        mixin DemoEntity!(db, "originals");
        string name;
        int age;
    }

    // Normalized wrapper with _normalizedSource
    static struct Normalized {
        mixin DemoEntity!(db, "originals");
        Original _normalizedSource;
    }

    // Plugin wrapper that carries _normalizedSource through chain
    static struct PluginWrapped {
        mixin DemoEntity!(db, "originals");
        Original _normalizedSource;
    }

    // Direct: Original → Normalized (stores original in _normalizedSource)
    auto orig = Original("1");
    orig.name = "Alice";
    orig.age = 30;
    auto norm = entityCastValue!(Normalized, Original)(orig);
    assert(norm._normalizedSource.name == "Alice");
    assert(norm._normalizedSource.age == 30);

    // Transitive: Normalized → PluginWrapped (copies _normalizedSource)
    auto wrapped = entityCastValue!(PluginWrapped, Normalized)(norm);
    assert(wrapped._normalizedSource.name == "Alice");
    assert(wrapped._normalizedSource.age == 30);
}

// Test _normalizedSource with POD types (no nodeId)
unittest {
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
