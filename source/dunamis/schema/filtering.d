/// Filtering plugin for GraphQL schemas.
///
/// The FilterPlugin automatically adds `filter` arguments to all array-returning
/// fields in the Query type and entity types (HasMany relationships).
///
/// Example:
/// ---
/// alias BaseSchema = Schema!Query;
/// alias FilteredSchema = FilterPlugin!BaseSchema;
///
/// // users: [User!]! becomes users(filter: UserFilter): [User!]!
/// ---
module dunamis.schema.filtering;

import std.traits : ReturnType, Parameters, ParameterDefaults, ParameterIdentifierTuple;
import std.typecons : Nullable;
import std.json : JSONValue, JSONType;
import std.conv : to;
import std.algorithm : canFind;

import dunamis.core.expr : Expr, ExprResultType, ExprBase;
import dunamis.core.types : isCustomScalar, isPublicMember;
import dunamis.core.filtering : filterBy, FilterByExpr, FilterItemExpr, FilterByInfo;
import dunamis.schema.plugin;
import dunamis.graphql.schema.udas : GqlName;
// isSchema imported via dunamis.schema.plugin wildcard import above

// ============================================================================
// Scalar Filter Input Types (connection-filter style)
// ============================================================================

/// String filter input type.
/// Supports equality, comparison, and pattern matching operations, named
/// and behaving as those of PostGraphile's connection filter: `includes`,
/// `startsWith` and `endsWith` match their operand literally (`%`, `_` and
/// `\` in it are escaped), `like` takes a SQL LIKE pattern (`%` matches any
/// characters, `_` any one character, `\` escapes the next character); the
/// `Insensitive` forms ignore case (ILIKE in PostgreSQL), and the `not`
/// forms negate. (On a nullable column, they only match non-null values.)
struct StringFilter {
    Nullable!string equalTo;
    Nullable!string notEqualTo;
    @GqlName("in") Nullable!(string[]) in_;
    Nullable!(string[]) notIn;
    Nullable!string lessThan;
    Nullable!string lessThanOrEqualTo;
    Nullable!string greaterThan;
    Nullable!string greaterThanOrEqualTo;
    Nullable!string includes;
    Nullable!string notIncludes;
    Nullable!string includesInsensitive;
    Nullable!string notIncludesInsensitive;
    Nullable!string startsWith;
    Nullable!string notStartsWith;
    Nullable!string startsWithInsensitive;
    Nullable!string notStartsWithInsensitive;
    Nullable!string endsWith;
    Nullable!string notEndsWith;
    Nullable!string endsWithInsensitive;
    Nullable!string notEndsWithInsensitive;
    Nullable!string like;
    Nullable!string notLike;
    Nullable!string likeInsensitive;
    Nullable!string notLikeInsensitive;
    Nullable!string equalToInsensitive;
    Nullable!string notEqualToInsensitive;
    Nullable!bool isNull;
}

/// Int filter input type.
/// Supports equality and comparison operations.
struct IntFilter {
    Nullable!int equalTo;
    Nullable!int notEqualTo;
    @GqlName("in") Nullable!(int[]) in_;
    Nullable!(int[]) notIn;
    Nullable!int lessThan;
    Nullable!int lessThanOrEqualTo;
    Nullable!int greaterThan;
    Nullable!int greaterThanOrEqualTo;
    Nullable!bool isNull;
}

/// Long filter input type.
/// Supports equality and comparison operations.
struct LongFilter {
    Nullable!long equalTo;
    Nullable!long notEqualTo;
    @GqlName("in") Nullable!(long[]) in_;
    Nullable!(long[]) notIn;
    Nullable!long lessThan;
    Nullable!long lessThanOrEqualTo;
    Nullable!long greaterThan;
    Nullable!long greaterThanOrEqualTo;
    Nullable!bool isNull;
}

/// Float filter input type.
/// Supports equality and comparison operations.
struct FloatFilter {
    Nullable!double equalTo;
    Nullable!double notEqualTo;
    @GqlName("in") Nullable!(double[]) in_;
    Nullable!(double[]) notIn;
    Nullable!double lessThan;
    Nullable!double lessThanOrEqualTo;
    Nullable!double greaterThan;
    Nullable!double greaterThanOrEqualTo;
    Nullable!bool isNull;
}

/// Boolean filter input type.
/// Supports equality and set membership operations.
struct BooleanFilter {
    Nullable!bool equalTo;
    Nullable!bool notEqualTo;
    @GqlName("in") Nullable!(bool[]) in_;
    Nullable!(bool[]) notIn;
    Nullable!bool isNull;
}

/// Enum filter input type template.
/// Generates a filter type for any D enum with equality and set membership operations.
template EnumFilter(E) if (is(E == enum)) {
    @NamedAfter!E("Filter")
    struct EnumFilter {
        Nullable!E equalTo;
        Nullable!E notEqualTo;
        @GqlName("in") Nullable!(E[]) in_;
        Nullable!(E[]) notIn;
        Nullable!bool isNull;

        /// Formats as the filter type's name (see EntityFilter.toString):
        /// formatting the fields would compile the formatting of `E`.
        void toString(scope void delegate(const(char)[]) sink) const {
            enum name = getOriginalTypeName!(typeof(this));
            sink(name);
        }
    }
}

/// The filter input type of custom scalars ordered by their values (see
/// `isOrderedCustomScalar`): `<Scalar>Filter` (e.g. DateFilter), with the
/// operands values of the scalar.
template ScalarFilter(T) if (isOrderedCustomScalar!T) {
    @NamedAfter!T("Filter")
    struct ScalarFilter {
        Nullable!T equalTo;
        Nullable!T notEqualTo;
        @GqlName("in") Nullable!(T[]) in_;
        Nullable!(T[]) notIn;
        Nullable!T lessThan;
        Nullable!T lessThanOrEqualTo;
        Nullable!T greaterThan;
        Nullable!T greaterThanOrEqualTo;
        Nullable!bool isNull;

        /// Formats as the filter type's name (see EntityFilter.toString).
        void toString(scope void delegate(const(char)[]) sink) const {
            enum name = getOriginalTypeName!(typeof(this));
            sink(name);
        }
    }
}

/// The operators of the filters of array fields (lists of nullable values of
/// type `T`, e.g. array columns), named and behaving as those of
/// PostGraphile's connection filter (PostgreSQL's array operators; null
/// elements match nothing): see `ArrayFilter`.
mixin template ArrayFilterOperators(T) {
    Nullable!bool isNull;
    /// The array is equal to this one (element by element; null elements
    /// are equal to each other, as in PostgreSQL's array equality)
    Nullable!(Nullable!T[]) equalTo;
    /// The array is not equal to this one
    Nullable!(Nullable!T[]) notEqualTo;
    /// The array contains all these values
    Nullable!(Nullable!T[]) contains;
    /// All the array's elements are among these values
    Nullable!(Nullable!T[]) containedBy;
    /// The array has an element in common with these values
    Nullable!(Nullable!T[]) overlaps;
    /// An element of the array is equal to this value
    Nullable!T anyEqualTo;
    /// An element of the array is not equal to this value
    Nullable!T anyNotEqualTo;
}

/// The filters of array fields of built-in value types (see `ArrayFilter`).
struct IntListFilter { mixin ArrayFilterOperators!int; }
/// ditto
struct LongListFilter { mixin ArrayFilterOperators!long; }
/// ditto
struct FloatListFilter { mixin ArrayFilterOperators!double; }
/// ditto
struct StringListFilter { mixin ArrayFilterOperators!string; }
/// ditto
struct BooleanListFilter { mixin ArrayFilterOperators!bool; }

/// The filter input type of array fields whose values are lists of
/// nullable values of type `T` (e.g. array columns): `<T>ListFilter`, with
/// the operators `contains`, `containedBy`, `overlaps`, `anyEqualTo`,
/// `anyNotEqualTo` and `isNull` (see `ArrayFilterOperators`); void if there
/// is none for such values.
template ArrayFilter(T) {
    static if (is(T == enum)) {
        @NamedAfter!T("ListFilter")
        struct ArrayFilter {
            mixin ArrayFilterOperators!T;

            /// Formats as the filter type's name (see EnumFilter.toString).
            void toString(scope void delegate(const(char)[]) sink) const {
                enum name = getOriginalTypeName!(typeof(this));
                sink(name);
            }
        }
    } else static if (is(T == int))
        alias ArrayFilter = IntListFilter;
    else static if (is(T == long))
        alias ArrayFilter = LongListFilter;
    else static if (is(T == double))
        alias ArrayFilter = FloatListFilter;
    else static if (is(T == string))
        alias ArrayFilter = StringListFilter;
    else static if (is(T == bool))
        alias ArrayFilter = BooleanListFilter;
    else
        alias ArrayFilter = void;
}

/// UDA on a value type declaring the filter input type `Filter` by which
/// columns (and other fields) of the type are filtered, for a type with
/// filter operators of its own (e.g. a range type, with containment).
///
/// `Filter` is an input struct with the operators as its fields, and an
/// optional `Nullable!bool isNull` (handled like that of the built-in
/// column filters). Its member function
/// ---
/// Expr!bool condition(V)(Expr!V value, ExprBase lengthSource) const
/// ---
/// builds the condition its other operators put on non-null values, or
/// returns null if they put none. `V` is the schema type standing for the
/// value type at the filter plugin's position (a wrapper of the declared
/// type, which carries its attributes and has its fields as field methods),
/// and `lengthSource` the expression constants of the condition take their
/// length from.
///
/// Example:
/// ---
/// @FilteredBy!SpanFilter
/// struct Span { int from; int to; }
///
/// struct SpanFilter {
///     Nullable!int contains;
///     Nullable!bool isNull;
///     Expr!bool condition(V)(Expr!V span, ExprBase lengthSource) const {
///         if (contains.isNull) return null;
///         auto point = constant(contains.get, lengthSource);
///         return V.from(span).le(point).and(point.lt(V.to(span)));
///     }
/// }
/// ---
struct FilteredBy(Filter) {}

/// Whether `T` is a custom scalar whose values compare with each other, so
/// that it is filtered by a `StringFilter` (its operands deserialized as
/// values of `T`). Other custom scalars, e.g. one wrapping a type whose
/// comparison operators its `alias this` does not reach, are not filtered
/// (unless they declare a filter with `@FilteredBy`).
template isOrderedCustomScalar(T) {
    import dunamis.core.types : isCustomScalar;
    static if (isCustomScalar!T)
        // (Compared as lvalues, as evaluation does: e.g. std.bigint.BigInt
        // compares rvalues but not lvalues through alias this.)
        enum bool isOrderedCustomScalar = __traits(compiles, { T a, b; bool r = a < b; r = a == b; });
    else
        enum bool isOrderedCustomScalar = false;
}

/// Whether values of type `T` are filtered by a filter type `T` declares
/// with `@FilteredBy`.
template hasDeclaredFilter(T) {
    import std.traits : hasUDA;
    static if (is(T == struct))
        enum bool hasDeclaredFilter = hasUDA!(T, FilteredBy);
    else
        enum bool hasDeclaredFilter = false;
}

/// The filter type `T` declares with `@FilteredBy`.
template DeclaredFilterType(T) if (hasDeclaredFilter!T) {
    import std.traits : getUDAs;
    static if (is(getUDAs!(T, FilteredBy)[0] == FilteredBy!F, F))
        alias DeclaredFilterType = F;
}

// ============================================================================
// Entity Filter Type Generation
// ============================================================================

/// Get filterable column names for an entity.
/// Returns columns that are scalar types (not FKs or relationships).
template getFilterableColumns(Entity) {
    import std.meta : AliasSeq;

    enum string[] getFilterableColumns = () {
        string[] columns;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (isPublicMember!(Entity, member) && isEntityColumnMethod!(Entity, member)) {
                columns ~= member;
            }
        }}
        return columns;
    }();
}

/// Get the names of the to-one object fields of an entity: fields taking no
/// arguments whose values are objects (e.g. `Post.author`, a relationship,
/// or a field of a value object type). They are filtered by the filter of
/// their object type; like every plugin, the filter treats all object types
/// alike, whatever their data source.
template getObjectFields(Entity) {
    enum string[] getObjectFields = () {
        string[] fields;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (isPublicMember!(Entity, member) && isObjectFieldMethod!(Entity, member))
                fields ~= member;
        }}
        return fields;
    }();
}

/// Check if a member is a field of `Entity` taking no arguments whose value is
/// an object (see getObjectFields).
template isObjectFieldMethod(Entity, string member) {
    static if (__traits(hasMember, Entity, member) &&
               __traits(compiles, typeof(__traits(getMember, Entity, member)))) {
        alias memberType = typeof(__traits(getMember, Entity, member));
        static if (is(memberType == function)) {
            alias params = Parameters!memberType;
            static if (params.length == 1 && is(params[0] == Expr!Entity) &&
                       is(ReturnType!memberType : Expr!T, T)) {
                import dunamis.core.types : isAbstractType;
                alias Target = ObjectFieldTargetType!(Entity, member);
                enum isObjectFieldMethod = !is(Target == U[], U) && isEntityType!Target &&
                    !isAbstractType!Target && !isFilterableType!Target;
            } else {
                enum isObjectFieldMethod = false;
            }
        } else {
            enum isObjectFieldMethod = false;
        }
    } else {
        enum isObjectFieldMethod = false;
    }
}

/// Check if a type is an object type (has fields/methods, not a scalar).
/// Used to distinguish entity/POD array elements (get nested ListFilter)
/// from scalar array elements (get ListFilter!ScalarFilter).
template isEntityType(T) {
    import dunamis.core.discovery : isObjectType;
    import dunamis.core.types : isCustomScalar;
    import std.typecons : Nullable;
    static if (is(T == Nullable!U, U))
        enum isEntityType = isEntityType!U;
    else
        enum isEntityType = !isCustomScalar!T && isObjectType!T;
}

/// Check if a member is an array-returning method (returns Expr!(T[]) for any T).
/// Used to generate some/every/none filters for collection fields.
/// Works for both entity arrays (User.posts -> Post[]) and scalar arrays (User.tags -> string[]).
/// Note: Excludes string columns since string is technically immutable(char)[] in D.
template isArrayReturningMethod(Entity, string member) {
    import std.traits : ReturnType, Parameters, isSomeFunction;

    // Only members with a type: not type or template members
    static if (__traits(hasMember, Entity, member) &&
               __traits(compiles, typeof(__traits(getMember, Entity, member)))) {
        alias memberType = typeof(__traits(getMember, Entity, member));
        // Use isSomeFunction to detect functions, function pointers, and delegates
        static if (isSomeFunction!memberType) {
            alias method = __traits(getMember, Entity, member);
            alias params = Parameters!method;

            // Must be callable with just one parameter that is some Expr!ParamT
            // (we check against Expr!Entity loosely since the Entity might have
            // different type identity across module boundaries).  Further
            // parameters must be optional: arguments added by earlier
            // plugins, e.g. orderBy/first/offset on a HasMany accessor.
            import std.traits : ParameterDefaults;
            enum bool restOptional = () {
                bool result = true;
                static foreach (i; 1 .. params.length)
                    static if (is(ParameterDefaults!method[i] == void))
                        result = false;
                return result;
            }();
            static if (params.length >= 1 && is(params[0] : Expr!ParamT, ParamT) && restOptional) {
                alias retType = ReturnType!method;
                alias resultType = ExprResultType!retType;

                // Match on the result type, not on retType itself: the
                // declared return type of a HasMany accessor is a concrete
                // Expr subclass (e.g. HasManyExpr, or MapExpr once a plugin
                // wrapped the entity), not the literal Expr!(T[]).
                // Exclude strings (immutable(char)[]) - scalars, not array fields
                import std.traits : isSomeString;
                import dunamis.core.types : isCustomScalar;
                static if (!isCustomScalar!resultType &&
                           is(resultType : ElementT[], ElementT) &&
                           !isSomeString!resultType) {
                    enum isArrayReturningMethod = true;
                } else {
                    enum isArrayReturningMethod = false;
                }
            } else {
                enum isArrayReturningMethod = false;
            }
        } else {
            enum isArrayReturningMethod = false;
        }
    } else {
        enum isArrayReturningMethod = false;
    }
}

/// Check if an array field returns entity elements (has @PrimaryKey).
template isEntityArrayField(Entity, string member) {
    static if (isArrayReturningMethod!(Entity, member)) {
        alias ElementT = getArrayElementType!(Entity, member);
        import std.typecons : Nullable;
        // Lists of nullable objects are not filtered, like lists of
        // nullable scalars (see isScalarArrayField).
        static if (is(ElementT == Nullable!U, U))
            enum isEntityArrayField = false;
        else
            // Lists of values of a type with a declared filter are filtered
            // by that filter (see isScalarArrayField), like single values,
            // not by an EntityFilter of the type's fields.
            enum isEntityArrayField = isEntityType!ElementT && !hasDeclaredFilter!ElementT;
    } else {
        enum isEntityArrayField = false;
    }
}

/// Check if an array field returns scalar elements (not entities).
template isScalarArrayField(Entity, string member) {
    static if (isArrayReturningMethod!(Entity, member)) {
        alias ElementT = getArrayElementType!(Entity, member);
        import std.typecons : Nullable;
        // Nullable collection elements need lifted comparison expressions;
        // until those are available, keep the collection queryable without
        // advertising a filter the executor cannot evaluate correctly.
        static if (is(ElementT == Nullable!U, U))
            enum isScalarArrayField = false;
        else
            enum isScalarArrayField = !isEntityType!ElementT || hasDeclaredFilter!ElementT;
    } else {
        enum isScalarArrayField = false;
    }
}

/// Check if a field of `Entity` is an array field of nullable values of a
/// type with an `ArrayFilter` (e.g. an array column), filtered by it.
template isNullableArrayField(Entity, string member) {
    static if (isArrayReturningMethod!(Entity, member)) {
        alias ElementT = getArrayElementType!(Entity, member);
        import std.typecons : Nullable;
        static if (is(ElementT == Nullable!U, U))
            enum isNullableArrayField = !is(ArrayFilter!U == void);
        else
            enum isNullableArrayField = false;
    } else {
        enum isNullableArrayField = false;
    }
}

/// Get the names of the array fields of nullable values (see
/// isNullableArrayField) of an entity.
template getNullableArrayFields(Entity) {
    enum string[] getNullableArrayFields = () {
        string[] fields;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (isPublicMember!(Entity, member) && isNullableArrayField!(Entity, member)) {
                fields ~= member;
            }
        }}
        return fields;
    }();
}

/// The value type of the elements of an array field of nullable values.
template NullableArrayValueType(Entity, string member) {
    import std.typecons : Nullable;
    static if (is(getArrayElementType!(Entity, member) == Nullable!U, U))
        alias NullableArrayValueType = U;
}

/// Get array-returning field names for an entity.
template getArrayFields(Entity) {
    enum string[] getArrayFields = () {
        string[] fields;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (isPublicMember!(Entity, member) && isArrayReturningMethod!(Entity, member)) {
                fields ~= member;
            }
        }}
        return fields;
    }();
}

/// Get entity array field names (arrays of entities with @PrimaryKey).
template getEntityArrayFields(Entity) {
    enum string[] getEntityArrayFields = () {
        string[] fields;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (isPublicMember!(Entity, member) && isEntityArrayField!(Entity, member)) {
                fields ~= member;
            }
        }}
        return fields;
    }();
}

/// Get scalar array field names (arrays of non-entity types like string[], int[]).
template getScalarArrayFields(Entity) {
    enum string[] getScalarArrayFields = () {
        string[] fields;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (isPublicMember!(Entity, member) && isScalarArrayField!(Entity, member)) {
                fields ~= member;
            }
        }}
        return fields;
    }();
}

/// Extract the element entity type from an array-returning method.
template getArrayElementType(Entity, string member) {
    import std.traits : ReturnType;

    alias method = __traits(getMember, Entity, member);
    // The declared return type may be a concrete Expr subclass rather than
    // the literal Expr!(T[]), so match on the result type (as
    // isArrayReturningMethod does).
    alias resultType = ExprResultType!(ReturnType!method);
    static if (is(resultType : T[], T)) {
        alias getArrayElementType = T;
    } else {
        static assert(false, "Method " ~ member ~ " does not return Expr!(T[])");
    }
}

/// The filter input type of a column whose values are of type `T`, or void if
/// such columns cannot be filtered. A nullable column shares the filter type
/// of its values; its `isNull` operator tests for null.
template ColumnFilterType(T) {
    static if (is(T == Nullable!U, U)) {
        alias ColumnFilterType = ColumnFilterType!U;
    } else static if (hasDeclaredFilter!T) {
        alias ColumnFilterType = DeclaredFilterType!T;
    } else static if (isOrderedCustomScalar!T) {
        alias ColumnFilterType = ScalarFilter!T;
    } else static if (is(T == enum)) {
        alias ColumnFilterType = EnumFilter!T;
    } else static if (is(T == string)) {
        alias ColumnFilterType = StringFilter;
    } else static if (is(T == int)) {
        alias ColumnFilterType = IntFilter;
    } else static if (is(T == long)) {
        alias ColumnFilterType = LongFilter;
    } else static if (is(T == float) || is(T == double)) {
        alias ColumnFilterType = FloatFilter;
    } else static if (is(T == bool)) {
        alias ColumnFilterType = BooleanFilter;
    } else {
        alias ColumnFilterType = void;
    }
}

/// The value type of a column method of `Entity`.
template ColumnValueType(Entity, string member) {
    alias ColumnValueType = ExprResultType!(ReturnType!(__traits(getMember, Entity, member)));
}

/// The object type of a to-one object field of `Entity` (without the
/// Nullable of an optional one).
template ObjectFieldTargetType(Entity, string member) {
    alias Result = ExprResultType!(ReturnType!(__traits(getMember, Entity, member)));
    static if (is(Result == Nullable!P, P))
        alias ObjectFieldTargetType = P;
    else
        alias ObjectFieldTargetType = Result;
}

/// List filter for scalar array fields with some/every/none operators.
/// Uses pointers to avoid Nullable initialization issues with complex nested types.
template ListFilter(ChildFilter) {
    @NamedAfter!ChildFilter("ListFilter")
    struct ListFilter {
        /// At least one element matches the filter
        ChildFilter* some;
        /// All elements match the filter
        ChildFilter* every;
        /// No element matches the filter (equivalent to not(some(...)))
        ChildFilter* none;
    }
}

/// List filter for to-many relationships (entity array fields) of `Parent`
/// to `Child`: which of the related entities must match the related
/// entity's filter. Named as PostGraphile's connection filter names them,
/// `<Parent>ToMany<Child>Filter` (without completing the, possibly cyclic,
/// filter types).
template EntityListFilter(Parent, Child) {
    @NamedAfterTwo!(Parent, Child)("ToMany", "Filter")
    struct EntityListFilter {
        /// At least one related entity matches the filter
        EntityFilter!Child* some;
        /// All related entities match the filter
        EntityFilter!Child* every;
        /// No related entity matches the filter (equivalent to not(some(...)))
        EntityFilter!Child* none;
    }
}

/// The filter input type of an entity: its filterable columns, its
/// relationships (to-one relationships by the related entity's own filter,
/// to-many relationships by an `EntityListFilter`), its scalar array fields,
/// and the logical combinators `and`, `or` and `not`.
///
/// Relationship filters refer to the related entities' `EntityFilter`s, to
/// any depth. Cycles in the schema (e.g. `User.posts` / `Post.author`) are
/// fine: relationships are referenced through pointers, and each entity has
/// exactly one filter type, which is only instantiated when first used.
///
/// Example: EntityFilter!User has the fields
/// ```
/// Nullable!StringFilter firstName;
/// Nullable!(EnumFilter!Role) role;
/// EntityFilter!Department* department;          // belongs-to
/// EntityListFilter!(User, Post)* posts;         // has-many
/// Nullable!(ListFilter!StringFilter) tags;      // scalar array
/// Nullable!(EntityFilter!User[]) and, or;
/// EntityFilter!User* not;
/// ```
template EntityFilter(Entity) {
    @NamedAfter!Entity("Filter")
    struct EntityFilter {
        mixin(entityFilterFieldsCode!Entity);

        Nullable!(typeof(this)[]) and;
        Nullable!(typeof(this)[]) or;
        typeof(this)* not;

        /// Formats as the filter type's name. Phobos compiles `toString` of
        /// every `Nullable!T` (e.g. of `and`), which would otherwise compile the
        /// formatting of every field of every filter type.
        void toString(scope void delegate(const(char)[]) sink) const {
            enum name = getOriginalTypeName!(typeof(this));
            sink(name);
        }
    }
}

/// The declarations of the column, relationship and scalar array fields of
/// `EntityFilter!Entity`. Fields are named like the entity's fields, and
/// carry their attributes.
private template entityFilterFieldsCode(Entity) {
    enum entityFilterFieldsCode = () {
        string code;
        // A filter field carries the attributes of the entity field it
        // filters (e.g. a presentation name).
        string attributes(string member)() {
            return "@(__traits(getAttributes, __traits(getMember, Entity, \"" ~ member ~ "\"))) ";
        }

        static foreach (member; getFilterableColumns!Entity) {
            code ~= attributes!member ~ "Nullable!(ColumnFilterType!(ColumnValueType!(Entity, \"" ~
                member ~ "\"))) " ~ member ~ ";\n";
        }

        static foreach (member; getObjectFields!Entity) {
            code ~= attributes!member ~ "EntityFilter!(ObjectFieldTargetType!(Entity, \"" ~
                member ~ "\"))* " ~ member ~ ";\n";
        }

        static foreach (member; getEntityArrayFields!Entity) {
            code ~= attributes!member ~ "EntityListFilter!(Entity, getArrayElementType!(Entity, \"" ~
                member ~ "\"))* " ~ member ~ ";\n";
        }

        static foreach (member; getNullableArrayFields!Entity) {
            code ~= attributes!member ~ "Nullable!(ArrayFilter!(NullableArrayValueType!(Entity, \"" ~
                member ~ "\"))) " ~ member ~ ";\n";
        }

        static foreach (member; getScalarArrayFields!Entity) {{
            alias ElemType = getArrayElementType!(Entity, member);
            // Enum arrays need an EnumFilter-aware collection predicate. Until
            // that predicate is available, keep the field queryable but do not
            // advertise a type-incorrect filter for it.
            static if (!is(ElemType == enum) && !is(ColumnFilterType!ElemType == void))
                code ~= attributes!member ~ "Nullable!(ListFilter!(ColumnFilterType!(getArrayElementType!(Entity, \"" ~
                    member ~ "\")))) " ~ member ~ ";\n";
        }}
        return code;
    }();
}

// ============================================================================
// Filter Predicate Building (Typed Filter -> Expr!bool)
// ============================================================================

/// Build an Expr!bool predicate from an entity filter.
/// This converts the connection-filter style nested filter to an expression tree.
/// The item can be any Expr!Entity (FilterItemExpr, EveryItemOfExpr, a
/// relationship of another item, etc.).
///
/// Relationship filters become predicates over the related entities: a
/// belongs-to filter tests the related entity (and does not match if there
/// is none), and a to-many filter becomes `some` (or its negations) over the
/// related entities.
Expr!bool buildFilterPredicateFromStruct(Entity)(Expr!Entity item, const ref EntityFilter!Entity filter) {
    import dunamis.core.expr : constant, EveryItemOfExpr, SomeExpr;
    import dunamis.core.expr.json : UnwrapNullableExpr;

    Expr!bool[] conditions;

    // Columns
    static foreach (member; getFilterableColumns!Entity) {{
        if (!__traits(getMember, filter, member).isNull) {
            alias colMethod = __traits(getMember, Entity, member);
            auto cond = buildColumnCondition(colMethod(item),
                __traits(getMember, filter, member).get, item, member);
            if (cond !is null)
                conditions ~= cond;
        }
    }}

    // To-one object fields (e.g. the relationship Post.author -> User).
    static foreach (member; getObjectFields!Entity) {{
        auto relationshipFilter = __traits(getMember, filter, member);
        if (relationshipFilter !is null) {
            alias relationshipMethod = __traits(getMember, Entity, member);
            auto relationshipExpr = relationshipMethod(item);
            alias Target = ObjectFieldTargetType!(Entity, member);
            static if (is(ExprResultType!(typeof(relationshipExpr)) == Nullable!Target)) {
                // A missing related row matches no relationship filter
                // (as with an EXISTS / joined-row predicate in SQL).
                Expr!(Nullable!Target) nullable = relationshipExpr;
                auto unwrapped = new UnwrapNullableExpr!Target(nullable);
                conditions ~= nullable.isNotNull().and(
                    buildFilterPredicateFromStruct!Target(unwrapped, *relationshipFilter));
            } else {
                Expr!Target related = relationshipExpr;
                conditions ~= buildFilterPredicateFromStruct!Target(related, *relationshipFilter);
            }
        }
    }}

    // To-many relationships (e.g. User.posts -> Post[]).
    static foreach (member; getEntityArrayFields!Entity) {{
        auto listFilterField = __traits(getMember, filter, member);
        if (listFilterField !is null) {
            auto listFilter = *listFilterField;
            alias ChildEntity = getArrayElementType!(Entity, member);
            alias arrayMethod = __traits(getMember, Entity, member);

            // Whether some child matches `childFilter` (or its negation).
            Expr!bool someChild(const ref EntityFilter!ChildEntity childFilter, bool negate) {
                Expr!(ChildEntity[]) collectionExpr = arrayMethod(item);
                auto childItem = new EveryItemOfExpr!ChildEntity();
                auto childPred = buildFilterPredicateFromStruct!ChildEntity(childItem, childFilter);
                if (negate)
                    childPred = childPred.not();
                auto someExpr = new SomeExpr!(ChildEntity, Expr!bool)(collectionExpr, childItem, childPred);
                return someExpr;
            }

            if (listFilter.some !is null)
                conditions ~= someChild(*listFilter.some, false);
            // every = not(some(not(pred)))
            if (listFilter.every !is null)
                conditions ~= someChild(*listFilter.every, true).not();
            // none = not(some(pred))
            if (listFilter.none !is null)
                conditions ~= someChild(*listFilter.none, false).not();
        }
    }}

    // Scalar array fields (e.g. User.tags -> string[])
    static foreach (member; getScalarArrayFields!Entity) {{
        static if (__traits(hasMember, EntityFilter!Entity, member)) {
            auto listFilterField = __traits(getMember, filter, member);
            if (!listFilterField.isNull) {
                auto listFilter = listFilterField.get;
                alias ElemType = getArrayElementType!(Entity, member);
                alias arrayMethod = __traits(getMember, Entity, member);

                Expr!bool someElement(F)(const ref F elementFilter, bool negate) {
                    Expr!(ElemType[]) collectionExpr = arrayMethod(item);
                    auto elemItem = new EveryItemOfExpr!ElemType();
                    Expr!bool elemPred = buildColumnCondition(cast(Expr!ElemType) elemItem,
                        elementFilter, elemItem, member);
                    if (elemPred is null)
                        elemPred = constant(true, elemItem);
                    if (negate)
                        elemPred = elemPred.not();
                    auto someExpr = new SomeExpr!(ElemType, Expr!bool)(collectionExpr, elemItem, elemPred);
                    return someExpr;
                }

                if (listFilter.some !is null)
                    conditions ~= someElement(*listFilter.some, false);
                if (listFilter.every !is null)
                    conditions ~= someElement(*listFilter.every, true).not();
                if (listFilter.none !is null)
                    conditions ~= someElement(*listFilter.none, false).not();
            }
        }
    }}

    // Array fields of nullable values (e.g. array columns)
    static foreach (member; getNullableArrayFields!Entity) {{
        auto arrayFilterField = __traits(getMember, filter, member);
        if (!arrayFilterField.isNull) {
            alias arrayMethod = __traits(getMember, Entity, member);
            auto cond = buildArrayCondition(arrayMethod(item), arrayFilterField.get, item);
            if (cond !is null)
                conditions ~= cond;
        }
    }}

    // Logical combinators
    if (!filter.and.isNull) {
        foreach (ref subFilter; filter.and.get)
            conditions ~= buildFilterPredicateFromStruct!Entity(item, subFilter);
    }

    // (An empty `or`, like an empty `and`, puts no condition.)
    if (!filter.or.isNull && filter.or.get.length > 0) {
        Expr!bool combined;
        foreach (ref subFilter; filter.or.get) {
            auto p = buildFilterPredicateFromStruct!Entity(item, subFilter);
            combined = combined is null ? p : combined.or(p);
        }
        conditions ~= combined;
    }

    if (filter.not !is null) {
        conditions ~= buildFilterPredicateFromStruct!Entity(item, *filter.not).not();
    }

    // Combine all conditions with AND (implicit)
    if (conditions.length == 0) {
        return constant(true, item);
    }

    auto result = conditions[0];
    foreach (c; conditions[1 .. $]) {
        result = result.and(c);
    }
    return result;
}

/// Build the condition an array filter (see `ArrayFilter`) puts on an array
/// field `arrayExpr` (lists of nullable values of type `T`), or null if it
/// puts none.
Expr!bool buildArrayCondition(T, ArrayFilterType)(Expr!(Nullable!T[]) arrayExpr, const ArrayFilterType filter,
        ExprBase lengthSource) {
    import dunamis.core.expr : arrayPredicate, ArrayPredicate, constant;

    Expr!bool[] conditions;
    // (An array field is never null.)
    if (!filter.isNull.isNull)
        conditions ~= constant(!filter.isNull.get, lengthSource);
    static foreach (op; ["equalTo", "notEqualTo", "contains", "containedBy", "overlaps"])
        if (!__traits(getMember, filter, op).isNull)
            conditions ~= arrayPredicate(arrayExpr, __traits(getMember, ArrayPredicate, op),
                __traits(getMember, filter, op).get.dup);
    static foreach (op; ["anyEqualTo", "anyNotEqualTo"])
        if (!__traits(getMember, filter, op).isNull)
            conditions ~= arrayPredicate(arrayExpr, __traits(getMember, ArrayPredicate, op),
                [Nullable!T(__traits(getMember, filter, op).get)]);
    if (conditions.length == 0)
        return null;
    auto result = conditions[0];
    foreach (c; conditions[1 .. $])
        result = result.and(c);
    return result;
}

/// Build the condition a column filter (StringFilter, IntFilter, etc.) puts
/// on a column, or null if it puts none. `fieldName` names the column in
/// error messages.
///
/// On a nullable column, the operators other than `isNull` only match
/// non-null values (as SQL comparisons do).
Expr!bool buildColumnCondition(ColExpr, ColumnFilter)(ColExpr colExpr, const ColumnFilter filter,
        ExprBase lengthSource, string fieldName) {
    import dunamis.core.expr : constant;
    import dunamis.core.expr.json : UnwrapNullableExpr;

    alias T = ColExpr.ResultType;
    Expr!bool[] conditions;
    static if (is(T == Nullable!U, U)) {
        Expr!(Nullable!U) nullable = colExpr;
        static if (__traits(hasMember, ColumnFilter, "isNull"))
            if (!filter.isNull.isNull)
                conditions ~= filter.isNull.get ? nullable.isNull() : nullable.isNotNull();
        auto valueCondition = buildValueCondition(
            cast(Expr!U) new UnwrapNullableExpr!U(nullable), filter, lengthSource, fieldName);
        if (valueCondition !is null)
            conditions ~= nullable.isNotNull().and(valueCondition);
    } else {
        // A non-null column is never null.
        static if (__traits(hasMember, ColumnFilter, "isNull"))
            if (!filter.isNull.isNull)
                conditions ~= constant(!filter.isNull.get, lengthSource);
        auto valueCondition = buildValueCondition(cast(Expr!T) colExpr, filter, lengthSource, fieldName);
        if (valueCondition !is null)
            conditions ~= valueCondition;
    }

    if (conditions.length == 0)
        return null;
    auto result = conditions[0];
    foreach (c; conditions[1 .. $])
        result = result.and(c);
    return result;
}

/// A string pattern operator of StringFilter: a LIKE match of the pattern
/// `prefix ~ operand ~ suffix` (the operand escaped if `literal`).
private struct StringPatternOperator {
    string name;
    string prefix, suffix;
    bool literal = true;
    bool insensitive;
    bool negated;
}

/// The string pattern operators (of StringFilter): `like`, `includes`,
/// `startsWith`, `endsWith` and `equalTo` (matching the operand literally:
/// as a LIKE pattern without wildcards), and their `Insensitive` and `not`
/// forms (but `equalTo`'s case-sensitive ones, which are comparisons).
private enum StringPatternOperator[] stringPatternOperators = () {
    StringPatternOperator[] result;
    foreach (base; [StringPatternOperator("like", "", "", false), StringPatternOperator("includes", "%", "%"),
            StringPatternOperator("startsWith", "", "%"), StringPatternOperator("endsWith", "%", ""),
            StringPatternOperator("equalTo", "", "")]) {
        foreach (insensitive; [false, true]) {
            foreach (negated; [false, true]) {
                if (base.name == "equalTo" && !insensitive)
                    continue;
                auto op = base;
                op.insensitive = insensitive;
                op.negated = negated;
                op.name = base.name ~ (insensitive ? "Insensitive" : "");
                if (negated)
                    op.name = "not" ~ cast(char)(op.name[0] - 'a' + 'A') ~ op.name[1 .. $];
                result ~= op;
            }
        }
    }
    return result;
}();

/// Build the condition the value operators of a column filter (all but
/// `isNull`) put on non-null column values, or null if they put none.
private Expr!bool buildValueCondition(T, ColumnFilter)(Expr!T colExpr, const ColumnFilter filter,
        ExprBase lengthSource, string fieldName) {
    import dunamis.core.expr : constant, isAmong;
    import dunamis.core.types : isCustomScalar;

    // Custom scalar columns are filtered through StringFilter (their wire
    // representation); parse operands that are not directly assignable to
    // the scalar's underlying type (e.g. a string for a long-backed scalar)
    // with the scalar's own deserializer.
    static S scalarOperand(S, V)(V value) {
        static if (is(V : S.DType))
            return S(value);
        else
            return S.fromJsonValue(JSONValue(value));
    }

    T operandValue(V)(V value) {
        static if (isCustomScalar!T && is(V : const(T)))
            return cast(T) value;
        else static if (isCustomScalar!T)
            return scalarOperand!T(value);
        else
            return cast(T) value;
    }

    auto operand(V)(V value) {
        return constant(operandValue(value), lengthSource);
    }

    T[] operandValues(V)(const(V)[] values) {
        T[] result;
        foreach (value; values)
            result ~= operandValue(value);
        return result;
    }

    Expr!bool[] conditions;

    // Operators which do not apply to the column's type are rejected rather
    // than ignored.
    void unsupported(string operator) {
        throw new Exception("Filter operator '" ~ operator ~ "' is not supported on field '" ~
            fieldName ~ "' of type " ~ T.stringof);
    }

    static if (hasDeclaredFilter!T) {
        // The operators of a filter type the value type declares
        if (auto condition = filter.condition(colExpr, lengthSource))
            conditions ~= condition;
    } else {
        static if (__traits(hasMember, ColumnFilter, "equalTo")) {
            if (!filter.equalTo.isNull)
                conditions ~= colExpr.eq(operand(filter.equalTo.get));
        }

        static if (__traits(hasMember, ColumnFilter, "notEqualTo")) {
            if (!filter.notEqualTo.isNull)
                conditions ~= colExpr.ne(operand(filter.notEqualTo.get));
        }

        // (Membership tests, which data sources can evaluate as such, e.g.
        // as one SQL `= ANY(...)`, rather than as chains of comparisons.)
        static if (__traits(hasMember, ColumnFilter, "in_")) {
            if (!filter.in_.isNull)
                conditions ~= isAmong(colExpr, operandValues(filter.in_.get));
        }

        static if (__traits(hasMember, ColumnFilter, "notIn")) {
            if (!filter.notIn.isNull)
                conditions ~= isAmong(colExpr, operandValues(filter.notIn.get)).not();
        }

        static foreach (op; ["lessThan", "lessThanOrEqualTo", "greaterThan", "greaterThanOrEqualTo"]) {
            static if (__traits(hasMember, ColumnFilter, op)) {
                if (!__traits(getMember, filter, op).isNull) {
                    auto value = operand(__traits(getMember, filter, op).get);
                    static if (op == "lessThan")
                        conditions ~= colExpr.lt(value);
                    else static if (op == "lessThanOrEqualTo")
                        conditions ~= colExpr.le(value);
                    else static if (op == "greaterThan")
                        conditions ~= colExpr.gt(value);
                    else
                        conditions ~= colExpr.ge(value);
                }
            }
        }

        // String-specific operators: LIKE patterns, of the operand (`like`)
        // or matching it literally, case-insensitive or not, and negated
        // or not (see StringFilter)
        static foreach (op; stringPatternOperators) {
            static if (__traits(hasMember, ColumnFilter, op.name)) {
                if (!__traits(getMember, filter, op.name).isNull) {
                    static if (is(T == string)) {
                        import dunamis.core.expr.operators : LikeExpr, escapeLikePattern;
                        auto value = __traits(getMember, filter, op.name).get;
                        auto pattern = op.prefix ~ (op.literal ? escapeLikePattern(value) : value) ~ op.suffix;
                        Expr!bool condition = new LikeExpr(colExpr, pattern, op.insensitive);
                        conditions ~= op.negated ? condition.not() : condition;
                    } else {
                        unsupported(op.name);
                    }
                }
            }
        }
    }

    if (conditions.length == 0) {
        return null;
    }

    auto result = conditions[0];
    foreach (c; conditions[1 .. $]) {
        result = result.and(c);
    }
    return result;
}

/// Check if a type is a filterable scalar type (not an entity or FK).
template isFilterableType(T) {
    import std.traits : Unqual;
    import std.typecons : Nullable;
    import dunamis.core.types : isCustomScalar;

    // Unwrap Nullable if present
    static if (is(T : Nullable!U, U)) {
        enum isFilterableType = isFilterableType!U;
    } else static if (hasDeclaredFilter!T) {
        enum isFilterableType = true;
    } else static if (isOrderedCustomScalar!T) {
        enum isFilterableType = true;
    } else {
        // Check if it's a basic scalar type or enum
        enum isFilterableType = is(T == string) || is(T == int) || is(T == long) ||
                                is(T == float) || is(T == double) || is(T == bool) ||
                                is(T == enum);
    }
}

/// Check if a member is an entity column method that returns a filterable type.
/// This excludes FK columns, relationship columns, and computed fields with extra arguments.
/// A valid column method takes exactly one parameter (Expr!Entity) and returns a filterable type.
template isEntityColumnMethod(Entity, string member) {
    static if (__traits(hasMember, Entity, member) &&
               __traits(compiles, typeof(__traits(getMember, Entity, member)))) {
        alias memberType = typeof(__traits(getMember, Entity, member));
        static if (is(memberType == function)) {
            alias params = Parameters!memberType;
            // Must take exactly one parameter (the entity expression)
            static if (params.length == 1 && is(params[0] == Expr!Entity)) {
                // Check if return type is a filterable type (not an entity)
                alias retType = ReturnType!memberType;
                static if (is(retType : Expr!T, T)) {
                    enum isEntityColumnMethod = isFilterableType!T;
                } else {
                    enum isEntityColumnMethod = false;
                }
            } else {
                enum isEntityColumnMethod = false;
            }
        } else {
            enum isEntityColumnMethod = false;
        }
    } else {
        enum isEntityColumnMethod = false;
    }
}

// ============================================================================
// FilterPlugin
// ============================================================================

/// Plugin that adds filter argument to all array-returning fields, with the
/// default argument surface (`DefaultFilterSurface`): see `FilterPluginWith`.
///
/// Transforms root Query fields:
///   users: [User!]!
/// Into:
///   users(filter: UserFilter): [User!]!
///
/// And nested entity fields:
///   User.posts: [Post!]!
/// Into:
///   User.posts(filter: PostFilter): [Post!]!
alias FilterPlugin = FilterPluginWith!DefaultFilterSurface;

/// Plugin that adds the arguments of the argument surfaces `Surfaces` to the
/// list fields (of objects), each selecting the elements a predicate of its
/// value holds for (applied in the order of the surfaces, beneath what later
/// plugins add: the elements must satisfy them all).
///
/// A surface is a template `Surface!(Scope, fieldName, Element)`, for the
/// list field `fieldName` of the type `Scope` (as the plugin's source schema
/// has them) whose elements are of type `Element` (likewise). If the field
/// gets an argument of it, it has:
/// - `Argument`: the type of the argument (an input type; the field's
///   parameter is a `Nullable!Argument`, null when it is not given),
/// - `enum string argumentName`: the argument's name, and
/// - `static Expr!bool predicate(Expr!Element item, const ref Argument)`:
///   the condition an element must satisfy (null: none).
///
/// Dunamis's surface is `DefaultFilterSurface` (`filter: <Element>Filter`);
/// an application can compose others (e.g. one per element type).
template FilterPluginWith(Surfaces...) {
    template FilterPluginWith(alias S) if (isSchema!S) {
        import std.meta : AliasSeq, staticMap;
        import dunamis.core.discovery : getSchemaObjectTypes, SchemaRootTypes;
        import dunamis.schema.transform : isTypeInList;

        // The schema's object types: its root types, and those reachable from them
        alias _AllEntityTypes = getSchemaObjectTypes!S;
        alias _AllTypes = AliasSeq!(SchemaRootTypes!S, _AllEntityTypes);

        // The list fields of the wrappers, filtered with the plugin's surfaces
        mixin template _FilteredField(SourceQuery, string fieldName, alias TypeMap) {
            mixin FilteredArrayField!(SourceQuery, fieldName, TypeMap, Surfaces);
        }

        // Generate filtered versions of each object type
        template FilteredEntity(Entity) {
            @(RemapTypeAttributes!(EntityTypeMap, __traits(getAttributes, Entity)))
            @OriginalName(__traits(identifier, Entity))
            struct FilteredEntity {
                mixin WrapFields!(Entity, EntityTypeMap, _FilteredField);
            }
        }

        // Map all entity types to their filtered versions
        alias AllEntityTypes = staticMap!(FilteredEntity, _AllEntityTypes);

        /// Entity type map: maps the schema's object types (the root types
        /// included) to their filtered versions.
        template EntityTypeMap(T) {
            static if (isTypeInList!(T, _AllTypes)) {
                alias EntityTypeMap = FilteredEntity!T;
            } else {
                alias EntityTypeMap = T;
            }
        }

        alias Query = EntityTypeMap!(S.Query);
        alias Mutation = EntityTypeMap!(S.Mutation);
        alias Subscription = EntityTypeMap!(S.Subscription);
    }
}

/// The default filter argument surface (see `FilterPluginWith`): `filter`,
/// of the element type's filter input type (`EntityFilter`, or the filter a
/// value type declares with `@FilteredBy`). Lists of values which are not
/// objects, or are nullable, get none.
template DefaultFilterSurface(Scope, string fieldName, Element) {
    import std.typecons : Nullable;
    static if (isEntityType!Element && !is(Element == Nullable!U, U)) {
        // Values of a type with a declared filter are filtered by it, here as
        // everywhere else, rather than by an EntityFilter of the type's fields.
        static if (hasDeclaredFilter!Element)
            alias Argument = DeclaredFilterType!Element;
        else
            alias Argument = EntityFilter!Element;

        enum string argumentName = "filter";

        static Expr!bool predicate(Expr!Element item, const ref Argument filter) {
            static if (hasDeclaredFilter!Element)
                return buildColumnCondition(item, filter, item, fieldName);
            else
                return buildFilterPredicateFromStruct!Element(item, filter);
        }
    }
}

// ============================================================================
// Mixin Templates for Field Generation
// ============================================================================

/// The surface `Surface` of the list field `fieldName` of `Scope`, with
/// elements of type `Element` (see `FilterPluginWith`).
template FilterSurfaceOf(alias Surface, Scope, string fieldName, Element) {
    alias FilterSurfaceOf = Surface!(Scope, fieldName, Element);
}

/// Whether any of the surfaces `Surfaces` gives the list field `fieldName`
/// of `Scope`, with elements of type `Element`, an argument.
template hasFilterArgument(Scope, string fieldName, Element, Surfaces...) {
    enum bool hasFilterArgument = () {
        bool result;
        static foreach (Surface; Surfaces)
            result = result || __traits(hasMember, FilterSurfaceOf!(Surface, Scope, fieldName, Element), "Argument");
        return result;
    }();
}

/// Mixin template to create a filtered version of an array-returning field,
/// with the arguments of the surfaces `Surfaces` (see `FilterPluginWith`).
///
/// The mixin template leaks a few type aliases (_SrcParams, _SrcDefaults,
/// _SrcEntity, _ElementType) and a private method (_applyFilter),
/// but these are harmless — filtered out by getSchemaFields.
///
/// Note: Cannot use the code template pattern (like SortedArrayFieldCode) because
/// LDC eagerly resolves `alias TypeMap` when forwarded from a mixin template to a
/// regular template, causing circular forward references during struct construction.
mixin template FilteredArrayField(SourceQuery, string fieldName, alias TypeMap, Surfaces...) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.conv : to;
    import dunamis.core.expr : Expr, ExprResultType;
    import dunamis.core.filtering : FilterByExpr, FilterItemExpr;
    import dunamis.schema.entity_cast : pluginEntityCast;
    import dunamis.schema.transform : wrapEntityResult;
    import std.typecons : Nullable;

    alias _SrcParams = Parameters!(__traits(getMember, SourceQuery, fieldName));
    alias _SrcDefaults = ParameterDefaults!(__traits(getMember, SourceQuery, fieldName));
    alias _SrcEntity = ExprResultType!(_SrcParams[0]);
    alias _ElementType = ArrayFieldElementType!(__traits(getMember, SourceQuery, fieldName));

    static if (!hasFilterArgument!(SourceQuery, fieldName, _ElementType, Surfaces)) {
        import dunamis.schema.plugin : ForwardField;
        mixin ForwardField!(SourceQuery, fieldName, TypeMap);
    } else {

    // Each filter wraps the field's collection as the previous plugins (and
    // surfaces) left it: with an earlier PaginationPlugin, it filters the
    // requested window. Plugin order determines the order of operations.
    private static Expr!(_ElementType[]) _applyFilter(alias Surface, T, A)(T base, Nullable!A argument) {
        if (argument.isNull)
            return base;
        auto item = new FilterItemExpr!_ElementType();
        Expr!bool predicate = Surface.predicate(item, argument.get);
        if (predicate is null) {
            import dunamis.core.expr : constant;
            predicate = constant(true, item);
        }
        return new FilterByExpr!_ElementType(base, item, predicate);
    }

    @(__traits(getAttributes, __traits(getMember, SourceQuery, fieldName)))
    mixin(() {
        enum string[] srcParamNames = [ParameterIdentifierTuple!(__traits(getMember, SourceQuery, fieldName))];

        string paramList = "Expr!(typeof(this)) " ~ srcParamNames[0];
        static foreach (i; 1 .. _SrcParams.length) {{
            paramList ~= ", _SrcParams[" ~ i.to!string ~ "] " ~ srcParamNames[i];
            static if (!is(_SrcDefaults[i] == void)) {
                paramList ~= " = _SrcDefaults[" ~ i.to!string ~ "]";
            }
        }}
        string body = "__traits(getMember, SourceQuery, \"" ~ fieldName ~ "\")(pluginEntityCast!(_SrcEntity)(" ~
            srcParamNames[0] ~ ")";
        static foreach (i; 1 .. _SrcParams.length)
            body ~= ", " ~ srcParamNames[i];
        body ~= ")";
        static foreach (i; 0 .. Surfaces.length) {{
            alias _S = FilterSurfaceOf!(Surfaces[i], SourceQuery, fieldName, _ElementType);
            static if (__traits(hasMember, _S, "Argument")) {
                enum s = "FilterSurfaceOf!(Surfaces[" ~ i.to!string ~
                    "], SourceQuery, \"" ~ fieldName ~ "\", _ElementType)";
                enum name = _S.argumentName;
                paramList ~= ", Nullable!(" ~ s ~ ".Argument) " ~ name ~ " = Nullable!(" ~ s ~ ".Argument).init";
                body = "_applyFilter!(" ~ s ~ ")(" ~ body ~ ", " ~ name ~ ")";
            }
        }}

        return "static auto " ~ fieldName ~ "(" ~ paramList ~ ") { " ~
              "return wrapEntityResult!(TypeMap)(" ~ body ~ "); }";
    }());
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // Test ColumnFilterType template
    static assert(is(ColumnFilterType!string == StringFilter));
    static assert(is(ColumnFilterType!int == IntFilter));
    static assert(is(ColumnFilterType!long == LongFilter));
    static assert(is(ColumnFilterType!double == FloatFilter));
    static assert(is(ColumnFilterType!bool == BooleanFilter));
    static assert(is(ColumnFilterType!(Nullable!string) == StringFilter));
    static assert(is(ColumnFilterType!(Nullable!bool) == BooleanFilter));
}

unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : CustomScalar, Executor;
    import dunamis.graphql.compiler : compileQuery;
    import dunamis.graphql.schema : Schema;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table;

    alias TestDate = CustomScalar!(string, "TestDate",
        (string value) => JSONValue(value),
        (JSONValue value) => value.str);
    static MockDB!() testDb;

    @DemoEntity!(testDb, "dated_rows")
    static struct DatedRow {
        mixin DemoId;
        mixin Col!("date", TestDate);
    }
    static struct Query { mixin Table!(DatedRow, "datedRows"); }
    alias FilteredSchema = FilterPlugin!(Schema!Query);
    // (Filtered by a filter of the scalar's own, of its values: TestDateFilter)
    import dunamis.graphql.schema : generateSchemaSDL;
    import std.algorithm.searching : canFind;
    enum sdl = generateSchemaSDL!FilteredSchema;
    static assert(sdl.canFind("  date: TestDateFilter\n"), sdl);
    static assert(sdl.canFind("input TestDateFilter {\n  equalTo: TestDate\n  notEqualTo: TestDate\n  in: [TestDate!]\n"), sdl);
    static assert(!sdl.canFind("includes: TestDate"), sdl);

    testDb = new MockDB!();
    testDb.setTableData("dated_rows",
        `[{"id":1,"date":"2020-07-01"},{"id":2,"date":"2021-01-01"}]`);
    auto variables = JSONValue(["date": JSONValue("2021-01-01")]);
    auto expression = compileQuery!FilteredSchema(`
        query($date: TestDate!) {
            datedRows(filter: {date: {equalTo: $date}}) { id }
        }
    `, variables);
    auto result = awaitSync(new Executor().execute(expression));
    assert(result["datedRows"].array.length == 1, result.toString());
    assert(result["datedRows"][0]["id"].integer == 2);
}

// Custom scalars, also those backed by a non-string type, are filtered
// through their ScalarFilter; operands are parsed with the scalar's deserializer.
unittest {
    import std.conv : to;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : CustomScalar, Executor;
    import dunamis.graphql.compiler : compileQuery;
    import dunamis.graphql.schema : Schema;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table;

    alias TestInt64 = CustomScalar!(long, "TestInt64",
        (long v) => JSONValue(v),
        (JSONValue j) => j.type == JSONType.integer ? j.integer : j.str.to!long);
    static MockDB!() testDb;

    @DemoEntity!(testDb, "big_rows")
    static struct BigRow {
        mixin DemoId;
        mixin Col!("big", TestInt64);
    }
    static struct Query { mixin Table!(BigRow, "bigRows"); }
    alias FilteredSchema = FilterPlugin!(Schema!Query);
    static assert(is(ColumnFilterType!TestInt64 == ScalarFilter!TestInt64));

    testDb = new MockDB!();
    testDb.setTableData("big_rows", `[
        {"id":1,"big":5000000000},
        {"id":2,"big":7},
        {"id":3,"big":8}
    ]`);

    long[] ids(string filter) {
        auto result = awaitSync(new Executor().execute(compileQuery!FilteredSchema(
            `{ bigRows(filter: ` ~ filter ~ `) { id } }`)));
        long[] found;
        foreach (row; result["bigRows"].array)
            found ~= row["id"].integer;
        return found;
    }

    assert(ids(`{big: {equalTo: "5000000000"}}`) == [1]);
    assert(ids(`{big: {notEqualTo: "7"}}`) == [1, 3]);
    assert(ids(`{big: {in: ["7", "8"]}}`) == [2, 3]);
    assert(ids(`{big: {notIn: ["7", "8"]}}`) == [1]);
    assert(ids(`{big: {greaterThan: "7", lessThan: "5000000000"}}`) == [3]);
}

unittest {
    import std.bigint : BigInt, toDecimalString;
    import dunamis.core : CustomScalar;

    // A custom scalar whose values do not compare (std.bigint.BigInt's
    // comparison is not reached through alias this) is not filtered
    alias TestBigInt = CustomScalar!(BigInt, "TestBigInt",
        (BigInt v) => JSONValue(toDecimalString(v)),
        (JSONValue j) => BigInt(j.str));
    static assert(!isOrderedCustomScalar!TestBigInt);
    static assert(is(ColumnFilterType!TestBigInt == void) && !isFilterableType!TestBigInt);

    alias TestLong = CustomScalar!(long, "TestLong", (long v) => JSONValue(v), (JSONValue j) => j.integer);
    static assert(isOrderedCustomScalar!TestLong && is(ColumnFilterType!TestLong == ScalarFilter!TestLong));
    static assert(!isOrderedCustomScalar!long);
}

// Integration test: FilterPlugin with Schema
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias BaseSchema = Schema!Query;
    alias FilteredSchema = FilterPlugin!BaseSchema;

    // Verify it's a valid schema
    static assert(isSchema!FilteredSchema);

    // Verify SDL shows filter argument on array field
    enum sdl = generateSchemaSDL!FilteredSchema;

    // Array field should have filter arg
    static assert(sdl.canFind("users("), "users should have arguments: " ~ sdl);
    static assert(sdl.canFind("filter:"), "should have filter arg: " ~ sdl);
}

// Test FilterPlugin with HasMany relationship
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias BaseSchema = Schema!Query;
    alias FilteredSchema = FilterPlugin!BaseSchema;
    static assert(isSchema!FilteredSchema);
}

// some/every/none over a HasMany relationship must actually filter, also when
// earlier plugins have wrapped the entity (its HasMany accessor then returns a
// concrete Expr subclass rather than a literal Expr!(T[])).
unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : Executor;
    import dunamis.graphql.compiler : compileQuery;
    import dunamis.graphql.schema : Schema;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, ForeignKey, HasMany, Table;
    import std.meta : AliasSeq;
    import dunamis.schema.crud : CrudMutationPlugin;
    import dunamis.schema.plugin : ApplyPlugins;
    import dunamis.schema.sorting : SortingPlugin;

    static MockDB!() db;

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
        mixin Col!("authorId", long);
    }

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id":1,"first_name":"Alice"},
        {"id":2,"first_name":"Bob"},
        {"id":3,"first_name":"Carol"}
    ]`);
    db.setTableData("posts", `[
        {"id":1,"title":"Hello World","author_id":1},
        {"id":2,"title":"Hello Again","author_id":1},
        {"id":3,"title":"Hello D","author_id":2},
        {"id":4,"title":"Goodbye","author_id":2}
    ]`);

    // (The Postgres integration suite covers these filters' SQL.)
    static void check(alias S)(string postsFilter, string[] expected) {
        foreach (optimize; [false, true]) {
            auto result = awaitSync(new Executor().execute(compileQuery!S(
                `{ users(filter: {posts: ` ~ postsFilter ~ `}) { firstName } }`), optimize));
            string[] found;
            foreach (user; result["users"].array)
                found ~= user["firstName"].str;
            assert(found == expected, postsFilter ~ ": " ~ found.to!string);
        }
    }

    static foreach (S; AliasSeq!(
        FilterPlugin!(Schema!Query),
        ApplyPlugins!(Schema!Query, CrudMutationPlugin, FilterPlugin, SortingPlugin),
    )) {
        check!S(`{some: {title: {includes: "Hello"}}}`, ["Alice", "Bob"]);
        check!S(`{every: {title: {includes: "Hello"}}}`, ["Alice", "Carol"]);
        check!S(`{none: {title: {includes: "Hello"}}}`, ["Carol"]);
    }
}

// A filter on a nullable belongs-to relationship that is evaluated in memory
// (not pushed into SQL) must test the related row, and must not match rows
// whose relationship is null.
unittest {
    import std.typecons : Nullable;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : Executor;
    import dunamis.graphql.compiler : compileQuery;
    import dunamis.graphql.schema : Schema;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : BelongsTo, Col, ForeignKey, Table;

    static MockDB!() db;

    @DemoEntity!(db, "people")
    static struct Person {
        mixin DemoId;
        mixin Col!("name", string);
    }

    @DemoEntity!(db, "chores")
    static struct Chore {
        mixin DemoId;
        mixin Col!("title", string);
        mixin Col!("assigneeId", Nullable!(ForeignKey!Person));
        mixin BelongsTo!("assignee", "assigneeId");
    }

    static struct Query {
        mixin Table!(Chore, "chores");
    }

    db = new MockDB!();
    db.setTableData("people", `[
        {"id":1,"name":"Alice"},
        {"id":2,"name":"Bob"}
    ]`);
    db.setTableData("chores", `[
        {"id":1,"title":"Dishes","assignee_id":1},
        {"id":2,"title":"Laundry","assignee_id":2},
        {"id":3,"title":"Garden","assignee_id":null},
        {"id":4,"title":"Windows","assignee_id":1}
    ]`);

    alias FilteredSchema = FilterPlugin!(Schema!Query);
    // Naive evaluation: see above.
    static string[] titles(string filter) {
        auto result = awaitSync(new Executor().execute(compileQuery!FilteredSchema(
            `{ chores(filter: ` ~ filter ~ `) { title } }`), false));
        string[] found;
        foreach (chore; result["chores"].array)
            found ~= chore["title"].str;
        return found;
    }

    auto alice = titles(`{assignee: {name: {equalTo: "Alice"}}}`);
    assert(alice == ["Dishes", "Windows"], alice.to!string);
    auto notAlice = titles(`{assignee: {name: {notEqualTo: "Alice"}}}`);
    assert(notAlice == ["Laundry"], notAlice.to!string);
}

// All object types are filtered alike: a to-one field of a value object type
// (here a struct-valued column) is filtered by the value type's filter, as a
// relationship is by the related entity's, and a field of an object type
// computed in D likewise. Value types are wrapped by the plugins like any
// other type, and appear in the SDL once.
unittest {
    import std.algorithm : canFind, count;
    import std.typecons : Nullable;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : Executor;
    import dunamis.core.expr : use;
    import dunamis.graphql.compiler : compileQuery;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table;
    import dunamis.schema.pagination : PaginationPlugin;
    import dunamis.schema.plugin : ApplyPlugins;
    import dunamis.schema.sorting : SortingPlugin;

    static MockDB!() db;

    static struct Period {
        Nullable!int quantity;
        Nullable!string unit;
    }

    static struct Label {
        string text;
    }

    @DemoEntity!(db, "terms")
    static struct Term {
        mixin DemoId;
        mixin Col!("name", string);
        mixin Col!("notice", Period);
        static auto label(Expr!Term t) {
            return use((string name) => Label(name ~ "!"), t.name);
        }
    }

    static struct Query {
        mixin Table!(Term, "terms");
    }

    db = new MockDB!();
    db.setTableData("terms", `[
        {"id":1,"name":"a","notice":{"quantity":3,"unit":"months"}},
        {"id":2,"name":"b","notice":{"quantity":1,"unit":"months"}},
        {"id":3,"name":"c","notice":{"quantity":3,"unit":"days"}}
    ]`);

    alias S = ApplyPlugins!(Schema!Query, FilterPlugin, SortingPlugin, PaginationPlugin);
    enum sdl = generateSchemaSDL!S;
    static assert(sdl.canFind("input PeriodFilter {"), sdl);
    static assert(sdl.canFind("  notice: PeriodFilter\n"), sdl);
    static assert(sdl.canFind("  label: LabelFilter\n"), sdl);
    static assert(sdl.count("type Period {") == 1, sdl);

    static string[] names(string filter) {
        auto result = awaitSync(new Executor().execute(compileQuery!S(
            `{ terms(filter: ` ~ filter ~ `) { name notice { unit } } }`), false));
        string[] found;
        foreach (term; result["terms"].array)
            found ~= term["name"].str;
        return found;
    }

    auto three = names(`{notice: {quantity: {equalTo: 3}}}`);
    assert(three == ["a", "c"], three.to!string);
    auto threeMonths = names(`{notice: {quantity: {equalTo: 3}, unit: {equalTo: "months"}}}`);
    assert(threeMonths == ["a"], threeMonths.to!string);
    auto labelled = names(`{label: {text: {equalTo: "b!"}}}`);
    assert(labelled == ["b"], labelled.to!string);
}

