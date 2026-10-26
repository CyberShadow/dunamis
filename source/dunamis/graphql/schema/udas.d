module dunamis.graphql.schema.udas;

import std.meta;
import std.traits;

// Re-export type introspection templates from core for backward compatibility.
// These were moved to dunamis.core.discovery as they are data-source agnostic.
public import dunamis.core.discovery : isObjectType, isValidFieldMethodForType;
public import dunamis.core.types : isInternalMember, isPublicMember, isPublicDataField;

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
        // Check for @GqlName UDA on the type (user-applied, presentation layer)
        static if (hasUDA!(T, GqlName)) {
            return getUDAs!(T, GqlName)[0].name;
        } else static if (__traits(hasMember, T, "__gqlTypeName")) {
            return T.__gqlTypeName;
        } else {
            // Check for @OriginalName UDA (applied by plugin wrappers)
            import dunamis.schema.plugin : OriginalName;
            static if (hasUDA!(T, OriginalName)) {
                return getUDAs!(T, OriginalName)[0].name;
            } else {
                // Use D type name
                return __traits(identifier, T);
            }
        }
    }();
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
