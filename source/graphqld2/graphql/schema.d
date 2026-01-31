module graphqld2.graphql.schema;

import std.algorithm;
import std.array;
import std.conv;
import std.meta;
import std.traits;
import std.typecons : Nullable;

import graphqld2.core.types : isCustomScalar;
import graphqld2.core.expr : Expr, ExprResultType, isExpr;

// ============================================================================
// Schema Template
// ============================================================================

/// Schema template bundling Query and optional Mutation types.
/// This is the primary entry point for schema operations.
///
/// Example:
/// ---
/// struct Query {
///     mixin Table!(db, User, "users");
/// }
///
/// struct Mutation {
///     static User createUser(CreateUserInput input) { ... }
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
        enum hasMutations = false;
    } else {
        alias Mutation = MutationType;
        enum hasMutations = true;
    }

    // Marker to identify Schema instantiations
    enum _isSchema = true;
}

/// Check if a type is a Schema instantiation
template isSchema(alias T) {
    static if (__traits(compiles, T._isSchema) && T._isSchema) {
        enum isSchema = true;
    } else {
        enum isSchema = false;
    }
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
    } else static if (__traits(hasMember, T, "_typeName")) {
        // Entity/aggregate type - reference by name
        enum graphqlBaseTypeName = T._typeName;
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

/// Field information extracted from entity mixins
struct FieldInfo {
    string name;
    string graphqlType;
    bool nullable;
    FieldKind kind;
    bool hidden;           // @GqlHidden
    string description;    // @GqlDescription (empty if not set)
    string deprecation;    // @GqlDeprecated reason (empty if not deprecated)
    ArgumentInfo[] arguments;  // For computed fields with arguments
}

enum FieldKind {
    column,
    hasMany,
    belongsTo,
    computed,
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
// Computed Field Detection
// ============================================================================

/// Check if a member is a computed field for the given Entity.
/// A computed field is a static function that:
/// - Takes Expr!Entity as first parameter
/// - Returns an Expr type
/// - Is NOT a generated accessor (has no corresponding _colField_*, _hasManyField_*, or _belongsToField_*)
template isComputedField(Entity, string memberName, alias member) {
    static if (is(typeof(member) == function)) {
        alias Params = Parameters!member;
        alias Return = ReturnType!member;
        static if (Params.length >= 1) {
            // First parameter must be Expr!Entity
            static if (is(Params[0] : Expr!E, E) && is(E == Entity)) {
                // Return type must be an Expr
                static if (isExpr!Return) {
                    // Exclude generated accessors (those with corresponding metadata structs)
                    enum hasColMeta = __traits(hasMember, Entity, "_colField_" ~ memberName);
                    enum hasHasManyMeta = __traits(hasMember, Entity, "_hasManyField_" ~ memberName);
                    enum hasBelongsToMeta = __traits(hasMember, Entity, "_belongsToField_" ~ memberName);
                    enum isComputedField = !hasColMeta && !hasHasManyMeta && !hasBelongsToMeta;
                } else {
                    enum isComputedField = false;
                }
            } else {
                enum isComputedField = false;
            }
        } else {
            enum isComputedField = false;
        }
    } else {
        enum isComputedField = false;
    }
}

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

            // Check if parameter has a default value
            static if (is(Defaults[i] == void)) {
                // No default - required argument
                args ~= ArgumentInfo(
                    paramNames[i],
                    graphqlTypeName!P,
                    false,
                    ""
                );
            } else {
                // Has default - optional argument (nullable in GraphQL)
                // For nullable types, use base type; otherwise add null default
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

/// Check if a member name is an internal mixin helper that should be skipped
template isInternalHelper(string name) {
    enum isInternalHelper =
        // Internal Col mixin helpers
        (name.length >= 5 && name[0..5] == "_Col_") ||
        // Internal BelongsTo mixin helpers
        (name.length >= 11 && name[0..11] == "_BelongsTo_") ||
        // Internal HasMany mixin helpers (if any)
        (name.length >= 9 && name[0..9] == "_HasMany_");
}

/// Extract field information from an entity type
template getEntityFields(Entity) {
    enum getEntityFields = () {
        FieldInfo[] fields;

        // Introspect all members looking for field metadata
        static foreach (member; __traits(allMembers, Entity)) {{
            // Skip internal mixin helper symbols
            static if (isInternalHelper!member) {
                // Skip
            }
            // Check for column fields (_colField_*)
            else
            static if (member.length > 10 && member[0..10] == "_colField_") {
                alias FieldMeta = __traits(getMember, Entity, member);

                // Check if @GqlHidden UDA is present
                enum isHidden = hasGqlHidden!FieldMeta;

                // Check if column is a primary key - use GraphQL ID type
                static if (__traits(hasMember, FieldMeta, "isPrimaryKey") && FieldMeta.isPrimaryKey) {
                    enum gqlType = "ID!";
                    enum colNullable = false;
                } else {
                    // Check if column has isNullable metadata
                    static if (__traits(hasMember, FieldMeta, "isNullable")) {
                        enum colNullable = FieldMeta.isNullable;
                    } else {
                        enum colNullable = false;
                    }
                    // Use base type name (without !) if nullable, full type name otherwise
                    static if (colNullable) {
                        enum gqlType = graphqlBaseTypeName!(FieldMeta.type);
                    } else {
                        enum gqlType = graphqlTypeName!(FieldMeta.type);
                    }
                }

                // Get GraphQL field name (use @GqlName if present)
                enum gqlFieldName = getGqlName!(FieldMeta, FieldMeta.name);

                // Get description and deprecation
                enum description = getGqlDescription!FieldMeta;
                enum deprecation = getGqlDeprecated!FieldMeta;

                fields ~= FieldInfo(
                    gqlFieldName,
                    gqlType,
                    colNullable,
                    FieldKind.column,
                    isHidden,
                    description,
                    deprecation
                );
            }
            // Check for hasMany fields (_hasManyField_*)
            else static if (member.length > 14 && member[0..14] == "_hasManyField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
                enum isHidden = hasGqlHidden!FieldMeta;
                enum gqlFieldName = getGqlName!(FieldMeta, FieldMeta.name);
                enum description = getGqlDescription!FieldMeta;
                enum deprecation = getGqlDeprecated!FieldMeta;
                // HasMany: non-nullable list of non-nullable items
                fields ~= FieldInfo(
                    gqlFieldName,
                    "[" ~ FieldMeta.childType._typeName ~ "!]!",
                    false,
                    FieldKind.hasMany,
                    isHidden,
                    description,
                    deprecation
                );
            }
            // Check for belongsTo fields (_belongsToField_*)
            else static if (member.length > 16 && member[0..16] == "_belongsToField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
                enum isHidden = hasGqlHidden!FieldMeta;
                enum gqlFieldName = getGqlName!(FieldMeta, FieldMeta.name);
                enum description = getGqlDescription!FieldMeta;
                enum deprecation = getGqlDeprecated!FieldMeta;
                // BelongsTo: nullable or not based on FK column
                static if (FieldMeta.nullable) {
                    enum belongsToType = FieldMeta.parentType._typeName;
                } else {
                    enum belongsToType = FieldMeta.parentType._typeName ~ "!";
                }
                fields ~= FieldInfo(
                    gqlFieldName,
                    belongsToType,
                    FieldMeta.nullable,
                    FieldKind.belongsTo,
                    isHidden,
                    description,
                    deprecation
                );
            }
            // Check for computed fields (static functions taking Expr!Entity)
            else static if (isComputedField!(Entity, member, __traits(getMember, Entity, member))) {
                alias fn = __traits(getMember, Entity, member);

                // Get UDAs from the function
                enum isHidden = hasGqlHidden!fn;
                enum gqlFieldName = getGqlName!(fn, member);
                enum description = getGqlDescription!fn;
                enum deprecation = getGqlDeprecated!fn;

                // Get return type and arguments
                enum gqlType = computedFieldReturnType!fn;
                enum arguments = getComputedFieldArguments!fn;

                fields ~= FieldInfo(
                    gqlFieldName,
                    gqlType,
                    false,  // computed fields are non-nullable by default
                    FieldKind.computed,
                    isHidden,
                    description,
                    deprecation,
                    arguments
                );
            }
        }}

        return fields;
    }();
}

/// Extract root query fields from a Query type
template getQueryFields(Query) {
    enum getQueryFields = () {
        FieldInfo[] fields;

        static foreach (member; __traits(allMembers, Query)) {{
            // Check for table fields (_tableField_*)
            static if (member.length > 12 && member[0..12] == "_tableField_") {
                alias FieldMeta = __traits(getMember, Query, member);
                // Root queries return non-nullable list of non-nullable items
                fields ~= FieldInfo(
                    FieldMeta.name,
                    "[" ~ FieldMeta.entityType._typeName ~ "!]!",
                    false,
                    FieldKind.hasMany  // Root queries return arrays
                );
            }
        }}

        return fields;
    }();
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
            static if (!isInternalHelper!member) {
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
    } else static if (isInputType!T) {
        // Input type struct - use struct name as type name
        enum graphqlInputTypeName = T.stringof;
    } else static if (__traits(hasMember, T, "_typeName")) {
        // Entity reference in input (e.g., for ID references)
        enum graphqlInputTypeName = T._typeName;
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

        static if (isInternalHelper!member) {
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

        static if (isInternalHelper!member) {
            alias getInputTypesFromEntityImpl = Rest;
        } else static if (__traits(compiles, isComputedField!(Entity, member, __traits(getMember, Entity, member)))) {
            static if (isComputedField!(Entity, member, __traits(getMember, Entity, member))) {
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

/// Helper to get related types from an entity by iterating over members
template getRelatedTypesImpl(Entity, size_t idx, Members...) {
    static if (idx >= Members.length) {
        alias getRelatedTypesImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getRelatedTypesImpl!(Entity, idx + 1, Members);

        // HasMany relationships
        static if (member.length > 14 && member[0..14] == "_hasManyField_") {
            alias FieldMeta = __traits(getMember, Entity, member);
            alias getRelatedTypesImpl = AliasSeq!(FieldMeta.childType, Rest);
        }
        // BelongsTo relationships
        else static if (member.length > 16 && member[0..16] == "_belongsToField_") {
            alias FieldMeta = __traits(getMember, Entity, member);
            alias getRelatedTypesImpl = AliasSeq!(FieldMeta.parentType, Rest);
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

/// Helper to get root types from Query by iterating over members
template getRootTypesImpl(Query, size_t idx, Members...) {
    static if (idx >= Members.length) {
        alias getRootTypesImpl = AliasSeq!();
    } else {
        enum member = Members[idx];
        alias Rest = getRootTypesImpl!(Query, idx + 1, Members);

        static if (member.length > 12 && member[0..12] == "_tableField_") {
            alias FieldMeta = __traits(getMember, Query, member);
            alias getRootTypesImpl = AliasSeq!(FieldMeta.entityType, Rest);
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
string generateTypeSDL(Entity)() {
    string result = "type " ~ Entity._typeName ~ " {\n";

    foreach (field; getEntityFields!Entity) {
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

/// Generate GraphQL SDL for the Query type
string generateQuerySDL(Query)() {
    string result = "type Query {\n";

    foreach (field; getQueryFields!Query) {
        // graphqlType already includes "!" for non-nullable types
        result ~= "  " ~ field.name ~ ": " ~ field.graphqlType ~ "\n";
    }

    result ~= "}\n";
    return result;
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
    enum getCustomScalarNames = () {
        string[] names;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (member.length > 10 && member[0..10] == "_colField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
                static if (isCustomScalar!(FieldMeta.type)) {
                    // Add if not already present
                    bool found = false;
                    foreach (n; names) {
                        if (n == FieldMeta.type.name) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        names ~= FieldMeta.type.name;
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
        enum hasMutations = SchemaOrQuery.hasMutations;
    } else {
        alias QueryType = SchemaOrQuery;
        struct MutationType {}
        enum hasMutations = false;
    }

    alias AllTypes = getAllEntityTypes!QueryType;
    alias AllInputTypes = getAllInputTypes!QueryType;

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
        result ~= generateQuerySDL!QueryType();
        result ~= "\n";

        // Generate each discovered entity type
        static foreach (Entity; AllTypes) {
            result ~= generateTypeSDL!Entity();
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
    alias Int64 = CustomScalar!(long, "Int64", (long v) => v.to!string, (string s) => s.to!long);
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
    import graphqld2.relational.demo : DemoEntity;  // Uses Int64 for id
    import graphqld2.relational.schema : Col;

    static struct User {
        mixin DemoEntity!"users";
        mixin Col!("name", string);

        @GqlHidden
        mixin Col!("passwordHash", string);
    }

    // Check that getEntityFields detects hidden field
    enum fields = getEntityFields!User;
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
    enum sdl = generateTypeSDL!User;
    assert(sdl.canFind("name:"), "SDL should include name field");
    assert(!sdl.canFind("passwordHash"), "SDL should NOT include passwordHash field");
}

// Test @GqlDescription and @GqlDeprecated UDAs
unittest {
    import std.algorithm : canFind;
    import graphqld2.relational.demo : DemoEntity;
    import graphqld2.relational.schema : Col;

    static struct Article {
        mixin DemoEntity!"articles";

        @GqlDescription("The article title")
        mixin Col!("title", string);

        @GqlDescription("Main content")
        @GqlDeprecated("Use content instead")
        mixin Col!("body", string);

        mixin Col!("plain", string);  // No annotations
    }

    // Check that getEntityFields extracts description and deprecation
    enum fields = getEntityFields!Article;

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
    enum sdl = generateTypeSDL!Article;

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
    import graphqld2.relational.demo : DemoEntity;
    import graphqld2.relational.schema : Col, Table, getAll;
    import graphqld2.relational.eval_context : MockDB;

    static struct User {
        mixin DemoEntity!"users";
        mixin Col!("name", string);
    }

    static MockDB!() db;

    static struct MyQuery {
        mixin Table!(db, User, "users");
    }

    // Schema without mutations
    alias MySchema = Schema!(MyQuery);

    // Verify Schema properties
    static assert(isSchema!MySchema);
    static assert(is(MySchema.Query == MyQuery));
    static assert(!MySchema.hasMutations);

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
