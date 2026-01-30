module graphqld2.graphql.schema;

import std.algorithm;
import std.array;
import std.conv;
import std.meta;
import std.traits;
import std.typecons : Nullable;

import graphqld2.core.types : isCustomScalar;

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

/// Field information extracted from entity mixins
struct FieldInfo {
    string name;
    string graphqlType;
    bool nullable;
    FieldKind kind;
    bool hidden;           // @GqlHidden
    string description;    // @GqlDescription (empty if not set)
    string deprecation;    // @GqlDeprecated reason (empty if not deprecated)
}

enum FieldKind {
    column,
    hasMany,
    belongsTo,
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

/// Extract field information from an entity type
template getEntityFields(Entity) {
    enum getEntityFields = () {
        FieldInfo[] fields;

        // Introspect all members looking for field metadata
        static foreach (member; __traits(allMembers, Entity)) {{
            // Check for column fields (_colField_*)
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

        // Field name and type
        result ~= "  " ~ field.name ~ ": " ~ field.graphqlType;

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

/// Generate complete GraphQL schema SDL by discovering all types from Query
template generateSchemaSDL(Query) {
    alias AllTypes = getAllEntityTypes!Query;

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
        result ~= generateQuerySDL!Query();
        result ~= "\n";

        // Generate each discovered entity type
        static foreach (Entity; AllTypes) {
            result ~= generateTypeSDL!Entity();
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
