module dunamis.graphql.compiler.selection;

import std.conv;
import std.json;
import std.traits;
import std.typecons : Nullable;

import graphql.ast;

import dunamis.core.expr : ExprBase, ExprResultType, Expr, isExpr, singleton,
    DynamicJsonObjectExpr, SequentialJsonObjectExpr, MapExpr, FieldAccessExpr, MethodCallExpr,
    use, toJsonValue, map, constant;
import dunamis.core.types : isCustomScalar, isPlainField, isPlainMethod;
import dunamis.graphql.introspection;
import dunamis.graphql.schema;
import dunamis.graphql.compiler.values;
import dunamis.graphql.compiler.fields;

// ============================================================================
// Root Mutation Compilation
// ============================================================================

package(dunamis.graphql):

/// Compile the root selection set for mutations (sequential execution)
SequentialJsonObjectExpr compileRootMutationSet(Mutation)(SelectionSet ss, JSONValue variables) {
    auto selections = iterateSelections(ss);

    if (selections.length == 0) {
        throw new CompilerException("Empty mutation selection set");
    }

    string[] fieldNames;
    ExprBase[] fieldExprs;

    foreach (sel; selections) {
        if (sel.ruleSelection != SelectionEnum.Field) continue;
        auto field = sel.field;
        if (!shouldIncludeField(field.dirs, variables)) continue;
        fieldNames ~= getOutputName(field);
        fieldExprs ~= compileRootField!Mutation(field, variables);
    }

    return new SequentialJsonObjectExpr(fieldNames, fieldExprs);
}

/// Compile a single root field (works for both Query and Mutation).
/// Scans for function members with matching GraphQL name.
ExprBase compileRootField(Parent, alias IntrospectionSource = Parent)(Field field, JSONValue variables) {
    auto fieldName = getFieldName(field);
    auto parentExpr = singleton(Parent.init);

    // Introspection fields
    if (fieldName == "__typename") {
        return wrapAsJsonExpr(singleton(getGraphQLTypeName!Parent));
    }
    if (fieldName == "__schema") {
        auto schemaJson = buildIntrospectionJson!IntrospectionSource();
        auto result = applySelectionSet(schemaJson, field.ss, variables);
        return wrapAsJsonExpr(singleton(result));
    }
    if (fieldName == "__type") {
        auto typeName = extractTypeNameArg(field.args, variables);
        auto lookup = buildTypeLookup!IntrospectionSource();
        if (auto typeJson = typeName in lookup) {
            return wrapAsJsonExpr(singleton(applySelectionSet(*typeJson, field.ss, variables)));
        }
        return wrapAsJsonExpr(singleton(JSONValue(null)));
    }

    static foreach (member; __traits(allMembers, Parent)) {{
        static if (!isInternalMember!member) {
            alias memberSym = __traits(getMember, Parent, member);
            static if (is(typeof(memberSym) == function)) {
                enum gqlName = getGqlName!(memberSym, member);
                if (fieldName == gqlName) {
                    return callRootField!(memberSym, Parent)(parentExpr, field.args, field.ss, variables);
                }
            }
        }
    }}

    throw new CompilerException("Unknown field: " ~ fieldName);
}

/// Call a root field function and handle the return type.
/// Root fields return Expr!T which we may need to descend into with a selection set.
/// Works for both Query and Mutation fields.
ExprBase callRootField(alias fn, Parent)(Expr!Parent parent, Arguments args, SelectionSet ss, JSONValue variables) {
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
    return compileFieldResult!(typeof(resultExpr))(resultExpr, ss, variables);
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
// Root Selection Set Compilation
// ============================================================================

/// Compile the root selection set (fields from Query type)
DynamicJsonObjectExpr compileRootSelectionSet(Query, alias IntrospectionSource = Query)(SelectionSet ss, JSONValue variables) {
    auto selections = iterateSelections(ss);

    if (selections.length == 0) {
        throw new CompilerException("Empty selection set");
    }

    string[] fieldNames;
    ExprBase[] fieldExprs;

    foreach (sel; selections) {
        if (sel.ruleSelection != SelectionEnum.Field) continue;
        auto field = sel.field;
        if (!shouldIncludeField(field.dirs, variables)) continue;
        fieldNames ~= getOutputName(field);
        fieldExprs ~= compileRootField!(Query, IntrospectionSource)(field, variables);
    }

    return buildDynamicJsonObject(fieldNames, fieldExprs);
}

// ============================================================================
// Selection Set Compilation (for entity types)
// ============================================================================

/// Compile a selection set into a MapExpr with DynamicJsonObjectExpr body.
/// Returns Expr!(JSONValue[]) which is the result of mapping over the collection.
/// Note: Explicit return type breaks circular template instantiation.
MapExpr!(Entity, DynamicJsonObjectExpr) compileMapExpr(Entity, Coll)(Coll collection, SelectionSet ss, JSONValue variables) {
    return map!(
        (Expr!Entity entity) => compileSelectionSetBody!Entity(entity, ss, variables)
    )(collection);
}

/// Compile the body of a selection set (the fields to extract).
/// Works with any struct type that has field methods.
DynamicJsonObjectExpr compileSelectionSetBody(T)(Expr!T ref_, SelectionSet ss, JSONValue variables) {
    auto selections = iterateSelections(ss);
    if (selections.length == 0) {
        throw new CompilerException("Empty selection set for " ~ T.stringof);
    }

    // Build field name/value pairs for jsonObject
    return compileFieldsToJsonObject!T(ref_, selections, variables);
}

/// Compile selected fields into a jsonObject call.
/// Works with any struct type that has field methods.
DynamicJsonObjectExpr compileFieldsToJsonObject(T)(Expr!T ref_, Selection[] selections, JSONValue variables) {
    // Collect field expressions
    ExprBase[] fieldExprs;
    string[] fieldNames;

    foreach (sel; selections) {
        if (sel.ruleSelection != SelectionEnum.Field) continue;
        auto field = sel.field;
        if (!shouldIncludeField(field.dirs, variables)) continue;
        auto name = getFieldName(field);
        auto outputName = getOutputName(field);

        fieldNames ~= outputName;
        fieldExprs ~= compileFieldAccess!T(ref_, field, variables);
    }

    // Build a dynamic JSON object using runtime construction
    return buildDynamicJsonObject(fieldNames, fieldExprs);
}

/// Build a JSON object from runtime field names and expressions
DynamicJsonObjectExpr buildDynamicJsonObject(string[] names, ExprBase[] exprs) {
    return new DynamicJsonObjectExpr(names, exprs);
}

/// Check if a member is a field method for type T.
/// A field method takes Expr!T as first parameter and returns an Expr.
template isFieldMethod(T, alias member) {
    import std.traits : Parameters, ReturnType;
    static if (is(typeof(member) == function)) {
        alias Params = Parameters!member;
        alias Return = ReturnType!member;
        static if (Params.length >= 1 && is(Params[0] == Expr!T) && isExpr!Return) {
            enum isFieldMethod = true;
        } else {
            enum isFieldMethod = false;
        }
    } else {
        enum isFieldMethod = false;
    }
}

/// Compile the result of a field method based on its return type.
/// Handles scalars, structs (with selection sets), and arrays.
/// Scalars are wrapped to convert to JSONValue.
/// Structs/arrays of structs compile selection sets.
ExprBase compileFieldResult(ResultExpr)(ResultExpr resultExpr, SelectionSet ss, JSONValue variables) {
    import dunamis.core.expr : ExprResultType, UnwrapNullableExpr, finalizeNullableObjectExpr;

    alias ResultType = ExprResultType!ResultExpr;

    // Arrays need element type inspection
    static if (is(ResultType == E[], E)) {
        static if (isCustomScalar!E || !is(E == struct)) {
            // Array of scalars (custom or primitive) - wrap to JSON
            return wrapAsJsonExpr(resultExpr);
        } else {
            // Array of structs - requires selection set
            if (ss is null) {
                throw new CompilerException(
                    "Field returning [" ~ E.stringof ~ "] requires a selection set");
            }
            return compileMapExpr!E(resultExpr, ss, variables);
        }
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
        auto innerExpr = compileSelectionSetBody!T(unwrapper, ss, variables);
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
        return compileSelectionSetBody!ResultType(resultExpr, ss, variables);
    }
    // Scalars (primitives and CustomScalar) - wrap to JSON
    else {
        return wrapAsJsonExpr(resultExpr);
    }
}

/// Compile access to a single field.
/// Finds a method with signature (Expr!T, args...) -> Expr!U and calls it.
/// Also handles plain fields (struct instance fields marked with plain fields).
ExprBase compileFieldAccess(T)(Expr!T ref_, Field field, JSONValue variables) {
    auto fieldName = getFieldName(field);

    // First, find a field method matching the GraphQL field name
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            alias memberSym = __traits(getMember, T, member);
            static if (isFieldMethod!(T, memberSym)) {
                // Check for @GqlHidden
                static if (!hasGqlHidden!memberSym) {
                    enum gqlName = getGqlName!(memberSym, member);

                    if (fieldName == gqlName) {
                        auto resultExpr = callComputedField!(memberSym, T)(ref_, field.args, variables);
                        return compileFieldResult!(typeof(resultExpr))(resultExpr, field.ss, variables);
                    }
                }
            }
        }
    }}

    // Second, check for plain fields (struct instance fields)
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            static if (isPlainField!(T, member)) {
                // Eager field - use D field name directly (GraphQL uses camelCase like D)
                if (fieldName == member) {
                    auto resultExpr = new FieldAccessExpr!(T, member)(ref_);
                    return compileFieldResult!(typeof(resultExpr))(resultExpr, field.ss, variables);
                }
            }
        }
    }}

    // Third, check for plain methods (instance methods returning non-Expr types)
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            static if (isPlainMethod!(T, member)) {
                alias methodSym = __traits(getMember, T, member);
                static if (!hasGqlHidden!methodSym) {
                    enum gqlName = getGqlName!(methodSym, member);
                    if (fieldName == gqlName) {
                        auto resultExpr = new MethodCallExpr!(T, member)(ref_);
                        return compileFieldResult!(typeof(resultExpr))(resultExpr, field.ss, variables);
                    }
                }
            }
        }
    }}

    // __typename: returns the GraphQL type name as a constant
    if (fieldName == "__typename") {
        return wrapAsJsonExpr(constant(getGraphQLTypeName!T, ref_));
    }

    throw new CompilerException("Unknown field '" ~ fieldName ~ "' on type " ~ T.stringof);
}
