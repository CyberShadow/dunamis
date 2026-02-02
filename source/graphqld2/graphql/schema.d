module graphqld2.graphql.schema;

import std.algorithm;
import std.array;
import std.conv;
import std.json : JSONValue;
import std.meta;
import std.traits;
import std.typecons : Nullable;

import graphqld2.core.types : isCustomScalar;
import graphqld2.core.expr : Expr, ExprResultType, isExpr;
import graphqld2.relational.schema : EntityID;

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
// GraphQL Type Mapping
// ============================================================================

/// Map D types to GraphQL type strings (including nullability suffix).
/// Non-nullable types include "!", Nullable types do not.
template graphqlTypeName(T) {
    static if (is(T == Nullable!U, U)) {
        // Nullable types - no "!" suffix
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
    } else static if (is(T == E[], E)) {
        // Array type
        enum graphqlBaseTypeName = "[" ~ graphqlTypeName!E ~ "]";
    } else static if (is(T == JSONValue[string])) {
        // Raw JSON object type - use JSON scalar
        enum graphqlBaseTypeName = "JSON";
    } else static if (is(T == JSONValue)) {
        // Raw JSON value - use JSON scalar
        enum graphqlBaseTypeName = "JSON";
    } else static if (__traits(hasMember, T, "nodeId")) {
        // Entity type - reference by type name from nodeId metadata
        enum graphqlBaseTypeName = EntityID!T.typeName;
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
/// Scans for methods with relational UDAs and computed fields.
///
/// UDA-based classification:
/// - @SqlColumn → column field (entities only)
/// - @HasManyFK → hasMany relationship (entities only)
/// - @BelongsToFK → belongsTo relationship (entities only)
/// - @TableEntity → root table entry (Query/Mutation only)
/// - No UDA → computed field (if valid signature)
template getFields(T) {
    import std.traits : hasUDA, getUDAs, ReturnType, Parameters;
    import std.meta : staticIndexOf;
    import graphqld2.relational.schema : SqlColumn, HasManyFK, BelongsToFK, PrimaryKeyAttr, NullableColumn;
    import graphqld2.relational.schema : ForeignKeyRef, HasManyChild, BelongsToParent, TableEntity;
    import graphqld2.relational.schema : hasForeignKeyRef, hasHasManyChild, hasBelongsToParent, hasTableEntity;
    import graphqld2.relational.schema : extractHasManyChild, extractBelongsToParent, extractTableEntity;
    import graphqld2.core.expr : ExprResultType;

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

                    // Check for relational UDAs first
                    static if (hasUDA!(fn, SqlColumn)) {
                        // Column field (entities)
                        enum isPrimaryKey = hasUDA!(fn, PrimaryKeyAttr);
                        enum isNullable = hasUDA!(fn, NullableColumn);
                        enum isFk = hasForeignKeyRef!fn;

                        static if (isPrimaryKey) {
                            enum gqlType = "ID!";
                        } else {
                            alias RetType = ExprResultType!(ReturnType!fn);
                            static if (isNullable) {
                                enum gqlType = graphqlBaseTypeName!RetType;
                            } else {
                                enum gqlType = graphqlTypeName!RetType;
                            }
                        }

                        fields ~= FieldInfo(
                            gqlFieldName,
                            gqlType,
                            isNullable,
                            isHidden,
                            description,
                            deprecation
                        );
                    }
                    else static if (hasUDA!(fn, HasManyFK)) {
                        // HasMany relationship (entities)
                        alias ChildType = extractHasManyChild!fn;
                        enum gqlType = "[" ~ EntityID!ChildType.typeName ~ "!]!";

                        fields ~= FieldInfo(
                            gqlFieldName,
                            gqlType,
                            false,
                            isHidden,
                            description,
                            deprecation
                        );
                    }
                    else static if (hasUDA!(fn, BelongsToFK)) {
                        // BelongsTo relationship (entities)
                        alias ParentType = extractBelongsToParent!fn;
                        enum isNullable = hasUDA!(fn, NullableColumn);

                        static if (isNullable) {
                            enum gqlType = EntityID!ParentType.typeName;
                        } else {
                            enum gqlType = EntityID!ParentType.typeName ~ "!";
                        }

                        fields ~= FieldInfo(
                            gqlFieldName,
                            gqlType,
                            isNullable,
                            isHidden,
                            description,
                            deprecation
                        );
                    }
                    else static if (hasTableEntity!fn) {
                        // Table entry point (Query/Mutation)
                        // May have pagination arguments if wrapped by PaginationPlugin
                        alias EntityType = extractTableEntity!fn;
                        enum gqlType = "[" ~ EntityID!EntityType.typeName ~ "!]!";

                        // Extract arguments (for pagination support)
                        // Table fields can have optional first/offset params
                        alias TableParams = Parameters!fn;
                        static if (TableParams.length > 1) {
                            // Has arguments beyond the first Expr param
                            enum arguments = getComputedFieldArguments!fn;
                        } else {
                            // No extra arguments
                            enum arguments = cast(ArgumentInfo[]) [];
                        }

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
                    else static if (isValidFieldMethod!(T, fn)) {
                        // Computed field or mutation method (no relational UDA)
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
/// - Are NOT mixin-generated (no @SqlColumn, @HasManyFK, @BelongsToFK, @TableEntity)
template isValidFieldMethod(T, alias fn) {
    import std.traits : hasUDA, Parameters, ReturnType;
    import graphqld2.relational.schema : SqlColumn, HasManyFK, BelongsToFK, TableEntity;

    static if (is(typeof(fn) == function)) {
        alias Params = Parameters!fn;
        alias Return = ReturnType!fn;

        static if (Params.length >= 1) {
            // First parameter must be Expr!T
            static if (is(Params[0] : Expr!E, E) && is(E == T)) {
                // Return type must be an Expr
                static if (isExpr!Return) {
                    // Must not have relational UDAs (those are handled separately)
                    enum hasMixinUda = hasUDA!(fn, SqlColumn) ||
                                       hasUDA!(fn, HasManyFK) ||
                                       hasUDA!(fn, BelongsToFK) ||
                                       hasUDA!(fn, TableEntity);
                    enum isValidFieldMethod = !hasMixinUda;
                } else {
                    enum isValidFieldMethod = false;
                }
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
                        // T → T! (required)
                        static if (is(MemberType == Nullable!(Nullable!U), U)) {
                            // Three-state: absent/null/value - GraphQL type is nullable
                            enum gqlType = graphqlInputTypeName!U;
                        } else static if (is(MemberType == Nullable!U, U)) {
                            // Two-state: null/value (absent = null) - GraphQL type is nullable
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
    } else static if (__traits(hasMember, T, "nodeId")) {
        // Entity reference in input (e.g., for ID references)
        enum graphqlInputTypeName = EntityID!T.typeName;
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

/// Helper to extract input types from function parameters (iterative)
template getInputTypesFromParamsImpl(size_t idx, Params...) {
    static if (idx >= Params.length) {
        alias getInputTypesFromParamsImpl = AliasSeq!();
    } else {
        alias P = Params[idx];
        alias Unwrapped = UnwrapNullable!P;
        alias Rest = getInputTypesFromParamsImpl!(idx + 1, Params);

        static if (isInputType!Unwrapped) {
            alias getInputTypesFromParamsImpl = AliasSeq!(Unwrapped, Rest);
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
                alias Unwrapped = UnwrapNullable!MemberType;

                static if (isInputType!Unwrapped) {
                    alias getNestedInputTypesImpl = AliasSeq!(Unwrapped, Rest);
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

/// Collect all input types from all entities in the schema
template getAllInputTypes(Query) {
    alias AllEntityTypes = getAllEntityTypes!Query;
    alias AllInputTypes = getInputTypesFromEntitiesImpl!AllEntityTypes;
    // Note: uniqueTypes is defined later in the file, but should work due to D's template instantiation order
    alias getAllInputTypes = uniqueTypes!AllInputTypes;
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

/// Helper to get related types from an entity by iterating over members.
/// Scans for methods with @HasManyChild or @BelongsToParent UDAs.
template getRelatedTypesImpl(Entity, size_t idx, Members...) {
    import std.traits : hasUDA;
    import graphqld2.relational.schema : HasManyFK, BelongsToFK;
    import graphqld2.relational.schema : hasHasManyChild, hasBelongsToParent;
    import graphqld2.relational.schema : extractHasManyChild, extractBelongsToParent;

    static if (idx >= Members.length) {
        alias getRelatedTypesImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getRelatedTypesImpl!(Entity, idx + 1, Members);

        // Check for function members with relationship UDAs
        static if (is(typeof(__traits(getMember, Entity, member)) == function)) {
            alias fieldMethod = __traits(getMember, Entity, member);

            // HasMany relationships
            static if (hasHasManyChild!fieldMethod) {
                alias ChildType = extractHasManyChild!fieldMethod;
                alias getRelatedTypesImpl = AliasSeq!(ChildType, Rest);
            }
            // BelongsTo relationships
            else static if (hasBelongsToParent!fieldMethod) {
                alias ParentType = extractBelongsToParent!fieldMethod;
                alias getRelatedTypesImpl = AliasSeq!(ParentType, Rest);
            }
            else {
                alias getRelatedTypesImpl = Rest;
            }
        }
        else {
            alias getRelatedTypesImpl = Rest;
        }
    }
}

/// Get all entity types directly referenced by an entity (via relationships)
template getRelatedTypes(Entity) {
    alias getRelatedTypes = getRelatedTypesImpl!(Entity, 0, __traits(allMembers, Entity));
}

/// Helper to get root types from Query by iterating over members.
/// Scans for methods with @TableEntity UDA.
template getRootTypesImpl(Query, size_t idx, Members...) {
    import graphqld2.relational.schema : hasTableEntity, extractTableEntity;

    static if (idx >= Members.length) {
        alias getRootTypesImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getRootTypesImpl!(Query, idx + 1, Members);

        // Check for function members with @TableEntity UDA
        static if (is(typeof(__traits(getMember, Query, member)) == function)) {
            alias fieldMethod = __traits(getMember, Query, member);

            static if (hasTableEntity!fieldMethod) {
                alias EntityType = extractTableEntity!fieldMethod;
                alias getRootTypesImpl = AliasSeq!(EntityType, Rest);
            }
            else {
                alias getRootTypesImpl = Rest;
            }
        }
        else {
            alias getRootTypesImpl = Rest;
        }
    }
}

/// Get root entity types from Query
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
    } else static if (__traits(hasMember, ResultType, "nodeId")) {
        enum rootFieldReturnType = EntityID!ResultType.typeName ~ "!";
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

/// Collect custom scalar names from an entity's column types
private template getCustomScalarNames(Entity) {
    import std.traits : hasUDA, ReturnType;
    import graphqld2.relational.schema : SqlColumn;
    import graphqld2.core.expr : ExprResultType;

    enum getCustomScalarNames = () {
        string[] names;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (is(typeof(__traits(getMember, Entity, member)) == function)) {
                alias fieldMethod = __traits(getMember, Entity, member);
                // Check for @SqlColumn UDA (column fields)
                static if (hasUDA!(fieldMethod, SqlColumn)) {
                    alias ColType = ExprResultType!(ReturnType!fieldMethod);
                    static if (isCustomScalar!ColType) {
                        // Add if not already present
                        bool found = false;
                        foreach (n; names) {
                            if (n == ColType.name) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            names ~= ColType.name;
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
template generateSchemaSDL(alias SchemaOrQuery) {
    // Determine if we have a Schema or raw Query type
    static if (isSchema!SchemaOrQuery) {
        alias QueryType = SchemaOrQuery.Query;
        alias MutationType = SchemaOrQuery.Mutation;
    } else {
        alias QueryType = SchemaOrQuery;
        struct MutationType {}
    }

    alias AllTypes = getAllEntityTypes!QueryType;

    // Collect input types from entities AND mutations (if any)
    alias EntityInputTypes = getAllInputTypes!QueryType;
    static if (getFields!MutationType.length > 0) {
        alias MutationInputTypes = getInputTypesFromMutation!MutationType;
        alias AllInputTypes = uniqueTypes!(AliasSeq!(EntityInputTypes, MutationInputTypes));
    } else {
        alias AllInputTypes = EntityInputTypes;
    }

    enum generateSchemaSDL = () {
        string result;

        // Declare custom scalars
        foreach (scalarName; getAllCustomScalarNames!AllTypes) {
            result ~= "scalar " ~ scalarName ~ "\n";
        }
        static if (getAllCustomScalarNames!AllTypes.length > 0) {
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

        // Generate each discovered entity type
        static foreach (Entity; AllTypes) {
            result ~= generateObjectTypeSDL!Entity(EntityID!Entity.typeName);
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
    import graphqld2.core.types : CustomScalar;
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
    import graphqld2.relational.demo : DemoEntity, MockDB;
    import graphqld2.relational.schema : Col;

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
    enum sdl = generateObjectTypeSDL!User(EntityID!User.typeName);
    assert(sdl.canFind("name:"), "SDL should include name field");
    assert(!sdl.canFind("passwordHash"), "SDL should NOT include passwordHash field");
}

// Test @GqlDescription and @GqlDeprecated UDAs
unittest {
    import std.algorithm : canFind;
    import graphqld2.relational.demo : DemoEntity, MockDB;
    import graphqld2.relational.schema : Col;

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
    enum sdl = generateObjectTypeSDL!Article(EntityID!Article.typeName);

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
    import graphqld2.relational.demo : DemoEntity, MockDB;
    import graphqld2.relational.schema : Col, Table, getAll;

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
    import graphqld2.relational.demo : DemoEntity, MockDB;
    import graphqld2.relational.schema : Col, Table, getAll;

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
        import graphqld2.core.expr : effect;

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
    import graphqld2.relational.demo : DemoEntity, MockDB;
    import graphqld2.relational.schema : Col, Table, getAll;

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
