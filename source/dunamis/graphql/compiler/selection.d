module dunamis.graphql.compiler.selection;

import std.conv;
import std.json;
import std.traits;
import std.typecons : Nullable;

import graphql.ast;

import dunamis.core.expr : ExprBase, ExprResultType, Expr, isExpr, singleton,
    DynamicJsonObjectExpr, SequentialJsonObjectExpr, MapExpr,
    use, toJsonValue, map, constant;
import dunamis.core.expr.combinators : SubsetExpr, ConcatArrayExpr, UnionExprInfo;
import dunamis.core.types : isCustomScalar, isGqlResult, GqlResult, isAbstractType;
import dunamis.core.discovery : getSchemaFields, fieldResultType, getSchemaObjectTypes,
    getAbstractTypeMembers, getNarrowTargets, getAllAbstractTypes;
import dunamis.graphql.introspection;
import dunamis.graphql.schema;
import dunamis.graphql.compiler.values;
import dunamis.graphql.compiler.fields;

// ============================================================================
// Root Subscription Compilation
// ============================================================================

package(dunamis.graphql):

/// Whether list items of type T are leaves (scalars, or lists of them),
/// which are serialized as they are, without a selection set.
private template isScalarElement(T) {
    static if (is(T == Nullable!U, U))
        enum isScalarElement = isScalarElement!U;
    else static if (is(T == E[], E) && !isSomeString!T && !isCustomScalar!T)
        enum isScalarElement = isScalarElement!E;
    else
        enum isScalarElement = isCustomScalar!T || !is(T == struct) || isGqlResult!T;
}

/// Whether items of type T are plain objects (non-null structs with a
/// selection set), compiled by compileMapExpr.
private template isObjectElement(T) {
    enum isObjectElement = is(T == struct) && !is(T == Nullable!U, U) && !isScalarElement!T;
}

/// Whether a null item in a list of T makes the list null (null bubbling):
/// T is non-null, and an object or a list which can itself become null.
private template bubblesNullItems(T) {
    static if (is(T == Nullable!U, U))
        enum bubblesNullItems = false;
    else static if (is(T == E[], E) && !isSomeString!T && !isCustomScalar!T)
        enum bubblesNullItems = bubblesNullItems!E;
    else
        enum bubblesNullItems = is(T == struct) && !isCustomScalar!T && !isGqlResult!T;
}

/// Compile the root selection set for subscriptions.
/// GraphQL spec requires exactly one root field for subscriptions.
DynamicJsonObjectExpr compileRootSubscriptionSet(Subscription, alias SchemaType = Subscription)(SelectionSet ss, JSONValue variables, FragmentMap fragments) {
    auto selections = iterateSelections(ss);

    if (selections.length == 0) {
        throw new CompilerException("Empty subscription selection set");
    }

    string[] fieldNames;
    ExprBase[] fieldExprs;

    processSelections!(getGraphQLTypeName!Subscription)(
        selections, variables, fragments, fieldNames, fieldExprs,
        (field) => compileRootField!(Subscription, SchemaType)(field, variables, fragments)
    );

    // GraphQL spec: subscriptions must have exactly one root field
    if (fieldNames.length != 1) {
        throw new CompilerException("Subscription operations must have exactly one root field, got " ~ fieldNames.length.to!string);
    }

    return new DynamicJsonObjectExpr(fieldNames, fieldExprs);
}

// ============================================================================
// Root Mutation Compilation
// ============================================================================

/// Compile the root selection set for mutations (sequential execution)
SequentialJsonObjectExpr compileRootMutationSet(Mutation, alias SchemaType = Mutation)(SelectionSet ss, JSONValue variables, FragmentMap fragments) {
    auto selections = iterateSelections(ss);

    if (selections.length == 0) {
        throw new CompilerException("Empty mutation selection set");
    }

    string[] fieldNames;
    ExprBase[] fieldExprs;
    string[] schemaFieldNames;

    processSelections!(getGraphQLTypeName!Mutation)(
        selections, variables, fragments, fieldNames, fieldExprs,
        (field) {
            schemaFieldNames ~= getFieldName(field);
            return compileRootField!(Mutation, SchemaType)(field, variables, fragments);
        }
    );
    assert(schemaFieldNames.length == fieldNames.length);

    // Null bubbling as for queries: a null in a non-null root field makes the
    // whole result null.
    return new SequentialJsonObjectExpr(fieldNames, fieldExprs, [],
        resolveNonNullFlags!Mutation(schemaFieldNames),
        resolveNonNullItemFlags!Mutation(schemaFieldNames));
}

/// Compile a single field of a root type (Query, Mutation or Subscription).
/// The root types' fields are compiled like those of any other type
/// (compileFieldAccess), on the request's single instance of the root type;
/// only the introspection meta-fields of the schema are particular to them.
ExprBase compileRootField(Parent, alias IntrospectionSource = Parent)(Field field, JSONValue variables, FragmentMap fragments) {
    auto fieldName = getFieldName(field);

    // Introspection meta-fields
    if (fieldName == "__schema") {
        auto schemaJson = buildIntrospectionJson!IntrospectionSource();
        auto result = applySelectionSet(schemaJson, field.ss, variables, fragments);
        return wrapAsJsonExpr(singleton(result));
    }
    if (fieldName == "__type") {
        auto typeName = extractTypeNameArg(field.args, variables);
        auto lookup = buildTypeLookup!IntrospectionSource();
        if (auto typeJson = typeName in lookup) {
            return wrapAsJsonExpr(singleton(applySelectionSet(*typeJson, field.ss, variables, fragments)));
        }
        return wrapAsJsonExpr(singleton(JSONValue(null)));
    }

    // The root type is a singleton: one instance per request
    static if (isSchema!IntrospectionSource)
        alias SchemaSource = IntrospectionSource;
    else
        alias SchemaSource = void;
    return compileFieldAccess!(Parent, SchemaSource)(singleton(Parent.init), field, variables, fragments);
}

/// Wrap an expression to convert its result to JSONValue
ExprBase wrapAsJsonExpr(E)(E expr) if (isExpr!E) {
    alias T = ExprResultType!E;
    return use((T val) => toJsonValue(val), expr);
}

/// Helper to extract all arguments for a function and return as a tuple
auto extractAllArgs(alias fn)(Arguments args, JSONValue variables) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.meta : staticMap, aliasSeqOf;
    import std.range : iota;
    import std.typecons : tuple;

    alias Params = Parameters!fn;
    alias Defaults = ParameterDefaults!fn;
    enum paramNames = [ParameterIdentifierTuple!fn];

    // Build a tuple of extracted arguments
    template ExtractArg(size_t i) {
        alias ExtractArg = extractArg!(Params[i], Defaults[i])(args, paramNames[i], variables);
    }

    // Use static foreach to build the tuple
    static if (Params.length == 0) {
        return tuple();
    } else {
        return mixin(() {
            string code = "tuple(";
            static foreach (i; 0 .. Params.length) {
                code ~= (i > 0 ? ", " : "") ~
                    "extractArg!(Params[" ~ i.stringof ~ "], Defaults[" ~ i.stringof ~ "])" ~
                    "(args, paramNames[" ~ i.stringof ~ "], variables)";
            }
            code ~= ")";
            return code;
        }());
    }
}

// ============================================================================
// Fragment/Selection Processing
// ============================================================================

/// The GraphQL names of the abstract types (unions and interfaces) of
/// AllTypes (a schema's object types) which have the object type T as a
/// member: the type conditions which, besides T's own name, apply to T.
template abstractTypeNamesOf(T, AllTypes...) {
    enum string[] abstractTypeNamesOf = () {
        string[] names;
        static foreach (AbstractT; getAllAbstractTypes!AllTypes)
            static foreach (Member; getAbstractTypeMembers!(AbstractT, AllTypes))
                static if (is(Member == T))
                    names ~= getGraphQLTypeName!AbstractT;
        return names;
    }();
}

/// The abstract type names (see abstractTypeNamesOf) of T in the schema
/// SchemaSource (none without one).
template abstractTypeNamesIn(T, alias SchemaSource) {
    static if (is(SchemaSource == void))
        enum string[] abstractTypeNamesIn = null;
    else
        enum string[] abstractTypeNamesIn = abstractTypeNamesOf!(T, getSchemaObjectTypes!SchemaSource);
}

/// Whether the type condition `condition` (null if none) of a fragment
/// applies to the type `typeName`, which is a member of the abstract types
/// `abstractNames`.
bool typeConditionApplies(string condition, string typeName, const string[] abstractNames) {
    if (condition is null || condition == typeName)
        return true;
    foreach (name; abstractNames)
        if (condition == name)
            return true;
    return false;
}

/// Process a list of selections, handling Field, FragmentSpread, and InlineFragment.
/// The processField delegate is called for each Field selection. Fragments
/// apply whose type condition is the type `typeName` or one of the abstract
/// types `abstractNames` it is a member of.
void processSelections(string typeName, string[] abstractNames = null)(
    Selection[] selections, JSONValue variables, FragmentMap fragments,
    ref string[] fieldNames, ref ExprBase[] fieldExprs,
    ExprBase delegate(Field) processField,
    bool[string] expanding = null
) {
    foreach (sel; selections) {
        if (sel.ruleSelection == SelectionEnum.Field) {
            auto field = sel.field;
            if (!shouldIncludeField(field.dirs, variables)) continue;
            fieldNames ~= getOutputName(field);
            fieldExprs ~= processField(field);
        } else if (sel.ruleSelection == SelectionEnum.Spread) {
            auto spread = sel.frag;
            if (!shouldIncludeField(spread.dirs, variables)) continue;
            auto fragName = spread.name.value;
            if (expanding !is null && fragName in expanding)
                throw new CompilerException("Circular fragment reference: " ~ fragName);
            auto fragDefPtr = fragName in fragments;
            if (fragDefPtr is null)
                throw new CompilerException("Unknown fragment: " ~ fragName);
            auto fragDef = *fragDefPtr;
            // Check type condition
            if (!typeConditionApplies(fragDef.tc.value, typeName, abstractNames))
                continue;
            if (expanding is null)
                expanding = [fragName: true];
            else
                expanding[fragName] = true;
            processSelections!(typeName, abstractNames)(
                iterateSelections(fragDef.ss), variables, fragments,
                fieldNames, fieldExprs, processField, expanding
            );
            expanding.remove(fragName);
        } else if (sel.ruleSelection == SelectionEnum.IFrag) {
            auto ifrag = sel.ifrag;
            if (!shouldIncludeField(ifrag.dirs, variables)) continue;
            // Check type condition
            if (!typeConditionApplies(ifrag.tc.value, typeName, abstractNames))
                continue;
            processSelections!(typeName, abstractNames)(
                iterateSelections(ifrag.ss), variables, fragments,
                fieldNames, fieldExprs, processField, expanding
            );
        }
    }
}

// ============================================================================
// Root Selection Set Compilation
// ============================================================================

/// Compile the root selection set (fields from Query type)
DynamicJsonObjectExpr compileRootSelectionSet(Query, alias IntrospectionSource = Query)(SelectionSet ss, JSONValue variables, FragmentMap fragments) {
    auto selections = iterateSelections(ss);

    if (selections.length == 0) {
        throw new CompilerException("Empty selection set");
    }

    string[] fieldNames;
    ExprBase[] fieldExprs;
    string[] schemaFieldNames;

    processSelections!(getGraphQLTypeName!Query)(
        selections, variables, fragments, fieldNames, fieldExprs,
        (field) {
            schemaFieldNames ~= getFieldName(field);
            return compileRootField!(Query, IntrospectionSource)(field, variables, fragments);
        }
    );
    assert(schemaFieldNames.length == fieldNames.length);

    // Null bubbling: a null in a non-null root field makes the whole result
    // (the response's `data`) null.
    return buildDynamicJsonObject(fieldNames, fieldExprs, [],
        resolveNonNullFlags!Query(schemaFieldNames),
        resolveNonNullItemFlags!Query(schemaFieldNames));
}

// ============================================================================
// Selection Set Compilation (for entity types)
// ============================================================================

/// Compile a selection set into a MapExpr with DynamicJsonObjectExpr body.
/// Returns Expr!(JSONValue[]) which is the result of mapping over the collection.
/// Note: Explicit return type breaks circular template instantiation.
/// SchemaSource enables abstract type resolution for nested fields.
MapExpr!(Entity, DynamicJsonObjectExpr) compileMapExpr(Entity, alias SchemaSource = void, Coll)(Coll collection, SelectionSet ss, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    return map!(
        (Expr!Entity entity) => compileSelectionSetBody!(Entity, SchemaSource)(entity, ss, variables, fragments, pathPrefix)
    )(collection);
}

/// Compile a selection set for each item of a list of objects, nullable
/// objects, or (nested) lists of them.
/// Returns Expr!(JSONValue[]), the items' JSON values for each list.
/// Note: Explicit return type breaks circular template instantiation.
Expr!(JSONValue[]) compileListItems(E, alias SchemaSource = void, Coll)(Coll collection, SelectionSet ss,
    JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    static if (isObjectElement!E) {
        return compileMapExpr!(E, SchemaSource)(collection, ss, variables, fragments, pathPrefix);
    } else {
        return map!(
            (Expr!E item) => compileListItem!(E, SchemaSource)(item, ss, variables, fragments, pathPrefix)
        )(collection);
    }
}

/// Compile one item of a list which is not a plain object (a nullable
/// object, or a list) as a field result of its own, as one JSON value.
Expr!JSONValue compileListItem(E, alias SchemaSource = void)(Expr!E item, SelectionSet ss,
    JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    auto compiled = compileFieldResult!(Expr!E, SchemaSource)(item, ss, variables, fragments, pathPrefix);
    if (auto json = cast(Expr!JSONValue) compiled)
        return json;
    auto items = cast(Expr!(JSONValue[])) compiled;
    assert(items !is null, "List item of type " ~ E.stringof ~ " compiled to neither JSON nor a JSON list");
    // Null bubbling: a null item in a list of non-null items makes the list null
    static if (is(E == F[], F) && bubblesNullItems!F)
        return use(&strictListJson, items);
    else
        return use(&listJson, items);
}

/// A list's JSON value.
private JSONValue listJson(JSONValue[] items) {
    return JSONValue(items);
}

/// A list's JSON value, null if one of its (non-null) items is null.
private JSONValue strictListJson(JSONValue[] items) {
    foreach (item; items)
        if (item.isNull)
            return JSONValue(null);
    return JSONValue(items);
}

/// Compile the body of a selection set (the fields to extract).
/// Works with any struct type that has field methods.
/// SchemaSource enables abstract type resolution for nested fields.
DynamicJsonObjectExpr compileSelectionSetBody(T, alias SchemaSource = void)(Expr!T ref_, SelectionSet ss, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    auto selections = iterateSelections(ss);
    if (selections.length == 0) {
        throw new CompilerException("Empty selection set for " ~ T.stringof);
    }

    // Build field name/value pairs for jsonObject
    return compileFieldsToJsonObject!(T, SchemaSource)(ref_, selections, variables, fragments, pathPrefix);
}

/// Compile selected fields into a jsonObject call.
/// Works with any struct type that has field methods.
/// SchemaSource enables abstract type resolution for nested fields.
DynamicJsonObjectExpr compileFieldsToJsonObject(T, alias SchemaSource = void)(Expr!T ref_, Selection[] selections, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    // Collect field expressions
    ExprBase[] fieldExprs;
    string[] fieldNames;
    // Schema field names, parallel to fieldNames (which hold output names,
    // i.e. aliases where present).
    string[] schemaFieldNames;

    processSelections!(getGraphQLTypeName!T, abstractTypeNamesIn!(T, SchemaSource))(
        selections, variables, fragments, fieldNames, fieldExprs,
        (field) {
            schemaFieldNames ~= getFieldName(field);
            return compileFieldAccess!(T, SchemaSource)(ref_, field, variables, fragments, pathPrefix);
        }
    );
    assert(schemaFieldNames.length == fieldNames.length);

    // Determine non-null flags for null bubbling. Nullability is a property
    // of the schema field, so look it up by field name, not by alias.
    bool[] nonNullFlags = resolveNonNullFlags!T(schemaFieldNames);
    bool[] nonNullItemFlags = resolveNonNullItemFlags!T(schemaFieldNames);

    // Build a dynamic JSON object using runtime construction, one per
    // object in ref_'s batch
    return buildDynamicJsonObject(fieldNames, fieldExprs, pathPrefix, nonNullFlags, nonNullItemFlags, ref_);
}

/// Determine which fields are non-nullable based on compile-time D type info.
/// Uses the D return type directly (avoiding graphqlTypeName which may fail for
/// internal types like ForeignKey).
bool[] resolveNonNullFlags(T)(string[] fieldNames) {
    bool[] flags = new bool[fieldNames.length];
    foreach (i, name; fieldNames) {
        if (name == "__typename") {
            flags[i] = true; // __typename is always String!
            continue;
        }
        static foreach (member; getSchemaFields!T) {{
            alias memberSym = __traits(getMember, T, member);
            static if (!hasGqlHidden!memberSym) {
                enum gqlName = getGqlName!(memberSym, member);
                if (name == gqlName) {
                    flags[i] = isNonNullResultType!(fieldResultType!(T, member));
                }
            }
        }}
    }
    return flags;
}

/// Determine which fields are lists of non-null objects ([T!]), so that a
/// null item (e.g. from null bubbling) can be propagated to the list.
bool[] resolveNonNullItemFlags(T)(string[] fieldNames) {
    bool[] flags = new bool[fieldNames.length];
    foreach (i, name; fieldNames) {
        static foreach (member; getSchemaFields!T) {{
            alias memberSym = __traits(getMember, T, member);
            static if (!hasGqlHidden!memberSym) {
                enum gqlName = getGqlName!(memberSym, member);
                if (name == gqlName) {
                    flags[i] = isNonNullObjectListType!(fieldResultType!(T, member));
                }
            }
        }}
    }
    return flags;
}

/// Check if a D type maps to a GraphQL list whose non-null items can become
/// null through null bubbling: objects, or lists of them (see
/// bubblesNullItems). Scalar items cannot, and array-valued scalars must not
/// be inspected.
private template isNonNullObjectListType(T) {
    import std.traits : isSomeString;
    import std.typecons : Nullable;
    static if (isGqlResult!T) {
        enum isNonNullObjectListType = isNonNullObjectListType!(typeof(T.init.value));
    } else static if (is(T == Nullable!U, U)) {
        enum isNonNullObjectListType = isNonNullObjectListType!U;
    } else static if (is(T == E[], E) && !isSomeString!T && !isCustomScalar!T) {
        enum isNonNullObjectListType = bubblesNullItems!E;
    } else {
        enum isNonNullObjectListType = false;
    }
}

/// Check if a D type maps to a non-nullable GraphQL type.
/// Nullable!T and pointer types are nullable; GqlResult!T uses inner type's nullability.
private template isNonNullResultType(T) {
    import std.typecons : Nullable;
    static if (is(T == Nullable!U, U)) {
        enum isNonNullResultType = false;
    } else static if (is(T == U*, U)) {
        enum isNonNullResultType = false;
    } else static if (isGqlResult!T) {
        enum isNonNullResultType = isNonNullResultType!(typeof(T.init.value));
    } else {
        enum isNonNullResultType = true;
    }
}

/// Build a JSON object from runtime field names and expressions
DynamicJsonObjectExpr buildDynamicJsonObject(string[] names, ExprBase[] exprs, JSONValue[] pathPrefix = [],
    bool[] nonNullFields = [], bool[] nonNullItemFields = [], ExprBase lengthSource = null) {
    return new DynamicJsonObjectExpr(names, exprs, pathPrefix, nonNullFields, nonNullItemFields, lengthSource);
}

/// Compile the result of a field method based on its return type.
/// Handles scalars, structs (with selection sets), arrays, and abstract types.
/// Scalars are wrapped to convert to JSONValue.
/// Structs/arrays of structs compile selection sets.
/// SchemaSource enables abstract type resolution (default void = no abstract types).
ExprBase compileFieldResult(ResultExpr, alias SchemaSource = void)(ResultExpr resultExpr, SelectionSet ss, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    import dunamis.core.expr : BoundObjectExpr, ExprResultType, ObjectExpr, UnwrapNullableExpr,
        finalizeNullableObjectExpr;

    alias ResultType = ExprResultType!ResultExpr;

    // Arrays need element type inspection
    static if (is(ResultType == E[], E)) {
        // Abstract type array (union/interface) — per-member dispatch
        static if (is(E == struct) && isAbstractType!E && !is(SchemaSource == void)) {
            if (ss is null) {
                throw new CompilerException(
                    "Field returning [" ~ E.stringof ~ "] requires a selection set");
            }
            return compileAbstractArrayResult!(E, SchemaSource)(resultExpr, ss, variables, fragments, pathPrefix);
        }
        else static if (isScalarElement!E) {
            // Array of scalars (custom or primitive) or GqlResult elements - wrap to JSON
            return wrapAsJsonExpr(resultExpr);
        } else {
            // Array of structs, nullable structs or lists of them - requires selection set
            if (ss is null) {
                throw new CompilerException(
                    "Field returning [" ~ E.stringof ~ "] requires a selection set");
            }
            return compileListItems!(E, SchemaSource)(resultExpr, ss, variables, fragments, pathPrefix);
        }
    }
    // GqlResult types — materialize errors to Nullable and recurse
    else static if (isGqlResult!ResultType) {
        import dunamis.core.expr.json : materializeResult;
        alias Inner = typeof(ResultType.init.value);
        auto materialized = materializeResult!Inner(resultExpr, pathPrefix);
        return compileFieldResult!(typeof(materialized), SchemaSource)(materialized, ss, variables, fragments, pathPrefix);
    }
    // Nullable lists of objects - like nullable objects, with the selection
    // set compiled for each element of the unwrapped list
    else static if (is(ResultType == Nullable!(E[]), E) && !isScalarElement!E && !isAbstractType!E) {
        if (ss is null) {
            throw new CompilerException(
                "Field returning [" ~ E.stringof ~ "] requires a selection set");
        }
        auto unwrapper = new UnwrapNullableExpr!(E[])(resultExpr);
        auto items = compileListItems!(E, SchemaSource)(unwrapper, ss, variables, fragments, pathPrefix);
        auto innerExpr = use(&listJson, items);
        return finalizeNullableObjectExpr!(E[])(resultExpr, unwrapper, innerExpr);
    }
    // Nullable structs (entities) - handle null case specially
    else static if (is(ResultType == Nullable!T, T) && is(T == struct) && !isCustomScalar!T) {
        if (ss is null) {
            throw new CompilerException(
                "Field returning " ~ T.stringof ~ " requires a selection set");
        }
        // Create unwrapper expression that forwards to the nullable input
        // This preserves the chain for optimization (findMapExprFromChain)
        auto unwrapper = new UnwrapNullableExpr!T(resultExpr);
        // Compile selection set using the unwrapper as input
        auto innerExpr = compileSelectionSetBody!(T, SchemaSource)(unwrapper, ss, variables, fragments, pathPrefix);
        // Wrap in nullable handler
        return finalizeNullableObjectExpr!T(resultExpr, unwrapper, innerExpr);
    }
    // Nullable scalars (e.g., Nullable!string) - wrap to JSON
    else static if (is(ResultType == Nullable!U, U)) {
        return wrapAsJsonExpr(resultExpr);
    }
    // Structs (non-CustomScalar, non-Nullable) require selection sets
    else static if (is(ResultType == struct) && !isCustomScalar!ResultType) {
        if (ss is null) {
            throw new CompilerException(
                "Field returning " ~ ResultType.stringof ~ " requires a selection set");
        }
        // Evaluate the object once for all selected fields (see ObjectExpr)
        auto bound = new BoundObjectExpr!ResultType(resultExpr);
        auto innerExpr = compileSelectionSetBody!(ResultType, SchemaSource)(bound, ss, variables, fragments, pathPrefix);
        return new ObjectExpr!ResultType(resultExpr, innerExpr, bound);
    }
    // Scalars (primitives and CustomScalar) - wrap to JSON
    else {
        return wrapAsJsonExpr(resultExpr);
    }
}

/// Compile access to a single field.
/// Finds a computed field method with signature (Expr!T, args...) -> Expr!U and calls it.
/// SchemaSource enables abstract type resolution for nested fields.
ExprBase compileFieldAccess(T, alias SchemaSource = void)(Expr!T ref_, Field field, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    auto fieldName = getFieldName(field);

    // Build nested path for selection sets within this field
    auto outputName = getOutputName(field);
    JSONValue[] nestedPath = pathPrefix.dup;
    nestedPath ~= JSONValue(outputName);

    // Match field against computed fields from the schema protocol
    static foreach (member; getSchemaFields!T) {{
        alias memberSym = __traits(getMember, T, member);
        static if (!hasGqlHidden!memberSym) {
            enum gqlName = getGqlName!(memberSym, member);
            if (fieldName == gqlName) {
                // A field without arguments is called directly, rather than
                // through an instance of callComputedField of its own
                static if (Parameters!memberSym.length > 1)
                    auto resultExpr = callComputedField!(memberSym, T)(ref_, field.args, variables);
                else
                    auto resultExpr = memberSym(ref_);
                return compileFieldResult!(typeof(resultExpr), SchemaSource)(resultExpr, field.ss, variables, fragments, nestedPath);
            }
        }
    }}

    // __typename: returns the GraphQL type name as a constant
    if (fieldName == "__typename") {
        return wrapAsJsonExpr(constant(getGraphQLTypeName!T, ref_));
    }

    throw new CompilerException("Unknown field '" ~ fieldName ~ "' on type " ~ T.stringof);
}

// ============================================================================
// Abstract Type Compilation (Unions / Interfaces)
// ============================================================================

/// Compile an abstract type array result (union or interface).
/// For each concrete member type:
///   1. SubsetExpr extracts that member's elements
///   2. MapExpr compiles that member's fields using type-conditioned selections
///   3. ConcatArrayExpr merges all per-member JSON arrays
ExprBase compileAbstractArrayResult(AbstractT, alias SchemaSource, ResultExpr)(
    ResultExpr resultExpr, SelectionSet ss, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = [])
{
    alias AllTypes = getSchemaObjectTypes!SchemaSource;
    alias Members = getAbstractTypeMembers!(AbstractT, AllTypes);

    static assert(Members.length > 0,
        "Abstract type " ~ AbstractT.stringof ~ " has no concrete members");

    ExprBase[] memberJsonExprs;

    static foreach (Member; Members) {{
        // 1. Extract this member type's elements from the union batch
        auto subset = new SubsetExpr!Member(resultExpr);

        // 2. Compile selection set for this member type
        // processSelections will naturally filter type-conditioned fragments
        auto memberMapExpr = compileMapExpr!(Member, SchemaSource)(subset, ss, variables, fragments, pathPrefix);

        memberJsonExprs ~= memberMapExpr;
    }}

    // 3. Concatenate all per-member JSON arrays
    return new ConcatArrayExpr(memberJsonExprs);
}
