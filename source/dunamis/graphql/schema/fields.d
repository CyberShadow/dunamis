module dunamis.graphql.schema.fields;

import std.algorithm;
import std.array;
import std.conv;
import std.json : JSONValue;
import std.meta;
import std.traits;
import std.typecons : Nullable;

import dunamis.core.types : isCustomScalar;
import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.graphql.schema.udas;

// Re-export isValidFieldMethod from core for backward compatibility
public import dunamis.core.discovery : isValidFieldMethod;

// ============================================================================
// GraphQL Type Mapping
// ============================================================================

/// Map D types to GraphQL type strings (including nullability suffix).
/// Non-nullable types include "!", Nullable types do not.
/// Pointers are treated as nullable (they can be null).
template graphqlTypeName(T) {
    static if (is(T == Nullable!U, U)) {
        // Nullable types - no "!" suffix
        enum graphqlTypeName = graphqlBaseTypeName!U;
    } else static if (is(T == U*, U)) {
        // Pointer types - nullable (no "!" suffix)
        enum graphqlTypeName = graphqlBaseTypeName!U;
    } else {
        // Non-nullable types - add "!" suffix
        enum graphqlTypeName = graphqlBaseTypeName!T ~ "!";
    }
}

/// Map D types to GraphQL base type names (without nullability suffix)
///
/// Recognizes:
/// - Built-in GraphQL scalars: int→Int, string→String, bool→Boolean, float/double→Float
/// - Custom scalars (types satisfying isCustomScalar)
/// - Aggregate types (structs with _typeName, emitted as GraphQL types)
/// - Input types (structs without _typeName, used as computed field arguments)
/// - Arrays of the above
///
/// Everything else is a compile error - use a CustomScalar for unsupported primitives.
template graphqlBaseTypeName(T) {
    static if (isCustomScalar!T) {
        // Custom scalar - use its declared name
        enum graphqlBaseTypeName = T.name;
    } else static if (is(T == enum)) {
        // D enum - use enum name as GraphQL enum type
        enum graphqlBaseTypeName = __traits(identifier, T);
    } else static if (is(T == string)) {
        // GraphQL String
        enum graphqlBaseTypeName = "String";
    } else static if (is(T == bool)) {
        // GraphQL Boolean
        enum graphqlBaseTypeName = "Boolean";
    } else static if (is(T == int)) {
        // GraphQL Int (32-bit signed)
        enum graphqlBaseTypeName = "Int";
    } else static if (is(T == float) || is(T == double)) {
        // GraphQL Float
        enum graphqlBaseTypeName = "Float";
    } else static if (is(T == Nullable!U, U)) {
        // Unwrap Nullable
        enum graphqlBaseTypeName = graphqlBaseTypeName!U;
    } else static if (is(T == U*, U)) {
        // Pointer - treat as nullable reference (enables recursive types)
        enum graphqlBaseTypeName = graphqlBaseTypeName!U;
    } else static if (is(T == E[], E)) {
        // Array type
        enum graphqlBaseTypeName = "[" ~ graphqlTypeName!E ~ "]";
    } else static if (is(T == JSONValue[string])) {
        // Raw JSON object type - use JSON scalar
        enum graphqlBaseTypeName = "JSON";
    } else static if (is(T == JSONValue)) {
        // Raw JSON value - use JSON scalar
        enum graphqlBaseTypeName = "JSON";
    } else static if (isObjectType!T) {
        // Object type (struct with valid field methods) - use type name
        enum graphqlBaseTypeName = getGraphQLTypeName!T;
    } else static if (is(T == struct)) {
        // Input type struct - use struct name
        enum graphqlBaseTypeName = T.stringof;
    } else {
        // Unsupported type - require explicit CustomScalar
        static assert(false,
            "No GraphQL type mapping for `" ~ T.stringof ~ "`. " ~
            "Use a CustomScalar to define how this type should be represented in GraphQL.");
    }
}

// ============================================================================
// Schema Introspection
// ============================================================================

/// Argument information for computed fields
struct ArgumentInfo {
    string name;
    string graphqlType;
    bool hasDefault;
    string defaultValue;   // String representation for SDL
}

/// Field information extracted from entity mixins.
/// Field classification (column, hasMany, belongsTo, computed) is determined
/// by UDAs on the method, not stored here - this struct is for GraphQL schema only.
struct FieldInfo {
    string name;
    string graphqlType;
    bool nullable;
    bool hidden;           // @GqlHidden
    string description;    // @GqlDescription (empty if not set)
    string deprecation;    // @GqlDeprecated reason (empty if not deprecated)
    ArgumentInfo[] arguments;  // For computed fields with arguments
}

// ============================================================================
// Computed Field Type Extraction
// ============================================================================

/// Get the GraphQL return type of a computed field
template computedFieldReturnType(alias member) {
    alias Return = ReturnType!(typeof(member));
    // Extract T from Expr!T
    alias ResultT = ExprResultType!Return;

    // Handle string specially (it's immutable(char)[] but should map to String)
    static if (is(ResultT == string)) {
        enum computedFieldReturnType = "String!";
    }
    // Check if result is an array (for hasMany-like computed fields)
    else static if (is(ResultT == E[], E)) {
        static if (is(E : Expr!Inner, Inner)) {
            // Array of expressions (e.g., from map) - extract inner type
            enum computedFieldReturnType = "[" ~ graphqlTypeName!Inner ~ "]!";
        } else {
            // Regular array
            enum computedFieldReturnType = "[" ~ graphqlTypeName!E ~ "]!";
        }
    } else {
        enum computedFieldReturnType = graphqlTypeName!ResultT;
    }
}

/// Extract arguments from a computed field (parameters after the first Expr!Entity)
template getComputedFieldArguments(alias member) {
    // Get parameter info - must use member directly, not typeof(member)
    // typeof(member) loses parameter names and default values
    alias Params = Parameters!member;
    alias Defaults = ParameterDefaults!member;

    // Get parameter names as a string array
    enum string[] paramNames = [ParameterIdentifierTuple!member];

    enum getComputedFieldArguments = () {
        ArgumentInfo[] args;

        // Skip first parameter (Expr!Entity), process rest as arguments
        static foreach (i; 1 .. Params.length) {{
            alias P = Params[i];

            enum argName = paramNames[i];

            // Check if parameter has a default value
            static if (is(Defaults[i] == void)) {
                // No default - required argument
                args ~= ArgumentInfo(
                    argName,
                    graphqlTypeName!P,
                    false,
                    ""
                );
            } else {
                // Has default - optional argument (nullable in GraphQL)
                // For nullable types, use base type; otherwise add null default
                static if (is(P == Nullable!U, U)) {
                    args ~= ArgumentInfo(
                        argName,
                        graphqlBaseTypeName!U,
                        true,
                        "null"
                    );
                } else {
                    args ~= ArgumentInfo(
                        argName,
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

/// Convert a default value to its GraphQL SDL string representation
string defaultValueToString(T)(T value) {
    static if (is(T == string)) {
        return `"` ~ value ~ `"`;
    } else static if (is(T == bool)) {
        return value ? "true" : "false";
    } else static if (is(T == typeof(null))) {
        return "null";
    } else {
        return value.to!string;
    }
}

// ============================================================================
// Field Extraction
// ============================================================================

/// Extract field information from any type (Entity, Query, or Mutation).
/// Scans for methods that are valid GraphQL field methods.
///
/// Valid field methods:
/// - Take Expr!T as first parameter
/// - Return an Expr type
template getFields(T) {
    import std.traits : hasUDA, getUDAs, ReturnType, Parameters;
    import std.meta : staticIndexOf;
    import dunamis.core.expr : ExprResultType;

    enum getFields = () {
        import dunamis.core.types : isPlainField, isPlainMethod, hasPrimaryKeyAttr;

        FieldInfo[] fields;

        // Zeroth pass: @PrimaryKey plain fields (so id appears first)
        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member) {
                static if (isPlainField!(T, member) && hasPrimaryKeyAttr!(T, member)) {
                    alias FieldType = typeof(__traits(getMember, T.init, member));
                    enum gqlFieldName0 = member;
                    enum gqlType0 = graphqlTypeName!FieldType;

                    fields ~= FieldInfo(
                        gqlFieldName0,
                        gqlType0,
                        false,  // isConnection
                        false,  // isHidden
                        "",     // description
                        "",     // deprecation
                        []      // arguments
                    );
                }
            }
        }}

        // First pass: field methods (static functions)
        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member) {
                static if (is(typeof(__traits(getMember, T, member)) == function)) {
                    alias fn = __traits(getMember, T, member);

                    // Get common UDAs
                    enum isHidden = hasGqlHidden!fn;
                    enum gqlFieldName = getGqlName!(fn, member);
                    enum description = getGqlDescription!fn;
                    enum deprecation = getGqlDeprecated!fn;

                    static if (isValidFieldMethod!(T, fn)) {
                        // Field method: computed field, relationship, or table entry point
                        enum gqlType = computedFieldReturnType!fn;
                        enum arguments = getComputedFieldArguments!fn;

                        fields ~= FieldInfo(
                            gqlFieldName,
                            gqlType,
                            false,
                            isHidden,
                            description,
                            deprecation,
                            arguments
                        );
                    }
                    // Skip plain methods here - they're handled in the third pass
                    else static if (isPlainMethod!(T, member)) {
                        // Handled in third pass
                    }
                    else static if (!isHidden) {
                        // Static method that doesn't conform and isn't hidden - compile error
                        static assert(false,
                            "Method '" ~ member ~ "' in " ~ T.stringof ~
                            " is not a valid GraphQL field. " ~
                            "Valid fields must take Expr!" ~ T.stringof ~ " as first parameter " ~
                            "and return an Expr type. " ~
                            "Add @GqlHidden to exclude this method from the schema.");
                    }
                    // @GqlHidden methods that don't conform are silently skipped
                }
            }
        }}

        // Second pass: non-PK plain fields (struct instance fields)
        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member) {
                static if (isPlainField!(T, member) && !hasPrimaryKeyAttr!(T, member)) {
                    alias FieldType = typeof(__traits(getMember, T.init, member));
                    // Use D field name directly (GraphQL uses camelCase like D)
                    enum gqlFieldName = member;
                    enum gqlType = graphqlTypeName!FieldType;

                    fields ~= FieldInfo(
                        gqlFieldName,
                        gqlType,
                        false,  // isConnection
                        false,  // isHidden
                        "",     // description
                        "",     // deprecation
                        []      // arguments
                    );
                }
            }
        }}

        // Third pass: plain methods (instance methods returning non-Expr types)
        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member) {
                static if (isPlainMethod!(T, member)) {
                    import std.traits : ReturnType;
                    alias MethodType = typeof(__traits(getMember, T, member));
                    alias RetType = ReturnType!MethodType;

                    // Get UDAs from the method
                    alias methodSym = __traits(getMember, T, member);
                    enum isHidden = hasGqlHidden!methodSym;
                    enum gqlFieldName = getGqlName!(methodSym, member);
                    enum description = getGqlDescription!methodSym;
                    enum deprecation = getGqlDeprecated!methodSym;
                    enum gqlType = graphqlTypeName!RetType;

                    fields ~= FieldInfo(
                        gqlFieldName,
                        gqlType,
                        false,  // isConnection
                        isHidden,
                        description,
                        deprecation,
                        []      // arguments (no arguments for plain methods yet)
                    );
                }
            }
        }}

        return fields;
    }();
}

