/// Computed fields from free functions.
///
/// `ComputedFieldsPlugin!(Sources)` attaches free functions of the form
/// `auto field(Expr!Entity e, args...)` to the schema type built from `Entity`,
/// as if they had been declared on the entity itself. Sources are modules,
/// function symbols and/or field sets; a module contributes every public
/// function it declares whose first parameter is an `Expr`, a function symbol
/// all its overloads that do, and a field set (a struct) the sources it has
/// public aliases of and the public static field functions it declares. Keep
/// helpers non-public.
///
/// The names of all types and functions the plugin and the plugins after it
/// generate include the plugin's sources, and so grow with their number (for
/// a function symbol, by its name and type). Where there are many, a field
/// set naming them keeps these names short, which saves compiler memory:
/// ---
/// struct AppFields {
///     alias users = app.fields.users;    // a module
///     alias fullName = app.fullName;      // a function
/// }
/// alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation),
///     ComputedFieldsPlugin!AppFields, FilterPlugin, SortingPlugin, PaginationPlugin);
/// ---
///
/// Example:
/// ---
/// // fields.d
/// auto fullName(Expr!User u) => u.firstName ~ " " ~ u.lastName;
///
/// // schema composition
/// alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation),
///     ComputedFieldsPlugin!(fields),
///     FilterPlugin, SortingPlugin, PaginationPlugin,
/// );
/// ---
///
/// Like every plugin, it works with the types of the schema it is applied to.
/// A function is attached to the type of that schema it is written against,
/// or to the type of that schema which directly wraps it: placed straight
/// after `Schema!`, whose types normalize the user-declared ones, functions
/// are written against the user-declared types (as computed fields declared
/// on an entity are) and see them unchanged (`u.posts` is `Expr!(Post[])`).
/// Their results are mapped to the schema's types likewise. The root types
/// are types of the schema like any other: `auto field(Expr!Query q, ...)`
/// and `auto field(Expr!Mutation m, ...)` are root fields.
module dunamis.schema.computed;

import std.meta : AliasSeq, Filter, staticMap;
import std.traits : Parameters;

import dunamis.core.discovery : extractObjectFromType, getSchemaObjectTypes, SchemaRootTypes;
import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.core.types : IncludesTypes, isAbstractType, isInternalMember;
import dunamis.schema.plugin : isSchema, NormalizeFields, OriginalName, getOriginalTypeName, RemapTypeAttributes, WrapFields, ForwardField;
import dunamis.schema.transform : isTypeInList;

// Fully qualified in generated code, so that entity field names cannot shadow them.
static import std.traits;
static import dunamis.core.expr;
static import dunamis.schema.computed;
static import dunamis.schema.transform;

// ============================================================================
// Field discovery
// ============================================================================

/// The free functions contributed by Sources (modules, function symbols and/or field sets).
template computedFieldsIn(Sources...) {
    alias computedFieldsIn = staticMap!(_fieldsOf, Sources);
}

/// The abstract types (unions and interfaces, see ImplementedBy) declared
/// by Sources: the public ones declared in source modules, and those field
/// sets have public aliases of. Written against the user-declared types,
/// like the functions, they are types of the schema (see IncludesTypes),
/// whether or not a field returns them.
template abstractTypesIn(Sources...) {
    alias abstractTypesIn = staticMap!(_abstractTypesOf, Sources);
}

private template _abstractTypesOf(alias source) {
    static if (__traits(isModule, source)) {
        alias _abstractTypesOf = staticMap!(_ApplyModule!source._declaredAbstractTypes, __traits(allMembers, source));
    } else static if (is(source == struct) && isAbstractType!source) {
        alias _abstractTypesOf = AliasSeq!(source);
    } else static if (is(source == struct)) {
        alias _abstractTypesOf = staticMap!(_ApplyFieldSet!source._abstractTypesOfMember, __traits(allMembers, source));
    } else {
        alias _abstractTypesOf = AliasSeq!();
    }
}

/// The type a computed field function is written against (its first parameter's).
template ComputedFieldEntity(alias fn) {
    alias ComputedFieldEntity = ExprResultType!(Parameters!fn[0]);
}

/// Whether the schema type `T` stands for the type `E` a field function is
/// written against: `E` is `T`, or the type `T` directly wraps (for the types
/// `Schema!` produces, the user-declared type they normalize).
enum bool standsFor(T, E) = is(T == E) || is(typeof(T._normalizedSource) == E);

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
    } else static if (is(source == struct) && isAbstractType!source) {
        // (An abstract type, see abstractTypesIn)
        alias _fieldsOf = AliasSeq!();
    } else static if (is(source == struct)) {
        alias _fieldsOf = staticMap!(_ApplyFieldSet!source._sourcesOf, __traits(allMembers, source));
    } else {
        static assert(_isFieldFunction!source,
            __traits(identifier, source) ~ " is not a computed field function (first parameter must be an Expr)");
        // A function symbol stands for its whole overload set (e.g. one field
        // name declared for several entity types).
        alias _fieldsOf = Filter!(_isFieldFunction,
            __traits(getOverloads, __traits(parent, source), __traits(identifier, source)));
    }
}

private template _ApplyFieldSet(F) {
    // The fields of the public members of the field set F: of the modules
    // and field sets it has aliases of, and of the functions it declares or
    // has aliases of (each with its whole overload set).
    template _sourcesOf(string name) {
        static if (isInternalMember!name || __traits(getVisibility, __traits(getMember, F, name)) != "public") {
            alias _sourcesOf = AliasSeq!();
        } else static if (__traits(isModule, __traits(getMember, F, name)) ||
                          is(__traits(getMember, F, name) == struct)) {
            alias _sourcesOf = _fieldsOf!(__traits(getMember, F, name));
        } else {
            alias _sourcesOf = Filter!(_isFieldFunction, __traits(getOverloads, F, name));
            static assert(_sourcesOf.length,
                F.stringof ~ "." ~ name ~ " is not a computed field source (a module, a field set, " ~
                "an abstract type or computed field functions)");
        }
    }

    // The abstract types of the public member `name` of F (see abstractTypesIn)
    template _abstractTypesOfMember(string name) {
        static if (isInternalMember!name || __traits(getVisibility, __traits(getMember, F, name)) != "public") {
            alias _abstractTypesOfMember = AliasSeq!();
        } else static if (__traits(isModule, __traits(getMember, F, name)) ||
                          is(__traits(getMember, F, name) == struct)) {
            alias _abstractTypesOfMember = _abstractTypesOf!(__traits(getMember, F, name));
        } else {
            alias _abstractTypesOfMember = AliasSeq!();
        }
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

    // Public abstract types declared in M itself (see abstractTypesIn).
    template _declaredAbstractTypes(string name) {
        static if (!isInternalMember!name && __traits(compiles, __traits(getMember, M, name)) &&
                   is(__traits(getMember, M, name) == struct)) {
            static if (__traits(isSame, __traits(parent, __traits(getMember, M, name)), M) &&
                       __traits(getVisibility, __traits(getMember, M, name)) == "public" &&
                       isAbstractType!(__traits(getMember, M, name)))
                alias _declaredAbstractTypes = AliasSeq!(__traits(getMember, M, name));
            else
                alias _declaredAbstractTypes = AliasSeq!();
        } else {
            alias _declaredAbstractTypes = AliasSeq!();
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

/// The argument field function `fn` is called with for `self`, an instance
/// of the plugin's wrapper of a schema type: cast to that schema type, and
/// from there to the type it wraps if `fn` is written against that one.
/// Each cast crosses a single layer.
auto fieldArgument(alias fn, W)(Expr!W self) {
    import dunamis.schema.entity_cast : pluginEntityCast;

    alias E = ComputedFieldEntity!fn;
    alias Input = typeof(W._normalizedSource);
    auto input = pluginEntityCast!Input(self);
    static if (is(Input == E))
        return input;
    else
        return pluginEntityCast!E(input);
}

/// Code template for one computed field method on a schema wrapper struct.
/// `fnRef` names the field function at the mixin site. There, `FieldTypeMap`
/// maps the types of the function's result to the types of the schema the
/// plugin is applied to, and `EntityTypeMap` those to the plugin's wrappers.
template ComputedFieldCode(alias fn, string fnRef) {
    import std.conv : to;
    import std.traits : ParameterDefaults, ParameterIdentifierTuple;

    private enum string[] names = [ParameterIdentifierTuple!fn];

    enum ComputedFieldCode = () {
        string params = "dunamis.core.expr.Expr!(typeof(this)) " ~ names[0];
        string args = "dunamis.schema.computed.fieldArgument!(" ~ fnRef ~ ")(" ~ names[0] ~ ")";
        static foreach (i; 1 .. names.length) {
            params ~= ", std.traits.Parameters!(" ~ fnRef ~ ")[" ~ i.to!string ~ "] " ~ names[i];
            static if (!is(ParameterDefaults!fn[i] == void))
                params ~= " = std.traits.ParameterDefaults!(" ~ fnRef ~ ")[" ~ i.to!string ~ "]";
            args ~= ", " ~ names[i];
        }
        return "@(__traits(getAttributes, " ~ fnRef ~ ")) " ~
            "static auto " ~ __traits(identifier, fn) ~ "(" ~ params ~ ") { " ~
            "return dunamis.schema.transform.wrapEntityResult!(EntityTypeMap)(" ~
            "dunamis.schema.transform.wrapEntityResult!(FieldTypeMap)(" ~
            fnRef ~ "(" ~ args ~ "))); }\n";
    }();
}

// ============================================================================
// Plugin
// ============================================================================

/// Plugin that adds computed fields defined as free functions.
///
/// Every object type is re-wrapped (like `FieldOverridePlugin`), so that types
/// referencing an extended type see the extended version. Each function is
/// attached to the type of the input schema that stands for (`standsFor`)
/// the type the function is written against.
///
/// Apply it straight after `Schema!`: functions are then written against the
/// user-declared types, and the plugins applied after it (`FilterPlugin`,
/// `SortingPlugin`, `PaginationPlugin`) treat computed fields like any other
/// field (offering filters and orderings on them, evaluated in memory where
/// they cannot be expressed in SQL).
template ComputedFieldsPlugin(Sources...) {
    private alias _fields = computedFieldsIn!Sources;
    private alias _abstractTypes = abstractTypesIn!Sources;

    template ComputedFieldsPlugin(alias S) if (isSchema!S) {
        // The schema's object types: its root types (functions written
        // against Query or Mutation are root fields), and those reachable
        // from them
        alias _AllTypes = AliasSeq!(SchemaRootTypes!S, getSchemaObjectTypes!S);

        template _standsFor(E) {
            enum bool _standsFor(T) = standsFor!(T, E);
        }

        static foreach (fn; _fields) {
            static assert(Filter!(_standsFor!(ComputedFieldEntity!fn), _AllTypes).length > 0,
                "Computed field " ~ __traits(identifier, fn) ~ ": " ~
                ComputedFieldEntity!fn.stringof ~ " is not a type of the schema ComputedFieldsPlugin " ~
                "is applied to, nor the type one of its types wraps (apply ComputedFieldsPlugin " ~
                "straight after Schema! for functions written against user-declared types)");
        }

        template _appliesTo(T) {
            enum bool _appliesTo(alias fn) = standsFor!(T, ComputedFieldEntity!fn);
        }

        template WithComputed(T) {
            alias _ownFields = Filter!(_appliesTo!T, _fields);

            static foreach (fn; _ownFields) {
                static assert(!__traits(hasMember, T, __traits(identifier, fn)),
                    "Computed field " ~ __traits(identifier, fn) ~ " collides with an existing field of " ~
                    getOriginalTypeName!T);
            }

            @(RemapTypeAttributes!(EntityTypeMap, __traits(getAttributes, T)))
            @(_includedTypes!T)
            @OriginalName(__traits(identifier, T))
            struct WithComputed {
                mixin WrapFields!(T, EntityTypeMap, ForwardField);
                static foreach (i, fn; _ownFields) {
                    mixin(ComputedFieldCode!(fn, "_ownFields[" ~ i.stringof ~ "]"));
                }
            }
        }

        /// The types the query root includes (see IncludesTypes): the
        /// abstract types of the sources, normalized as result-only types
        /// (so that their members are the schema's types).
        template _includedTypes(T) {
            static if (is(T == S.Query) && _abstractTypes.length > 0)
                alias _includedTypes = AliasSeq!(IncludesTypes!(staticMap!(EntityTypeMap,
                    staticMap!(_ResultOnlyType, _abstractTypes))));
            else
                alias _includedTypes = AliasSeq!();
        }

        /// Maps every object type of the input schema, and every result-only
        /// type (see FieldTypeMap), to its extended version.
        template EntityTypeMap(T) {
            static if (isTypeInList!(T, _AllTypes) || is(T == _ResultOnlyType!R, R)) {
                alias EntityTypeMap = WithComputed!T;
            } else {
                alias EntityTypeMap = T;
            }
        }

        /// Maps a type of a computed field's result to the type of the input
        /// schema standing for it. Object types that are not part of the
        /// schema (a POD only computed fields return, or an entity reached
        /// through a computed relation) are normalized here, as Schema
        /// normalizes the types it discovers, with their members mapped in
        /// turn, so that e.g. an entity member of a POD is the schema's
        /// entity type. Other types pass through unchanged.
        template FieldTypeMap(R) {
            alias _matches = Filter!(_standsFor!R, _AllTypes);
            static if (_matches.length > 0)
                alias FieldTypeMap = _matches[0];
            else static if (is(extractObjectFromType!R == R) && !isAbstractType!R)
                alias FieldTypeMap = _ResultOnlyType!R;
            else
                alias FieldTypeMap = R;
        }

        template _ResultOnlyType(R) {
            @(RemapTypeAttributes!(FieldTypeMap, __traits(getAttributes, R)))
            @OriginalName(__traits(identifier, R))
            struct _ResultOnlyType {
                mixin NormalizeFields!(R, FieldTypeMap);
            }
        }

        static if (__traits(hasMember, S, "AllEntityTypes"))
            alias AllEntityTypes = staticMap!(EntityTypeMap, S.AllEntityTypes);

        alias Query = EntityTypeMap!(S.Query);
        alias Mutation = EntityTypeMap!(S.Mutation);
        alias Subscription = EntityTypeMap!(S.Subscription);
    }
}
