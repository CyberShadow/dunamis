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
import dunamis.core.types : isCustomScalar;
import dunamis.core.filtering : filterBy, FilterByExpr, FilterItemExpr, FilterByInfo;
import dunamis.schema.plugin;
import dunamis.graphql.schema.udas : GqlName, getGraphQLTypeName;
// isSchema imported via dunamis.schema.plugin wildcard import above

// ============================================================================
// Scalar Filter Input Types (PostGraphile-style)
// ============================================================================

/// String filter input type.
/// Supports equality, comparison, and pattern matching operations.
struct StringFilter {
    Nullable!string equalTo;
    Nullable!string notEqualTo;
    @GqlName("in") Nullable!(string[]) in_;
    Nullable!(string[]) notIn;
    Nullable!string lessThan;
    Nullable!string lessThanOrEqualTo;
    Nullable!string greaterThan;
    Nullable!string greaterThanOrEqualTo;
    Nullable!string contains;
    Nullable!string startsWith;
    Nullable!string endsWith;
    Nullable!string containsInsensitive;
    Nullable!string includesInsensitive;
    Nullable!string startsWithInsensitive;
    Nullable!string endsWithInsensitive;
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
/// Supports equality operations.
struct BooleanFilter {
    Nullable!bool equalTo;
    Nullable!bool notEqualTo;
    Nullable!bool isNull;
}

/// Enum filter input type template.
/// Generates a filter type for any D enum with equality and set membership operations.
struct EnumFilter(E) if (is(E == enum)) {
    enum __gqlTypeName = getGraphQLTypeName!E ~ "Filter";
    Nullable!E equalTo;
    Nullable!E notEqualTo;
    @GqlName("in") Nullable!(E[]) in_;
    Nullable!(E[]) notIn;
    Nullable!bool isNull;
}

template isDateRangeType(T) {
    // Range value objects are deliberately identified structurally.  Avoid
    // invoking scalar-name discovery here: this predicate is instantiated for
    // primitive columns too, and a generated range type is wrapped by
    // schema normalization before the filter plugin sees it.
    enum isDateRangeType = __traits(hasMember, T, "start") &&
        __traits(hasMember, T, "end");
}

template dateRangeEndpoint(Range) if (isDateRangeType!Range) {
    import std.traits : isSomeFunction, ReturnType;
    import dunamis.core.expr : ExprResultType;

    alias StartMember = __traits(getMember, Range, "start");
    static if (isSomeFunction!StartMember)
        alias MaybeEndpoint = ExprResultType!(ReturnType!StartMember);
    else
        alias MaybeEndpoint = typeof(Range.init.start);
    static if (is(MaybeEndpoint == Nullable!E, E))
        alias dateRangeEndpoint = E;
    else
        alias dateRangeEndpoint = MaybeEndpoint;
}

/// PostgreSQL range filter.  Native execution currently needs the element
/// containment predicate; a compatibility schema may advertise
/// a wider range vocabulary for extension handling.
struct DateRangeFilter(Range) if (isDateRangeType!Range) {
    enum __gqlTypeName = "DateRangeFilter";
    Nullable!(dateRangeEndpoint!Range) containsElement;
    Nullable!bool isNull;
}

// ============================================================================
// Type Mapping
// ============================================================================

/// Map D types to their corresponding filter types.
template FilterTypeFor(T) {
    static if (isCustomScalar!T) {
        alias FilterTypeFor = StringFilter;
    } else static if (is(T == string)) {
        alias FilterTypeFor = StringFilter;
    } else static if (is(T == int)) {
        alias FilterTypeFor = IntFilter;
    } else static if (is(T == long)) {
        alias FilterTypeFor = LongFilter;
    } else static if (is(T == float) || is(T == double)) {
        alias FilterTypeFor = FloatFilter;
    } else static if (is(T == bool)) {
        alias FilterTypeFor = BooleanFilter;
    } else static if (isDateRangeType!T) {
        alias FilterTypeFor = DateRangeFilter!T;
    } else {
        // Default to StringFilter for unknown types
        alias FilterTypeFor = StringFilter;
    }
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
            static if (!isInternalMember!member && isEntityColumnMethod!(Entity, member)) {
                columns ~= member;
            }
        }}
        return columns;
    }();
}

/// Get singular belongs-to relationship names for an entity.
/// BelongsTo methods carry @BelongsToParent metadata, which avoids treating
/// arbitrary computed object-returning fields as database relationships.
template getBelongsToFields(Entity) {
    import dunamis.relational.schema.attrs : hasBelongsToParent;

    enum string[] getBelongsToFields = () {
        string[] relationships;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (!isInternalMember!member &&
                       __traits(compiles, typeof(__traits(getMember, Entity, member)))) {
                alias candidate = __traits(getMember, Entity, member);
                static if (hasBelongsToParent!candidate)
                    relationships ~= member;
            }
        }}
        return relationships;
    }();
}

/// Extract the parent entity type recorded on a belongs-to method.
template getBelongsToParentType(Entity, string member) {
    import dunamis.relational.schema.attrs : extractBelongsToParent;
    alias getBelongsToParentType = extractBelongsToParent!
        (__traits(getMember, Entity, member));
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

    static if (__traits(hasMember, Entity, member)) {
        alias memberType = typeof(__traits(getMember, Entity, member));
        // Use isSomeFunction to detect functions, function pointers, and delegates
        static if (isSomeFunction!memberType) {
            alias method = __traits(getMember, Entity, member);
            alias params = Parameters!method;

            // Must take exactly one parameter that is some Expr!ParamT
            // (we check against Expr!Entity loosely since the Entity might have
            // different type identity across module boundaries)
            static if (params.length == 1 && is(params[0] : Expr!ParamT, ParamT)) {
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
        enum isEntityArrayField = isEntityType!ElementT;
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
            enum isScalarArrayField = !isEntityType!ElementT;
    } else {
        enum isScalarArrayField = false;
    }
}

/// Get array-returning field names for an entity.
template getArrayFields(Entity) {
    enum string[] getArrayFields = () {
        string[] fields;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (!isInternalMember!member && isArrayReturningMethod!(Entity, member)) {
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
            static if (!isInternalMember!member && isEntityArrayField!(Entity, member)) {
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
            static if (!isInternalMember!member && isScalarArrayField!(Entity, member)) {
                fields ~= member;
            }
        }}
        return fields;
    }();
}

/// Map a scalar type to its filter type name.
template scalarFilterTypeName(T) {
    import std.typecons : Nullable;
    static if (is(T == Nullable!U, U)) {
        enum scalarFilterTypeName = scalarFilterTypeName!U;
    } else static if (is(T == string)) {
        enum scalarFilterTypeName = "StringFilter";
    } else static if (is(T == int)) {
        enum scalarFilterTypeName = "IntFilter";
    } else static if (is(T == long)) {
        enum scalarFilterTypeName = "LongFilter";
    } else static if (is(T == float) || is(T == double)) {
        enum scalarFilterTypeName = "FloatFilter";
    } else static if (is(T == bool)) {
        enum scalarFilterTypeName = "BooleanFilter";
    } else {
        enum scalarFilterTypeName = "StringFilter";  // fallback
    }
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

/// List filter for array fields with some/every/none operators.
/// Used to filter parent entities based on their related children.
/// Uses pointers to avoid Nullable initialization issues with complex nested types.
struct ListFilter(ChildFilter) {
    enum __gqlTypeName = getGraphQLTypeName!ChildFilter ~ "ListFilter";
    /// At least one child matches the filter
    ChildFilter* some;
    /// All children match the filter
    ChildFilter* every;
    /// No children match the filter (equivalent to not(some(...)))
    ChildFilter* none;
}

/// Module-level shallow filter type generation.
/// Encapsulates helper templates so they don't leak into host structs.
/// Produces a filter struct with only scalar column fields (no nested entity arrays),
/// used for child entity filters in ListFilter to avoid circular type references.
template _ShallowFilterFor(Entity) {
    import std.typecons : Nullable;
    import std.traits : ReturnType;

    template _ColTypeFor(string member) {
        alias _colMethod = __traits(getMember, Entity, member);
        alias _ColTypeFor = ReturnType!_colMethod.ResultType;
    }

    static foreach (member; getFilterableColumns!Entity) {
        static if (is(_ColTypeFor!member == enum)) {
            mixin("alias _EnumType_" ~ member ~ " = _ColTypeFor!\"" ~ member ~ "\";");
        }
    }

    mixin(() {
        string result = "@GqlName(\"" ~ getGraphQLTypeName!Entity ~ "ShallowFilter\")\n";
        result ~= "struct _ShallowFilter {\n";

        static foreach (member; getFilterableColumns!Entity) {{
            alias ColType = _ColTypeFor!member;

            static if (isDateRangeType!ColType) {
                result ~= "    Nullable!(DateRangeFilter!(_ColTypeFor!\"" ~ member ~ "\")) " ~ member ~ ";\n";
            } else static if (isCustomScalar!ColType) {
                result ~= "    Nullable!(FilterTypeFor!(_ColTypeFor!\"" ~ member ~ "\")) " ~ member ~ ";\n";
            } else static if (is(ColType == string)) {
                result ~= "    Nullable!StringFilter " ~ member ~ ";\n";
            } else static if (is(ColType == int)) {
                result ~= "    Nullable!IntFilter " ~ member ~ ";\n";
            } else static if (is(ColType == long)) {
                result ~= "    Nullable!LongFilter " ~ member ~ ";\n";
            } else static if (is(ColType == float) || is(ColType == double)) {
                result ~= "    Nullable!FloatFilter " ~ member ~ ";\n";
            } else static if (is(ColType == bool)) {
                result ~= "    Nullable!BooleanFilter " ~ member ~ ";\n";
            } else static if (is(ColType == enum)) {
                result ~= "    Nullable!(EnumFilter!(_EnumType_" ~ member ~ ")) " ~ member ~ ";\n";
            } else static if (is(ColType == Nullable!U, U)) {
                static if (is(U == int))
                    result ~= "    Nullable!IntFilter " ~ member ~ ";\n";
                else static if (is(U == long))
                    result ~= "    Nullable!LongFilter " ~ member ~ ";\n";
            }
        }}

        result ~= "    Nullable!(typeof(this)[]) and;\n";
        result ~= "    Nullable!(typeof(this)[]) or;\n";
        result ~= "    typeof(this)* not;\n";

        result ~= "}\n";

        return result;
    }());
}

/// Module-level entity filter type generation.
/// Encapsulates helper templates so they don't leak into host structs.
/// Generates a full filter struct with scalar column fields, entity array fields
/// (via _ShallowFilterFor), scalar array fields, and logical combinators.
///
/// Example: _FilterTypesFor!User._EntityFilter produces:
/// ```
/// struct _EntityFilter {
///     Nullable!StringFilter firstName;
///     Nullable!IntFilter age;
///     Nullable!EnumFilter!Role role;
///     Nullable!(ListFilter!(_ShallowFilterFor!Post._ShallowFilter)) posts;
///     Nullable!(ListFilter!StringFilter) tags;
///     typeof(this)[] and;
///     typeof(this)[] or;
///     typeof(this)* not;
/// }
/// ```
template _FilterTypesFor(Entity) {
    import std.typecons : Nullable;
    import std.traits : ReturnType;

    template _ColTypeFor(string member) {
        alias _colMethod = __traits(getMember, Entity, member);
        alias _ColTypeFor = ReturnType!_colMethod.ResultType;
    }

    static foreach (member; getFilterableColumns!Entity) {
        static if (is(_ColTypeFor!member == enum)) {
            mixin("alias _EnumType_" ~ member ~ " = _ColTypeFor!\"" ~ member ~ "\";");
        }
    }

    mixin(() {
        string result = "";

        result ~= "@GqlName(\"" ~ getGraphQLTypeName!Entity ~ "Filter\")\n";
        result ~= "struct _EntityFilter {\n";

        // Filterable column fields
        static foreach (member; getFilterableColumns!Entity) {{
            alias ColType = _ColTypeFor!member;

            static if (isDateRangeType!ColType) {
                result ~= "    Nullable!(DateRangeFilter!(_ColTypeFor!\"" ~ member ~ "\")) " ~ member ~ ";\n";
            } else static if (isCustomScalar!ColType) {
                result ~= "    Nullable!(FilterTypeFor!(_ColTypeFor!\"" ~ member ~ "\")) " ~ member ~ ";\n";
            } else static if (is(ColType == string)) {
                result ~= "    Nullable!StringFilter " ~ member ~ ";\n";
            } else static if (is(ColType == int)) {
                result ~= "    Nullable!IntFilter " ~ member ~ ";\n";
            } else static if (is(ColType == long)) {
                result ~= "    Nullable!LongFilter " ~ member ~ ";\n";
            } else static if (is(ColType == float) || is(ColType == double)) {
                result ~= "    Nullable!FloatFilter " ~ member ~ ";\n";
            } else static if (is(ColType == bool)) {
                result ~= "    Nullable!BooleanFilter " ~ member ~ ";\n";
            } else static if (is(ColType == enum)) {
                result ~= "    Nullable!(EnumFilter!(_EnumType_" ~ member ~ ")) " ~ member ~ ";\n";
            } else static if (is(ColType == Nullable!U, U)) {
                static if (is(U == int))
                    result ~= "    Nullable!IntFilter " ~ member ~ ";\n";
                else static if (is(U == long))
                    result ~= "    Nullable!LongFilter " ~ member ~ ";\n";
            } else static if (isEntityType!ColType && !isDateRangeType!ColType) {
                // Belongs-to / foreign-key relationship. Use the shallow
                // target filter so relationship predicates do not create
                // recursive filter type cycles.
                result ~= "    Nullable!(_ShallowFilterFor!(_ColTypeFor!\"" ~
                    member ~ "\")._ShallowFilter) " ~ member ~ ";\n";
            }
        }}

        // Singular belongs-to relationships use a shallow target filter to
        // prevent recursive input-type cycles (for example User.manager).
        static foreach (member; getBelongsToFields!Entity) {
            result ~= "    Nullable!(_ShallowFilterFor!(getBelongsToParentType!(Entity, \"" ~
                member ~ "\"))._ShallowFilter) " ~ member ~ ";\n";
        }

        // Entity array fields — reference shallow filter via module-level template
        static foreach (member; getEntityArrayFields!Entity) {
            result ~= "    Nullable!(ListFilter!(_ShallowFilterFor!(getArrayElementType!(Entity, \"" ~ member ~ "\"))._ShallowFilter)) " ~ member ~ ";\n";
        }

        // Scalar array fields
        static foreach (member; getScalarArrayFields!Entity) {{
            alias ElemType = getArrayElementType!(Entity, member);
            // Enum arrays need an EnumFilter-aware collection predicate. Until
            // that predicate is available, keep the field queryable but do not
            // advertise a type-incorrect StringFilter for it.
            static if (!is(ElemType == enum))
                result ~= "    Nullable!(ListFilter!" ~ scalarFilterTypeName!ElemType ~ ") " ~ member ~ ";\n";
        }}

        // Logical combinators (self-referential)
        result ~= "    Nullable!(typeof(this)[]) and;\n";
        result ~= "    Nullable!(typeof(this)[]) or;\n";
        result ~= "    typeof(this)* not;\n";

        result ~= "}\n";

        return result;
    }());
}

// ============================================================================
// Filter Predicate Building (Typed Filter -> Expr!bool)
// ============================================================================

/// Build an Expr!bool predicate from a typed entity filter struct.
/// This converts the PostGraphile-style nested filter to an expression tree.
/// The item parameter can be any Expr!Entity (FilterItemExpr, EveryItemOfExpr, etc.)
Expr!bool buildFilterPredicateFromStruct(Entity, FilterType, ItemExpr)(ItemExpr item, FilterType filter)
    if (is(ItemExpr : Expr!Entity))
{
    import dunamis.core.expr : constant, EveryItemOfExpr, SomeExpr;

    Expr!bool[] conditions;

    // Process each filterable column
    static foreach (member; getFilterableColumns!Entity) {{
        // Check if this filter field is set
        static if (__traits(hasMember, FilterType, member)) {
            // Use runtime check for the filter field value
            if (!__traits(getMember, filter, member).isNull) {
                // Use alias for the column method (required for calling static methods)
                alias colMethod = __traits(getMember, Entity, member);
                auto colExpr = colMethod(item);
                alias ColType = ExprResultType!(ReturnType!colMethod);
                static if (isEntityType!ColType && !isDateRangeType!ColType)
                    auto cond = buildFilterPredicateFromStruct(colExpr,
                        __traits(getMember, filter, member).get);
                else
                    auto cond = buildConditionFromScalarFilter(colExpr,
                        __traits(getMember, filter, member).get, item);
                if (cond !is null) {
                    conditions ~= cond;
                }
            }
        }
    }}


    // Process singular belongs-to relationships (e.g. Post.author -> User).
    static foreach (member; getBelongsToFields!Entity) {{
        static if (__traits(hasMember, FilterType, member)) {
            auto relationshipFilter = __traits(getMember, filter, member);
            if (!relationshipFilter.isNull) {
                alias relationshipMethod = __traits(getMember, Entity, member);
                auto relationshipExpr = relationshipMethod(item);
                alias RelationshipEntity = ExprResultType!(typeof(relationshipExpr));
                static if (is(RelationshipEntity == Nullable!Parent, Parent)) {
                    import dunamis.core.expr.json : UnwrapNullableExpr;
                    // A missing related row matches no relationship filter
                    // (as with an EXISTS / joined-row predicate in SQL).
                    auto unwrapped = new UnwrapNullableExpr!Parent(relationshipExpr);
                    conditions ~= relationshipExpr.isNotNull().and(
                        buildFilterPredicateFromStruct!Parent(
                            unwrapped, relationshipFilter.get));
                } else {
                    conditions ~= buildFilterPredicateFromStruct!RelationshipEntity(
                        relationshipExpr, relationshipFilter.get);
                }
            }
        }
    }}

    // Process each entity array field (e.g., User.posts -> Post[])
    debug(filter) {
        import std.stdio : writefln, stdout;
        writefln("  buildFilterPredicateFromStruct: entityArrayFields for %s = %s", Entity.stringof, getEntityArrayFields!Entity);
        stdout.flush();
    }
    static foreach (member; getEntityArrayFields!Entity) {{
        static if (__traits(hasMember, FilterType, member)) {
            // Access the filter field at runtime
            auto listFilterField = __traits(getMember, filter, member);
            debug(filter) {
                import std.stdio : writefln, stdout;
                writefln("  buildFilterPredicateFromStruct: checking entity array %s, isNull=%s", member, listFilterField.isNull);
                stdout.flush();
            }
            if (!listFilterField.isNull) {
                auto listFilter = listFilterField.get;
                alias ChildEntity = getArrayElementType!(Entity, member);

                // Get the collection expression
                alias arrayMethod = __traits(getMember, Entity, member);
                auto collectionExpr = arrayMethod(item);

                // Handle 'some' - at least one child matches
                if (listFilter.some !is null) {
                    debug(filter) {
                        import std.stdio : writefln, stdout;
                        writefln("  buildFilterPredicateFromStruct: creating SomeExpr for entity array field %s", member);
                        stdout.flush();
                    }
                    auto childItem = new EveryItemOfExpr!ChildEntity();
                    auto childPred = buildFilterPredicateFromStruct!ChildEntity(childItem, *listFilter.some);
                    auto someExpr = new SomeExpr!(ChildEntity, typeof(childPred))(collectionExpr, childItem, childPred);
                    childItem._parentMap = someExpr;
                    conditions ~= someExpr;
                    debug(filter) {
                        import std.stdio : writefln, stdout;
                        writefln("  buildFilterPredicateFromStruct: someExpr created, class=%s", typeid(someExpr).name);
                        stdout.flush();
                    }
                }

                // Handle 'every' - all children match (= not(some(not(pred))))
                if (listFilter.every !is null) {
                    auto childItem = new EveryItemOfExpr!ChildEntity();
                    auto childPred = buildFilterPredicateFromStruct!ChildEntity(childItem, *listFilter.every);
                    auto negPred = childPred.not();
                    auto someExpr = new SomeExpr!(ChildEntity, typeof(negPred))(collectionExpr, childItem, negPred);
                    childItem._parentMap = someExpr;
                    conditions ~= someExpr.not();
                }

                // Handle 'none' - no children match (= not(some(...)))
                if (listFilter.none !is null) {
                    auto childItem = new EveryItemOfExpr!ChildEntity();
                    auto childPred = buildFilterPredicateFromStruct!ChildEntity(childItem, *listFilter.none);
                    auto someExpr = new SomeExpr!(ChildEntity, typeof(childPred))(collectionExpr, childItem, childPred);
                    childItem._parentMap = someExpr;
                    conditions ~= someExpr.not();  // none = not(some)
                }
            }
        }
    }}

    // Process each scalar array field (e.g., User.tags -> string[])
    debug(filter) {
        import std.stdio : writefln, stdout;
        writefln("  buildFilterPredicateFromStruct: scalarArrayFields for %s = %s", Entity.stringof, getScalarArrayFields!Entity);
        stdout.flush();
    }
    static foreach (member; getScalarArrayFields!Entity) {{
        static if (__traits(hasMember, FilterType, member)) {
            // Access the filter field at runtime
            auto listFilterField = __traits(getMember, filter, member);
            debug(filter) {
                import std.stdio : writefln, stdout;
                writefln("  buildFilterPredicateFromStruct: checking scalar array %s, isNull=%s", member, listFilterField.isNull);
                stdout.flush();
            }
            if (!listFilterField.isNull) {
                auto listFilter = listFilterField.get;
                alias ElemType = getArrayElementType!(Entity, member);

                // Get the collection expression
                alias arrayMethod = __traits(getMember, Entity, member);
                auto collectionExpr = arrayMethod(item);

                // Handle 'some' - at least one element matches the scalar filter
                // Uses unified SomeExpr/EveryItemOfExpr which now handles both entities and scalars
                if (listFilter.some !is null) {
                    debug(filter) {
                        import std.stdio : writefln, stdout;
                        writefln("  buildFilterPredicateFromStruct: creating SomeExpr for scalar array field %s", member);
                        stdout.flush();
                    }
                    auto elemItem = new EveryItemOfExpr!ElemType();
                    auto elemPred = buildConditionFromScalarFilter(elemItem, *listFilter.some, item);
                    if (elemPred !is null) {
                        auto someExpr = new SomeExpr!(ElemType, typeof(elemPred))(collectionExpr, elemItem, elemPred);
                        elemItem._parentMap = someExpr;
                        conditions ~= someExpr;
                    }
                }

                // Handle 'every' - all elements match the scalar filter (= not(some(not(pred))))
                if (listFilter.every !is null) {
                    auto elemItem = new EveryItemOfExpr!ElemType();
                    auto elemPred = buildConditionFromScalarFilter(elemItem, *listFilter.every, item);
                    if (elemPred !is null) {
                        auto negPred = elemPred.not();
                        auto someExpr = new SomeExpr!(ElemType, typeof(negPred))(collectionExpr, elemItem, negPred);
                        elemItem._parentMap = someExpr;
                        conditions ~= someExpr.not();
                    }
                }

                // Handle 'none' - no elements match (= not(some(...)))
                if (listFilter.none !is null) {
                    auto elemItem = new EveryItemOfExpr!ElemType();
                    auto elemPred = buildConditionFromScalarFilter(elemItem, *listFilter.none, item);
                    if (elemPred !is null) {
                        auto someExpr = new SomeExpr!(ElemType, typeof(elemPred))(collectionExpr, elemItem, elemPred);
                        elemItem._parentMap = someExpr;
                        conditions ~= someExpr.not();  // none = not(some)
                    }
                }
            }
        }
    }}

    // Handle 'and' combinator
    if (!filter.and.isNull && filter.and.get.length > 0) {
        Expr!bool[] andPreds;
        foreach (ref subFilter; filter.and.get) {
            andPreds ~= buildFilterPredicateFromStruct!Entity(item, subFilter);
        }
        if (andPreds.length > 0) {
            auto combined = andPreds[0];
            foreach (p; andPreds[1 .. $]) {
                combined = combined.and(p);
            }
            conditions ~= combined;
        }
    }

    // Handle 'or' combinator
    if (!filter.or.isNull && filter.or.get.length > 0) {
        Expr!bool[] orPreds;
        foreach (ref subFilter; filter.or.get) {
            orPreds ~= buildFilterPredicateFromStruct!Entity(item, subFilter);
        }
        if (orPreds.length > 0) {
            auto combined = orPreds[0];
            foreach (p; orPreds[1 .. $]) {
                combined = combined.or(p);
            }
            conditions ~= combined;
        }
    }

    // Handle 'not' combinator
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

/// Build a condition from a scalar filter (StringFilter, IntFilter, etc.)
Expr!bool buildConditionFromScalarFilter(ColExpr, ScalarFilter)(ColExpr colExpr, ScalarFilter filter, ExprBase lengthSource) {
    import dunamis.core.expr : constant;
    import dunamis.core.expr.operators : sqlBinaryBool;
    import dunamis.core.types : isCustomScalar;

    enum isNullableColumn = is(ColExpr.ResultType == Nullable!NullableElement, NullableElement);

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

    auto operand(V)(V value) {
        static if (is(ColExpr.ResultType == Nullable!U, U))
            static if (isCustomScalar!U)
                return constant(Nullable!U(scalarOperand!U(value)), lengthSource);
            else
                return constant(Nullable!U(value), lengthSource);
        else static if (isCustomScalar!(ColExpr.ResultType))
            return constant(scalarOperand!(ColExpr.ResultType)(value), lengthSource);
        else
            return constant(value, lengthSource);
    }

    Expr!bool[] conditions;

    static if (isDateRangeType!(ColExpr.ResultType)) {
        if (!filter.containsElement.isNull) {
            alias Range = ColExpr.ResultType;
            conditions ~= sqlBinaryBool(colExpr, "rangeContains",
                constant(filter.containsElement.get.to!string, lengthSource),
                (Range range, string element) {
                    // PostgreSQL's canonical date ranges are half-open: [start, end).
                    // Nullable endpoints represent unbounded sides.
                    static if (__traits(hasMember, Range, "_normalizedSource"))
                        auto raw = range._normalizedSource;
                    else
                        auto raw = range;
                    bool afterStart = raw.start.isNull || raw.start.get.value <= element;
                    bool beforeEnd = raw.end.isNull || element < raw.end.get.value;
                    return afterStart && beforeEnd;
                });
        }
    } else {

    // Check each operator in the scalar filter
    static if (__traits(hasMember, ScalarFilter, "equalTo")) {
        if (!filter.equalTo.isNull) {
            conditions ~= colExpr.eq(operand(filter.equalTo.get));
        }
    }

    static if (__traits(hasMember, ScalarFilter, "notEqualTo")) {
        if (!filter.notEqualTo.isNull) {
            conditions ~= colExpr.ne(operand(filter.notEqualTo.get));
        }
    }

    static if (__traits(hasMember, ScalarFilter, "in_")) {
        if (!filter.in_.isNull) {
            auto values = filter.in_.get;
            Expr!bool membership = constant(false, lengthSource);
            foreach (value; values)
                membership = membership.or(colExpr.eq(operand(value)));
            conditions ~= membership;
        }
    }

    static if (__traits(hasMember, ScalarFilter, "notIn")) {
        if (!filter.notIn.isNull) {
            auto values = filter.notIn.get;
            Expr!bool membership = constant(true, lengthSource);
            foreach (value; values)
                membership = membership.and(colExpr.ne(operand(value)));
            conditions ~= membership;
        }
    }

    static if (__traits(hasMember, ScalarFilter, "lessThan")) {
        static if (!isNullableColumn) {
            if (!filter.lessThan.isNull) {
                conditions ~= colExpr.lt(operand(filter.lessThan.get));
            }
        }
    }

    static if (__traits(hasMember, ScalarFilter, "lessThanOrEqualTo")) {
        static if (!isNullableColumn) {
            if (!filter.lessThanOrEqualTo.isNull) {
                conditions ~= colExpr.le(operand(filter.lessThanOrEqualTo.get));
            }
        }
    }

    static if (__traits(hasMember, ScalarFilter, "greaterThan")) {
        static if (!isNullableColumn) {
            if (!filter.greaterThan.isNull) {
                conditions ~= colExpr.gt(operand(filter.greaterThan.get));
            }
        }
    }

    static if (__traits(hasMember, ScalarFilter, "greaterThanOrEqualTo")) {
        static if (!isNullableColumn) {
            if (!filter.greaterThanOrEqualTo.isNull) {
                conditions ~= colExpr.ge(operand(filter.greaterThanOrEqualTo.get));
            }
        }
    }

    // String-specific operators
    static if (__traits(hasMember, ScalarFilter, "contains") &&
               is(ColExpr.ResultType == string)) {
        if (!filter.contains.isNull) {
            conditions ~= colExpr.contains(filter.contains.get);
        }
    }

    static if (__traits(hasMember, ScalarFilter, "startsWith") &&
               is(ColExpr.ResultType == string)) {
        if (!filter.startsWith.isNull) {
            conditions ~= colExpr.startsWith(filter.startsWith.get);
        }
    }

    static if (__traits(hasMember, ScalarFilter, "endsWith") &&
               is(ColExpr.ResultType == string)) {
        if (!filter.endsWith.isNull) {
            conditions ~= colExpr.endsWith(filter.endsWith.get);
        }
    }

    // Case-insensitive string operators
    static if (__traits(hasMember, ScalarFilter, "containsInsensitive") &&
               is(ColExpr.ResultType == string)) {
        if (!filter.containsInsensitive.isNull) {
            conditions ~= colExpr.containsInsensitive(filter.containsInsensitive.get);
        }
    }
    static if (__traits(hasMember, ScalarFilter, "includesInsensitive") &&
               is(ColExpr.ResultType == string)) {
        if (!filter.includesInsensitive.isNull) {
            conditions ~= colExpr.containsInsensitive(filter.includesInsensitive.get);
        }
    }

    static if (__traits(hasMember, ScalarFilter, "startsWithInsensitive") &&
               is(ColExpr.ResultType == string)) {
        if (!filter.startsWithInsensitive.isNull) {
            conditions ~= colExpr.startsWithInsensitive(filter.startsWithInsensitive.get);
        }
    }

    static if (__traits(hasMember, ScalarFilter, "endsWithInsensitive") &&
               is(ColExpr.ResultType == string)) {
        if (!filter.endsWithInsensitive.isNull) {
            conditions ~= colExpr.endsWithInsensitive(filter.endsWithInsensitive.get);
        }
    }
    }

    // Combine conditions with AND
    if (conditions.length == 0) {
        return null;
    }

    auto result = conditions[0];
    foreach (c; conditions[1 .. $]) {
        result = result.and(c);
    }
    return result;
}

// ============================================================================
// Filter Predicate Building (JSON -> Expr!bool) - Legacy/Fallback
// ============================================================================

/// Build an Expr!bool predicate from a JSON filter object.
/// This converts the PostGraphile-style nested filter to an expression tree.
///
/// Example input JSON:
///   { "firstName": { "equalTo": "Alice" }, "age": { "greaterThan": 18 } }
///
/// Returns an Expr!bool that can be used with FilterByExpr.
Expr!bool buildFilterPredicate(Entity)(FilterItemExpr!Entity item, JSONValue filter) {
    import dunamis.core.expr : constant;

    if (filter.type != JSONType.object) {
        // Invalid filter, return true (no filtering)
        return constant(true, item);
    }

    Expr!bool[] conditions;

    foreach (string key, JSONValue value; filter.object) {
        // Handle logical combinators
        if (key == "and") {
            if (value.type == JSONType.array) {
                Expr!bool[] andPreds;
                foreach (v; value.array) {
                    andPreds ~= buildFilterPredicate!Entity(item, v);
                }
                if (andPreds.length > 0) {
                    auto combined = andPreds[0];
                    foreach (p; andPreds[1 .. $]) {
                        combined = combined.and(p);
                    }
                    conditions ~= combined;
                }
            }
            continue;
        }

        if (key == "or") {
            if (value.type == JSONType.array) {
                Expr!bool[] orPreds;
                foreach (v; value.array) {
                    orPreds ~= buildFilterPredicate!Entity(item, v);
                }
                if (orPreds.length > 0) {
                    auto combined = orPreds[0];
                    foreach (p; orPreds[1 .. $]) {
                        combined = combined.or(p);
                    }
                    conditions ~= combined;
                }
            }
            continue;
        }

        if (key == "not") {
            if (value.type == JSONType.object) {
                conditions ~= buildFilterPredicate!Entity(item, value).not();
            }
            continue;
        }

        // Column filter: { columnName: { operator: value } }
        if (value.type == JSONType.object) {
            auto columnCondition = buildColumnFilter!Entity(item, key, value);
            if (columnCondition !is null) {
                conditions ~= columnCondition;
            }
        }
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

/// Build filter condition for a single column.
private Expr!bool buildColumnFilter(Entity)(FilterItemExpr!Entity item, string columnName, JSONValue operators) {
    import dunamis.core.expr : constant;

    // Get the column expression from the entity
    // Use compile-time reflection to access the column
    Expr!bool[] conditions;

    foreach (string opName, JSONValue opValue; operators.object) {
        auto cond = buildColumnCondition!Entity(item, columnName, opName, opValue);
        if (cond !is null) {
            conditions ~= cond;
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

/// Build a single column condition for the given operator.
private Expr!bool buildColumnCondition(Entity)(FilterItemExpr!Entity item, string columnName, string op, JSONValue value) {
    import dunamis.core.expr : constant;

    // Try to access the column via the entity's static methods
    // This uses runtime dispatch since we don't know the column type at compile time
    return buildColumnConditionRuntime!Entity(item, columnName, op, value);
}

/// Runtime column condition builder that dispatches based on column type.
private Expr!bool buildColumnConditionRuntime(Entity)(FilterItemExpr!Entity item, string columnName, string op, JSONValue value) {
    import dunamis.core.expr : constant;

    // For now, we'll use a simplified approach that builds comparison expressions
    // based on the value type in the JSON.
    // The actual column access will happen during predicate optimization.

    // Build a comparison expression that will be pattern-matched during optimization
    return buildComparisonFromJson!Entity(item, columnName, op, value);
}

/// Build a comparison expression from JSON operator and value.
private Expr!bool buildComparisonFromJson(Entity)(FilterItemExpr!Entity item, string columnName, string op, JSONValue value) {
    import dunamis.core.expr : constant;

    // Access the column via Entity's static method
    // The column access method takes Expr!Entity and returns Expr!ColumnType
    // We need to call it dynamically based on columnName

    // For compile-time known entities, we can use static foreach
    // But since this is runtime, we need a different approach

    // Strategy: Build a DynamicColumnFilter expression that will be expanded during optimization
    // For now, return a placeholder that will be replaced

    // Since we need to support runtime column names, we'll use a different approach:
    // Create expressions using string interpolation that reference Entity columns

    static foreach (member; __traits(allMembers, Entity)) {{
        static if (!isInternalMember!member && isEntityColumnMethod!(Entity, member)) {
            if (member == columnName) {
                // Found the column - build the condition
                alias colMethod = __traits(getMember, Entity, member);
                alias ColType = ReturnType!(colMethod).ResultType;

                auto colExpr = colMethod(item);
                return buildTypedCondition!ColType(colExpr, op, value, item);
            }
        }
    }}

    // Column not found - return null (skip this condition)
    return null;
}

/// Check if a type is a filterable scalar type (not an entity or FK).
template isFilterableType(T) {
    import std.traits : Unqual;
    import std.typecons : Nullable;
    import dunamis.core.types : isCustomScalar;

    // Unwrap Nullable if present
    static if (is(T : Nullable!U, U)) {
        enum isFilterableType = isFilterableType!U;
    } else static if (isDateRangeType!T) {
        enum isFilterableType = true;
    } else static if (isCustomScalar!T) {
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

/// A date range in its PostgreSQL text form (e.g. `[2020-01-01,2021-01-01)`),
/// normalized to the half-open day interval [lower, upper).
private struct DayRange {
    bool empty;
    long lower = long.min;  // long.min: unbounded
    long upper = long.max;  // long.max: unbounded
}

/// Parse a date range literal, or (if `elementAllowed`) a single date, which
/// stands for the range containing just that day. Throws on other input.
private DayRange parseDayRange(string text, bool elementAllowed) {
    import std.datetime.date : Date;
    import std.string : strip, toLower;
    import std.algorithm : countUntil;

    static long day(string s) {
        return Date.fromISOExtString(s).dayOfGregorianCal;
    }
    static string boundText(string s) {
        s = s.strip;
        if (s.length >= 2 && s[0] == '"' && s[$ - 1] == '"')
            s = s[1 .. $ - 1];
        return s;
    }
    static bool unbounded(string s) {
        return s.length == 0 || s.toLower == "infinity" || s.toLower == "-infinity";
    }

    text = text.strip;
    if (text.toLower == "empty")
        return DayRange(true);
    if (text.length && (text[0] == '[' || text[0] == '(')) {
        auto comma = text.countUntil(',');
        if (comma < 0 || text.length < 3 || (text[$ - 1] != ']' && text[$ - 1] != ')'))
            throw new Exception("Invalid date range: " ~ text);
        DayRange range;
        auto lower = boundText(text[1 .. comma]);
        auto upper = boundText(text[comma + 1 .. $ - 1]);
        if (!unbounded(lower))
            range.lower = day(lower) + (text[0] == '(' ? 1 : 0);
        if (!unbounded(upper))
            range.upper = day(upper) + (text[$ - 1] == ']' ? 1 : 0);
        range.empty = range.lower >= range.upper;
        return range;
    }
    if (!elementAllowed)
        throw new Exception("Invalid date range: " ~ text);
    auto d = day(text);
    return DayRange(false, d, d + 1);
}

/// In-memory semantics of the PostgreSQL range operators used by range
/// filters, for date ranges stored as text, matching PostgreSQL's
/// `daterange` operators. The operand is a range literal, or for
/// `rangeContains` also a single date (containment of an element).
/// A null (empty-text) column matches nothing, as NULL does in SQL.
bool delegate(string, string) dateRangeTextPredicate(string op) {
    return (string column, string operand) {
        if (column.length == 0)
            return false;
        auto a = parseDayRange(column, false);
        auto b = parseDayRange(operand, op == "rangeContains");
        static bool contains(DayRange outer, DayRange inner) {
            if (inner.empty) return true;
            if (outer.empty) return false;
            return outer.lower <= inner.lower && inner.upper <= outer.upper;
        }
        switch (op) {
            case "rangeContains": return contains(a, b);
            case "rangeContainedBy": return contains(b, a);
            default: break;
        }
        if (a.empty || b.empty)
            return false;
        switch (op) {
            case "rangeOverlaps": return a.lower < b.upper && b.lower < a.upper;
            case "rangeStrictlyLeft": return a.upper <= b.lower;
            case "rangeStrictlyRight": return a.lower >= b.upper;
            case "rangeNotExtendsRight": return a.upper <= b.upper;
            case "rangeNotExtendsLeft": return a.lower >= b.lower;
            case "rangeAdjacent": return a.upper == b.lower || b.upper == a.lower;
            default:
                throw new Exception("Range operator " ~ op ~ " cannot be evaluated in memory");
        }
    };
}

unittest {
    auto p(string op) { return dateRangeTextPredicate(op); }
    enum y2020 = "[2020-01-01,2021-01-01)";
    assert(p("rangeContains")(y2020, "2020-06-01"));
    assert(p("rangeContains")(y2020, "2020-01-01"));
    assert(!p("rangeContains")(y2020, "2021-01-01"));
    assert(p("rangeContains")("[2020-01-01,)", "2999-01-01"));
    assert(p("rangeContains")(y2020, "[2020-03-01,2020-04-01)"));
    assert(p("rangeContains")("[2020-01-01,2020-12-31]", "2020-12-31"));
    assert(!p("rangeContains")("(2020-01-01,2020-12-31]", "2020-01-01"));
    assert(!p("rangeContains")(y2020, "[2020-03-01,)"));
    assert(p("rangeContainedBy")("[2020-03-01,2020-04-01)", y2020));
    assert(p("rangeOverlaps")(y2020, "[2020-12-31,2022-01-01)"));
    assert(!p("rangeOverlaps")(y2020, "[2021-01-01,2022-01-01)"));
    assert(p("rangeStrictlyLeft")(y2020, "[2021-01-01,)"));
    assert(!p("rangeStrictlyLeft")(y2020, "[2020-12-31,)"));
    assert(p("rangeStrictlyRight")("[2021-01-01,)", y2020));
    assert(p("rangeNotExtendsRight")(y2020, "[2019-01-01,2021-01-01)"));
    assert(!p("rangeNotExtendsRight")("[2020-01-01,)", y2020));
    assert(p("rangeNotExtendsLeft")(y2020, "[2020-01-01,2020-02-01)"));
    assert(p("rangeAdjacent")(y2020, "[2021-01-01,2022-01-01)"));
    assert(p("rangeAdjacent")(y2020, "[2019-01-01,2019-12-31]"));
    assert(!p("rangeAdjacent")(y2020, "[2021-01-02,2022-01-01)"));
    assert(!p("rangeOverlaps")("empty", y2020));
    assert(p("rangeContains")(y2020, "empty"));
    assert(!p("rangeContains")("", "2020-06-01"));
    bool threw;
    try p("rangeContains")("[2020-01-01,2021-01-01)", "soon");
    catch (Exception) threw = true;
    assert(threw);
}

/// Build a typed condition for a specific column type.
private Expr!bool buildTypedCondition(ColType)(Expr!ColType colExpr, string op, JSONValue value, ExprBase lengthSource) {
    import dunamis.core.expr : constant;
    import dunamis.core.expr.operators : sqlBinaryBool;

    // Date ranges are stored by the relational layer as their
    // PostgreSQL text representation. Preserve that lightweight storage type
    // while still compiling the range-specific GraphQL filter vocabulary to
    // native PostgreSQL operators.
    static if (is(ColType == string)) {
        string rangeLiteral(JSONValue range) {
            auto start = "start" in range && !range["start"].isNull
                ? range["start"].str : "";
            auto end = "end" in range && !range["end"].isNull
                ? range["end"].str : "";
            return "[" ~ start ~ "," ~ end ~ ")";
        }
        string rangeOperator;
        string operand;
        if (op == "containsElement" && value.type == JSONType.string) {
            rangeOperator = "rangeContains";
            operand = value.str;
        } else if (value.type == JSONType.object) {
            operand = rangeLiteral(value);
            switch (op) {
                case "contains": rangeOperator = "rangeContains"; break;
                case "containedBy": rangeOperator = "rangeContainedBy"; break;
                case "overlaps": rangeOperator = "rangeOverlaps"; break;
                case "strictlyLeftOf": rangeOperator = "rangeStrictlyLeft"; break;
                case "strictlyRightOf": rangeOperator = "rangeStrictlyRight"; break;
                case "notExtendsRightOf": rangeOperator = "rangeNotExtendsRight"; break;
                case "notExtendsLeftOf": rangeOperator = "rangeNotExtendsLeft"; break;
                case "adjacentTo": rangeOperator = "rangeAdjacent"; break;
                default: break;
            }
        }
        if (rangeOperator.length)
            return sqlBinaryBool(colExpr, rangeOperator,
                constant(operand, lengthSource), dateRangeTextPredicate(rangeOperator));
    }

    switch (op) {
        case "equalTo":
            return colExpr.eq(constant(extractJsonValue!ColType(value), lengthSource));
        case "notEqualTo":
            return colExpr.ne(constant(extractJsonValue!ColType(value), lengthSource));
        case "lessThan":
            return colExpr.lt(constant(extractJsonValue!ColType(value), lengthSource));
        case "lessThanOrEqualTo":
            return colExpr.le(constant(extractJsonValue!ColType(value), lengthSource));
        case "greaterThan":
            return colExpr.gt(constant(extractJsonValue!ColType(value), lengthSource));
        case "greaterThanOrEqualTo":
            return colExpr.ge(constant(extractJsonValue!ColType(value), lengthSource));
        case "isNull":
            // isNull only applies to Nullable types - skip for non-nullable
            // For now, return a placeholder (this case shouldn't normally occur)
            return null;
        // String-specific operators
        case "contains":
            static if (is(ColType == string)) {
                return colExpr.contains(value.str);
            } else {
                return null;
            }
        case "startsWith":
            static if (is(ColType == string)) {
                return colExpr.startsWith(value.str);
            } else {
                return null;
            }
        case "endsWith":
            static if (is(ColType == string)) {
                return colExpr.endsWith(value.str);
            } else {
                return null;
            }
        // Case-insensitive string operators
        case "containsInsensitive":
            static if (is(ColType == string)) {
                return colExpr.containsInsensitive(value.str);
            } else {
                return null;
            }
        case "startsWithInsensitive":
            static if (is(ColType == string)) {
                return colExpr.startsWithInsensitive(value.str);
            } else {
                return null;
            }
        case "endsWithInsensitive":
            static if (is(ColType == string)) {
                return colExpr.endsWithInsensitive(value.str);
            } else {
                return null;
            }
        default:
            return null;
    }
}

/// Convert a string to a D enum value by matching member names.
private T _enumFromString(T)(string s) if (is(T == enum)) {
    import std.traits : EnumMembers;
    static foreach (member; EnumMembers!T) {
        if (__traits(identifier, member) == s)
            return member;
    }
    return T.init;
}

/// Extract a value of type T from JSON.
T extractJsonValue(T)(JSONValue value) {
    static if (is(T == string)) {
        return value.type == JSONType.string ? value.str : "";
    } else static if (is(T == int)) {
        return value.type == JSONType.integer ? cast(int) value.integer : 0;
    } else static if (is(T == long)) {
        return value.type == JSONType.integer ? value.integer : 0;
    } else static if (is(T == float) || is(T == double)) {
        if (value.type == JSONType.float_) return cast(T) value.floating;
        if (value.type == JSONType.integer) return cast(T) value.integer;
        return 0;
    } else static if (is(T == bool)) {
        return value.type == JSONType.true_;
    } else static if (is(T == enum)) {
        // D enum - convert from string using enumFromString
        if (value.type == JSONType.string) {
            return _enumFromString!T(value.str);
        }
        return T.init;
    } else {
        return T.init;
    }
}

// ============================================================================
// FilterPlugin
// ============================================================================

/// Plugin that adds filter argument to all array-returning fields.
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
template FilterPlugin(alias S) if (isSchema!S) {
    import std.meta : AliasSeq, Filter, staticMap;
    import dunamis.core.discovery : getAllObjectTypes;
    import dunamis.relational.schema.attrs : hasEntityAttr;
    import dunamis.schema.transform : isTypeInList;

    // Get all entity types discovered from the schema
    alias _OriginalQuery = S.Query;
    alias _AllObjectTypes = getAllObjectTypes!_OriginalQuery;
    template IsRelationalEntity(T) {
        enum IsRelationalEntity = hasEntityAttr!T;
    }
    alias _AllEntityTypes = Filter!(IsRelationalEntity, _AllObjectTypes);

    // Generate filtered versions of each entity type
    template FilteredEntity(Entity) {
        @(RemapTypeAttributes!(EntityTypeMap, __traits(getAttributes, Entity)))
        @OriginalName(getGraphQLTypeName!Entity)
        struct FilteredEntity {
            mixin WrapFields!(Entity, EntityTypeMap, FilteredArrayField);
        }
    }

    // Map all entity types to their filtered versions
    alias AllEntityTypes = staticMap!(FilteredEntity, _AllEntityTypes);

    /// Entity type map: maps original entity types to their filtered versions.
    template EntityTypeMap(T) {
        static if (isTypeInList!(T, _AllEntityTypes)) {
            alias EntityTypeMap = FilteredEntity!T;
        } else {
            alias EntityTypeMap = T;
        }
    }

    struct FilteredQuery {
        mixin WrapFields!(_OriginalQuery, EntityTypeMap, FilteredArrayField);
    }

    struct FilteredMutation {
        mixin WrapFields!(S.Mutation, EntityTypeMap, FilteredArrayField);
    }

    struct FilteredSubscription {
        mixin WrapFields!(S.Subscription, EntityTypeMap, FilteredArrayField);
    }

    alias Query = FilteredQuery;
    alias Mutation = FilteredMutation;
    alias Subscription = FilteredSubscription;
}

// ============================================================================
// Mixin Templates for Field Generation
// ============================================================================

/// Mixin template to create a filtered version of an array-returning field.
///
/// Uses module-level _FilterTypesFor and _ShallowFilterFor templates for filter
/// type generation, so the filter struct and its helper templates (_ColTypeFor,
/// _EnumType_*, _ShallowFilter) stay encapsulated and don't leak into the host
/// struct. The mixin template itself still leaks a few type aliases (_SrcParams,
/// _SrcDefaults, _SrcEntity, _ElementType, _FilterType) and a private method
/// (_applyFilter), but these are harmless — filtered out by getSchemaFields.
///
/// Note: Cannot use the code template pattern (like SortedArrayFieldCode) because
/// LDC eagerly resolves `alias TypeMap` when forwarded from a mixin template to a
/// regular template, causing circular forward references during struct construction.
mixin template FilteredArrayField(SourceQuery, string fieldName, alias TypeMap) {
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

    static if (!isEntityType!_ElementType) {
        import dunamis.schema.plugin : ForwardField;
        mixin ForwardField!(SourceQuery, fieldName, TypeMap);
    } else {

    // Filter type from module-level template — doesn't leak _ColTypeFor,
    // _EnumType_*, _EntityFilter, _ShallowFilter, or _*ChildFilter into the host struct.
    alias _FilterType = _FilterTypesFor!_ElementType._EntityFilter;

    private static Expr!(_ElementType[]) _applyFilter(T)(T base, Nullable!_FilterType filter) {
        if (filter.isNull)
            return base;

        auto item = new FilterItemExpr!_ElementType();
        auto predicate = buildFilterPredicateFromStruct!_ElementType(item, filter.get);
        auto filterExpr = new FilterByExpr!_ElementType(base, item, predicate);
        item._parentFilter = filterExpr;
        return filterExpr;
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
        paramList ~= ", Nullable!_FilterType filter = Nullable!_FilterType.init";

        string argList = "pluginEntityCast!(_SrcEntity)(" ~ srcParamNames[0] ~ ")";
        static foreach (i; 1 .. _SrcParams.length) {
            argList ~= ", " ~ srcParamNames[i];
        }

        return "static auto " ~ fieldName ~ "(" ~ paramList ~ ") { " ~
              "return wrapEntityResult!(TypeMap)(_applyFilter(" ~
              "__traits(getMember, SourceQuery, \"" ~ fieldName ~ "\")(" ~ argList ~ "), filter)); }";
    }());
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // Test FilterTypeFor template
    static assert(is(FilterTypeFor!string == StringFilter));
    static assert(is(FilterTypeFor!int == IntFilter));
    static assert(is(FilterTypeFor!long == LongFilter));
    static assert(is(FilterTypeFor!double == FloatFilter));
    static assert(is(FilterTypeFor!bool == BooleanFilter));
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

// Custom scalars backed by a non-string type are still filtered through
// StringFilter; operands are parsed with the scalar's deserializer.
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
    static assert(is(FilterTypeFor!TestInt64 == StringFilter));

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
    // Test extractJsonValue
    import std.json : parseJSON;

    auto strVal = parseJSON(`"hello"`);
    assert(extractJsonValue!string(strVal) == "hello");

    auto intVal = parseJSON(`42`);
    assert(extractJsonValue!int(intVal) == 42);
    assert(extractJsonValue!long(intVal) == 42);

    auto floatVal = parseJSON(`3.14`);
    assert(extractJsonValue!double(floatVal) == 3.14);

    auto boolVal = parseJSON(`true`);
    assert(extractJsonValue!bool(boolVal) == true);
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

    static void check(alias S)(string postsFilter, string[] expected) {
        auto result = awaitSync(new Executor().execute(compileQuery!S(
            `{ users(filter: {posts: ` ~ postsFilter ~ `}) { firstName } }`)));
        string[] found;
        foreach (user; result["users"].array)
            found ~= user["firstName"].str;
        assert(found == expected, postsFilter ~ ": " ~ found.to!string);
    }

    static foreach (S; AliasSeq!(
        FilterPlugin!(Schema!Query),
        ApplyPlugins!(Schema!Query, CrudMutationPlugin, FilterPlugin, SortingPlugin),
    )) {
        check!S(`{some: {title: {contains: "Hello"}}}`, ["Alice", "Bob"]);
        check!S(`{every: {title: {contains: "Hello"}}}`, ["Alice", "Carol"]);
        check!S(`{none: {title: {contains: "Hello"}}}`, ["Carol"]);
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
    static string[] titles(string filter) {
        auto result = awaitSync(new Executor().execute(compileQuery!FilteredSchema(
            `{ chores(filter: ` ~ filter ~ `) { title } }`)));
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

// Range filters built from JSON on a range stored as text must also be
// evaluated correctly when they are not pushed down to SQL.
unittest {
    import std.json : parseJSON;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : Executor;
    import dunamis.core.expr : map, use;
    import dunamis.core.filtering : FilterByExpr, FilterItemExpr;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, getAll;

    static MockDB!() db;

    @DemoEntity!(db, "terms")
    static struct Term {
        mixin DemoId;
        mixin Col!("period", string);
    }

    db = new MockDB!();
    db.setTableData("terms", `[
        {"id":1,"period":"[2020-01-01,2021-01-01)"},
        {"id":2,"period":"[2021-01-01,2022-01-01)"},
        {"id":3,"period":"[2020-06-01,)"}
    ]`);

    static long[] ids(string filter) {
        auto item = new FilterItemExpr!Term();
        auto predicate = buildFilterPredicate!Term(item, parseJSON(filter));
        auto filtered = new FilterByExpr!Term(getAll!Term(), item, predicate);
        item._parentFilter = filtered;
        auto query = map!((Expr!Term t) => use((Term term) => term.id.value, t))(filtered);
        return awaitSync(new Executor().execute(query, false));
    }

    assert(ids(`{"period": {"containsElement": "2020-07-01"}}`) == [1, 3]);
    assert(ids(`{"period": {"containsElement": "2021-03-01"}}`) == [2, 3]);
    assert(ids(`{"period": {"overlaps": {"start": "2020-12-01", "end": "2021-02-01"}}}`) == [1, 2, 3]);
    assert(ids(`{"period": {"strictlyLeftOf": {"start": "2021-01-01", "end": null}}}`) == [1]);
    assert(ids(`{"period": {"adjacentTo": {"start": "2019-01-01", "end": "2020-01-01"}}}`) == [1]);
}
