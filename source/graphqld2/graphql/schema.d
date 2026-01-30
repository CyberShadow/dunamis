module graphqld2.graphql.schema;

import std.algorithm;
import std.array;
import std.conv;
import std.meta;
import std.traits;
import std.typecons : Nullable;

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
template graphqlBaseTypeName(T) {
    static if (is(T == string)) {
        enum graphqlBaseTypeName = "String";
    } else static if (is(T == bool)) {
        enum graphqlBaseTypeName = "Boolean";
    } else static if (is(T == int) || is(T == short) || is(T == byte)) {
        enum graphqlBaseTypeName = "Int";
    } else static if (is(T == long)) {
        // GraphQL Int is 32-bit; use Int64 for 64-bit integers
        enum graphqlBaseTypeName = "Int64";
    } else static if (is(T == float) || is(T == double)) {
        enum graphqlBaseTypeName = "Float";
    } else static if (is(T == Nullable!U, U)) {
        // Unwrap Nullable
        enum graphqlBaseTypeName = graphqlBaseTypeName!U;
    } else static if (is(T == E[], E)) {
        enum graphqlBaseTypeName = "[" ~ graphqlTypeName!E ~ "]";
    } else static if (__traits(hasMember, T, "_typeName")) {
        // Entity type - reference by name
        enum graphqlBaseTypeName = T._typeName;
    } else {
        enum graphqlBaseTypeName = T.stringof;
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
}

enum FieldKind {
    column,
    hasMany,
    belongsTo,
}

/// Extract field information from an entity type
template getEntityFields(Entity) {
    enum getEntityFields = () {
        FieldInfo[] fields;

        // Always add id field (non-nullable)
        fields ~= FieldInfo("id", "ID!", false, FieldKind.column);

        // Introspect all members looking for field metadata
        static foreach (member; __traits(allMembers, Entity)) {{
            // Check for column fields (_colField_*)
            static if (member.length > 10 && member[0..10] == "_colField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
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
                fields ~= FieldInfo(
                    FieldMeta.name,
                    gqlType,
                    colNullable,
                    FieldKind.column
                );
            }
            // Check for hasMany fields (_hasManyField_*)
            else static if (member.length > 14 && member[0..14] == "_hasManyField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
                // HasMany: non-nullable list of non-nullable items
                fields ~= FieldInfo(
                    FieldMeta.name,
                    "[" ~ FieldMeta.childType._typeName ~ "!]!",
                    false,
                    FieldKind.hasMany
                );
            }
            // Check for belongsTo fields (_belongsToField_*)
            else static if (member.length > 16 && member[0..16] == "_belongsToField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
                // BelongsTo: nullable or not based on FK column
                static if (FieldMeta.nullable) {
                    enum belongsToType = FieldMeta.parentType._typeName;
                } else {
                    enum belongsToType = FieldMeta.parentType._typeName ~ "!";
                }
                fields ~= FieldInfo(
                    FieldMeta.name,
                    belongsToType,
                    FieldMeta.nullable,
                    FieldKind.belongsTo
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
        // graphqlType already includes "!" for non-nullable types
        result ~= "  " ~ field.name ~ ": " ~ field.graphqlType ~ "\n";
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

/// Generate complete GraphQL schema SDL by discovering all types from Query
template generateSchemaSDL(Query) {
    alias AllTypes = getAllEntityTypes!Query;

    enum generateSchemaSDL = () {
        string result;

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
    // Test graphqlTypeName (includes "!" for non-nullable)
    static assert(graphqlTypeName!string == "String!");
    static assert(graphqlTypeName!int == "Int!");
    static assert(graphqlTypeName!long == "Int64!");  // 64-bit uses Int64, not Int
    static assert(graphqlTypeName!bool == "Boolean!");
    static assert(graphqlTypeName!float == "Float!");
    static assert(graphqlTypeName!(string[]) == "[String!]!");

    // Test Nullable types (no "!" suffix)
    static assert(graphqlTypeName!(Nullable!string) == "String");
    static assert(graphqlTypeName!(Nullable!int) == "Int");
    static assert(graphqlTypeName!(Nullable!long) == "Int64");

    // Test base type names (without "!")
    static assert(graphqlBaseTypeName!string == "String");
    static assert(graphqlBaseTypeName!long == "Int64");
    static assert(graphqlBaseTypeName!(Nullable!string) == "String");
}
