/// Plugin-aware entity cast infrastructure.
///
/// Satellite module for pluginEntityCast — separated from transform.d to avoid
/// forward reference errors when loaded via .imported during plugin type construction.
/// This module must NOT import from plugin.d or any module that transitively imports it.
module dunamis.schema.entity_cast;

import dunamis.core.expr : Expr;

/// The user-declared type at the bottom of T's plugin layer chain.
/// Each plugin wrapper stores its immediate source type in `_normalizedSource`;
/// types without one (user-declared types, Query/Mutation wrappers) are their own base.
template BaseEntityOf(T) {
    static if (is(T == struct) && __traits(hasMember, T, "_normalizedSource"))
        alias BaseEntityOf = BaseEntityOf!(typeof(T._normalizedSource));
    else
        alias BaseEntityOf = T;
}

/// True if U is T or one of the layers T wraps, transitively.
template isInChain(T, U) {
    static if (is(T == U))
        enum isInChain = true;
    else static if (is(T == struct) && __traits(hasMember, T, "_normalizedSource"))
        enum isInChain = isInChain!(typeof(T._normalizedSource), U);
    else
        enum isInChain = false;
}

/// Plugin-aware entity cast value conversion. Handles per-layer _normalizedSource
/// propagation: each plugin wrapper stores its immediate source type.
/// A cast may span several layers of the same chain, in either direction.
To entityCastValue(To, From)(From from) {
    To to;
    static if (is(From == struct) && is(To == struct)) {
        static if (!is(From == To) && isInChain!(From, To)) {
            // Unwrap: To is in From's _normalizedSource chain — extract it
            static if (is(typeof(From._normalizedSource) == To))
                return from._normalizedSource;
            else
                return entityCastValue!(To, typeof(From._normalizedSource))(from._normalizedSource);
        } else {
            import dunamis.core.types : isInternalMember;

            // Copy matching public instance fields.
            // Uses visibility checks instead of name conventions (see Principle 8 in ARCHITECTURE.md).
            // Cannot use isPlainField here because entityCastValue runs during plugin type
            // construction when forward references may not yet be resolved.
            static foreach (member; __traits(allMembers, From)) {{
                // Keep the member-existence probe in a nested static-if. D may
                // resolve both operands of `&&` during template expansion,
                // which makes duplicated private plugin aliases ambiguous.
                static if (!isInternalMember!member) {
                  static if (__traits(hasMember, To, member)) {
                    // Skip non-public fields (e.g., package-scoped _normalizedSource)
                    static if (__traits(compiles, __traits(getVisibility, __traits(getMember, From, member))) &&
                               __traits(getVisibility, __traits(getMember, From, member)) == "public") {
                        static if (__traits(compiles, __traits(getMember, from, member)) &&
                                   __traits(compiles, __traits(getMember, to, member) = __traits(getMember, from, member))) {
                            __traits(getMember, to, member) = __traits(getMember, from, member);
                        }
                    }
                  }
                }
            }}
            // Wrap: To stores its immediate source as _normalizedSource (per-layer);
            // when From is deeper in To's chain, build the intermediate layers.
            static if (__traits(hasMember, To, "_normalizedSource")) {
                static if (is(typeof(To._normalizedSource) == From))
                    to._normalizedSource = from;
                else static if (isInChain!(typeof(To._normalizedSource), From))
                    to._normalizedSource = entityCastValue!(typeof(To._normalizedSource), From)(from);
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
