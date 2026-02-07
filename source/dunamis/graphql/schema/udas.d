module dunamis.graphql.schema.udas;

import std.algorithm;
import std.meta;
import std.traits;
import std.typecons : Nullable;

import dunamis.core.types : isCustomScalar;
import dunamis.core.expr : Expr, ExprResultType, isExpr;

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

/// Check if a type is an "object type" (struct with valid field methods, plain fields, or plain methods).
/// This replaces the old isEntity check - now any struct with Expr-returning
/// static methods, plain fields, or plain methods is treated as a GraphQL object type.
///
/// Exclusions:
/// - JSONValue is treated as a scalar (passed through as raw JSON)
/// - Custom scalars are treated as scalars
/// - Input types (structs without valid field methods used as computed field arguments)
template isObjectType(T) {
    import std.json : JSONValue;
    static if (is(T == struct)) {
        // Exclude JSONValue (raw JSON pass-through)
        static if (is(T == JSONValue)) {
            enum isObjectType = false;
        }
        // Exclude custom scalars
        else static if (isCustomScalar!T) {
            enum isObjectType = false;
        }
        // Check if it has at least one valid field method, plain field, or plain method
        else {
            enum isObjectType = hasAnyValidFieldMethod!T || hasAnyPlainField!T || hasAnyPlainMethod!T;
        }
    } else {
        enum isObjectType = false;
    }
}

// ============================================================================
// UDA Helpers
// ============================================================================

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
// Member Validation Helpers
// ============================================================================

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

/// Helper to check if a member is a valid field method for type T.
/// Uses string member name to avoid forward reference issues.
template isValidFieldMethodForType(T, string member) {
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
// Private Helpers
// ============================================================================

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

/// Check if type has any plain fields (struct instance fields)
private template hasAnyPlainField(T) {
    import dunamis.core.types : isPlainField;
    enum hasAnyPlainField = () {
        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member) {
                static if (isPlainField!(T, member)) {
                    return true;
                }
            }
        }}
        return false;
    }();
}

/// Check if type has any plain methods (instance methods returning non-Expr types)
private template hasAnyPlainMethod(T) {
    import dunamis.core.types : isPlainMethod;
    enum hasAnyPlainMethod = () {
        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member) {
                static if (isPlainMethod!(T, member)) {
                    return true;
                }
            }
        }}
        return false;
    }();
}
