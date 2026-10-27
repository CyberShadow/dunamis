/// Plugin-aware entity cast infrastructure.
///
/// Satellite module for pluginEntityCast — separated from transform.d to avoid
/// forward reference errors when loaded via .imported during plugin type construction.
/// This module must NOT import from plugin.d or any module that transitively imports it.
module dunamis.schema.entity_cast;

import dunamis.core.expr : Expr;

/// Plugin-aware entity cast value conversion. Handles per-layer _normalizedSource
/// propagation: each plugin wrapper stores its immediate source type.
To entityCastValue(To, From)(From from) {
    To to;
    static if (is(From == struct) && is(To == struct)) {
        // Unwrap: From wraps To in _normalizedSource — extract directly
        static if (__traits(hasMember, From, "_normalizedSource") &&
                   is(typeof(From._normalizedSource) == To)) {
            return from._normalizedSource;
        } else {
            import dunamis.core.types : isInternalMember;

            import std.traits : FieldNameTuple;

            // Copy matching public instance fields.
            // Uses visibility checks instead of name conventions (see Principle 8 in ARCHITECTURE.md).
            // Cannot use isPlainField here because entityCastValue runs during plugin type
            // construction when forward references may not yet be resolved. Only data
            // fields can be copied, so only those are checked (rather than every
            // member, e.g. every field function of a schema type).
            static foreach (member; FieldNameTuple!From) {{
                static if (!isInternalMember!member && __traits(hasMember, To, member)) {
                    // Skip non-public fields (e.g., package-scoped _normalizedSource)
                    static if (__traits(compiles, __traits(getVisibility, __traits(getMember, From, member))) &&
                               __traits(getVisibility, __traits(getMember, From, member)) == "public") {
                        static if (__traits(compiles, __traits(getMember, from, member)) &&
                                   __traits(compiles, __traits(getMember, to, member) = __traits(getMember, from, member))) {
                            __traits(getMember, to, member) = __traits(getMember, from, member);
                        }
                    }
                }
            }}
            // Wrap: To stores From as its _normalizedSource (per-layer)
            static if (__traits(hasMember, To, "_normalizedSource") &&
                       is(typeof(To._normalizedSource) == From)) {
                to._normalizedSource = from;
            }
        }
    }
    return to;
}

/// Plugin-aware entity cast expression. Uses entityCastValue (which handles
/// _normalizedSource propagation) instead of the core defaultEntityCast.
auto pluginEntityCast(To, From)(Expr!From source) {
    import dunamis.core.expr.primitives : EntityCastExpr;
    return new EntityCastExpr!(To, From, .entityCastValue)(source);
}
