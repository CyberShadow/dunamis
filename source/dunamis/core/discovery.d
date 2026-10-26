/// Type discovery infrastructure for walking D type graphs.
///
/// These templates perform compile-time BFS over struct field return types
/// to discover all object types reachable from a root type (e.g., Query).
/// They are data-source agnostic — they work by structural analysis
/// (checking for field methods, plain fields, plain methods) without
/// knowledge of Entity mixins, databases, or GraphQL.
module dunamis.core.discovery;

import std.meta;
import std.traits;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.core.types : isCustomScalar, isInternalMember, isPlainField, isPlainMethod, isGqlResult,
    isAbstractType, getImplementedByMembers, implementsAbstractType, ImplementedBy, Implements;

// ============================================================================
// Field Introspection
// ============================================================================

/// Get all field member names from a type (excluding internal members).
/// Returns a compile-time array of member names that are valid field methods.
template getFieldMembers(T) {
    enum getFieldMembers = () {
        string[] members;
        static foreach (member; __traits(allMembers, T)) {
            static if (!isInternalMember!member) {
                static if (__traits(compiles, __traits(getMember, T, member)) &&
                           is(typeof(__traits(getMember, T, member)) == function)) {
                    members ~= member;
                }
            }
        }
        return members;
    }();
}

/// Check if a member is a computed field (static method taking Expr!T as first parameter).
/// Computed fields can be forwarded via ForwardField mixin.
/// Plain methods (instance methods with no Expr parameter) should use ForwardPlainMethod instead.
template isComputedField(T, string member) {
    static if (__traits(compiles, __traits(getMember, T, member)) &&
               is(typeof(__traits(getMember, T, member)) == function)) {
        alias fn = __traits(getMember, T, member);
        alias Params = Parameters!fn;
        static if (Params.length >= 1) {
            enum isComputedField = isExpr!(Params[0]);
        } else {
            enum isComputedField = false;
        }
    } else {
        enum isComputedField = false;
    }
}

// ============================================================================
// Schema Protocol
// ============================================================================
//
// The Schema Protocol is the canonical interface between the GraphQL
// compiler and schema types. Instead of using ad-hoc __traits(allMembers)
// loops, all consumers (compiler, validator, SDL generator, introspection)
// use these templates to discover and interact with type fields.
//
// Precondition: Types must be normalized (via NormalizePlugin or Schema!()).
// After normalization, all fields are computed fields — static methods that
// take Expr!T as first parameter and return an Expr type.
//
// Templates:
//   getSchemaFields!T      — enumerate all field member names
//   fieldResultType!(T, m) — get the D result type of a field
//

/// Get all schema field member names for a normalized type T.
/// Returns only computed fields: static methods (Expr!T, args...) → Expr!U.
///
/// This is the single source of truth for "what fields does this type expose?"
/// All compiler, validator, SDL, and introspection code should use this
/// instead of raw __traits(allMembers) loops.
template getSchemaFields(T) {
    enum string[] getSchemaFields = _buildSchemaFields!T();
}

private string[] _buildSchemaFields(T)() {
    string[] result;
    static foreach (member; __traits(allMembers, T)) {
        static if (!isInternalMember!member &&
                   isValidFieldMethodForType!(T, member) &&
                   __traits(getVisibility, __traits(getMember, T, member)) == "public") {
            result ~= member;
        }
    }
    return result;
}

/// Get the D result type of a schema field (unwraps Expr!U → U).
///
/// For a computed field `fn: (Expr!T, args...) → Expr!U`, returns `U`.
template fieldResultType(T, string member) {
    alias fn = __traits(getMember, T, member);
    alias fieldResultType = ExprResultType!(ReturnType!(typeof(fn)));
}

// ============================================================================
// Object Type Detection
// ============================================================================

/// Check if a type is an "object type" — a struct with valid field methods,
/// plain fields, or plain methods.
///
/// Exclusions:
/// - JSONValue is treated as a scalar (passed through as raw JSON)
/// - Custom scalars are treated as scalars
/// - Input types (structs without valid field methods used as computed field arguments)
template isObjectType(T) {
    import std.json : JSONValue;
    static if (is(T == struct)) {
        // Exclude JSONValue (raw JSON pass-through)
        static if (is(T == JSONValue)) {
            enum isObjectType = false;
        }
        // Exclude custom scalars
        else static if (isCustomScalar!T) {
            enum isObjectType = false;
        }
        // Exclude GqlResult (error wrapper, not a domain type)
        else static if (isGqlResult!T) {
            enum isObjectType = false;
        }
        // Check if it has at least one valid field method, plain field, or plain method
        else {
            enum isObjectType = hasAnyValidFieldMethod!T || hasAnyPlainField!T || hasAnyPlainMethod!T;
        }
    } else {
        enum isObjectType = false;
    }
}

// ============================================================================
// Field Method Validation
// ============================================================================

/// Check if a method is a valid field method for type T.
/// Valid field methods:
/// - Take Expr!T as first parameter
/// - Return an Expr type
template isValidFieldMethod(T, alias fn) {
    import std.traits : Parameters, ReturnType;

    static if (is(typeof(fn) == function)) {
        alias Params = Parameters!fn;
        alias Return = ReturnType!fn;

        static if (Params.length >= 1) {
            // First parameter must be Expr!T
            static if (is(Params[0] : Expr!E, E) && is(E == T)) {
                // Return type must be an Expr
                enum isValidFieldMethod = isExpr!Return;
            } else {
                enum isValidFieldMethod = false;
            }
        } else {
            enum isValidFieldMethod = false;
        }
    } else {
        enum isValidFieldMethod = false;
    }
}

/// Helper to check if a member is a valid field method for type T.
/// Uses string member name to avoid forward reference issues.
template isValidFieldMethodForType(T, string member) {
    static if (__traits(compiles, __traits(getMember, T, member))) {
        alias fn = __traits(getMember, T, member);
        static if (is(typeof(fn) == function)) {
            alias Params = Parameters!fn;
            alias Return = ReturnType!fn;
            static if (Params.length >= 1) {
                static if (is(Params[0] : Expr!E, E) && is(E == T)) {
                    enum isValidFieldMethodForType = isExpr!Return;
                } else {
                    enum isValidFieldMethodForType = false;
                }
            } else {
                enum isValidFieldMethodForType = false;
            }
        } else {
            enum isValidFieldMethodForType = false;
        }
    } else {
        enum isValidFieldMethodForType = false;
    }
}

// ============================================================================
// Object Type Discovery (BFS)
// ============================================================================

/// Fixpoint object type discovery — expands relationships until no new types are found.
/// Discovers all object types reachable from a root type's field return types.
template getAllObjectTypes(Query) {
    // Several root fields may return the same type
    alias getAllObjectTypes = expandObjectFixpoint!(uniqueTypes!(getRootTypes!Query));
}

/// Check if a type is already in an AliasSeq
template staticContains(T, Types...) {
    static if (Types.length == 0) {
        enum staticContains = false;
    } else static if (is(T == Types[0])) {
        enum staticContains = true;
    } else {
        enum staticContains = staticContains!(T, Types[1..$]);
    }
}

/// Filter a type list to exclude types present in a known set.
/// Uses a wrapper template to work around D's single variadic pack limitation.
/// Usage: ExcludeTypes!(Known...).From!(Candidates...)
template ExcludeTypes(Known...) {
    template From(Candidates...) {
        static if (Candidates.length == 0) {
            alias From = AliasSeq!();
        } else static if (staticContains!(Candidates[0], Known)) {
            alias From = From!(Candidates[1..$]);
        } else {
            alias From = AliasSeq!(Candidates[0], From!(Candidates[1..$]));
        }
    }
}

/// Extract object type from a result type (handles T, T[], Nullable!T).
/// Returns void if no object type is found.
template extractObjectFromType(T) {
    static if (is(T == E[], E)) {
        // Array - check element type
        alias extractObjectFromType = extractObjectFromType!E;
    } else static if (is(T == Nullable!U, U)) {
        // Nullable - unwrap
        alias extractObjectFromType = extractObjectFromType!U;
    } else static if (isGqlResult!T) {
        // GqlResult - unwrap to inner type
        alias extractObjectFromType = extractObjectFromType!(typeof(T.init.value));
    } else static if (isAbstractType!T) {
        // Abstract type (union/interface) — include in type graph for member discovery
        alias extractObjectFromType = T;
    } else static if (isObjectType!T) {
        // Object type (struct with valid field methods)
        alias extractObjectFromType = T;
    } else {
        // Not an object type
        alias extractObjectFromType = void;
    }
}

/// Get all object types directly referenced by a type (via field return types).
/// For abstract types, also follows @ImplementedBy links to include member types.
template getRelatedTypes(T) {
    alias _fieldRelated = getRelatedTypesImpl!(T, 0, __traits(allMembers, T));
    // For abstract types, also include member types from @ImplementedBy
    static if (isAbstractType!T) {
        alias getRelatedTypes = AliasSeq!(_fieldRelated, getImplementedByMembers!T);
    } else {
        alias getRelatedTypes = _fieldRelated;
    }
}

/// Get root object types from a Query type
template getRootTypes(Query) {
    alias getRootTypes = getRootTypesImpl!(Query, 0, __traits(allMembers, Query));
}

/// Remove duplicates from a type list
template uniqueTypes(Types...) {
    static if (Types.length == 0) {
        alias uniqueTypes = AliasSeq!();
    } else static if (staticContains!(Types[0], Types[1..$])) {
        alias uniqueTypes = uniqueTypes!(Types[1..$]);
    } else {
        alias uniqueTypes = AliasSeq!(Types[0], uniqueTypes!(Types[1..$]));
    }
}

/// Forward declaration helper for uniqueTypes
template uniqueTypesForExpand(Types...) {
    static if (Types.length == 0) {
        alias uniqueTypesForExpand = AliasSeq!();
    } else static if (staticContains!(Types[0], Types[1..$])) {
        alias uniqueTypesForExpand = uniqueTypesForExpand!(Types[1..$]);
    } else {
        alias uniqueTypesForExpand = AliasSeq!(Types[0], uniqueTypesForExpand!(Types[1..$]));
    }
}

// ============================================================================
// Abstract Type Protocol
// ============================================================================

/// Get the concrete member types of an abstract type.
/// Merges two declaration modes:
///   1. @ImplementedBy!(Members...) on the abstract type (including through _normalizedSource chain)
///   2. @Implements!(AbstractTypes...) on member types (scanned from AllTypes)
///
/// AllTypes is typically getAllObjectTypes!Query — the set of known concrete types.
/// This is the single source of truth for "what types does this abstract type contain?"
template getAbstractTypeMembers(AbstractT, AllTypes...) {
    alias _fromUDA = getImplementedByMembers!AbstractT;
    alias _fromImpl = _collectImplementors!(AbstractT, AllTypes);
    alias getAbstractTypeMembers = uniqueTypes!(AliasSeq!(_fromUDA, _fromImpl));
}

/// Get the narrow targets for a type (types it can be narrowed to via `... on TypeName`).
/// For abstract types: returns concrete member types.
/// For concrete types: returns empty tuple (no narrowing).
///
/// This is the compiler's single entry point for type narrowing.
template getNarrowTargets(T, AllTypes...) {
    static if (isAbstractType!T) {
        alias getNarrowTargets = getAbstractTypeMembers!(T, AllTypes);
    } else {
        alias getNarrowTargets = AliasSeq!();
    }
}

/// Discover all abstract types from a set of types and their field return types.
/// Scans for structs with @ImplementedBy UDA.
template getAllAbstractTypes(AllTypes...) {
    alias getAllAbstractTypes = _filterAbstractTypes!(AllTypes);
}

/// Get the abstract interfaces that a concrete type implements.
/// Returns a tuple of abstract types that have schema fields (i.e., interfaces, not unions).
template getImplementedInterfaces(T, AllAbstractTypes...) {
    alias getImplementedInterfaces = _filterImplementedInterfaces!(T, AllAbstractTypes);
}

// --- Private abstract type helpers ---

/// Collect types from AllTypes that declare @Implements for AbstractT
private template _collectImplementors(AbstractT, AllTypes...) {
    static if (AllTypes.length == 0) {
        alias _collectImplementors = AliasSeq!();
    } else {
        static if (implementsAbstractType!(AllTypes[0], AbstractT)) {
            alias _collectImplementors = AliasSeq!(AllTypes[0], _collectImplementors!(AbstractT, AllTypes[1..$]));
        } else {
            alias _collectImplementors = _collectImplementors!(AbstractT, AllTypes[1..$]);
        }
    }
}

/// Filter a type list to only abstract types
private template _filterAbstractTypes(Types...) {
    static if (Types.length == 0) {
        alias _filterAbstractTypes = AliasSeq!();
    } else {
        static if (isAbstractType!(Types[0])) {
            alias _filterAbstractTypes = AliasSeq!(Types[0], _filterAbstractTypes!(Types[1..$]));
        } else {
            alias _filterAbstractTypes = _filterAbstractTypes!(Types[1..$]);
        }
    }
}

/// Filter abstract types to those that T is a member of AND that have schema fields (interfaces)
private template _filterImplementedInterfaces(T, AllAbstractTypes...) {
    static if (AllAbstractTypes.length == 0) {
        alias _filterImplementedInterfaces = AliasSeq!();
    } else {
        alias AbstractT = AllAbstractTypes[0];
        alias Rest = _filterImplementedInterfaces!(T, AllAbstractTypes[1..$]);
        // Check: is T a member of this abstract type, and does the abstract type have schema fields?
        static if (_isMemberOf!(T, AbstractT) && getSchemaFields!AbstractT.length > 0) {
            alias _filterImplementedInterfaces = AliasSeq!(AbstractT, Rest);
        } else {
            alias _filterImplementedInterfaces = Rest;
        }
    }
}

/// Check if T is a member of abstract type AbstractT (via @ImplementedBy on AbstractT)
private template _isMemberOf(T, AbstractT) {
    alias Members = getImplementedByMembers!AbstractT;
    enum _isMemberOf = staticContains!(T, Members);
}

// ============================================================================
// Private Helpers
// ============================================================================

/// Check if type has any valid field methods
private template hasAnyValidFieldMethod(T) {
    enum hasAnyValidFieldMethod = () {
        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member &&
                       is(typeof(__traits(getMember, T, member)) == function)) {
                static if (isValidFieldMethodForType!(T, member)) {
                    return true;
                }
            }
        }}
        return false;
    }();
}

/// Check if type has any plain fields (struct instance fields)
private template hasAnyPlainField(T) {
    enum hasAnyPlainField = () {
        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member) {
                static if (isPlainField!(T, member)) {
                    return true;
                }
            }
        }}
        return false;
    }();
}

/// Check if type has any plain methods (instance methods returning non-Expr types)
private template hasAnyPlainMethod(T) {
    enum hasAnyPlainMethod = () {
        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member) {
                static if (isPlainMethod!(T, member)) {
                    return true;
                }
            }
        }}
        return false;
    }();
}

/// Helper to get related types from a type by iterating over members.
private template getRelatedTypesImpl(T, size_t idx, Members...) {
    static if (idx >= Members.length) {
        alias getRelatedTypesImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getRelatedTypesImpl!(T, idx + 1, Members);

        static if (!isInternalMember!member) {
            // 1. Check computed fields (static methods returning Expr!T)
            static if (is(typeof(__traits(getMember, T, member)) == function)) {
                alias fn = __traits(getMember, T, member);

                static if (isValidFieldMethod!(T, fn)) {
                    alias RetType = ReturnType!fn;
                    alias ResultT = ExprResultType!RetType;

                    // Extract object type from return type
                    alias ObjectFromReturn = extractObjectFromType!ResultT;

                    static if (!is(ObjectFromReturn == void)) {
                        alias getRelatedTypesImpl = AliasSeq!(ObjectFromReturn, Rest);
                    } else {
                        alias getRelatedTypesImpl = Rest;
                    }
                }
                // 2. Check plain methods (instance methods returning non-Expr types)
                else static if (isPlainMethod!(T, member)) {
                    alias RetType = ReturnType!fn;
                    alias ObjectFromReturn = extractObjectFromType!RetType;

                    static if (!is(ObjectFromReturn == void)) {
                        alias getRelatedTypesImpl = AliasSeq!(ObjectFromReturn, Rest);
                    } else {
                        alias getRelatedTypesImpl = Rest;
                    }
                } else {
                    alias getRelatedTypesImpl = Rest;
                }
            }
            // 3. Check plain fields (struct instance fields)
            else static if (isPlainField!(T, member)) {
                alias FieldType = typeof(__traits(getMember, T.init, member));
                alias ObjectFromField = extractObjectFromType!FieldType;

                static if (!is(ObjectFromField == void)) {
                    alias getRelatedTypesImpl = AliasSeq!(ObjectFromField, Rest);
                } else {
                    alias getRelatedTypesImpl = Rest;
                }
            } else {
                alias getRelatedTypesImpl = Rest;
            }
        } else {
            alias getRelatedTypesImpl = Rest;
        }
    }
}

/// Helper to get root types from Query by iterating over members.
private template getRootTypesImpl(Query, size_t idx, Members...) {
    static if (idx >= Members.length) {
        alias getRootTypesImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getRootTypesImpl!(Query, idx + 1, Members);

        static if (!isInternalMember!member &&
                   is(typeof(__traits(getMember, Query, member)) == function)) {
            alias fn = __traits(getMember, Query, member);

            // Check if it's a valid field method
            static if (isValidFieldMethod!(Query, fn)) {
                alias RetType = ReturnType!fn;
                alias ResultT = ExprResultType!RetType;

                // Extract object type from return type
                alias ObjectFromReturn = extractObjectFromType!ResultT;

                static if (!is(ObjectFromReturn == void)) {
                    alias getRootTypesImpl = AliasSeq!(ObjectFromReturn, Rest);
                } else {
                    alias getRootTypesImpl = Rest;
                }
            } else {
                alias getRootTypesImpl = Rest;
            }
        } else {
            alias getRootTypesImpl = Rest;
        }
    }
}

/// Expand one level: get all related types from a set of types
private template expandOneLevel(Types...) {
    static if (Types.length == 0) {
        alias expandOneLevel = AliasSeq!();
    } else {
        alias First = getRelatedTypes!(Types[0]);
        alias Rest = expandOneLevel!(Types[1..$]);
        alias expandOneLevel = AliasSeq!(First, Rest);
    }
}

private template expandObjectFixpoint(PrevTypes...) {
    alias NewOnly = uniqueTypes!(ExcludeTypes!(PrevTypes).From!(expandOneLevel!PrevTypes));

    static if (NewOnly.length == 0)
        alias expandObjectFixpoint = PrevTypes;
    else
        alias expandObjectFixpoint = expandObjectFixpoint!(AliasSeq!(PrevTypes, NewOnly));
}

// ============================================================================
// Schema Protocol — Unit Tests
// ============================================================================

unittest {
    import dunamis.core.expr : Expr;

    // Test entity with computed fields only (post-normalization shape)
    static struct User {
        static Expr!string firstName(Expr!User u) { assert(false); }
        static Expr!string lastName(Expr!User u) { assert(false); }
        static Expr!long age(Expr!User u) { assert(false); }
    }

    // getSchemaFields returns all computed field names
    enum fields = getSchemaFields!User;
    static assert(fields.length == 3);
    static assert(fields[0] == "firstName");
    static assert(fields[1] == "lastName");
    static assert(fields[2] == "age");

    // fieldResultType unwraps Expr!T → T
    static assert(is(fieldResultType!(User, "firstName") == string));
    static assert(is(fieldResultType!(User, "age") == long));

    // isObjectType still works
    static assert(isObjectType!User);
}

unittest {
    import dunamis.core.expr : Expr;

    // Internal members and non-field methods are excluded
    static struct Widget {
        static Expr!string name(Expr!Widget w) { assert(false); }

        // Not a field method (wrong first param)
        static int helper() { return 0; }

        // toString is an internal member
        string toString() const { return ""; }
    }

    enum fields = getSchemaFields!Widget;
    static assert(fields.length == 1);
    static assert(fields[0] == "name");
}

unittest {
    import dunamis.core.expr : Expr;

    // Empty struct has no schema fields
    static struct Empty {}

    enum fields = getSchemaFields!Empty;
    static assert(fields.length == 0);
    static assert(!isObjectType!Empty);
}

unittest {
    import dunamis.core.expr : Expr;
    import std.typecons : Nullable;

    // Test fieldResultType with array and nullable return types
    static struct Post {
        static Expr!(string[]) tags(Expr!Post p) { assert(false); }
        static Expr!(Nullable!string) bio(Expr!Post p) { assert(false); }
    }

    static assert(is(fieldResultType!(Post, "tags") == string[]));
    static assert(is(fieldResultType!(Post, "bio") == Nullable!string));
}

// ============================================================================
// Abstract Type Protocol — Unit Tests
// ============================================================================

unittest {
    import dunamis.core.expr : Expr;
    import dunamis.core.types : ImplementedBy, Implements, AbstractField;

    // Wrapper struct enables forward references between nested types
    static struct S {
        static struct User {
            static Expr!string name(Expr!User u) { assert(false); }
            static Expr!long id(Expr!User u) { assert(false); }
        }

        static struct Post {
            static Expr!string title(Expr!Post p) { assert(false); }
            static Expr!long id(Expr!Post p) { assert(false); }
        }

        // Union (no shared fields)
        @ImplementedBy!(User, Post)
        static struct SearchResult {}
    }

    alias User = S.User;
    alias Post = S.Post;
    alias SearchResult = S.SearchResult;

    // isAbstractType detection
    static assert(isAbstractType!SearchResult);
    static assert(!isAbstractType!User);

    // Pure unions don't pass isObjectType (no fields)
    static assert(!isObjectType!SearchResult);

    // extractObjectFromType handles abstract types
    static assert(is(extractObjectFromType!SearchResult == SearchResult));
    static assert(is(extractObjectFromType!(SearchResult[]) == SearchResult));

    // getAbstractTypeMembers from @ImplementedBy
    alias members = getAbstractTypeMembers!(SearchResult, User, Post);
    static assert(members.length == 2);
    static assert(is(members[0] == User));
    static assert(is(members[1] == Post));

    // getNarrowTargets for abstract type returns members
    alias targets = getNarrowTargets!(SearchResult, User, Post);
    static assert(targets.length == 2);

    // getNarrowTargets for concrete type returns empty
    alias noTargets = getNarrowTargets!(User, User, Post);
    static assert(noTargets.length == 0);

    // getAllAbstractTypes finds abstract types
    alias abstracts = getAllAbstractTypes!(SearchResult, User, Post);
    static assert(abstracts.length == 1);
    static assert(is(abstracts[0] == SearchResult));
}

unittest {
    import dunamis.core.expr : Expr;
    import dunamis.core.types : ImplementedBy, Implements, AbstractField;

    static struct S {
        static struct User {
            static Expr!string name(Expr!User u) { assert(false); }
            static Expr!long id(Expr!User u) { assert(false); }
        }

        static struct Post {
            static Expr!string title(Expr!Post p) { assert(false); }
            static Expr!long id(Expr!Post p) { assert(false); }
        }

        // Interface (has shared fields via AbstractField)
        @ImplementedBy!(User, Post)
        static struct Node {
            mixin AbstractField!("id", long);
        }

        // Pure union for comparison
        @ImplementedBy!(User, Post)
        static struct SearchResult {}
    }

    alias User = S.User;
    alias Node = S.Node;
    alias SearchResult = S.SearchResult;

    // Interface passes isObjectType (has a valid field method from AbstractField)
    static assert(isAbstractType!Node);
    static assert(isObjectType!Node);

    // getSchemaFields picks up the AbstractField-generated method
    enum fields = getSchemaFields!Node;
    static assert(fields.length == 1);
    static assert(fields[0] == "id");

    // fieldResultType works on AbstractField
    static assert(is(fieldResultType!(Node, "id") == long));

    // getImplementedInterfaces: Node is an interface (has schema fields)
    alias nodeInterfaces = getImplementedInterfaces!(User, Node);
    static assert(nodeInterfaces.length == 1);
    static assert(is(nodeInterfaces[0] == Node));

    // Pure union has no schema fields, so not returned as interface
    alias searchInterfaces = getImplementedInterfaces!(User, SearchResult);
    static assert(searchInterfaces.length == 0);
}

unittest {
    import dunamis.core.expr : Expr;
    import dunamis.core.types : ImplementedBy, Implements;

    // Test @Implements merging
    static struct S {
        @ImplementedBy!(User, Post)
        static struct SearchResult {}

        static struct User {
            static Expr!string name(Expr!User u) { assert(false); }
        }

        static struct Post {
            static Expr!string title(Expr!Post p) { assert(false); }
        }

        @Implements!SearchResult
        static struct Comment {
            static Expr!string body_(Expr!Comment c) { assert(false); }
        }
    }

    // getAbstractTypeMembers merges @ImplementedBy + @Implements
    alias members = getAbstractTypeMembers!(S.SearchResult, S.User, S.Post, S.Comment);
    static assert(members.length == 3);  // User, Post from @ImplementedBy + Comment from @Implements
}

unittest {
    import dunamis.core.expr : Expr;
    import dunamis.core.types : ImplementedBy;

    // Test BFS type discovery follows @ImplementedBy links
    static struct S {
        static struct User {
            static Expr!string name(Expr!User u) { assert(false); }
        }

        static struct Post {
            static Expr!string title(Expr!Post p) { assert(false); }
        }

        @ImplementedBy!(User, Post)
        static struct SearchResult {}

        static struct Query {
            static Expr!(SearchResult[]) search(Expr!Query q) { assert(false); }
        }
    }

    // getAllObjectTypes should discover User and Post through SearchResult's @ImplementedBy
    alias allTypes = getAllObjectTypes!(S.Query);

    // Should contain SearchResult, User, Post
    static assert(staticContains!(S.SearchResult, allTypes));
    static assert(staticContains!(S.User, allTypes));
    static assert(staticContains!(S.Post, allTypes));
}

unittest {
    import dunamis.core.expr : Expr;

    // A type returned by several root fields is discovered once
    struct S {
        static struct User {
            static Expr!string name(Expr!User u) { assert(false); }
        }
        static struct Query {
            static Expr!(User[]) users(Expr!Query q) { assert(false); }
            static Expr!User viewer(Expr!Query q) { assert(false); }
        }
    }

    alias allTypes = getAllObjectTypes!(S.Query);
    static assert(allTypes.length == 1 && is(allTypes[0] == S.User), allTypes.stringof);
}
