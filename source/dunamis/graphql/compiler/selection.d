module dunamis.graphql.compiler.selection;

import std.conv;
import std.json;
import std.traits;
import std.typecons : Nullable;

import graphql.ast;
import graphql.tokenmodule : Token;

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
import dunamis.graphql.compiler.shape;

// ============================================================================
// Root Selection Sets
// ============================================================================

package(dunamis.graphql):

/// The fields of the root selection set `ss` of an operation on the root
/// type Root, compiled (see compileRootField), with their output names and
/// nullability (see fieldNullability). `operation` names the operation for
/// errors ("query", "mutation", "subscription").
private auto compileRootFields(Root, alias SchemaType)(SelectionSet ss, JSONValue variables,
    FragmentMap fragments, string operation)
{
    static struct RootFields {
        string[] names;
        ExprBase[] exprs;
        FieldNullability nullability;
    }

    if (iterateSelections(ss).length == 0)
        throw new CompilerException(operation == "query" ? "Empty selection set" :
            "Empty " ~ operation ~ " selection set");

    RootFields result;
    string[] schemaFieldNames;
    processSelections!(getGraphQLTypeName!Root)(ss, variables, fragments, result.names, result.exprs,
        (field) {
            schemaFieldNames ~= getFieldName(field);
            return compileRootField!(Root, SchemaType)(field, variables, fragments);
        }
    );
    assert(schemaFieldNames.length == result.names.length);
    result.nullability = fieldNullability!Root(schemaFieldNames);
    return result;
}

/// Compile the root selection set for subscriptions.
/// GraphQL spec requires exactly one root field for subscriptions.
DynamicJsonObjectExpr compileRootSubscriptionSet(Subscription, alias SchemaType = Subscription)(SelectionSet ss, JSONValue variables, FragmentMap fragments) {
    auto fields = compileRootFields!(Subscription, SchemaType)(ss, variables, fragments, "subscription");

    // GraphQL spec: subscriptions must have exactly one root field
    if (fields.names.length != 1) {
        throw new CompilerException("Subscription operations must have exactly one root field, got " ~ fields.names.length.to!string);
    }

    return new DynamicJsonObjectExpr(fields.names, fields.exprs);
}

/// Compile the root selection set for mutations (sequential execution).
/// Null bubbling as for queries: a null in a non-null root field makes the
/// whole result null.
SequentialJsonObjectExpr compileRootMutationSet(Mutation, alias SchemaType = Mutation)(SelectionSet ss, JSONValue variables, FragmentMap fragments) {
    auto fields = compileRootFields!(Mutation, SchemaType)(ss, variables, fragments, "mutation");
    return new SequentialJsonObjectExpr(fields.names, fields.exprs, [],
        fields.nullability.nonNull, fields.nullability.nonNullItems);
}

/// Compile the root selection set of a query (fields from the Query type).
/// Null bubbling: a null in a non-null root field makes the whole result
/// (the response's `data`) null.
DynamicJsonObjectExpr compileRootSelectionSet(Query, alias IntrospectionSource = Query)(SelectionSet ss, JSONValue variables, FragmentMap fragments) {
    auto fields = compileRootFields!(Query, IntrospectionSource)(ss, variables, fragments, "query");
    return buildDynamicJsonObject(fields.names, fields.exprs, [],
        fields.nullability.nonNull, fields.nullability.nonNullItems);
}

/// The selection set `ss` of the introspection JSON `data` (see
/// applySelectionSet), applied when evaluated (for the root's batch of one):
/// the objects of each request's response are its own.
private final class IntrospectionSelectionExpr : Expr!JSONValue {
    import ae.utils.promise : Promise, resolve;
    import dunamis.core.eval : EvalContext;

    private JSONValue _data;
    private SelectionSet _ss;
    private JSONValue _variables;
    private FragmentMap _fragments;

    this(JSONValue data, SelectionSet ss, JSONValue variables, FragmentMap fragments) {
        _data = data;
        _ss = ss;
        _variables = variables;
        _fragments = fragments;
    }

    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t, ExprBase) {}

    override Promise!(JSONValue[]) eval(EvalContext ctx) {
        return resolve([applySelectionSet(_data, _ss, _variables, _fragments)]);
    }
}

/// The introspection JSON of the schema (or Query type) S (see
/// buildIntrospectionJson), built once per thread: the values introspection
/// meta-fields select from (which they do not modify).
private JSONValue introspectionJsonOf(alias S)() {
    static JSONValue cached;
    static bool built;
    if (!built) {
        cached = buildIntrospectionJson!S();
        built = true;
    }
    return cached;
}

/// The introspection JSON of each type of S, by name (see
/// buildTypeLookup), built once per thread.
private JSONValue[string] typeLookupOf(alias S)() {
    static JSONValue[string] cached;
    static bool built;
    if (!built) {
        foreach (typeJson; introspectionJsonOf!S()["types"].array)
            cached[typeJson["name"].str] = typeJson;
        built = true;
    }
    return cached;
}

/// Compile a single field of a root type (Query, Mutation or Subscription).
/// The root types' fields are compiled like those of any other type
/// (compileFieldAccess), on the request's single instance of the root type;
/// only the introspection meta-fields of the schema are particular to them.
ExprBase compileRootField(Parent, alias IntrospectionSource = Parent)(Field field, JSONValue variables, FragmentMap fragments) {
    auto fieldName = getFieldName(field);

    // Introspection meta-fields
    if (fieldName == "__schema")
        return new IntrospectionSelectionExpr(introspectionJsonOf!IntrospectionSource(), field.ss, variables,
            fragments);
    if (fieldName == "__type") {
        auto typeName = extractTypeNameArg(field.args, variables);
        auto lookup = typeLookupOf!IntrospectionSource();
        if (auto typeJson = typeName in lookup)
            return new IntrospectionSelectionExpr(*typeJson, field.ss, variables, fragments);
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

/// Compile the fields selection set `ss` selects (see foreachSelectedField):
/// processField compiles each, whose output name and compiled expression
/// are appended to fieldNames and fieldExprs. Fragments apply whose type
/// condition is the type `typeName` or one of the abstract types
/// `abstractNames` it is a member of.
void processSelections(string typeName, string[] abstractNames = null)(
    SelectionSet ss, JSONValue variables, FragmentMap fragments,
    ref string[] fieldNames, ref ExprBase[] fieldExprs,
    ExprBase delegate(Field) processField
) {
    // The fields by response key, in the order of their first occurrence:
    // a key selected more than once (e.g. by a fragment and by the selection
    // set itself) is one field, whose selection set is all of theirs (as
    // the spec merges them: CollectFields, MergeSelectionSets)
    string[] keys;
    Field[][string] occurrences;
    foreachSelectedField(ss, fragments, &variables,
        (Token typeCondition, SelectionSet _) => typeConditionApplies(typeCondition.value, typeName, abstractNames),
        (Field field) {
            auto key = getOutputName(field);
            if (key !in occurrences)
                keys ~= key;
            occurrences[key] ~= field;
        },
        FragmentSpreads(true));
    foreach (key; keys) {
        fieldNames ~= key;
        fieldExprs ~= processField(mergedField(occurrences[key]));
    }
}

/// The field `fields` (the occurrences of one response key) select: the
/// first, with the selection sets of all (if it has one).
private Field mergedField(Field[] fields) @safe {
    import graphql.ast : FieldEnum, Selections, SelectionsEnum, SelectionSetEnum;

    if (fields.length == 1 || fields[0].ss is null)
        return fields[0];
    // The selections of all, chained (each occurrence's in its order)
    Selections head, tail;
    foreach (field; fields) {
        if (field.ss is null)
            continue;
        for (auto sels = field.ss.sel; sels !is null; sels = sels.follow) {
            auto link = new Selections(SelectionsEnum.Sels, sels.sel);
            if (head is null)
                head = link;
            else
                tail.follow = link;
            tail = link;
        }
    }
    auto merged = new Field(fields[0].ruleSelection, fields[0].name, fields[0].args, fields[0].dirs,
        new SelectionSet(SelectionSetEnum.SS, head));
    return merged;
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
    static if (shapeOf!E == Shape.object) {
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
    if (iterateSelections(ss).length == 0) {
        throw new CompilerException("Empty selection set for " ~ T.stringof);
    }

    // Build field name/value pairs for jsonObject
    return compileFieldsToJsonObject!(T, SchemaSource)(ref_, ss, variables, fragments, pathPrefix);
}

/// Compile selected fields into a jsonObject call.
/// Works with any struct type that has field methods.
/// SchemaSource enables abstract type resolution for nested fields.
DynamicJsonObjectExpr compileFieldsToJsonObject(T, alias SchemaSource = void)(Expr!T ref_, SelectionSet ss, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    // Collect field expressions
    ExprBase[] fieldExprs;
    string[] fieldNames;
    // Schema field names, parallel to fieldNames (which hold output names,
    // i.e. aliases where present).
    string[] schemaFieldNames;

    processSelections!(getGraphQLTypeName!T, abstractTypeNamesIn!(T, SchemaSource))(
        ss, variables, fragments, fieldNames, fieldExprs,
        (field) {
            schemaFieldNames ~= getFieldName(field);
            return compileFieldAccess!(T, SchemaSource)(ref_, field, variables, fragments, pathPrefix);
        }
    );
    assert(schemaFieldNames.length == fieldNames.length);

    // Determine non-null flags for null bubbling. Nullability is a property
    // of the schema field, so look it up by field name, not by alias.
    auto nullability = fieldNullability!T(schemaFieldNames);

    // Build a dynamic JSON object using runtime construction, one per
    // object in ref_'s batch
    return buildDynamicJsonObject(fieldNames, fieldExprs, pathPrefix, nullability.nonNull,
        nullability.nonNullItems, ref_);
}

/// The nullability of fields of a type, for null bubbling (one flag per
/// field, see fieldNullability).
struct FieldNullability {
    /// The field has a non-null type: a null in it makes its object null.
    bool[] nonNull;
    /// The field is a list of non-null objects ([T!], or lists of them): a
    /// null item (e.g. from null bubbling) makes the list null.
    bool[] nonNullItems;
}

/// The nullability of the fields of T named (in GraphQL) `fieldNames`,
/// from their D result types (see isNonNullType, isNonNullItemListType;
/// avoiding graphqlTypeName, which may fail for internal types like
/// ForeignKey). Nullability is a property of the schema field: look it up by
/// field name, not by alias.
FieldNullability fieldNullability(T)(string[] fieldNames) {
    FieldNullability result;
    result.nonNull = new bool[fieldNames.length];
    result.nonNullItems = new bool[fieldNames.length];
    foreach (i, name; fieldNames) {
        if (name == "__typename") {
            result.nonNull[i] = true; // __typename is always String!
            continue;
        }
        static foreach (member; getSchemaFields!T) {{
            alias memberSym = __traits(getMember, T, member);
            static if (!hasGqlHidden!memberSym) {
                enum gqlName = getGqlName!(memberSym, member);
                if (name == gqlName) {
                    result.nonNull[i] = isNonNullType!(fieldResultType!(T, member));
                    result.nonNullItems[i] = isNonNullItemListType!(fieldResultType!(T, member));
                }
            }
        }}
    }
    return result;
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
        else static if (isLeafElement!E) {
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
    else static if (is(ResultType == Nullable!(E[]), E) && !isLeafElement!E && !isAbstractType!E) {
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
