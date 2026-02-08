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
import dunamis.core.types : isCustomScalar, isInternalMember, isPlainField, isPlainMethod;

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
    alias getAllObjectTypes = expandObjectFixpoint!(getRootTypes!Query);
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
    } else static if (isObjectType!T) {
        // Object type (struct with valid field methods)
        alias extractObjectFromType = T;
    } else {
        // Not an object type
        alias extractObjectFromType = void;
    }
}

/// Get all object types directly referenced by a type (via field return types)
template getRelatedTypes(T) {
    alias getRelatedTypes = getRelatedTypesImpl!(T, 0, __traits(allMembers, T));
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
