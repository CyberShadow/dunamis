module dunamis.graphql.schema.discovery;

import std.meta;
import std.traits;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.graphql.schema.udas;
import dunamis.graphql.schema.fields : isValidFieldMethod, graphqlTypeName;
import dunamis.graphql.schema.input_types;

// Re-export type discovery from core (renamed: getAllEntityTypes → getAllObjectTypes)
public import dunamis.core.discovery :
    getAllObjectTypes, extractObjectFromType,
    getRelatedTypes, getSchemaObjectTypes, SchemaRootTypes,
    uniqueTypes, uniqueTypesForExpand,
    staticContains, ExcludeTypes;

// Backward-compatible alias
alias getAllEntityTypes = getAllObjectTypes;

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

        static if (!isPublicDataField!(T, member)) {
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
    // (Iterative: see the type list helpers in dunamis.core.discovery.)
    alias expandInputOneLevel = staticMap!(getNestedInputTypes, Types);
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

        static if (!isPublicMember!(Entity, member)) {
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
    alias getInputTypesFromEntitiesImpl = staticMap!(getInputTypesFromEntity, Entities);
}

/// Collect all input types of the schema with the root types `Roots`: the
/// argument types of the fields of the roots and of all object types
/// reachable from them.
/// Uses BFS expansion to discover nested input types including recursive ones.
template getAllInputTypes(Roots...) {
    alias DirectInputTypes = getInputTypesFromEntitiesImpl!(getAllObjectTypes!Roots, Roots);
    // Expand to discover nested input types (handles recursive types via fixed-depth BFS)
    alias getAllInputTypes = expandAllInputTypes!(uniqueTypesForExpand!DirectInputTypes);
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

        static if (!isPublicMember!(Entity, member)) {
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
template UnwrapEnumContainer(T) {
    static if (is(T == Nullable!U, U))
        alias UnwrapEnumContainer = UnwrapEnumContainer!U;
    else static if (is(T == E[], E))
        alias UnwrapEnumContainer = UnwrapEnumContainer!E;
    else static if (is(T == U*, U))
        alias UnwrapEnumContainer = UnwrapEnumContainer!U;
    else
        alias UnwrapEnumContainer = T;
}

template getEnumTypesFromParamsImpl(size_t idx, Params...) {
    static if (idx >= Params.length) {
        alias getEnumTypesFromParamsImpl = AliasSeq!();
    } else {
        alias P = Params[idx];
        alias Unwrapped = UnwrapEnumContainer!P;
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

        static if (!isPublicDataField!(T, member)) {
            alias getEnumTypesFromInputTypeImpl = Rest;
        } else static if (__traits(compiles, typeof(__traits(getMember, T, member)))) {
            alias MemberType = typeof(__traits(getMember, T, member));

            static if (!is(MemberType == function) && !is(MemberType == void)) {
                alias Unwrapped = UnwrapEnumContainer!MemberType;

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
    alias getEnumTypesFromEntitiesImpl = staticMap!(getEnumTypesFromEntity, Entities);
}

/// Collect all enum types of the schema with the root types `Roots` (those
/// of the fields of the roots and of all object types reachable from them)
template getAllEnumTypes(Roots...) {
    alias AllEnumTypes = getEnumTypesFromEntitiesImpl!(getAllObjectTypes!Roots, Roots);
    alias getAllEnumTypes = uniqueTypes!AllEnumTypes;
}
