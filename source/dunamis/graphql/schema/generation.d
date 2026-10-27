module dunamis.graphql.schema.generation;

import std.meta;
import std.traits;
import std.typecons : Nullable;

import dunamis.core.types : isCustomScalar, isAbstractType, getImplementedByMembers, isInternalMember;
import dunamis.core.discovery : getAllObjectTypes, getAllAbstractTypes, getAbstractTypeMembers,
    getImplementedInterfaces, getSchemaFields, isObjectType, uniqueTypesForExpand,
    isValidFieldMethod;
import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.graphql.schema.udas;
import dunamis.graphql.schema.fields;
import dunamis.graphql.schema.input_types;
import dunamis.graphql.schema.discovery;

// ============================================================================
// SDL Generation
// ============================================================================

/// Generate GraphQL SDL for any object type (entity, Query, or Mutation).
/// The AllAbstractTypes parameter enables `implements` clause generation.
string generateObjectTypeSDL(T, AllAbstractTypes...)(string typeName) {
    enum fields = getFields!T;

    static if (fields.length == 0) {
        return "";  // No fields defined
    } else {
        string result = "type " ~ typeName;

        // Add implements clause for interface types
        static if (AllAbstractTypes.length > 0) {
            enum interfaces = _getInterfaceNames!(T, AllAbstractTypes);
            static if (interfaces.length > 0) {
                result ~= " implements";
                foreach (i, name; interfaces) {
                    if (i > 0) result ~= " &";
                    result ~= " " ~ name;
                }
            }
        }

        result ~= " {\n";

        foreach (field; fields) {
            // Skip hidden fields
            if (field.hidden) continue;

            // Add description as doc string
            if (field.description.length > 0) {
                result ~= "  \"\"\"" ~ field.description ~ "\"\"\"\n";
            }

            // Field name
            result ~= "  " ~ field.name;

            // Add arguments if present
            if (field.arguments.length > 0) {
                result ~= "(";
                foreach (i, arg; field.arguments) {
                    if (i > 0) result ~= ", ";
                    result ~= arg.name ~ ": " ~ arg.graphqlType;
                    if (arg.hasDefault) {
                        result ~= " = " ~ arg.defaultValue;
                    }
                }
                result ~= ")";
            }

            // Return type
            result ~= ": " ~ field.graphqlType;

            // Add @deprecated directive if present
            if (field.deprecation.length > 0) {
                result ~= " @deprecated(reason: \"" ~ field.deprecation ~ "\")";
            }

            result ~= "\n";
        }

        result ~= "}\n";
        return result;
    }
}

// ============================================================================
// Root Field Return Type Extraction
// ============================================================================

/// Get the GraphQL return type of a root field (Query or Mutation).
/// Root fields return Expr!T, so we extract T and convert to GraphQL type.
template rootFieldReturnType(alias member) {
    alias Return = ReturnType!(typeof(member));

    // Extract inner type from Expr!T
    static if (is(Return : Expr!T, T)) {
        alias ResultType = T;
    } else {
        alias ResultType = Return;  // Fallback
    }

    static if (is(ResultType == void)) {
        // void returns Boolean (success/failure)
        enum rootFieldReturnType = "Boolean";
    } else static if (is(ResultType == string)) {
        enum rootFieldReturnType = "String!";
    } else static if (is(ResultType == bool)) {
        enum rootFieldReturnType = "Boolean!";
    } else static if (is(ResultType == int) || is(ResultType == long)) {
        enum rootFieldReturnType = "Int!";
    } else static if (is(ResultType == float) || is(ResultType == double)) {
        enum rootFieldReturnType = "Float!";
    } else static if (is(ResultType == Nullable!U, U)) {
        // Nullable - no "!" suffix
        enum rootFieldReturnType = graphqlBaseTypeName!U;
    } else static if (is(ResultType == E[], E)) {
        enum rootFieldReturnType = "[" ~ graphqlTypeName!E ~ "]!";
    } else static if (isObjectType!ResultType) {
        enum rootFieldReturnType = getGraphQLTypeName!ResultType ~ "!";
    } else static if (isCustomScalar!ResultType) {
        enum rootFieldReturnType = ResultType.name ~ "!";
    } else {
        enum rootFieldReturnType = "Unknown";
    }
}

/// Extract root field arguments from a function.
/// Skips the first parameter (Expr!Parent parent).
template getRootFieldArguments(alias member) {
    alias Params = Parameters!member;
    alias Defaults = ParameterDefaults!member;
    enum string[] paramNames = [ParameterIdentifierTuple!member];

    enum getRootFieldArguments = () {
        ArgumentInfo[] args;

        // Start from 1 to skip the parent Expr parameter
        static foreach (i; 1 .. Params.length) {{
            alias P = Params[i];

            static if (is(Defaults[i] == void)) {
                // No default - required argument
                args ~= ArgumentInfo(
                    paramNames[i],
                    graphqlTypeName!P,
                    false,
                    ""
                );
            } else {
                // Has default - optional argument
                static if (is(P == Nullable!U, U)) {
                    args ~= ArgumentInfo(
                        paramNames[i],
                        graphqlBaseTypeName!U,
                        true,
                        "null"
                    );
                } else {
                    args ~= ArgumentInfo(
                        paramNames[i],
                        graphqlBaseTypeName!P,
                        true,
                        defaultValueToString(Defaults[i])
                    );
                }
            }
        }}
        return args;
    }();
}

/// Generate GraphQL SDL for an input type
string generateInputTypeSDL(T)() if (isInputType!T) {
    string result = "input " ~ getGraphQLTypeName!T ~ " {\n";

    foreach (field; getInputTypeFields!T) {
        result ~= "  " ~ field.name ~ ": " ~ field.graphqlType;
        if (field.hasDefault) {
            result ~= " = " ~ field.defaultValue;
        }
        result ~= "\n";
    }

    result ~= "}\n";
    return result;
}

/// Collect custom scalar names from any type's field return types.
private template getCustomScalarNames(T) {
    import dunamis.core.expr : ExprResultType;

    enum getCustomScalarNames = () {
        string[] names;
        static foreach (member; __traits(allMembers, T)) {{
            static if (isPublicMember!(T, member) &&
                       is(typeof(__traits(getMember, T, member)) == function)) {
                alias fn = __traits(getMember, T, member);

                static if (isValidFieldMethod!(T, fn)) {
                    alias RetType = ReturnType!fn;
                    alias ResultT = ExprResultType!RetType;
                    alias Unwrapped = UnwrapNullable!ResultT;

                    // Check if the unwrapped type is a custom scalar
                    static if (isCustomScalar!Unwrapped) {
                        // Add if not already present
                        bool found = false;
                        foreach (n; names) {
                            if (n == Unwrapped.name) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            names ~= Unwrapped.name;
                        }
                    }
                    // Also check array element types
                    else static if (is(Unwrapped == E[], E) && isCustomScalar!E) {
                        bool found = false;
                        foreach (n; names) {
                            if (n == E.name) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            names ~= E.name;
                        }
                    }
                }
            }
        }}
        return names;
    }();
}

/// Collect all custom scalar names from multiple entities
package(dunamis.graphql) template getAllCustomScalarNames(Entities...) {
    enum getAllCustomScalarNames = () {
        string[] allNames;
        static foreach (Entity; Entities) {
            foreach (name; getCustomScalarNames!Entity) {
                // Add if not already present
                bool found = false;
                foreach (n; allNames) {
                    if (n == name) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    allNames ~= name;
                }
            }
        }
        return allNames;
    }();
}

/// Get the GraphQL names of interfaces that a concrete type implements.
private template _getInterfaceNames(T, AllAbstractTypes...) {
    enum string[] _getInterfaceNames = () {
        string[] names;
        static foreach (AbstractT; AllAbstractTypes) {
            // Interface = abstract type with schema fields
            static if (getSchemaFields!AbstractT.length > 0) {
                // Check if T is a member of this interface
                static if (_staticContainsType!(T, getImplementedByMembers!AbstractT)) {
                    names ~= getGraphQLTypeName!AbstractT;
                }
            }
        }
        return names;
    }();
}

/// Check if T is in a type tuple
private template _staticContainsType(T, Types...) {
    enum _staticContainsType = () {
        static foreach (U; Types) {
            static if (is(T == U)) return true;
        }
        return false;
    }();
}

/// Generate GraphQL SDL for a union type.
string generateUnionTypeSDL(Union, AllTypes...)(string typeName) {
    alias Members = getAbstractTypeMembers!(Union, AllTypes);

    string result = "union " ~ typeName ~ " =";
    static foreach (i, Member; Members) {
        static if (i > 0) {
            result ~= " |";
        }
        result ~= " " ~ getGraphQLTypeName!Member;
    }
    result ~= "\n";
    return result;
}

/// Generate GraphQL SDL for an interface type.
string generateInterfaceTypeSDL(T)(string typeName) {
    enum fields = getFields!T;
    string result = "interface " ~ typeName ~ " {\n";
    foreach (field; fields) {
        if (field.hidden) continue;
        result ~= "  " ~ field.name ~ ": " ~ field.graphqlType ~ "\n";
    }
    result ~= "}\n";
    return result;
}

/// Generate complete GraphQL schema SDL.
/// Accepts either a Schema type or a raw Query type (for backwards compatibility).
/// If the Schema provides an AllEntityTypes member, it will be used instead of
/// auto-discovering entity types. This allows plugins to provide transformed types.
template generateSchemaSDL(alias SchemaOrQuery) {
    import dunamis.graphql.schema : isSchema;

    // Determine if we have a Schema or raw Query type
    static if (isSchema!SchemaOrQuery) {
        alias QueryType = SchemaOrQuery.Query;
        alias MutationType = SchemaOrQuery.Mutation;
        alias SubscriptionType = SchemaOrQuery.Subscription;
    } else {
        alias QueryType = SchemaOrQuery;
        struct MutationType {}
        struct SubscriptionType {}
    }

    // Use Schema-provided AllEntityTypes if available (for plugins like PaginationPlugin),
    // otherwise discover entity types from Query
    static if (isSchema!SchemaOrQuery && __traits(hasMember, SchemaOrQuery, "AllEntityTypes")) {
        alias AllTypes = SchemaOrQuery.AllEntityTypes;
    } else {
        alias AllTypes = getAllObjectTypes!QueryType;
    }

    // Collect input types from entities AND mutations (if any)
    // Both are expanded to discover nested types (handles recursive types)
    alias EntityInputTypes = getAllInputTypes!QueryType;
    // Root Query arguments (notably plugin-generated filters/orderings) are
    // not part of getAllObjectTypes!QueryType, so discover them explicitly.
    alias QueryDirectInputTypes = getInputTypesFromEntity!QueryType;
    alias QueryInputTypes = expandAllInputTypes!(uniqueTypesForExpand!QueryDirectInputTypes);
    alias QueryAndEntityInputTypes = uniqueTypesForExpand!(AliasSeq!(EntityInputTypes, QueryInputTypes));
    static if (getFields!MutationType.length > 0) {
        alias MutationDirectTypes = getInputTypesFromMutation!MutationType;
        alias MutationInputTypes = expandAllInputTypes!(uniqueTypesForExpand!MutationDirectTypes);
        alias AllInputTypes = uniqueTypesForExpand!(AliasSeq!(QueryAndEntityInputTypes, MutationInputTypes));
    } else {
        alias AllInputTypes = QueryAndEntityInputTypes;
    }

    // Collect enum types from entities
    alias AllEnumTypes = uniqueTypes!(getAllEnumTypes!QueryType, getEnumTypesFromEntity!QueryType);

    // Discover abstract types (unions + interfaces)
    alias AllAbstractTypes = getAllAbstractTypes!AllTypes;

    enum generateSchemaSDL = () {
        string result;

        // Declare custom scalars
        foreach (scalarName; getAllCustomScalarNames!AllTypes) {
            result ~= "scalar " ~ scalarName ~ "\n";
        }
        static if (getAllCustomScalarNames!AllTypes.length > 0) {
            result ~= "\n";
        }

        // Generate enum types
        static foreach (EnumType; AllEnumTypes) {
            result ~= generateEnumTypeSDL!EnumType;
            result ~= "\n";
        }

        // Generate union types (abstract types with no schema fields)
        static foreach (AbstractT; AllAbstractTypes) {
            static if (getSchemaFields!AbstractT.length == 0) {
                result ~= generateUnionTypeSDL!(AbstractT, AllTypes)(getGraphQLTypeName!AbstractT);
                result ~= "\n";
            }
        }

        // Generate interface types (abstract types with schema fields)
        static foreach (AbstractT; AllAbstractTypes) {
            static if (getSchemaFields!AbstractT.length > 0) {
                result ~= generateInterfaceTypeSDL!AbstractT(getGraphQLTypeName!AbstractT);
                result ~= "\n";
            }
        }

        // Generate Query type
        result ~= generateObjectTypeSDL!QueryType("Query");
        result ~= "\n";

        // Generate Mutation type if it has fields
        enum mutationSdl = generateObjectTypeSDL!MutationType("Mutation");
        static if (mutationSdl.length > 0) {
            result ~= mutationSdl;
            result ~= "\n";
        }

        // Generate Subscription type if it has fields
        enum subscriptionSdl = generateObjectTypeSDL!SubscriptionType("Subscription");
        static if (subscriptionSdl.length > 0) {
            result ~= subscriptionSdl;
            result ~= "\n";
        }

        // Generate each discovered object type (skip abstract types — they have their own SDL)
        static foreach (Entity; AllTypes) {
            static if (!isAbstractType!Entity) {
                result ~= generateObjectTypeSDL!(Entity, AllAbstractTypes)(getGraphQLTypeName!Entity);
                result ~= "\n";
            }
        }

        // Generate input types (discovered from computed field arguments)
        // Several D types may stand for the same input type (e.g.
        // instantiations of a filter template for types of the same name at
        // different plugin positions), but distinct input types must not
        // share a name, as one would shadow the other.
        string[string] emittedInputTypes;  // name -> SDL
        static foreach (InputType; AllInputTypes) {{
            enum inputTypeName = getGraphQLTypeName!InputType;
            auto inputTypeSDL = generateInputTypeSDL!InputType();
            if (auto previous = inputTypeName in emittedInputTypes) {
                assert(*previous == inputTypeSDL,
                    "Distinct GraphQL input types share the name " ~ inputTypeName ~ ":\n" ~
                    *previous ~ inputTypeSDL);
            } else {
                emittedInputTypes[inputTypeName] = inputTypeSDL;
                result ~= inputTypeSDL;
                result ~= "\n";
            }
        }}

        return result;
    }();
}
