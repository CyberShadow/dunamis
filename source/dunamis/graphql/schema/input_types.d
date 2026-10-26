module dunamis.graphql.schema.input_types;

import std.json : JSONValue;
import std.meta;
import std.traits;
import std.typecons : Nullable;

import dunamis.core.types : isCustomScalar, isPublicDataField;
import dunamis.graphql.schema.udas;
import dunamis.graphql.schema.fields : graphqlTypeName, graphqlBaseTypeName;

// ============================================================================
// Input Type Detection
// ============================================================================

/// Check if a type is a struct that should be treated as a GraphQL input type.
/// Input types are structs that:
/// - Are not entities (no _typeName member from Entity mixin)
/// - Are not Nullable wrappers
/// - Are not built-in types (string, int, etc.)
/// - Are not JSONValue (raw JSON pass-through)
template isInputType(T) {
    import std.json : JSONValue;
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
        // Must not be JSONValue (raw JSON pass-through type)
        else static if (is(T == JSONValue)) {
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
        string result = "enum " ~ getGraphQLTypeName!E ~ " {\n";
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
            static if (isPublicDataField!(T, member)) {
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

                        fields ~= InputFieldInfo(
                            getGqlName!(__traits(getMember, T, member), member),
                            gqlType,
                            false,
                            "",
                        );
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
        enum graphqlInputTypeName = getGraphQLTypeName!T;
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
