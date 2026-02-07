module dunamis.graphql.schema.discovery;

import std.meta;
import std.traits;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.graphql.schema.udas;
import dunamis.graphql.schema.fields : isValidFieldMethod, graphqlTypeName;
import dunamis.graphql.schema.input_types;

// ============================================================================
// Input Type Discovery
// ============================================================================

/// Helper to extract input types from function parameters (iterative)
template getInputTypesFromParamsImpl(size_t idx, Params...) {
    static if (idx >= Params.length) {
        alias getInputTypesFromParamsImpl = AliasSeq!();
    } else {
        alias P = Params[idx];
        alias Extracted = extractInputTypeFromType!P;
        alias Rest = getInputTypesFromParamsImpl!(idx + 1, Params);

        static if (!is(Extracted == void)) {
            alias getInputTypesFromParamsImpl = AliasSeq!(Extracted, Rest);
        } else {
            alias getInputTypesFromParamsImpl = Rest;
        }
    }
}

/// Extract input types from computed field arguments (skip first Expr!Entity param)
template getInputTypesFromArguments(alias member) {
    alias Params = Parameters!member;
    // Skip first parameter (index 0), start from index 1
    static if (Params.length > 1) {
        alias getInputTypesFromArguments = getInputTypesFromParamsImpl!(1, Params);
    } else {
        alias getInputTypesFromArguments = AliasSeq!();
    }
}

/// Helper to get input types from struct fields (iterative)
template getNestedInputTypesImpl(T, size_t idx, Members...) {
    static if (idx >= Members.length) {
        alias getNestedInputTypesImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getNestedInputTypesImpl!(T, idx + 1, Members);

        static if (isInternalMember!member) {
            alias getNestedInputTypesImpl = Rest;
        } else static if (__traits(compiles, typeof(__traits(getMember, T, member)))) {
            alias MemberType = typeof(__traits(getMember, T, member));

            static if (!is(MemberType == function) && !is(MemberType == void)) {
                alias Extracted = extractInputTypeFromType!MemberType;

                static if (!is(Extracted == void)) {
                    alias getNestedInputTypesImpl = AliasSeq!(Extracted, Rest);
                } else {
                    alias getNestedInputTypesImpl = Rest;
                }
            } else {
                alias getNestedInputTypesImpl = Rest;
            }
        } else {
            alias getNestedInputTypesImpl = Rest;
        }
    }
}

/// Get nested input types from an input type's fields
template getNestedInputTypes(T) if (isInputType!T) {
    alias getNestedInputTypes = getNestedInputTypesImpl!(T, 0, __traits(allMembers, T));
}

/// Expand one level: get all nested input types from a set of input types
template expandInputOneLevel(Types...) {
    static if (Types.length == 0) {
        alias expandInputOneLevel = AliasSeq!();
    } else {
        alias First = getNestedInputTypes!(Types[0]);
        alias Rest = expandInputOneLevel!(Types[1..$]);
        alias expandInputOneLevel = AliasSeq!(First, Rest);
    }
}

/// Fixpoint input type discovery - expands nested input types until no new types are found.
template expandAllInputTypes(InputTypes...) {
    alias expandAllInputTypes = expandInputFixpoint!InputTypes;
}

private template expandInputFixpoint(PrevTypes...) {
    alias NewOnly = uniqueTypesForExpand!(ExcludeTypes!(PrevTypes).From!(expandInputOneLevel!PrevTypes));

    static if (NewOnly.length == 0)
        alias expandInputFixpoint = PrevTypes;
    else
        alias expandInputFixpoint = expandInputFixpoint!(AliasSeq!(PrevTypes, NewOnly));
}

/// Helper to collect input types from entity members (iterative)
template getInputTypesFromEntityImpl(Entity, size_t idx, Members...) {
    static if (idx >= Members.length) {
        alias getInputTypesFromEntityImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getInputTypesFromEntityImpl!(Entity, idx + 1, Members);

        static if (isInternalMember!member) {
            alias getInputTypesFromEntityImpl = Rest;
        } else static if (__traits(compiles, isValidFieldMethod!(Entity, __traits(getMember, Entity, member)))) {
            static if (isValidFieldMethod!(Entity, __traits(getMember, Entity, member))) {
                alias fn = __traits(getMember, Entity, member);
                alias InputTypes = getInputTypesFromArguments!fn;
                alias getInputTypesFromEntityImpl = AliasSeq!(InputTypes, Rest);
            } else {
                alias getInputTypesFromEntityImpl = Rest;
            }
        } else {
            alias getInputTypesFromEntityImpl = Rest;
        }
    }
}

/// Collect all input types from an entity's computed fields
template getInputTypesFromEntity(Entity) {
    alias getInputTypesFromEntity = getInputTypesFromEntityImpl!(Entity, 0, __traits(allMembers, Entity));
}

/// Helper to collect input types from multiple entities
template getInputTypesFromEntitiesImpl(Entities...) {
    static if (Entities.length == 0) {
        alias getInputTypesFromEntitiesImpl = AliasSeq!();
    } else {
        alias First = getInputTypesFromEntity!(Entities[0]);
        alias Rest = getInputTypesFromEntitiesImpl!(Entities[1..$]);
        alias getInputTypesFromEntitiesImpl = AliasSeq!(First, Rest);
    }
}

/// Collect all input types from all entities in the schema.
/// Uses BFS expansion to discover nested input types including recursive ones.
template getAllInputTypes(Query) {
    alias _AllEntityTypes = getAllEntityTypes!Query;
    alias DirectInputTypes = getInputTypesFromEntitiesImpl!_AllEntityTypes;
    // Expand to discover nested input types (handles recursive types via fixed-depth BFS)
    alias getAllInputTypes = expandAllInputTypes!(uniqueTypesForExpand!DirectInputTypes);
}

/// Helper to get input types from mutation parameters (iterative)
template getInputTypesFromMutationImpl(Mutation, size_t idx, Members...) {
    static if (idx >= Members.length) {
        alias getInputTypesFromMutationImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getInputTypesFromMutationImpl!(Mutation, idx + 1, Members);

        static if (isInternalMember!member) {
            alias getInputTypesFromMutationImpl = Rest;
        } else static if (is(typeof(__traits(getMember, Mutation, member)) == function)) {
            alias fn = __traits(getMember, Mutation, member);
            alias Params = Parameters!fn;
            // Get input types from parameters (skip first which is parent Expr!Mutation)
            alias InputTypes = getInputTypesFromParamsImpl!(1, Params);
            alias getInputTypesFromMutationImpl = AliasSeq!(InputTypes, Rest);
        } else {
            alias getInputTypesFromMutationImpl = Rest;
        }
    }
}

/// Collect all input types from a Mutation type's parameters
template getInputTypesFromMutation(Mutation) {
    alias getInputTypesFromMutation = getInputTypesFromMutationImpl!(Mutation, 0, __traits(allMembers, Mutation));
}

// ============================================================================
// Enum Type Discovery
// ============================================================================

/// Helper to extract enum type from a type (unwraps Nullable, arrays)
template extractEnumFromType(T) {
    static if (is(T == E[], E)) {
        alias extractEnumFromType = extractEnumFromType!E;
    } else static if (is(T == Nullable!U, U)) {
        alias extractEnumFromType = extractEnumFromType!U;
    } else static if (isGraphQLEnum!T) {
        alias extractEnumFromType = T;
    } else {
        alias extractEnumFromType = void;
    }
}

/// Helper to collect enum types from entity members (iterative)
template getEnumTypesFromEntityImpl(Entity, size_t idx, Members...) {
    import std.traits : ReturnType, Parameters;
    import dunamis.core.expr : ExprResultType;

    static if (idx >= Members.length) {
        alias getEnumTypesFromEntityImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getEnumTypesFromEntityImpl!(Entity, idx + 1, Members);

        static if (isInternalMember!member) {
            alias getEnumTypesFromEntityImpl = Rest;
        } else static if (__traits(compiles, isValidFieldMethod!(Entity, __traits(getMember, Entity, member)))) {
            static if (isValidFieldMethod!(Entity, __traits(getMember, Entity, member))) {
                alias fn = __traits(getMember, Entity, member);
                alias RetType = ReturnType!fn;
                alias ResultT = ExprResultType!RetType;

                // Check return type for enum
                alias EnumFromReturn = extractEnumFromType!ResultT;

                // Check argument types for enums
                alias Params = Parameters!fn;
                alias EnumFromArgs = getEnumTypesFromParamsImpl!(1, Params);

                static if (!is(EnumFromReturn == void)) {
                    alias getEnumTypesFromEntityImpl = AliasSeq!(EnumFromReturn, EnumFromArgs, Rest);
                } else {
                    alias getEnumTypesFromEntityImpl = AliasSeq!(EnumFromArgs, Rest);
                }
            } else {
                alias getEnumTypesFromEntityImpl = Rest;
            }
        } else {
            alias getEnumTypesFromEntityImpl = Rest;
        }
    }
}

/// Helper to extract enum types from parameters (iterative)
template getEnumTypesFromParamsImpl(size_t idx, Params...) {
    static if (idx >= Params.length) {
        alias getEnumTypesFromParamsImpl = AliasSeq!();
    } else {
        alias P = Params[idx];
        alias Unwrapped = UnwrapNullable!P;
        alias Rest = getEnumTypesFromParamsImpl!(idx + 1, Params);

        static if (isGraphQLEnum!Unwrapped) {
            alias getEnumTypesFromParamsImpl = AliasSeq!(Unwrapped, Rest);
        } else static if (isInputType!Unwrapped) {
            // Check inside input type for enum fields
            alias EnumsFromInput = getEnumTypesFromInputType!Unwrapped;
            alias getEnumTypesFromParamsImpl = AliasSeq!(EnumsFromInput, Rest);
        } else {
            alias getEnumTypesFromParamsImpl = Rest;
        }
    }
}

/// Helper to collect enum types from input type fields
template getEnumTypesFromInputTypeImpl(T, size_t idx, Members...) {
    static if (idx >= Members.length) {
        alias getEnumTypesFromInputTypeImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getEnumTypesFromInputTypeImpl!(T, idx + 1, Members);

        static if (isInternalMember!member) {
            alias getEnumTypesFromInputTypeImpl = Rest;
        } else static if (__traits(compiles, typeof(__traits(getMember, T, member)))) {
            alias MemberType = typeof(__traits(getMember, T, member));

            static if (!is(MemberType == function) && !is(MemberType == void)) {
                alias Unwrapped = UnwrapNullable!MemberType;

                static if (isGraphQLEnum!Unwrapped) {
                    alias getEnumTypesFromInputTypeImpl = AliasSeq!(Unwrapped, Rest);
                } else {
                    alias getEnumTypesFromInputTypeImpl = Rest;
                }
            } else {
                alias getEnumTypesFromInputTypeImpl = Rest;
            }
        } else {
            alias getEnumTypesFromInputTypeImpl = Rest;
        }
    }
}

/// Collect enum types from an input type's fields
template getEnumTypesFromInputType(T) if (isInputType!T) {
    alias getEnumTypesFromInputType = getEnumTypesFromInputTypeImpl!(T, 0, __traits(allMembers, T));
}

/// Collect all enum types from an entity's fields
template getEnumTypesFromEntity(Entity) {
    alias getEnumTypesFromEntity = getEnumTypesFromEntityImpl!(Entity, 0, __traits(allMembers, Entity));
}

/// Helper to collect enum types from multiple entities
template getEnumTypesFromEntitiesImpl(Entities...) {
    static if (Entities.length == 0) {
        alias getEnumTypesFromEntitiesImpl = AliasSeq!();
    } else {
        alias First = getEnumTypesFromEntity!(Entities[0]);
        alias Rest = getEnumTypesFromEntitiesImpl!(Entities[1..$]);
        alias getEnumTypesFromEntitiesImpl = AliasSeq!(First, Rest);
    }
}

/// Collect all enum types from all entities in the schema
template getAllEnumTypes(Query) {
    alias _AllEntityTypes = getAllEntityTypes!Query;
    alias AllEnumTypes = getEnumTypesFromEntitiesImpl!_AllEntityTypes;
    alias getAllEnumTypes = uniqueTypes!AllEnumTypes;
}

// ============================================================================
// Entity Type Discovery
// ============================================================================

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
package(dunamis.graphql) template ExcludeTypes(Known...) {
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
template extractEntityFromType(T) {
    static if (is(T == E[], E)) {
        // Array - check element type
        alias extractEntityFromType = extractEntityFromType!E;
    } else static if (is(T == Nullable!U, U)) {
        // Nullable - unwrap
        alias extractEntityFromType = extractEntityFromType!U;
    } else static if (isObjectType!T) {
        // Object type (struct with valid field methods)
        alias extractEntityFromType = T;
    } else {
        // Not an object type
        alias extractEntityFromType = void;
    }
}

/// Helper to get related types from a type by iterating over members.
/// Scans for valid field methods, plain fields, and plain methods,
/// and extracts object types from return types.
template getRelatedTypesImpl(T, size_t idx, Members...) {
    import dunamis.core.expr : ExprResultType;
    import dunamis.core.types : isPlainField, isPlainMethod;

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
                    alias EntityFromReturn = extractEntityFromType!ResultT;

                    static if (!is(EntityFromReturn == void)) {
                        alias getRelatedTypesImpl = AliasSeq!(EntityFromReturn, Rest);
                    } else {
                        alias getRelatedTypesImpl = Rest;
                    }
                }
                // 2. Check plain methods (instance methods returning non-Expr types)
                else static if (isPlainMethod!(T, member)) {
                    alias RetType = ReturnType!fn;
                    alias EntityFromReturn = extractEntityFromType!RetType;

                    static if (!is(EntityFromReturn == void)) {
                        alias getRelatedTypesImpl = AliasSeq!(EntityFromReturn, Rest);
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
                alias EntityFromField = extractEntityFromType!FieldType;

                static if (!is(EntityFromField == void)) {
                    alias getRelatedTypesImpl = AliasSeq!(EntityFromField, Rest);
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

/// Get all object types directly referenced by a type (via field return types)
template getRelatedTypes(T) {
    alias getRelatedTypes = getRelatedTypesImpl!(T, 0, __traits(allMembers, T));
}

/// Helper to get root types from Query by iterating over members.
/// Scans for valid field methods and extracts object types from return types.
template getRootTypesImpl(Query, size_t idx, Members...) {
    import dunamis.core.expr : ExprResultType;

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
                alias EntityFromReturn = extractEntityFromType!ResultT;

                static if (!is(EntityFromReturn == void)) {
                    alias getRootTypesImpl = AliasSeq!(EntityFromReturn, Rest);
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

/// Get root object types from Query
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
package(dunamis.graphql) template uniqueTypesForExpand(Types...) {
    static if (Types.length == 0) {
        alias uniqueTypesForExpand = AliasSeq!();
    } else static if (staticContains!(Types[0], Types[1..$])) {
        alias uniqueTypesForExpand = uniqueTypesForExpand!(Types[1..$]);
    } else {
        alias uniqueTypesForExpand = AliasSeq!(Types[0], uniqueTypesForExpand!(Types[1..$]));
    }
}

/// Expand one level: get all related types from a set of types
template expandOneLevel(Types...) {
    static if (Types.length == 0) {
        alias expandOneLevel = AliasSeq!();
    } else {
        alias First = getRelatedTypes!(Types[0]);
        alias Rest = expandOneLevel!(Types[1..$]);
        alias expandOneLevel = AliasSeq!(First, Rest);
    }
}

/// Fixpoint entity type discovery - expands relationships until no new types are found.
template getAllEntityTypes(Query) {
    alias getAllEntityTypes = expandEntityFixpoint!(getRootTypes!Query);
}

private template expandEntityFixpoint(PrevTypes...) {
    alias NewOnly = uniqueTypes!(ExcludeTypes!(PrevTypes).From!(expandOneLevel!PrevTypes));

    static if (NewOnly.length == 0)
        alias expandEntityFixpoint = PrevTypes;
    else
        alias expandEntityFixpoint = expandEntityFixpoint!(AliasSeq!(PrevTypes, NewOnly));
}
