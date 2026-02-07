module dunamis.graphql.schema.generation;

import std.meta;
import std.traits;
import std.typecons : Nullable;

import dunamis.core.types : isCustomScalar;
import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.graphql.schema.udas;
import dunamis.graphql.schema.fields;
import dunamis.graphql.schema.input_types;
import dunamis.graphql.schema.discovery;

// ============================================================================
// SDL Generation
// ============================================================================

/// Generate GraphQL SDL for any object type (entity, Query, or Mutation).
string generateObjectTypeSDL(T)(string typeName) {
    enum fields = getFields!T;

    static if (fields.length == 0) {
        return "";  // No fields defined
    } else {
        string result = "type " ~ typeName ~ " {\n";

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
    string result = "input " ~ T.stringof ~ " {\n";

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
            static if (!isInternalMember!member &&
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
    } else {
        alias QueryType = SchemaOrQuery;
        struct MutationType {}
    }

    // Use Schema-provided AllEntityTypes if available (for plugins like PaginationPlugin),
    // otherwise discover entity types from Query
    static if (isSchema!SchemaOrQuery && __traits(hasMember, SchemaOrQuery, "AllEntityTypes")) {
        alias AllTypes = SchemaOrQuery.AllEntityTypes;
    } else {
        alias AllTypes = getAllEntityTypes!QueryType;
    }

    // Collect input types from entities AND mutations (if any)
    // Both are expanded to discover nested types (handles recursive types)
    alias EntityInputTypes = getAllInputTypes!QueryType;
    static if (getFields!MutationType.length > 0) {
        alias MutationDirectTypes = getInputTypesFromMutation!MutationType;
        alias MutationInputTypes = expandAllInputTypes!(uniqueTypesForExpand!MutationDirectTypes);
        alias AllInputTypes = uniqueTypesForExpand!(AliasSeq!(EntityInputTypes, MutationInputTypes));
    } else {
        alias AllInputTypes = EntityInputTypes;
    }

    // Collect enum types from entities
    alias AllEnumTypes = getAllEnumTypes!QueryType;

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

        // Generate Query type
        result ~= generateObjectTypeSDL!QueryType("Query");
        result ~= "\n";

        // Generate Mutation type if it has fields
        enum mutationSdl = generateObjectTypeSDL!MutationType("Mutation");
        static if (mutationSdl.length > 0) {
            result ~= mutationSdl;
            result ~= "\n";
        }

        // Generate each discovered object type
        static foreach (Entity; AllTypes) {
            result ~= generateObjectTypeSDL!Entity(getGraphQLTypeName!Entity);
            result ~= "\n";
        }

        // Generate input types (discovered from computed field arguments)
        static foreach (InputType; AllInputTypes) {
            result ~= generateInputTypeSDL!InputType();
            result ~= "\n";
        }

        return result;
    }();
}
