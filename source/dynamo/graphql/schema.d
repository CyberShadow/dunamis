module dynamo.graphql.schema;

import std.algorithm;
import std.array;
import std.conv;
import std.json : JSONValue;
import std.meta;
import std.traits;
import std.typecons : Nullable;

import dynamo.core.types : isCustomScalar;
import dynamo.core.expr : Expr, ExprResultType, isExpr;

// ============================================================================
// Schema Template
// ============================================================================

/// Schema template bundling Query and optional Mutation types.
/// This is the primary entry point for schema operations.
///
/// Example:
/// ---
/// static MyDB db;
///
/// struct User {
///     mixin Entity!(db, "users");
///     mixin Col!("name", string);
/// }
///
/// struct Query {
///     mixin Table!(User, "users");  // db derived from User._db
/// }
///
/// struct Mutation {
///     static Expr!string createUser(Expr!Mutation parent, string name) { ... }
/// }
///
/// // With mutations
/// alias MySchema = Schema!(Query, Mutation);
///
/// // Without mutations (Mutation defaults to empty)
/// alias MySchema = Schema!(Query);
///
/// // Usage
/// pragma(msg, generateSchemaSDL!MySchema);
/// auto query = compileQuery!MySchema(`{ users { name } }`);
/// ---
template Schema(QueryType, MutationType = void) {
    alias Query = QueryType;

    static if (is(MutationType == void)) {
        // Empty mutation type when not provided
        struct Mutation {}
    } else {
        alias Mutation = MutationType;
    }
}

/// Check if a type is a Schema (has Query and Mutation members)
template isSchema(alias T) {
    enum isSchema = __traits(hasMember, T, "Query") && __traits(hasMember, T, "Mutation");
}

// ============================================================================
// GraphQL UDAs
// ============================================================================

/// UDA to hide a field from the GraphQL schema.
/// Can be attached to Col, HasMany, or BelongsTo mixin invocations.
enum GqlHidden;

/// UDA to override the GraphQL field name.
/// Useful for D keyword conflicts (e.g., `body_` in D → `body` in GraphQL).
///
/// Example:
///   @GqlName("body")
///   mixin Col!("body_", string, "body");
struct GqlName {
    string name;
}

/// UDA to add a description to a field or type.
/// Rendered as a doc comment in GraphQL SDL.
///
/// Example:
///   @GqlDescription("The user's email address")
///   mixin Col!("email", string);
struct GqlDescription {
    string text;
}

/// UDA to mark a field as deprecated.
/// Rendered with @deprecated directive in GraphQL SDL.
///
/// Example:
///   @GqlDeprecated("Use fullName instead")
///   mixin Col!("name", string);
struct GqlDeprecated {
    string reason = "No longer supported";
}

// ============================================================================
// GraphQL Type Name Resolution
// ============================================================================

/// Get GraphQL type name for any D type.
/// 1. Check for @GqlName UDA on the type
/// 2. If absent, use __traits(identifier) for the D type name
template getGraphQLTypeName(T) {
    enum getGraphQLTypeName = () {
        // Check for @GqlName UDA on the type
        static if (hasUDA!(T, GqlName)) {
            return getUDAs!(T, GqlName)[0].name;
        } else {
            // Use D type name
            return __traits(identifier, T);
        }
    }();
}

/// Check if a type is an "object type" (struct with valid field methods).
/// This replaces the old isEntity check - now any struct with Expr-returning
/// static methods is treated as a GraphQL object type.
template isObjectType(T) {
    static if (is(T == struct)) {
        // Check if it has at least one valid field method
        enum isObjectType = hasAnyValidFieldMethod!T;
    } else {
        enum isObjectType = false;
    }
}

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

/// Helper to check if a member is a valid field method for type T.
/// Uses string member name to avoid forward reference issues.
private template isValidFieldMethodForType(T, string member) {
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

/// Check if a member has the @GqlHidden UDA
template hasGqlHidden(alias member) {
    enum hasGqlHidden = staticIndexOf!(GqlHidden, __traits(getAttributes, member)) >= 0;
}

/// Get the @GqlName value if present, otherwise return the default name
template getGqlName(alias member, string defaultName) {
    enum getGqlName = () {
        alias attrs = __traits(getAttributes, member);
        static foreach (attr; attrs) {
            static if (is(typeof(attr) == GqlName)) {
                return attr.name;
            }
        }
        return defaultName;
    }();
}

/// Get the @GqlDescription text if present, otherwise return empty string
template getGqlDescription(alias member) {
    enum getGqlDescription = () {
        alias attrs = __traits(getAttributes, member);
        static foreach (attr; attrs) {
            static if (is(typeof(attr) == GqlDescription)) {
                return attr.text;
            }
        }
        return "";
    }();
}

/// Get the @GqlDeprecated reason if present, otherwise return empty string
template getGqlDeprecated(alias member) {
    enum getGqlDeprecated = () {
        alias attrs = __traits(getAttributes, member);
        static foreach (attr; attrs) {
            static if (is(typeof(attr) == GqlDeprecated)) {
                return attr.reason;
            }
        }
        return "";
    }();
}

// ============================================================================
// Computed Field Type Extraction
// ============================================================================

/// Get the GraphQL return type of a computed field
template computedFieldReturnType(alias member) {
    alias Return = ReturnType!(typeof(member));
    // Extract T from Expr!T, then map to GraphQL type
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

/// Check if a member name is an internal member that should be skipped.
/// This is used by schema generation to filter out mixin helper symbols
/// and D built-in methods.
template isInternalMember(string name) {
    import std.algorithm : startsWith;
    enum isInternalMember =
        // Entity internal field (all metadata is in nodeId's type)
        name == "nodeId" ||
        // D built-in methods
        name == "toString" ||
        name == "toHash" ||
        name == "opEquals" ||
        name == "opCmp" ||
        name == "opAssign" ||
        name == "factory" ||
        // Module/compiler internals
        name == "Monitor" ||
        name == "__ctor" ||
        name == "__dtor" ||
        name == "__xdtor" ||
        name == "__postblit" ||
        name == "__xpostblit" ||
        // Private members (used by mixins for internal aliases)
        name.startsWith("_");
}


/// Extract field information from any type (Entity, Query, or Mutation).
/// Scans for methods that are valid GraphQL field methods.
///
/// Valid field methods:
/// - Take Expr!T as first parameter
/// - Return an Expr type
template getFields(T) {
    import std.traits : hasUDA, getUDAs, ReturnType, Parameters;
    import std.meta : staticIndexOf;
    import dynamo.core.expr : ExprResultType;

    enum getFields = () {
        FieldInfo[] fields;

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

        return fields;
    }();
}

/// Check if a method is a valid GraphQL field method for type T.
/// Valid field methods:
/// - Take Expr!T as first parameter
/// - Return an Expr type
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

// ============================================================================
// Input Type Detection
// ============================================================================

/// Check if a type is a struct that should be treated as a GraphQL input type.
/// Input types are structs that:
/// - Are not entities (no _typeName member from Entity mixin)
/// - Are not Nullable wrappers
/// - Are not built-in types (string, int, etc.)
template isInputType(T) {
    static if (is(T == struct)) {
        // Must not be an entity (entities have _typeName)
        static if (__traits(hasMember, T, "_typeName")) {
            enum isInputType = false;
        }
        // Must not be a Nullable wrapper
        else static if (is(T == Nullable!U, U)) {
            enum isInputType = false;
        }
        // Must not be a custom scalar
        else static if (isCustomScalar!T) {
            enum isInputType = false;
        }
        else {
            enum isInputType = true;
        }
    } else {
        enum isInputType = false;
    }
}

/// Check if a type is a D enum that should become a GraphQL enum
template isGraphQLEnum(T) {
    enum isGraphQLEnum = is(T == enum);
}

/// Generate GraphQL SDL for a D enum type
template generateEnumTypeSDL(E) if (isGraphQLEnum!E) {
    import std.traits : EnumMembers;

    enum generateEnumTypeSDL = () {
        string result = "enum " ~ __traits(identifier, E) ~ " {\n";
        static foreach (member; EnumMembers!E) {
            result ~= "  " ~ __traits(identifier, member) ~ "\n";
        }
        return result ~ "}\n";
    }();
}

/// Field information for input type fields
struct InputFieldInfo {
    string name;
    string graphqlType;
    bool hasDefault;
    string defaultValue;
}

/// Extract fields from an input type struct
template getInputTypeFields(T) if (isInputType!T) {
    enum getInputTypeFields = () {
        InputFieldInfo[] fields;

        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member) {
                alias MemberType = typeof(__traits(getMember, T, member));

                // Skip non-field members (functions, etc.)
                static if (!is(MemberType == function) && !is(MemberType == void)) {
                    // Check for default value by seeing if the field is initialized
                    // In D, we can check FieldNameTuple and use .init
                    enum hasInit = __traits(compiles, { auto v = __traits(getMember, T.init, member); });

                    static if (hasInit) {
                        // Determine GraphQL type based on D type
                        // Nullable!(Nullable!T) → T (three-state, same GraphQL repr as Nullable!T)
                        // Nullable!T → T (optional, absent = null)
                        // T* → T (pointer - nullable reference for recursive types)
                        // T → T! (required)
                        static if (is(MemberType == Nullable!(Nullable!U), U)) {
                            // Three-state: absent/null/value - GraphQL type is nullable
                            enum gqlType = graphqlInputTypeName!U;
                        } else static if (is(MemberType == Nullable!U, U)) {
                            // Two-state: null/value (absent = null) - GraphQL type is nullable
                            enum gqlType = graphqlInputTypeName!U;
                        } else static if (is(MemberType == U*, U)) {
                            // Pointer - nullable reference (enables recursive types)
                            enum gqlType = graphqlInputTypeName!U;
                        } else {
                            // Required non-null
                            enum gqlType = graphqlInputTypeName!MemberType ~ "!";
                        }

                        fields ~= InputFieldInfo(member, gqlType, false, "");
                    }
                }
            }
        }}

        return fields;
    }();
}

/// Map D types to GraphQL input type names.
/// Similar to graphqlBaseTypeName but handles input type structs.
template graphqlInputTypeName(T) {
    static if (isCustomScalar!T) {
        enum graphqlInputTypeName = T.name;
    } else static if (is(T == enum)) {
        // D enum - use enum name as GraphQL enum type
        enum graphqlInputTypeName = __traits(identifier, T);
    } else static if (is(T == string)) {
        enum graphqlInputTypeName = "String";
    } else static if (is(T == bool)) {
        enum graphqlInputTypeName = "Boolean";
    } else static if (is(T == int)) {
        enum graphqlInputTypeName = "Int";
    } else static if (is(T == float) || is(T == double)) {
        enum graphqlInputTypeName = "Float";
    } else static if (is(T == Nullable!U, U)) {
        enum graphqlInputTypeName = graphqlInputTypeName!U;
    } else static if (is(T == U*, U)) {
        // Pointer - treat as nullable reference (enables recursive types)
        enum graphqlInputTypeName = graphqlInputTypeName!U;
    } else static if (is(T == E[], E)) {
        // Array type - elements are non-null by default in input
        enum graphqlInputTypeName = "[" ~ graphqlInputTypeName!E ~ "!]";
    } else static if (is(T == JSONValue[string])) {
        // Raw JSON object type
        enum graphqlInputTypeName = "JSON";
    } else static if (is(T == JSONValue)) {
        // Raw JSON value
        enum graphqlInputTypeName = "JSON";
    } else static if (isInputType!T) {
        // Input type struct - use struct name as type name
        enum graphqlInputTypeName = T.stringof;
    } else static if (isObjectType!T) {
        // Object type reference in input (e.g., for ID references)
        enum graphqlInputTypeName = getGraphQLTypeName!T;
    } else {
        static assert(false,
            "No GraphQL input type mapping for `" ~ T.stringof ~ "`. " ~
            "Use a CustomScalar or define it as an input type struct.");
    }
}

/// Unwrap Nullable layers to get the base type
template UnwrapNullable(T) {
    static if (is(T == Nullable!U, U)) {
        alias UnwrapNullable = UnwrapNullable!U;
    } else {
        alias UnwrapNullable = T;
    }
}

/// Extract the base input type from a type (unwraps arrays, Nullable, and pointers).
/// Returns void if no input type is found.
template extractInputTypeFromType(T) {
    static if (is(T == E[], E)) {
        // Array - extract from element type
        alias extractInputTypeFromType = extractInputTypeFromType!E;
    } else static if (is(T == Nullable!U, U)) {
        // Nullable - unwrap
        alias extractInputTypeFromType = extractInputTypeFromType!U;
    } else static if (is(T == U*, U)) {
        // Pointer - unwrap (enables recursive types)
        alias extractInputTypeFromType = extractInputTypeFromType!U;
    } else static if (isInputType!T) {
        // Base case: input type struct
        alias extractInputTypeFromType = T;
    } else {
        // Not an input type
        alias extractInputTypeFromType = void;
    }
}

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

/// Forward declaration helper for uniqueTypes (defined later)
private template uniqueTypesForExpand(Types...) {
    static if (Types.length == 0) {
        alias uniqueTypesForExpand = AliasSeq!();
    } else static if (staticContains!(Types[0], Types[1..$])) {
        alias uniqueTypesForExpand = uniqueTypesForExpand!(Types[1..$]);
    } else {
        alias uniqueTypesForExpand = AliasSeq!(Types[0], uniqueTypesForExpand!(Types[1..$]));
    }
}

/// Expand all input types - performs BFS to discover nested types up to 4 levels deep.
/// This is sufficient for most recursive type structures.
template expandAllInputTypes(InputTypes...) {
    // Level 0: direct input types
    alias Level0 = InputTypes;
    // Level 1: add types nested in Level0
    alias Level1 = uniqueTypesForExpand!(AliasSeq!(Level0, expandInputOneLevel!Level0));
    // Level 2: add types nested in Level1
    alias Level2 = uniqueTypesForExpand!(AliasSeq!(Level1, expandInputOneLevel!Level1));
    // Level 3: add types nested in Level2
    alias Level3 = uniqueTypesForExpand!(AliasSeq!(Level2, expandInputOneLevel!Level2));
    // Level 4: add types nested in Level3
    alias Level4 = uniqueTypesForExpand!(AliasSeq!(Level3, expandInputOneLevel!Level3));

    alias expandAllInputTypes = Level4;
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
    alias AllEntityTypes = getAllEntityTypes!Query;
    alias DirectInputTypes = getInputTypesFromEntitiesImpl!AllEntityTypes;
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
    import dynamo.core.expr : ExprResultType;

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
    alias AllEntityTypes = getAllEntityTypes!Query;
    alias AllEnumTypes = getEnumTypesFromEntitiesImpl!AllEntityTypes;
    alias getAllEnumTypes = uniqueTypes!AllEnumTypes;
}

// ============================================================================
// Type Discovery
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
/// Scans for valid field methods and extracts object types from return types.
template getRelatedTypesImpl(T, size_t idx, Members...) {
    import dynamo.core.expr : ExprResultType;

    static if (idx >= Members.length) {
        alias getRelatedTypesImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getRelatedTypesImpl!(T, idx + 1, Members);

        static if (!isInternalMember!member &&
                   is(typeof(__traits(getMember, T, member)) == function)) {
            alias fn = __traits(getMember, T, member);

            // Check if it's a valid field method
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
    import dynamo.core.expr : ExprResultType;

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

/// Fixed-depth type discovery (sufficient for most schemas)
/// Expands relationships up to 4 levels deep
template getAllEntityTypes(Query) {
    // Start with root types
    alias Level0 = getRootTypes!Query;

    // Expand level by level, deduping at each step
    alias Level1 = uniqueTypes!(Level0, expandOneLevel!Level0);
    alias Level2 = uniqueTypes!(Level1, expandOneLevel!Level1);
    alias Level3 = uniqueTypes!(Level2, expandOneLevel!Level2);
    alias Level4 = uniqueTypes!(Level3, expandOneLevel!Level3);

    alias getAllEntityTypes = Level4;
}

// ============================================================================
// SDL Generation
// ============================================================================

/// Generate GraphQL SDL for an entity type
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
    import dynamo.core.expr : ExprResultType;

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
private template getAllCustomScalarNames(Entities...) {
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

// ============================================================================
// Tests
// ============================================================================

unittest {
    import dynamo.core.types : CustomScalar;
    import std.conv : to;
    import std.json : JSONValue, JSONType;

    // Test built-in GraphQL scalars
    static assert(graphqlTypeName!string == "String!");
    static assert(graphqlTypeName!int == "Int!");
    static assert(graphqlTypeName!bool == "Boolean!");
    static assert(graphqlTypeName!float == "Float!");
    static assert(graphqlTypeName!double == "Float!");
    static assert(graphqlTypeName!(string[]) == "[String!]!");

    // Test Nullable types (no "!" suffix)
    static assert(graphqlTypeName!(Nullable!string) == "String");
    static assert(graphqlTypeName!(Nullable!int) == "Int");

    // Test base type names (without "!")
    static assert(graphqlBaseTypeName!string == "String");
    static assert(graphqlBaseTypeName!int == "Int");
    static assert(graphqlBaseTypeName!(Nullable!string) == "String");

    // Test custom scalars
    alias Int64 = CustomScalar!(
        long, "Int64",
        (long v) => JSONValue(v),
        (JSONValue j) => j.type == JSONType.integer ? j.integer : j.str.to!long
    );
    static assert(isCustomScalar!Int64);
    static assert(graphqlTypeName!Int64 == "Int64!");
    static assert(graphqlBaseTypeName!Int64 == "Int64");
    static assert(graphqlTypeName!(Nullable!Int64) == "Int64");

    // Verify unsupported types would error (can't test static assert failure directly)
    // graphqlTypeName!long would fail: "No GraphQL type mapping for `long`..."
}

// Test that UDAs on mixin templates propagate to generated members
unittest {
    import std.meta : staticIndexOf;

    // Simple mixin template that generates a marker
    mixin template TestCol(string name) {
        mixin("enum _marker_" ~ name ~ " = true;");
    }

    static struct TestEntity {
        @GqlHidden
        mixin TestCol!"hidden";

        mixin TestCol!"visible";
    }

    // Check if UDA propagates to generated member
    static if (__traits(hasMember, TestEntity, "_marker_hidden")) {
        alias attrs = __traits(getAttributes, __traits(getMember, TestEntity, "_marker_hidden"));
        static assert(attrs.length == 1, "Expected 1 attribute on hidden marker, got " ~ attrs.length.stringof);
        // GqlHidden is an enum, so check if it's in the attributes
        static assert(staticIndexOf!(GqlHidden, attrs) >= 0, "Expected GqlHidden attribute");
    }

    static if (__traits(hasMember, TestEntity, "_marker_visible")) {
        alias attrs2 = __traits(getAttributes, __traits(getMember, TestEntity, "_marker_visible"));
        static assert(attrs2.length == 0, "Expected no attributes on visible marker");
    }
}

// Test @GqlHidden with actual Col mixin
unittest {
    import std.algorithm : canFind;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        @GqlHidden
        mixin Col!("passwordHash", string);
    }

    // Check that getFields detects hidden field
    enum fields = getFields!User;
    static assert(fields.length == 3);

    // Find the passwordHash field and verify it's hidden
    bool foundPasswordHash = false;
    foreach (f; fields) {
        if (f.name == "passwordHash") {
            foundPasswordHash = true;
            assert(f.hidden, "passwordHash should be hidden");
        }
        if (f.name == "name") {
            assert(!f.hidden, "name should not be hidden");
        }
    }
    assert(foundPasswordHash, "passwordHash field should exist");

    // Verify SDL doesn't include hidden field
    enum sdl = generateObjectTypeSDL!User(getGraphQLTypeName!User);
    assert(sdl.canFind("name:"), "SDL should include name field");
    assert(!sdl.canFind("passwordHash"), "SDL should NOT include passwordHash field");
}

// Test @GqlDescription and @GqlDeprecated UDAs
unittest {
    import std.algorithm : canFind;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col;

    static MockDB!() db;

    static struct Article {
        mixin DemoEntity!(db, "articles");

        @GqlDescription("The article title")
        mixin Col!("title", string);

        @GqlDescription("Main content")
        @GqlDeprecated("Use content instead")
        mixin Col!("body", string);

        mixin Col!("plain", string);  // No annotations
    }

    // Check that getFields extracts description and deprecation
    enum fields = getFields!Article;

    bool foundTitle = false;
    bool foundBody = false;
    bool foundPlain = false;

    foreach (f; fields) {
        if (f.name == "title") {
            foundTitle = true;
            assert(f.description == "The article title", "title should have description");
            assert(f.deprecation == "", "title should not be deprecated");
        }
        if (f.name == "body") {
            foundBody = true;
            assert(f.description == "Main content", "body should have description");
            assert(f.deprecation == "Use content instead", "body should be deprecated");
        }
        if (f.name == "plain") {
            foundPlain = true;
            assert(f.description == "", "plain should have no description");
            assert(f.deprecation == "", "plain should not be deprecated");
        }
    }
    assert(foundTitle && foundBody && foundPlain, "All fields should exist");

    // Verify SDL output
    enum sdl = generateObjectTypeSDL!Article(getGraphQLTypeName!Article);

    // Should have description as doc string
    assert(sdl.canFind(`"""The article title"""`), "SDL should include title description");
    assert(sdl.canFind(`"""Main content"""`), "SDL should include body description");

    // Should have @deprecated directive
    assert(sdl.canFind(`@deprecated(reason: "Use content instead")`), "SDL should include deprecation");

    // Plain field should exist without annotations
    assert(sdl.canFind("plain: String!"), "plain field should exist in SDL");
}

// Test Schema template
unittest {
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table, getAll;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    static struct MyQuery {
        mixin Table!(User, "users");
    }

    // Schema without mutations
    alias MySchema = Schema!(MyQuery);

    // Verify Schema properties
    static assert(isSchema!MySchema);
    static assert(is(MySchema.Query == MyQuery));
    static assert(getFields!(MySchema.Mutation).length == 0);  // No mutation fields

    // generateSchemaSDL should work with Schema
    enum sdlFromSchema = generateSchemaSDL!MySchema;
    enum sdlFromQuery = generateSchemaSDL!MyQuery;

    // Both should produce identical output
    static assert(sdlFromSchema == sdlFromQuery, "Schema and Query should generate same SDL");

    // Verify SDL contains expected content
    import std.algorithm : canFind;
    static assert(sdlFromSchema.canFind("type Query"));
    static assert(sdlFromSchema.canFind("users: [User!]!"));
    static assert(sdlFromSchema.canFind("type User"));
}

// Test isSchema with non-schema types
unittest {
    static struct NotASchema {
        int x;
    }

    static struct AlsoNotASchema {
        alias Query = int;  // Has Query but not Mutation
    }

    static assert(!isSchema!NotASchema);
    static assert(!isSchema!int);
}

// Test mutation SDL generation
unittest {
    import std.algorithm : canFind;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table, getAll;

    static MockDB!() db;

    // Define an entity for mutation results
    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    // Input type for mutations
    static struct CreateUserInput {
        string name;
        string email;
    }

    // Mutation type with various mutation patterns
    // Mutations take Expr!Mutation as first param (ignored) and return Expr!T
    static struct MyMutation {
        import dynamo.core.expr : effect;

        // Simple mutation returning entity
        static Expr!User createUser(Expr!MyMutation parent, CreateUserInput input) {
            return effect(() => User.init, parent);
        }

        // Mutation returning scalar
        static Expr!bool deleteUser(Expr!MyMutation parent, int id) {
            return effect(() => true, parent);
        }

        // Mutation with optional parameter
        static Expr!string greet(Expr!MyMutation parent, string name, string greeting = "Hello") {
            return effect(() => greeting ~ " " ~ name, parent);
        }

        @GqlDescription("Updates a user's profile")
        @GqlDeprecated("Use updateUserV2 instead")
        static Expr!User updateUser(Expr!MyMutation parent, int id, CreateUserInput input) {
            return effect(() => User.init, parent);
        }
    }

    static struct MyQuery {
        mixin Table!(User, "users");
    }

    // Schema with mutations
    alias MySchema = Schema!(MyQuery, MyMutation);

    // Verify Schema properties
    static assert(isSchema!MySchema);
    static assert(getFields!(MySchema.Mutation).length > 0);  // Has mutation fields
    static assert(is(MySchema.Mutation == MyMutation));

    // Check getFields extracts fields correctly
    enum mutationFields = getFields!MyMutation;
    static assert(mutationFields.length == 4, "Should have 4 mutation fields");

    // Verify SDL generation
    enum sdl = generateSchemaSDL!MySchema;

    // Debug: print SDL
    // pragma(msg, sdl);

    // Should include Query type
    static assert(sdl.canFind("type Query"));
    static assert(sdl.canFind("users: [User!]!"));

    // Should include Mutation type
    static assert(sdl.canFind("type Mutation"));

    // Check mutation signatures
    static assert(sdl.canFind("createUser(input: CreateUserInput!): User!"),
        "createUser mutation should have correct signature");
    static assert(sdl.canFind("deleteUser(id: Int!): Boolean!"),
        "deleteUser mutation should have correct signature");
    static assert(sdl.canFind("greet(name: String!, greeting: String = "),
        "greet mutation should have optional parameter");

    // Check UDAs on mutations
    static assert(sdl.canFind(`"""Updates a user's profile"""`),
        "Should have description comment");
    static assert(sdl.canFind(`@deprecated(reason: "Use updateUserV2 instead")`),
        "Should have deprecation directive");

    // Should include User entity type
    static assert(sdl.canFind("type User"));

    // Should include input type
    static assert(sdl.canFind("input CreateUserInput"));
}

// Test Schema without mutations generates no Mutation type
unittest {
    import std.algorithm : canFind;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table, getAll;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    static struct MyQuery {
        mixin Table!(User, "users");
    }

    // Schema without mutations
    alias MySchema = Schema!(MyQuery);

    enum sdl = generateSchemaSDL!MySchema;

    // Should have Query but not Mutation
    static assert(sdl.canFind("type Query"));
    static assert(!sdl.canFind("type Mutation"),
        "Schema without mutations should not have type Mutation");
}

// Test enum support in GraphQL schema
unittest {
    import std.algorithm : canFind;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table, getAll;

    // Define a D enum
    enum Status { pending, inProgress, completed }

    static MockDB!() db;

    static struct Task {
        mixin DemoEntity!(db, "tasks");
        mixin Col!("title", string);
        mixin Col!("status", Status);
    }

    static struct MyQuery {
        mixin Table!(Task, "tasks");
    }

    // Test type name mapping
    static assert(graphqlTypeName!Status == "Status!");
    static assert(graphqlBaseTypeName!Status == "Status");
    static assert(graphqlTypeName!(Nullable!Status) == "Status");

    // Test enum detection
    static assert(isGraphQLEnum!Status);
    static assert(!isGraphQLEnum!string);
    static assert(!isGraphQLEnum!int);

    // Test SDL generation
    enum sdl = generateSchemaSDL!MyQuery;

    // Should contain enum definition
    static assert(sdl.canFind("enum Status"), "SDL should contain enum Status: " ~ sdl);
    static assert(sdl.canFind("pending"), "SDL should contain pending: " ~ sdl);
    static assert(sdl.canFind("inProgress"), "SDL should contain inProgress: " ~ sdl);
    static assert(sdl.canFind("completed"), "SDL should contain completed: " ~ sdl);

    // Task type should have status field
    static assert(sdl.canFind("status: Status!"), "Task should have status: Status! field: " ~ sdl);
}

// Test nested input type discovery
unittest {
    import std.algorithm : canFind;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table;

    // Nested input types
    static struct Inner {
        string x;
    }

    static struct Outer {
        string y;
        Inner inner;
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        // Computed field with nested input type
        static auto format(Expr!User u, Outer options) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    enum sdl = generateSchemaSDL!Query;

    // Both input types should be discovered
    static assert(sdl.canFind("input Outer"), "SDL should contain input Outer: " ~ sdl);
    static assert(sdl.canFind("input Inner"), "SDL should contain input Inner: " ~ sdl);
    static assert(sdl.canFind("inner: Inner!"), "Outer should have inner: Inner! field: " ~ sdl);
}

// Test self-referential input type via array
unittest {
    import std.algorithm : canFind;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table;

    // Self-referential via array
    static struct FilterInput {
        string field;
        FilterInput[] and;  // Self-reference via array
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        static auto filter(Expr!User u, FilterInput f) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    enum sdl = generateSchemaSDL!Query;

    // FilterInput should appear in SDL
    static assert(sdl.canFind("input FilterInput"), "SDL should contain input FilterInput: " ~ sdl);
    static assert(sdl.canFind("and: [FilterInput!]!"), "FilterInput should have and field: " ~ sdl);
}

// Test self-referential input type via pointer
unittest {
    import std.algorithm : canFind;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table;

    // Self-referential via pointer (nullable reference)
    static struct NodeInput {
        string value;
        NodeInput* next;  // Self-reference via pointer
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        static auto traverse(Expr!User u, NodeInput* head) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    enum sdl = generateSchemaSDL!Query;

    // NodeInput should appear in SDL
    static assert(sdl.canFind("input NodeInput"), "SDL should contain input NodeInput: " ~ sdl);
    // next should be nullable (pointer = nullable reference)
    static assert(sdl.canFind("next: NodeInput") && !sdl.canFind("next: NodeInput!"),
        "NodeInput.next should be nullable: " ~ sdl);
}

// Test deeply nested input types via pointer
unittest {
    import std.algorithm : canFind;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table;

    // Deeply nested via pointer (A -> B -> C via pointers)
    static struct TypeC {
        string z;
    }

    static struct TypeB {
        string y;
        TypeC* c;
    }

    static struct TypeA {
        string x;
        TypeB* b;
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        static auto process(Expr!User u, TypeA input) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    enum sdl = generateSchemaSDL!Query;

    // All three types should be discovered
    static assert(sdl.canFind("input TypeA"), "SDL should contain input TypeA: " ~ sdl);
    static assert(sdl.canFind("input TypeB"), "SDL should contain input TypeB: " ~ sdl);
    static assert(sdl.canFind("input TypeC"), "SDL should contain input TypeC: " ~ sdl);
    // Pointer references should be nullable
    static assert(sdl.canFind("b: TypeB") && !sdl.canFind("b: TypeB!"),
        "TypeA.b should be nullable: " ~ sdl);
    static assert(sdl.canFind("c: TypeC") && !sdl.canFind("c: TypeC!"),
        "TypeB.c should be nullable: " ~ sdl);
}
