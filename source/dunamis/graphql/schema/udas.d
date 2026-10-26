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

/// The GraphQL name of a member whose D name is `defaultName`: the name
/// given by its @GqlName UDA if present; otherwise a D keyword followed by an
/// underscore (D's convention for names which are keywords, e.g. `in_`)
/// stands for the keyword; otherwise the D name.
template getGqlName(alias member, string defaultName) {
    enum getGqlName = () {
        alias attrs = __traits(getAttributes, member);
        static foreach (attr; attrs) {
            static if (is(typeof(attr) == GqlName)) {
                return attr.name;
            }
        }
        return presentedMemberName(defaultName);
    }();
}

/// The GraphQL name of a D member name `name` without @GqlName: a D keyword
/// followed by an underscore stands for the keyword.
string presentedMemberName(string name) pure nothrow @safe {
    import std.algorithm.searching : canFind;
    if (name.length > 1 && name[$ - 1] == '_' && dKeywords.canFind(name[0 .. $ - 1]))
        return name[0 .. $ - 1];
    return name;
}

/// D keywords, which cannot name a member.
private immutable string[] dKeywords = [
    "abstract", "alias", "align", "asm", "assert", "auto", "body", "bool", "break", "byte",
    "case", "cast", "catch", "cdouble", "cent", "cfloat", "char", "class", "const", "continue",
    "creal", "dchar", "debug", "default", "delegate", "delete", "deprecated", "do", "double",
    "else", "enum", "export", "extern", "false", "final", "finally", "float", "for", "foreach",
    "foreach_reverse", "function", "goto", "idouble", "if", "ifloat", "immutable", "import",
    "in", "inout", "int", "interface", "invariant", "ireal", "is", "lazy", "long", "macro",
    "mixin", "module", "new", "nothrow", "null", "out", "override", "package", "pragma",
    "private", "protected", "public", "pure", "real", "ref", "return", "scope", "shared",
    "short", "static", "struct", "super", "switch", "synchronized", "template", "this",
    "throw", "true", "try", "typeid", "typeof", "ubyte", "ucent", "uint", "ulong", "union",
    "unittest", "ushort", "version", "void", "wchar", "while", "with",
];

unittest {
    static assert(presentedMemberName("in_") == "in");
    static assert(presentedMemberName("version_") == "version");
    static assert(presentedMemberName("name_") == "name_");
    static assert(presentedMemberName("_") == "_");
    static assert(presentedMemberName("in") == "in");
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
