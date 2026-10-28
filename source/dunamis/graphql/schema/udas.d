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

/// UDA to add a description to a field, an input object field, an enum
/// member or a type (object, interface, union, input object or enum).
/// Rendered as a doc string in GraphQL SDL, and given by introspection.
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

/// UDA giving the default value of an input object field in the GraphQL
/// schema, as a GraphQL value literal (e.g. `@GqlDefault("[]")`).
///
/// It is the value of the field's D initializer, which an absent field has:
/// the attribute only presents it. A field with a default may be omitted
/// even if its type is non-null.
struct GqlDefault {
    string value;
}

/// The @GqlDefault value of a member, or null if it has none
template getGqlDefault(alias member) {
    enum getGqlDefault = () {
        alias attrs = __traits(getAttributes, member);
        static foreach (attr; attrs) {
            static if (is(typeof(attr) == GqlDefault)) {
                return attr.value;
            }
        }
        return string.init;
    }();
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

/// The @GqlDescription text of the member named `name` of enum E, or ""
template getEnumMemberDescription(E, string name) if (is(E == enum)) {
    enum getEnumMemberDescription = getGqlDescription!(__traits(getMember, E, name));
}

/// The SDL doc string (a block string, on lines of its own indented by
/// `indent`) of the description `text`, or "" if it is empty.
/// A one-line description stays on the line of its quotes.
string sdlDescription(string text, string indent) {
    import std.algorithm : canFind, endsWith;
    import std.array : replace, split, join;

    if (text.length == 0) return "";
    // (Within a block string, only `"""` needs to be escaped.)
    auto escaped = text.replace(`"""`, `\"""`);
    if (!escaped.canFind('\n') && !escaped.endsWith(`"`))
        return indent ~ `"""` ~ escaped ~ `"""` ~ "\n";
    string result = indent ~ `"""` ~ "\n";
    foreach (line; escaped.split('\n'))
        result ~= (line.length ? indent ~ line : "") ~ "\n";
    return result ~ indent ~ `"""` ~ "\n";
}

unittest {
    assert(sdlDescription("", "  ") == "");
    assert(sdlDescription("One line", "  ") == "  \"\"\"One line\"\"\"\n");
    assert(sdlDescription("Two\n\nlines", "  ") == "  \"\"\"\n  Two\n\n  lines\n  \"\"\"\n");
    assert(sdlDescription(`Ends with "quotes"`, "") == "\"\"\"\nEnds with \"quotes\"\n\"\"\"\n");
    assert(sdlDescription(`Has """ inside`, "") == "\"\"\"Has \\\"\"\" inside\"\"\"\n");
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
