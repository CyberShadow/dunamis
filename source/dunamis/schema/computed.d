/// Computed fields from free functions.
///
/// `ComputedFieldsPlugin!(Sources)` attaches free functions of the form
/// `auto field(Expr!Entity e, args...)` to the schema type built from `Entity`,
/// as if they had been declared on the entity itself. Sources are modules
/// and/or function symbols; a module contributes every public function it
/// declares whose first parameter is an `Expr`. Keep helpers non-public.
///
/// Example:
/// ---
/// // fields.d
/// auto fullName(Expr!User u) => u.firstName ~ " " ~ u.lastName;
///
/// // schema composition
/// alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation),
///     FilterPlugin, SortingPlugin, PaginationPlugin,
///     ComputedFieldsPlugin!(fields),
/// );
/// ---
///
/// Functions are written against the user-declared entity types and see them
/// unchanged (`u.posts` is `Expr!(Post[])`), regardless of where the plugin is
/// placed in the chain. Entity results are mapped to the current schema level.
module dunamis.schema.computed;

import std.meta : AliasSeq, Filter, staticMap;
import std.traits : Parameters;

import dunamis.core.discovery : extractObjectFromType, getAllObjectTypes;
import dunamis.core.expr : ExprResultType, isExpr;
import dunamis.core.types : isAbstractType, isInternalMember;
import dunamis.graphql.schema.udas : getGraphQLTypeName;
import dunamis.schema.entity_cast : BaseEntityOf;
import dunamis.schema.plugin : isSchema, NormalizeFields, OriginalName, RemapTypeAttributes, WrapFields, ForwardField;
import dunamis.schema.transform : isTypeInList;

// Fully qualified in generated code, so that entity field names cannot shadow them.
static import std.traits;
static import dunamis.core.expr;
static import dunamis.schema.computed;
static import dunamis.schema.entity_cast;
static import dunamis.schema.transform;

// ============================================================================
// Field discovery
// ============================================================================

/// The free functions contributed by Sources (modules and/or function symbols).
template computedFieldsIn(Sources...) {
    alias computedFieldsIn = staticMap!(_fieldsOf, Sources);
}

/// The user-declared entity type a computed field function attaches to.
template ComputedFieldEntity(alias fn) {
    alias ComputedFieldEntity = BaseEntityOf!(ExprResultType!(Parameters!fn[0]));
}

// Nested static ifs: D may resolve both operands of `&&` during template expansion.
private template _isFieldFunction(alias fn) {
    static if (is(typeof(fn) == function) && Parameters!fn.length >= 1)
        enum bool _isFieldFunction = isExpr!(Parameters!fn[0]);
    else
        enum bool _isFieldFunction = false;
}

private template _fieldsOf(alias source) {
    static if (__traits(isModule, source)) {
        alias _fieldsOf = staticMap!(_ApplyModule!source._declaredFields, __traits(allMembers, source));
    } else {
        static assert(_isFieldFunction!source,
            __traits(identifier, source) ~ " is not a computed field function (first parameter must be an Expr)");
        alias _fieldsOf = source;
    }
}

private template _ApplyModule(alias M) {
    // Public field functions declared in M itself (not imported into it).
    template _declaredFields(string name) {
        static if (isInternalMember!name || !__traits(compiles, __traits(getOverloads, M, name))) {
            alias _declaredFields = AliasSeq!();
        } else {
            alias _declaredFields = Filter!(_isDeclaredField, __traits(getOverloads, M, name));
        }
    }

    template _isDeclaredField(alias fn) {
        static if (__traits(isSame, __traits(parent, fn), M) && __traits(getVisibility, fn) == "public")
            enum bool _isDeclaredField = _isFieldFunction!fn;
        else
            enum bool _isDeclaredField = false;
    }
}

// ============================================================================
// Code Generation
// ============================================================================

/// Code template for one computed field method on a schema wrapper struct.
/// `fnRef` names the field function at the mixin site; `ResultTypeMap` there maps
/// result types to the current schema level.
template ComputedFieldCode(alias fn, string fnRef) {
    import std.conv : to;
    import std.traits : ParameterDefaults, ParameterIdentifierTuple;

    private enum string[] names = [ParameterIdentifierTuple!fn];

    enum ComputedFieldCode = () {
        string params = "dunamis.core.expr.Expr!(typeof(this)) " ~ names[0];
        string args = "dunamis.schema.entity_cast.pluginEntityCast!(" ~
            "dunamis.schema.computed.ComputedFieldEntity!(" ~ fnRef ~ "))(" ~ names[0] ~ ")";
        static foreach (i; 1 .. names.length) {
            params ~= ", std.traits.Parameters!(" ~ fnRef ~ ")[" ~ i.to!string ~ "] " ~ names[i];
            static if (!is(ParameterDefaults!fn[i] == void))
                params ~= " = std.traits.ParameterDefaults!(" ~ fnRef ~ ")[" ~ i.to!string ~ "]";
            args ~= ", " ~ names[i];
        }
        return "@(__traits(getAttributes, " ~ fnRef ~ ")) " ~
            "static auto " ~ __traits(identifier, fn) ~ "(" ~ params ~ ") { " ~
            "return dunamis.schema.transform.wrapEntityResult!(ResultTypeMap)(" ~
            fnRef ~ "(" ~ args ~ ")); }\n";
    }();
}

// ============================================================================
// Plugin
// ============================================================================

/// Plugin that adds computed fields defined as free functions.
///
/// Every object type is re-wrapped (like `FieldOverridePlugin`), so that types
/// referencing an extended type see the extended version. Fields are matched
/// to schema types by the user-declared type at the bottom of each wrapper
/// chain, so the plugin works at any position in `ApplyPlugins`.
///
/// Place it after `FilterPlugin` and `SortingPlugin`: those plugins treat
/// every scalar field as a column, and a filter on a computed field (which has
/// no column) is currently skipped silently.
template ComputedFieldsPlugin(Sources...) {
    private alias _fields = computedFieldsIn!Sources;

    template ComputedFieldsPlugin(alias S) if (isSchema!S) {
        alias _AllTypes = getAllObjectTypes!(S.Query);

        template _isLayerOf(Base) {
            enum bool _isLayerOf(T) = is(BaseEntityOf!T == Base);
        }

        static foreach (fn; _fields) {
            static assert(Filter!(_isLayerOf!(ComputedFieldEntity!fn), _AllTypes).length > 0,
                "Computed field " ~ __traits(identifier, fn) ~ ": " ~
                ComputedFieldEntity!fn.stringof ~ " is not part of the schema");
        }

        template _appliesTo(T) {
            enum bool _appliesTo(alias fn) = is(ComputedFieldEntity!fn == BaseEntityOf!T);
        }

        template WithComputed(T) {
            alias _ownFields = Filter!(_appliesTo!T, _fields);

            static foreach (fn; _ownFields) {
                static assert(!__traits(hasMember, T, __traits(identifier, fn)),
                    "Computed field " ~ __traits(identifier, fn) ~ " collides with an existing field of " ~
                    getGraphQLTypeName!T);
            }

            @(RemapTypeAttributes!(EntityTypeMap, __traits(getAttributes, T)))
            @OriginalName(getGraphQLTypeName!T)
            struct WithComputed {
                mixin WrapFields!(T, EntityTypeMap, ForwardField);
                static foreach (i, fn; _ownFields) {
                    mixin(ComputedFieldCode!(fn, "_ownFields[" ~ i.stringof ~ "]"));
                }
            }
        }

        /// Maps every discovered object type to its extended version.
        template EntityTypeMap(T) {
            static if (isTypeInList!(T, _AllTypes)) {
                alias EntityTypeMap = WithComputed!T;
            } else {
                alias EntityTypeMap = T;
            }
        }

        /// Maps a computed field's result type (at any layer of a schema type's
        /// chain, typically the user-declared one) to the extended version.
        /// Object types that are not part of the schema (POD types that only
        /// computed fields return) are normalized here, as Schema normalizes
        /// the types it discovers. Other types pass through unchanged.
        template ResultTypeMap(R) {
            alias _matches = Filter!(_isLayerOf!(BaseEntityOf!R), _AllTypes);
            static if (_matches.length > 0)
                alias ResultTypeMap = EntityTypeMap!(_matches[0]);
            else static if (is(extractObjectFromType!R == R) && !isAbstractType!R)
                alias ResultTypeMap = _ResultOnlyType!R;
            else
                alias ResultTypeMap = R;
        }

        template _ResultOnlyType(R) {
            @(RemapTypeAttributes!(ResultTypeMap, __traits(getAttributes, R)))
            @OriginalName(getGraphQLTypeName!R)
            struct _ResultOnlyType {
                mixin NormalizeFields!(R, ResultTypeMap);
            }
        }

        static if (__traits(hasMember, S, "AllEntityTypes"))
            alias AllEntityTypes = staticMap!(EntityTypeMap, S.AllEntityTypes);

        struct ComputedQuery {
            mixin WrapFields!(S.Query, EntityTypeMap, ForwardField);
        }

        struct ComputedMutation {
            mixin WrapFields!(S.Mutation, EntityTypeMap, ForwardField);
        }

        struct ComputedSubscription {
            mixin WrapFields!(S.Subscription, EntityTypeMap, ForwardField);
        }

        alias Query = ComputedQuery;
        alias Mutation = ComputedMutation;
        alias Subscription = ComputedSubscription;
    }
}
