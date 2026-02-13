module dunamis.graphql.compiler.selection;

import std.conv;
import std.json;
import std.traits;
import std.typecons : Nullable;

import graphql.ast;

import dunamis.core.expr : ExprBase, ExprResultType, Expr, isExpr, singleton,
    DynamicJsonObjectExpr, SequentialJsonObjectExpr, MapExpr,
    use, toJsonValue, map, constant;
import dunamis.core.types : isCustomScalar, isGqlResult, GqlResult;
import dunamis.core.discovery : getSchemaFields, fieldResultType;
import dunamis.graphql.introspection;
import dunamis.graphql.schema;
import dunamis.graphql.compiler.values;
import dunamis.graphql.compiler.fields;

// ============================================================================
// Root Mutation Compilation
// ============================================================================

package(dunamis.graphql):

/// Compile the root selection set for mutations (sequential execution)
SequentialJsonObjectExpr compileRootMutationSet(Mutation)(SelectionSet ss, JSONValue variables, FragmentMap fragments) {
    auto selections = iterateSelections(ss);

    if (selections.length == 0) {
        throw new CompilerException("Empty mutation selection set");
    }

    string[] fieldNames;
    ExprBase[] fieldExprs;

    processSelections!(getGraphQLTypeName!Mutation)(
        selections, variables, fragments, fieldNames, fieldExprs,
        (field) => compileRootField!Mutation(field, variables, fragments)
    );

    return new SequentialJsonObjectExpr(fieldNames, fieldExprs);
}

/// Compile a single root field (works for both Query and Mutation).
/// Scans for function members with matching GraphQL name.
ExprBase compileRootField(Parent, alias IntrospectionSource = Parent)(Field field, JSONValue variables, FragmentMap fragments) {
    auto fieldName = getFieldName(field);
    auto parentExpr = singleton(Parent.init);

    // Introspection fields
    if (fieldName == "__typename") {
        return wrapAsJsonExpr(singleton(getGraphQLTypeName!Parent));
    }
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

    // Build path prefix for nested selections: [outputName]
    auto outputName = getOutputName(field);
    JSONValue[] nestedPath = [JSONValue(outputName)];

    static foreach (member; getSchemaFields!Parent) {{
        alias memberSym = __traits(getMember, Parent, member);
        enum gqlName = getGqlName!(memberSym, member);
        if (fieldName == gqlName) {
            return callRootField!(memberSym, Parent)(parentExpr, field.args, field.ss, variables, fragments, nestedPath);
        }
    }}

    throw new CompilerException("Unknown field: " ~ fieldName);
}

/// Call a root field function and handle the return type.
/// Root fields return Expr!T which we may need to descend into with a selection set.
/// Works for both Query and Mutation fields.
ExprBase callRootField(alias fn, Parent)(Expr!Parent parent, Arguments args, SelectionSet ss, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    import std.traits : Parameters, ReturnType, ParameterDefaults, ParameterIdentifierTuple;
    import std.typecons : tuple;
    import dunamis.core.expr : Expr, ExprResultType, isExpr;

    alias Params = Parameters!fn;
    alias Return = ReturnType!fn;

    // Verify return type is an Expr
    static assert(isExpr!Return,
        "Root field " ~ __traits(identifier, fn) ~ " must return an Expr type, got " ~ Return.stringof);

    // Extract arguments (skip first param which is parent)
    static if (Params.length == 1) {
        // Only parent, no additional args
        auto resultExpr = fn(parent);
    } else {
        auto argTuple = mixin(() {
            string code = "tuple(";
            static foreach (i; 1 .. Params.length) {
                code ~= (i > 1 ? ", " : "") ~
                    "extractArg!(Params[" ~ i.stringof ~ "], ParameterDefaults!fn[" ~ i.stringof ~ "])" ~
                    "(args, [ParameterIdentifierTuple!fn][" ~ i.stringof ~ "], variables)";
            }
            code ~= ")";
            return code;
        }());
        auto resultExpr = fn(parent, argTuple.expand);
    }

    // Handle return type generically
    return compileFieldResult!(typeof(resultExpr))(resultExpr, ss, variables, fragments, pathPrefix);
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

/// Process a list of selections, handling Field, FragmentSpread, and InlineFragment.
/// The processField delegate is called for each Field selection.
void processSelections(string typeName)(
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
            if (fragDef.tc.value !is null && fragDef.tc.value != typeName)
                continue;
            if (expanding is null)
                expanding = [fragName: true];
            else
                expanding[fragName] = true;
            processSelections!typeName(
                iterateSelections(fragDef.ss), variables, fragments,
                fieldNames, fieldExprs, processField, expanding
            );
            expanding.remove(fragName);
        } else if (sel.ruleSelection == SelectionEnum.IFrag) {
            auto ifrag = sel.ifrag;
            if (!shouldIncludeField(ifrag.dirs, variables)) continue;
            // Check type condition
            if (ifrag.tc.value !is null && ifrag.tc.value != typeName)
                continue;
            processSelections!typeName(
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

    processSelections!(getGraphQLTypeName!Query)(
        selections, variables, fragments, fieldNames, fieldExprs,
        (field) => compileRootField!(Query, IntrospectionSource)(field, variables, fragments)
    );

    return buildDynamicJsonObject(fieldNames, fieldExprs);
}

// ============================================================================
// Selection Set Compilation (for entity types)
// ============================================================================

/// Compile a selection set into a MapExpr with DynamicJsonObjectExpr body.
/// Returns Expr!(JSONValue[]) which is the result of mapping over the collection.
/// Note: Explicit return type breaks circular template instantiation.
MapExpr!(Entity, DynamicJsonObjectExpr) compileMapExpr(Entity, Coll)(Coll collection, SelectionSet ss, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    return map!(
        (Expr!Entity entity) => compileSelectionSetBody!Entity(entity, ss, variables, fragments, pathPrefix)
    )(collection);
}

/// Compile the body of a selection set (the fields to extract).
/// Works with any struct type that has field methods.
DynamicJsonObjectExpr compileSelectionSetBody(T)(Expr!T ref_, SelectionSet ss, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    auto selections = iterateSelections(ss);
    if (selections.length == 0) {
        throw new CompilerException("Empty selection set for " ~ T.stringof);
    }

    // Build field name/value pairs for jsonObject
    return compileFieldsToJsonObject!T(ref_, selections, variables, fragments, pathPrefix);
}

/// Compile selected fields into a jsonObject call.
/// Works with any struct type that has field methods.
DynamicJsonObjectExpr compileFieldsToJsonObject(T)(Expr!T ref_, Selection[] selections, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    // Collect field expressions
    ExprBase[] fieldExprs;
    string[] fieldNames;

    processSelections!(getGraphQLTypeName!T)(
        selections, variables, fragments, fieldNames, fieldExprs,
        (field) => compileFieldAccess!T(ref_, field, variables, fragments, pathPrefix)
    );

    // Determine non-null flags for null bubbling
    bool[] nonNullFlags = resolveNonNullFlags!T(fieldNames);

    // Build a dynamic JSON object using runtime construction
    return buildDynamicJsonObject(fieldNames, fieldExprs, pathPrefix, nonNullFlags);
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
DynamicJsonObjectExpr buildDynamicJsonObject(string[] names, ExprBase[] exprs, JSONValue[] pathPrefix = [], bool[] nonNullFields = []) {
    return new DynamicJsonObjectExpr(names, exprs, pathPrefix, nonNullFields);
}

/// Compile the result of a field method based on its return type.
/// Handles scalars, structs (with selection sets), and arrays.
/// Scalars are wrapped to convert to JSONValue.
/// Structs/arrays of structs compile selection sets.
ExprBase compileFieldResult(ResultExpr)(ResultExpr resultExpr, SelectionSet ss, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
    import dunamis.core.expr : ExprResultType, UnwrapNullableExpr, finalizeNullableObjectExpr;

    alias ResultType = ExprResultType!ResultExpr;

    // Arrays need element type inspection
    static if (is(ResultType == E[], E)) {
        static if (isCustomScalar!E || !is(E == struct) || isGqlResult!E) {
            // Array of scalars (custom or primitive) or GqlResult elements - wrap to JSON
            return wrapAsJsonExpr(resultExpr);
        } else {
            // Array of structs - requires selection set
            if (ss is null) {
                throw new CompilerException(
                    "Field returning [" ~ E.stringof ~ "] requires a selection set");
            }
            return compileMapExpr!E(resultExpr, ss, variables, fragments, pathPrefix);
        }
    }
    // GqlResult types — materialize errors to Nullable and recurse
    else static if (isGqlResult!ResultType) {
        import dunamis.core.expr.json : materializeResult;
        alias Inner = typeof(ResultType.init.value);
        auto materialized = materializeResult!Inner(resultExpr, pathPrefix);
        return compileFieldResult!(typeof(materialized))(materialized, ss, variables, fragments, pathPrefix);
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
        auto innerExpr = compileSelectionSetBody!T(unwrapper, ss, variables, fragments, pathPrefix);
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
        return compileSelectionSetBody!ResultType(resultExpr, ss, variables, fragments, pathPrefix);
    }
    // Scalars (primitives and CustomScalar) - wrap to JSON
    else {
        return wrapAsJsonExpr(resultExpr);
    }
}

/// Compile access to a single field.
/// Finds a computed field method with signature (Expr!T, args...) -> Expr!U and calls it.
ExprBase compileFieldAccess(T)(Expr!T ref_, Field field, JSONValue variables, FragmentMap fragments, JSONValue[] pathPrefix = []) {
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
                auto resultExpr = callComputedField!(memberSym, T)(ref_, field.args, variables);
                return compileFieldResult!(typeof(resultExpr))(resultExpr, field.ss, variables, fragments, nestedPath);
            }
        }
    }}

    // __typename: returns the GraphQL type name as a constant
    if (fieldName == "__typename") {
        return wrapAsJsonExpr(constant(getGraphQLTypeName!T, ref_));
    }

    throw new CompilerException("Unknown field '" ~ fieldName ~ "' on type " ~ T.stringof);
}
