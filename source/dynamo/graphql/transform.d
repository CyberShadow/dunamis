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
module dynamo.graphql.transform;

import std.meta : AliasSeq;
import std.traits : Parameters, ReturnType, ParameterDefaults, ParameterIdentifierTuple, isSomeString;
import std.typecons : Nullable;

import dynamo.core.expr : Expr, ExprResultType, isExpr;
import dynamo.graphql.schema : isObjectType, getAllEntityTypes, getFields, isInternalMember,
    getGraphQLTypeName, isSchema;
import dynamo.graphql.plugin : getFieldMembers, isArrayReturningField, ForwardField;

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

// ============================================================================
// Identity TypeMap
// ============================================================================

/// Identity type map - returns types unchanged. Useful for testing.
template IdentityTypeMap(T) {
    alias IdentityTypeMap = T;
}

// ============================================================================
// Field Forwarding with Type Substitution
// ============================================================================

/// Mixin template to forward a field from SourceType with type substitution.
/// The return type has entity references replaced via TypeMap.
mixin template ForwardFieldWithTypeMap(SourceType, string fieldName, alias TypeMap) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple, ReturnType;
    import dynamo.core.expr : Expr, ExprResultType, entityCast;
    import dynamo.graphql.transform : ReplaceTypeRefs;

    alias _srcFn = __traits(getMember, SourceType, fieldName);
    alias _SrcParams = Parameters!_srcFn;
    alias _SrcDefaults = ParameterDefaults!_srcFn;
    enum string[] _srcParamNames = [ParameterIdentifierTuple!_srcFn];

    alias _SrcFirstParam = _SrcParams[0];
    alias _SrcEntity = ExprResultType!_SrcFirstParam;

    // Build parameter list string
    enum string _paramListStr = () {
        string result = "Expr!(typeof(this)) " ~ _srcParamNames[0];
        static foreach (i; 1 .. _SrcParams.length) {
            result ~= ", " ~ _SrcParams[i].stringof ~ " " ~ _srcParamNames[i];
            static if (!is(_SrcDefaults[i] == void)) {
                result ~= " = " ~ _SrcDefaults[i].stringof;
            }
        }
        return result;
    }();

    // Build argument list string
    enum string _argListStr = () {
        string result = "entityCast!(_SrcEntity)(" ~ _srcParamNames[0] ~ ")";
        static foreach (i; 1 .. _SrcParams.length) {
            result ~= ", " ~ _srcParamNames[i];
        }
        return result;
    }();

    @(__traits(getAttributes, _srcFn))
    mixin("static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
          "return _srcFn(" ~ _argListStr ~ "); }");
}

/// Mixin template to forward a plain method from SourceType (instance method with no Expr parameter).
mixin template ForwardPlainMethodWithTypeMap(SourceType, string methodName, alias TypeMap) {
    import std.traits : ReturnType;

    alias _srcMethod = __traits(getMember, SourceType, methodName);
    alias _RetType = ReturnType!_srcMethod;

    @(__traits(getAttributes, _srcMethod))
    mixin("_RetType " ~ methodName ~ "() { " ~
          "return (cast(SourceType*) &this)." ~ methodName ~ "(); }");
}

/// Mixin template to copy all fields from SourceType with type substitution.
mixin template CopyFieldsWithTypeMap(SourceType, alias TypeMap) {
    import dynamo.graphql.plugin : getFieldMembers, isComputedField;
    import dynamo.graphql.transform : ForwardFieldWithTypeMap, ForwardPlainMethodWithTypeMap;

    static foreach (member; getFieldMembers!SourceType) {
        static if (isComputedField!(SourceType, member)) {
            mixin ForwardFieldWithTypeMap!(SourceType, member, TypeMap);
        } else {
            mixin ForwardPlainMethodWithTypeMap!(SourceType, member, TypeMap);
        }
    }
}

// ============================================================================
// Pagination Field Transform
// ============================================================================

/// Mixin that adds first/offset arguments to array-returning fields.
/// Non-array fields are forwarded unchanged.
template AddPaginationArgs(SourceType, string fieldName) {
    import dynamo.core.expr : Expr, ExprResultType, entityCast;
    import std.typecons : Nullable;

    alias _srcFn = __traits(getMember, SourceType, fieldName);

    static if (isArrayReturningField!_srcFn) {
        alias _Params = Parameters!_srcFn;
        alias _Defaults = ParameterDefaults!_srcFn;
        enum string[] _paramNames = [ParameterIdentifierTuple!_srcFn];
        alias _SrcEntity = ExprResultType!(_Params[0]);

        enum string _paramStr = () {
            string result = "Expr!(typeof(this)) " ~ _paramNames[0];
            static foreach (i; 1 .. _Params.length) {
                result ~= ", " ~ _Params[i].stringof ~ " " ~ _paramNames[i];
                static if (!is(_Defaults[i] == void)) {
                    result ~= " = " ~ _Defaults[i].stringof;
                }
            }
            result ~= ", Nullable!int first = Nullable!int.init";
            result ~= ", Nullable!int offset = Nullable!int.init";
            return result;
        }();

        enum string _argStr = () {
            string result = "entityCast!_SrcEntity(" ~ _paramNames[0] ~ ")";
            static foreach (i; 1 .. _Params.length) {
                result ~= ", " ~ _paramNames[i];
            }
            return result;
        }();

        @(__traits(getAttributes, _srcFn))
        mixin("static auto " ~ fieldName ~ "(" ~ _paramStr ~ ") { " ~
              "return _srcFn(" ~ _argStr ~ "); }");
    } else {
        mixin ForwardField!(SourceType, fieldName);
    }
}

// ============================================================================
// Entity Type Transformation (for Nested Pagination/Sorting)
// ============================================================================

/// Mixin that adds first/offset arguments to array-returning fields with type substitution.
/// Unlike AddPaginationArgs, this uses TypeMap to transform return types (for nested pagination).
///
/// Note: TypeMap must be accessible from the scope where this mixin is instantiated.
/// When using from outside this module, use the fully qualified .TypeMap syntax for lazy resolution.
mixin template AddPaginationArgsWithTypeMap(SourceType, string fieldName, alias TypeMap) {
    import dynamo.core.expr : Expr, ExprResultType, entityCast;
    import dynamo.core.pagination : limit, offset;
    import dynamo.graphql.plugin : getFieldMembers, isArrayReturningField, ForwardField, ArrayFieldElementType, isComputedField;
    import dynamo.graphql.transform : ForwardFieldWithTypeMap, ForwardPlainMethodWithTypeMap;
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple, ReturnType;
    import std.typecons : Nullable;

    alias _srcFn = __traits(getMember, SourceType, fieldName);

    static if (isArrayReturningField!_srcFn) {
        alias _Params = Parameters!_srcFn;
        alias _Defaults = ParameterDefaults!_srcFn;
        enum string[] _paramNames = [ParameterIdentifierTuple!_srcFn];
        alias _SrcEntity = ExprResultType!(_Params[0]);

        // Extract element type from array expression
        alias _ElementType = ArrayFieldElementType!_srcFn;

        enum string _paramStr = () {
            string result = "Expr!(typeof(this)) " ~ _paramNames[0];
            static foreach (i; 1 .. _Params.length) {
                result ~= ", " ~ _Params[i].stringof ~ " " ~ _paramNames[i];
                static if (!is(_Defaults[i] == void)) {
                    result ~= " = " ~ _Defaults[i].stringof;
                }
            }
            result ~= ", Nullable!int first = Nullable!int.init";
            result ~= ", Nullable!int offset = Nullable!int.init";
            return result;
        }();

        enum string _argStr = () {
            string result = "entityCast!_SrcEntity(" ~ _paramNames[0] ~ ")";
            static foreach (i; 1 .. _Params.length) {
                result ~= ", " ~ _paramNames[i];
            }
            return result;
        }();

        // Helper function to apply pagination (avoids type inference issues in mixin)
        // Returns Expr!(_ElementType[]) - uses original element type for compatibility
        private static Expr!(_ElementType[]) _applyPagination(T)(T base, Nullable!int first, Nullable!int offset_) {
            // Apply offset first, then limit
            if (offset_.isNull && first.isNull) {
                return base;
            } else if (offset_.isNull) {
                return base.limit(cast(size_t) first.get);
            } else if (first.isNull) {
                return base.offset(cast(size_t) offset_.get);
            } else {
                return base.offset(cast(size_t) offset_.get).limit(cast(size_t) first.get);
            }
        }

        @(__traits(getAttributes, _srcFn))
        mixin("static auto " ~ fieldName ~ "(" ~ _paramStr ~ ") { " ~
              "return _applyPagination(_srcFn(" ~ _argStr ~ "), first, offset); }");
    } else static if (isComputedField!(SourceType, fieldName)) {
        mixin ForwardFieldWithTypeMap!(SourceType, fieldName, TypeMap);
    } else {
        // Plain method (instance method with no Expr parameter)
        mixin ForwardPlainMethodWithTypeMap!(SourceType, fieldName, TypeMap);
    }
}

/// Generate a paginated version of an entity type.
/// Array fields get first/offset arguments. Type references use TypeMap for lazy resolution.
///
/// Example:
/// ---
/// template TypeMap(T) {
///     static if (isTypeInList!(T, AllEntityTypes)) {
///         alias TypeMap = PaginatedEntityType!(T, .TypeMap);  // Note: .TypeMap for lazy
///     } else {
///         alias TypeMap = T;
///     }
/// }
/// ---
template PaginatedEntityType(Entity, alias TypeMap) {
    import dynamo.relational.schema : EntityID;

    mixin("struct PaginatedEntityType {
        // Copy entity infrastructure - nodeId with same type
        static if (__traits(hasMember, Entity, \"nodeId\")) {
            typeof(Entity.nodeId) nodeId;

            // Constructor from ID string
            this(string id) { nodeId = typeof(nodeId)(id); }

            // For debugging
            string toString() const { return nodeId.toString(); }
        }

        // Copy all fields with pagination on array fields
        static foreach (member; getFieldMembers!Entity) {
            mixin AddPaginationArgsWithTypeMap!(Entity, member, TypeMap);
        }
    }");
}

// ============================================================================
// Unit Tests
// ============================================================================

version (unittest) {
    import dynamo.relational.schema : Entity, Col, HasMany, BelongsTo, ForeignKey, Table;
    import dynamo.relational.demo : MockDB;

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

// Test ForwardFieldWithTypeMap
unittest {
    import dynamo.graphql.schema : Schema;

    static struct ForwardedQuery {
        mixin ForwardFieldWithTypeMap!(TestQuery, "authors", IdentityTypeMap);
    }

    static assert(__traits(hasMember, ForwardedQuery, "authors"));
    static assert(is(typeof(ForwardedQuery.authors) == function));
}

// Test AddPaginationArgs
unittest {
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import dynamo.core.types : NoSchemaConfig;
    import dynamo.core.expr : constant;
    import std.algorithm : canFind;

    static MockDB!() db;

    static struct Widget {
        mixin Entity!(db, "widgets", "Widget");
        mixin Col!("id", int);
    }

    static struct OriginalQuery {
        mixin Table!(Widget, "widgets");

        static auto scalar(Expr!OriginalQuery q) {
            return constant("test", q);
        }
    }

    struct PaginatedSchema {
        struct Query {
            static foreach (member; getFieldMembers!OriginalQuery) {
                mixin AddPaginationArgs!(OriginalQuery, member);
            }
        }
        struct Mutation {}
        alias Config = NoSchemaConfig;
    }

    static assert(isSchema!PaginatedSchema);

    enum sdl = generateSchemaSDL!PaginatedSchema;
    static assert(sdl.canFind("widgets("), "Should have widgets with args");
    static assert(sdl.canFind("first:"), "Should have first arg");
    static assert(sdl.canFind("offset:"), "Should have offset arg");
    static assert(sdl.canFind("scalar: String!"), "Scalar unchanged");
}

// Test with circular references
unittest {
    import dynamo.graphql.schema : Schema, getAllEntityTypes;

    alias BaseSchema = Schema!TestQuery;
    alias AllTypes = getAllEntityTypes!TestQuery;

    static assert(AllTypes.length == 2);
    static assert(isTypeInList!(TestAuthor, AllTypes));
    static assert(isTypeInList!(TestPost, AllTypes));
}
