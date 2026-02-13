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
import dunamis.core.filtering : filterBy, FilterByExpr, FilterItemExpr, FilterByInfo;
import dunamis.schema.plugin;
// isSchema imported via dunamis.schema.plugin wildcard import above

// ============================================================================
// Scalar Filter Input Types (PostGraphile-style)
// ============================================================================

/// String filter input type.
/// Supports equality, comparison, and pattern matching operations.
struct StringFilter {
    Nullable!string equalTo;
    Nullable!string notEqualTo;
    Nullable!(string[]) in_;
    Nullable!(string[]) notIn;
    Nullable!string lessThan;
    Nullable!string lessThanOrEqualTo;
    Nullable!string greaterThan;
    Nullable!string greaterThanOrEqualTo;
    Nullable!string contains;
    Nullable!string startsWith;
    Nullable!string endsWith;
    Nullable!string containsInsensitive;
    Nullable!string startsWithInsensitive;
    Nullable!string endsWithInsensitive;
    Nullable!bool isNull;
}

/// Int filter input type.
/// Supports equality and comparison operations.
struct IntFilter {
    Nullable!int equalTo;
    Nullable!int notEqualTo;
    Nullable!(int[]) in_;
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
    Nullable!(long[]) in_;
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
    Nullable!(double[]) in_;
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
    Nullable!E equalTo;
    Nullable!E notEqualTo;
    Nullable!(E[]) in_;
    Nullable!(E[]) notIn;
    Nullable!bool isNull;
}

// ============================================================================
// Type Mapping
// ============================================================================

/// Map D types to their corresponding filter types.
template FilterTypeFor(T) {
    static if (is(T == string)) {
        alias FilterTypeFor = StringFilter;
    } else static if (is(T == int)) {
        alias FilterTypeFor = IntFilter;
    } else static if (is(T == long)) {
        alias FilterTypeFor = LongFilter;
    } else static if (is(T == float) || is(T == double)) {
        alias FilterTypeFor = FloatFilter;
    } else static if (is(T == bool)) {
        alias FilterTypeFor = BooleanFilter;
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

/// Check if a type is an object type (has fields/methods, not a scalar).
/// Used to distinguish entity/POD array elements (get nested ListFilter)
/// from scalar array elements (get ListFilter!ScalarFilter).
template isEntityType(T) {
    import dunamis.core.discovery : isObjectType;
    enum isEntityType = isObjectType!T;
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

                // Check if return type is Expr!(ElementT[]) for any ElementT
                // Exclude string (which is immutable(char)[]) - it's a scalar, not an array field
                static if (is(retType : Expr!(ElementT[]), ElementT) && !is(retType : Expr!string)) {
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
    static if (is(T == string)) {
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
    alias retType = ReturnType!method;
    // retType is Expr!(T[]), extract T
    static if (is(retType : Expr!(T[]), T)) {
        alias getArrayElementType = T;
    } else {
        static assert(false, "Method " ~ member ~ " does not return Expr!(T[])");
    }
}

/// List filter for array fields with some/every/none operators.
/// Used to filter parent entities based on their related children.
/// Uses pointers to avoid Nullable initialization issues with complex nested types.
struct ListFilter(ChildFilter) {
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
        string result = "struct _ShallowFilter {\n";

        static foreach (member; getFilterableColumns!Entity) {{
            alias ColType = _ColTypeFor!member;

            static if (is(ColType == string)) {
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
            }
        }}

        result ~= "    typeof(this)[] and;\n";
        result ~= "    typeof(this)[] or;\n";
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

        result ~= "struct _EntityFilter {\n";

        // Filterable column fields
        static foreach (member; getFilterableColumns!Entity) {{
            alias ColType = _ColTypeFor!member;

            static if (is(ColType == string)) {
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
            }
        }}

        // Entity array fields — reference shallow filter via module-level template
        static foreach (member; getEntityArrayFields!Entity) {
            result ~= "    Nullable!(ListFilter!(_ShallowFilterFor!(getArrayElementType!(Entity, \"" ~ member ~ "\"))._ShallowFilter)) " ~ member ~ ";\n";
        }

        // Scalar array fields
        static foreach (member; getScalarArrayFields!Entity) {{
            alias ElemType = getArrayElementType!(Entity, member);
            result ~= "    Nullable!(ListFilter!" ~ scalarFilterTypeName!ElemType ~ ") " ~ member ~ ";\n";
        }}

        // Logical combinators (self-referential)
        result ~= "    typeof(this)[] and;\n";
        result ~= "    typeof(this)[] or;\n";
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
                auto cond = buildConditionFromScalarFilter(colExpr, __traits(getMember, filter, member).get, item);
                if (cond !is null) {
                    conditions ~= cond;
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
    if (filter.and.length > 0) {
        Expr!bool[] andPreds;
        foreach (ref subFilter; filter.and) {
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
    if (filter.or.length > 0) {
        Expr!bool[] orPreds;
        foreach (ref subFilter; filter.or) {
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

    Expr!bool[] conditions;

    // Check each operator in the scalar filter
    static if (__traits(hasMember, ScalarFilter, "equalTo")) {
        if (!filter.equalTo.isNull) {
            conditions ~= colExpr.eq(constant(filter.equalTo.get, lengthSource));
        }
    }

    static if (__traits(hasMember, ScalarFilter, "notEqualTo")) {
        if (!filter.notEqualTo.isNull) {
            conditions ~= colExpr.ne(constant(filter.notEqualTo.get, lengthSource));
        }
    }

    static if (__traits(hasMember, ScalarFilter, "lessThan")) {
        if (!filter.lessThan.isNull) {
            conditions ~= colExpr.lt(constant(filter.lessThan.get, lengthSource));
        }
    }

    static if (__traits(hasMember, ScalarFilter, "lessThanOrEqualTo")) {
        if (!filter.lessThanOrEqualTo.isNull) {
            conditions ~= colExpr.le(constant(filter.lessThanOrEqualTo.get, lengthSource));
        }
    }

    static if (__traits(hasMember, ScalarFilter, "greaterThan")) {
        if (!filter.greaterThan.isNull) {
            conditions ~= colExpr.gt(constant(filter.greaterThan.get, lengthSource));
        }
    }

    static if (__traits(hasMember, ScalarFilter, "greaterThanOrEqualTo")) {
        if (!filter.greaterThanOrEqualTo.isNull) {
            conditions ~= colExpr.ge(constant(filter.greaterThanOrEqualTo.get, lengthSource));
        }
    }

    // String-specific operators
    static if (__traits(hasMember, ScalarFilter, "contains")) {
        if (!filter.contains.isNull) {
            conditions ~= colExpr.contains(filter.contains.get);
        }
    }

    static if (__traits(hasMember, ScalarFilter, "startsWith")) {
        if (!filter.startsWith.isNull) {
            conditions ~= colExpr.startsWith(filter.startsWith.get);
        }
    }

    static if (__traits(hasMember, ScalarFilter, "endsWith")) {
        if (!filter.endsWith.isNull) {
            conditions ~= colExpr.endsWith(filter.endsWith.get);
        }
    }

    // Case-insensitive string operators
    static if (__traits(hasMember, ScalarFilter, "containsInsensitive")) {
        if (!filter.containsInsensitive.isNull) {
            conditions ~= colExpr.containsInsensitive(filter.containsInsensitive.get);
        }
    }

    static if (__traits(hasMember, ScalarFilter, "startsWithInsensitive")) {
        if (!filter.startsWithInsensitive.isNull) {
            conditions ~= colExpr.startsWithInsensitive(filter.startsWithInsensitive.get);
        }
    }

    static if (__traits(hasMember, ScalarFilter, "endsWithInsensitive")) {
        if (!filter.endsWithInsensitive.isNull) {
            conditions ~= colExpr.endsWithInsensitive(filter.endsWithInsensitive.get);
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

    // Unwrap Nullable if present
    static if (is(T : Nullable!U, U)) {
        enum isFilterableType = isFilterableType!U;
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
    static if (__traits(hasMember, Entity, member)) {
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

/// Build a typed condition for a specific column type.
private Expr!bool buildTypedCondition(ColType)(Expr!ColType colExpr, string op, JSONValue value, ExprBase lengthSource) {
    import dunamis.core.expr : constant;

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
    import std.meta : AliasSeq, staticMap;
    import dunamis.core.discovery : getAllObjectTypes;
    import dunamis.schema.transform : isTypeInList;

    // Get all entity types discovered from the schema
    alias _OriginalQuery = S.Query;
    alias _AllEntityTypes = getAllObjectTypes!_OriginalQuery;

    // Generate filtered versions of each entity type
    template FilteredEntity(Entity) {
        @(__traits(getAttributes, Entity))
        @OriginalName(__traits(identifier, Entity))
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

    alias Query = FilteredQuery;
    alias Mutation = FilteredMutation;
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
