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
/// 1. The name given by a @GqlName UDA on the type
/// 2. For a type the schema layer names after another type (@NamedAfter,
///    e.g. the filter input type of an entity), the GraphQL name of that
///    type followed by the suffix
/// 3. The original D name of the type a plugin wrapper stands for
///    (the first @OriginalName UDA)
/// 4. The D type's identifier
template getGraphQLTypeName(T) {
    import dunamis.schema.plugin : OriginalName, NamedAfter, NamedAfterBase;

    static if (hasUDA!(T, GqlName)) {
        enum string getGraphQLTypeName = getUDAs!(T, GqlName)[0].name;
    } else static if (hasUDA!(T, NamedAfter)) {
        enum string getGraphQLTypeName = getGraphQLTypeName!(NamedAfterBase!T) ~
            getUDAs!(T, NamedAfter)[0].suffix;
    } else static if (hasUDA!(T, OriginalName)) {
        enum string getGraphQLTypeName = getUDAs!(T, OriginalName)[0].name;
    } else {
        enum string getGraphQLTypeName = __traits(identifier, T);
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
