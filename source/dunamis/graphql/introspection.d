module dunamis.graphql.introspection;

import std.algorithm;
import std.array;
import std.conv;
import std.json : JSONValue, JSONType;
import std.meta;
import std.traits;
import std.typecons : Nullable;

import dunamis.core.types : isCustomScalar, isAbstractType, getImplementedByMembers, isPublicDataField;
import dunamis.core.discovery : getAllAbstractTypes, getAbstractTypeMembers, getImplementedInterfaces,
    getSchemaFields;
import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.graphql.schema;

// ============================================================================
// Layer 1: D Type → Runtime Type Info (reusable)
// ============================================================================

// ----------------------------------------------------------------------------
// 1a. typeRefJson - D type → __Type JSON reference
// ----------------------------------------------------------------------------

/// Build the recursive __Type JSON reference for a D type.
/// Maps D types directly to the GraphQL introspection type system:
///   string          → NON_NULL { SCALAR "String" }
///   Nullable!string → SCALAR "String"
///   string[]        → NON_NULL { LIST { NON_NULL { SCALAR "String" } } }
///   User (object)   → NON_NULL { OBJECT "User" }
///   Status (enum)   → NON_NULL { ENUM "Status" }
///   FormatOpts (in) → NON_NULL { INPUT_OBJECT "FormatOptions" }
template typeRefJson(T) {
    enum typeRefJson = buildTypeRefJson!T();
}

private JSONValue buildTypeRefJson(T)() {
    // Nullable → no NON_NULL wrapper
    static if (is(T == Nullable!U, U)) {
        return buildBaseTypeRefJson!U();
    }
    // Pointer → nullable (no NON_NULL wrapper)
    else static if (is(T == U*, U)) {
        return buildBaseTypeRefJson!U();
    }
    // Everything else → wrapped in NON_NULL
    else {
        return nonNullOf(buildBaseTypeRefJson!T());
    }
}

private JSONValue buildBaseTypeRefJson(T)() {
    // Scalar types (check string BEFORE array since string is immutable(char)[])
    static if (is(T == string)) {
        return namedType("SCALAR", "String");
    } else static if (is(T == bool)) {
        return namedType("SCALAR", "Boolean");
    } else static if (is(T == int) || is(T == long)) {
        return namedType("SCALAR", "Int");
    } else static if (is(T == float) || is(T == double)) {
        return namedType("SCALAR", "Float");
    }
    // JSONValue → JSON scalar
    else static if (is(T == JSONValue)) {
        return namedType("SCALAR", "JSON");
    }
    // Custom scalar
    else static if (isCustomScalar!T) {
        return namedType("SCALAR", T.name);
    }
    // Array → LIST (after string check since string is immutable(char)[])
    else static if (is(T == E[], E)) {
        return listOf(buildTypeRefJson!E());
    }
    // Enum
    else static if (is(T == enum)) {
        return namedType("ENUM", getGraphQLTypeName!T);
    }
    // Abstract type: interface (has schema fields)
    else static if (isAbstractType!T && getSchemaFields!T.length > 0) {
        return namedType("INTERFACE", getGraphQLTypeName!T);
    }
    // Abstract type: union (no schema fields)
    else static if (isAbstractType!T) {
        return namedType("UNION", getGraphQLTypeName!T);
    }
    // Object type (entity or POD struct with fields)
    else static if (isObjectType!T) {
        return namedType("OBJECT", getGraphQLTypeName!T);
    }
    // Input type
    else static if (isInputType!T) {
        return namedType("INPUT_OBJECT", getGraphQLTypeName!T);
    }
    // Fallback
    else {
        return namedType("SCALAR", "String");
    }
}

/// Build a NON_NULL wrapper type
private JSONValue nonNullOf(JSONValue inner) {
    return JSONValue([
        "kind": JSONValue("NON_NULL"),
        "name": JSONValue(null),
        "ofType": inner
    ]);
}

/// Build a LIST wrapper type
private JSONValue listOf(JSONValue inner) {
    return JSONValue([
        "kind": JSONValue("LIST"),
        "name": JSONValue(null),
        "ofType": inner
    ]);
}

/// Build a named type (SCALAR, OBJECT, ENUM, INPUT_OBJECT)
private JSONValue namedType(string kind, string name) {
    return JSONValue([
        "kind": JSONValue(kind),
        "name": JSONValue(name),
        "ofType": JSONValue(null)
    ]);
}

// ----------------------------------------------------------------------------
// 1b. RuntimeFieldInfo / RuntimeArgInfo + getRuntimeFields
// ----------------------------------------------------------------------------

struct RuntimeArgInfo {
    string name;
    JSONValue typeJson;
    bool hasDefault;
    string defaultValue;
}

struct RuntimeFieldInfo {
    string name;
    JSONValue typeJson;
    bool hidden;
    string description;
    string deprecation;
    RuntimeArgInfo[] args;
}

/// Extract runtime field information from any type.
/// Uses the Schema Protocol to discover computed fields.
template getRuntimeFields(T) {
    enum getRuntimeFields = buildRuntimeFields!T();
}

private RuntimeFieldInfo[] buildRuntimeFields(T)() {
    import dunamis.core.discovery : getSchemaFields;

    RuntimeFieldInfo[] fields;

    // All fields are computed fields after normalization
    static foreach (member; getSchemaFields!T) {{
        alias fn = __traits(getMember, T, member);

        enum isHidden = hasGqlHidden!fn;
        enum gqlFieldName = getGqlName!(fn, member);
        enum description = getGqlDescription!fn;
        enum deprecation = getGqlDeprecated!fn;
        // Instantiated per result type, and only for fields with arguments:
        // per field, they would be compiled for every field of the schema
        enum typeJson = fieldResultTypeRefJson!(ExprResultType!(ReturnType!(typeof(fn))))();
        static if (Parameters!fn.length > 1)
            enum args = computedFieldRuntimeArgs!fn();
        else
            enum RuntimeArgInfo[] args = null;

        fields ~= RuntimeFieldInfo(
            gqlFieldName,
            typeJson,
            isHidden,
            description,
            deprecation,
            args
        );
    }}

    return fields;
}

/// Get JSONValue type ref for a computed field's result type (the value type
/// of its Expr return type).
/// Mirrors computedFieldReturnType but produces JSONValue instead of string.
private JSONValue fieldResultTypeRefJson(ResultT)() {
    static if (is(ResultT == string)) {
        return typeRefJson!string;
    }
    else static if (is(ResultT == E[], E)) {
        static if (is(E : Expr!Inner, Inner)) {
            // Array of expressions (e.g., from map) - extract inner type → [Inner!]!
            return nonNullOf(listOf(typeRefJson!Inner));
        } else {
            return nonNullOf(listOf(typeRefJson!E));
        }
    }
    else {
        return typeRefJson!ResultT;
    }
}

/// Extract runtime argument info from a computed field.
/// Mirrors getComputedFieldArguments but produces JSONValue type refs.
private RuntimeArgInfo[] computedFieldRuntimeArgs(alias member)() {
    alias Params = Parameters!member;
    alias Defaults = ParameterDefaults!member;
    enum string[] paramNames = [ParameterIdentifierTuple!member];

    RuntimeArgInfo[] args;

    // Skip first parameter (Expr!Entity), process rest as arguments
    static foreach (i; 1 .. Params.length) {{
        alias P = Params[i];

        static if (is(Defaults[i] == void)) {
            // No default - required argument
            args ~= RuntimeArgInfo(
                paramNames[i],
                typeRefJson!P,
                false,
                ""
            );
        } else {
            // Has default - optional argument
            static if (is(P == Nullable!U, U)) {
                args ~= RuntimeArgInfo(
                    paramNames[i],
                    buildBaseTypeRefJson!U(),  // nullable, no NON_NULL wrapper
                    true,
                    "null"
                );
            } else {
                args ~= RuntimeArgInfo(
                    paramNames[i],
                    buildBaseTypeRefJson!P(),  // nullable (has default), no NON_NULL wrapper
                    true,
                    defaultValueToString!(Defaults[i])
                );
            }
        }
    }}
    return args;
}

// ----------------------------------------------------------------------------
// 1c. getRuntimeInputFields
// ----------------------------------------------------------------------------

struct RuntimeInputFieldInfo {
    string name;
    JSONValue typeJson;
    string defaultValue;  // empty if no default
}

/// Extract runtime input field info from an input type struct.
template getRuntimeInputFields(T) if (isInputType!T) {
    enum getRuntimeInputFields = buildRuntimeInputFields!T();
}

private RuntimeInputFieldInfo[] buildRuntimeInputFields(T)() {
    RuntimeInputFieldInfo[] fields;

    static foreach (member; __traits(allMembers, T)) {{
        static if (isPublicDataField!(T, member)) {
            alias MemberType = typeof(__traits(getMember, T, member));

            static if (!is(MemberType == function) && !is(MemberType == void)) {
                static if (__traits(compiles, { auto v = __traits(getMember, T.init, member); })) {
                    // Determine type ref based on nullability
                    static if (is(MemberType == Nullable!(Nullable!U), U)) {
                        // Three-state: absent/null/value → nullable
                        enum typeJson = buildBaseTypeRefJson!U();
                    } else static if (is(MemberType == Nullable!U, U)) {
                        // Two-state → nullable
                        enum typeJson = buildBaseTypeRefJson!U();
                    } else static if (is(MemberType == U*, U)) {
                        // Pointer → nullable
                        enum typeJson = buildBaseTypeRefJson!U();
                    } else {
                        // Required → NON_NULL
                        enum typeJson = nonNullOf(buildBaseTypeRefJson!MemberType());
                    }

                    fields ~= RuntimeInputFieldInfo(getGqlName!(__traits(getMember, T, member), member), typeJson,
                        getGqlDefault!(__traits(getMember, T, member)));
                }
            }
        }
    }}

    return fields;
}

// ============================================================================
// Layer 2: Introspection JSON Assembly
// ============================================================================

// ----------------------------------------------------------------------------
// 2a. buildIntrospectionJson
// ----------------------------------------------------------------------------

/// Build the complete __Schema introspection JSON.
/// Accepts either a Schema type or a raw Query type.
JSONValue buildIntrospectionJson(alias SchemaOrQuery)() {
    // Determine Query/Mutation/Subscription types
    static if (isSchema!SchemaOrQuery) {
        alias QueryType = SchemaOrQuery.Query;
        alias MutationType = SchemaOrQuery.Mutation;
        alias SubscriptionType = SchemaOrQuery.Subscription;
    } else {
        alias QueryType = SchemaOrQuery;
        struct MutationType {}
        struct SubscriptionType {}
    }

    // Discover all types (same pattern as generateSchemaSDL)
    static if (isSchema!SchemaOrQuery && __traits(hasMember, SchemaOrQuery, "AllEntityTypes")) {
        alias AllEntityTypes = SchemaOrQuery.AllEntityTypes;
    } else {
        alias AllEntityTypes = getAllObjectTypes!(QueryType, MutationType, SubscriptionType);
    }

    alias AllInputTypes = getAllInputTypes!(QueryType, MutationType, SubscriptionType);
    alias AllEnumTypes = getAllEnumTypes!(QueryType, MutationType, SubscriptionType);

    // Discover abstract types
    alias AllAbstractTypes = getAllAbstractTypes!AllEntityTypes;

    // Build types array
    JSONValue[] types;

    // Built-in scalars
    types ~= scalarTypeJson("String");
    types ~= scalarTypeJson("Int");
    types ~= scalarTypeJson("Float");
    types ~= scalarTypeJson("Boolean");

    // Custom scalars
    static foreach (scalarName; getAllCustomScalarNames!AllEntityTypes) {
        types ~= scalarTypeJson(scalarName);
    }

    // Enum types
    static foreach (EnumType; AllEnumTypes) {
        types ~= buildEnumTypeJson!EnumType();
    }

    // Union types (abstract types with no schema fields)
    static foreach (AbstractT; AllAbstractTypes) {
        static if (getSchemaFields!AbstractT.length == 0) {
            types ~= buildUnionTypeJson!(AbstractT, AllEntityTypes)();
        }
    }

    // Interface types (abstract types with schema fields)
    static foreach (AbstractT; AllAbstractTypes) {
        static if (getSchemaFields!AbstractT.length > 0) {
            types ~= buildInterfaceTypeJson!(AbstractT, AllEntityTypes)();
        }
    }

    // Query type
    types ~= buildObjectTypeJsonFromFields!QueryType("Query");

    // Mutation type (if it has fields)
    static if (getFields!MutationType.length > 0) {
        types ~= buildObjectTypeJsonFromFields!MutationType("Mutation");
    }

    // Subscription type (if it has fields)
    static if (getFields!SubscriptionType.length > 0) {
        types ~= buildObjectTypeJsonFromFields!SubscriptionType("Subscription");
    }

    // Entity/object types (skip abstract types — they have their own entries)
    static foreach (Entity; AllEntityTypes) {
        static if (!isAbstractType!Entity) {
            types ~= buildObjectTypeJsonFromFields!(Entity, AllAbstractTypes)(getGraphQLTypeName!Entity);
        }
    }

    // Input types
    static foreach (InputType; AllInputTypes) {
        types ~= buildInputObjectTypeJson!InputType();
    }

    // Introspection meta-types
    types ~= introspectionMetaTypes();

    types = uniqueNamedTypes(types);

    // Build schema JSON
    JSONValue queryTypeRef = JSONValue(["name": JSONValue("Query")]);

    JSONValue mutationTypeRef;
    static if (getFields!MutationType.length > 0) {
        mutationTypeRef = JSONValue(["name": JSONValue("Mutation")]);
    } else {
        mutationTypeRef = JSONValue(null);
    }

    JSONValue subscriptionTypeRef;
    static if (getFields!SubscriptionType.length > 0) {
        subscriptionTypeRef = JSONValue(["name": JSONValue("Subscription")]);
    } else {
        subscriptionTypeRef = JSONValue(null);
    }

    // Standard directives
    JSONValue[] directives;
    directives ~= directiveJson("skip", "Directs the executor to skip this field or fragment when the `if` argument is true.",
        ["FIELD", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"],
        [inputValueJson("if", "Skipped when true.", nonNullOf(namedType("SCALAR", "Boolean")), "")]);
    directives ~= directiveJson("include", "Directs the executor to include this field or fragment only when the `if` argument is true.",
        ["FIELD", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"],
        [inputValueJson("if", "Included when true.", nonNullOf(namedType("SCALAR", "Boolean")), "")]);
    directives ~= directiveJson("deprecated", "Marks an element of a GraphQL schema as no longer supported.",
        ["FIELD_DEFINITION", "ENUM_VALUE"],
        [inputValueJson("reason", "Explains why this element was deprecated.", namedType("SCALAR", "String"), `"No longer supported"`)]);

    return JSONValue([
        "queryType": queryTypeRef,
        "mutationType": mutationTypeRef,
        "subscriptionType": subscriptionTypeRef,
        "types": JSONValue(types),
        "directives": JSONValue(directives)
    ]);
}

/// The types of `types`, each name once. Several D types may stand for the
/// same GraphQL type (e.g. instantiations of a filter template for types of
/// the same name at different plugin positions), but distinct GraphQL types
/// must not share a name: one would shadow the other in the schema, so this
/// throws.
private JSONValue[] uniqueNamedTypes(JSONValue[] types) {
    JSONValue[] result;
    JSONValue[string] seen;
    foreach (type; types) {
        auto name = type["name"].str;
        if (auto previous = name in seen) {
            if (*previous != type)
                throw new Exception("Distinct GraphQL types share the name " ~ name ~
                    ":\n" ~ previous.toString() ~ "\n" ~ type.toString());
            continue;
        }
        seen[name] = type;
        result ~= type;
    }
    return result;
}

unittest {
    import std.exception : assertThrown;
    import std.json : parseJSON;

    auto a = parseJSON(`{"name": "SpanFilter", "kind": "INPUT_OBJECT", "inputFields": [{"name": "contains"}]}`);
    auto sameAsA = parseJSON(`{"kind": "INPUT_OBJECT", "inputFields": [{"name": "contains"}], "name": "SpanFilter"}`);
    auto b = parseJSON(`{"name": "SpanFilter", "kind": "INPUT_OBJECT", "inputFields": [{"name": "from"}]}`);
    auto other = parseJSON(`{"name": "Other", "kind": "SCALAR"}`);

    // The same type, discovered twice, is served once.
    assert(uniqueNamedTypes([a, other, sameAsA]) == [a, other]);
    // Distinct types of the same name are rejected.
    assertThrown(uniqueNamedTypes([a, other, b]));
}

// ----------------------------------------------------------------------------
// 2b. buildTypeLookup
// ----------------------------------------------------------------------------

/// Build a lookup map from type name → __Type JSON.
JSONValue[string] buildTypeLookup(alias SchemaOrQuery)() {
    auto schemaJson = buildIntrospectionJson!SchemaOrQuery();
    JSONValue[string] lookup;

    foreach (typeJson; schemaJson["types"].array) {
        auto name = typeJson["name"].str;
        lookup[name] = typeJson;
    }

    return lookup;
}

// ----------------------------------------------------------------------------
// 2c. applySelectionSet
// ----------------------------------------------------------------------------

/// Apply a GraphQL selection set to an introspection JSON value,
/// extracting only the requested fields.
JSONValue applySelectionSet(JSONValue data, SelectionSet ss, JSONValue variables, FragmentMap fragments = null) {
    import graphql.ast : SelectionEnum;

    if (ss is null) return data;
    if (data.isNull) return data;
    // A selection applies to the element type of a GraphQL list regardless of
    // how many list wrappers the type has (for example [[Cell!]!]!). Recurse
    // through every list layer before projecting object fields.
    if (data.type == JSONType.array) {
        JSONValue[] items;
        foreach (item; data.array)
            items ~= applySelectionSet(item, ss, variables, fragments);
        return JSONValue(items);
    }

    auto selections = iterateSelections(ss);
    if (selections.length == 0) return data;

    JSONValue result = JSONValue.emptyObject;

    void processField(Field field) {
        auto fieldName = getFieldName(field);
        auto outputName = getOutputName(field);

        if (fieldName is null) return;

        // Check if the field exists in the data
        if (fieldName !in data) {
            result[outputName] = JSONValue(null);
            return;
        }

        auto fieldValue = data[fieldName];

        // Special handling for fields/enumValues: filter by includeDeprecated
        if (fieldName == "fields" || fieldName == "enumValues") {
            fieldValue = filterDeprecated(fieldValue, field, variables);
        }

        // Apply sub-selection set
        if (field.ss !is null) {
            if (fieldValue.type == JSONType.array) {
                // Array: apply selection to each element
                JSONValue[] items;
                foreach (item; fieldValue.array) {
                    items ~= applySelectionSet(item, field.ss, variables, fragments);
                }
                result[outputName] = JSONValue(items);
            } else if (fieldValue.type == JSONType.object) {
                result[outputName] = applySelectionSet(fieldValue, field.ss, variables, fragments);
            } else {
                result[outputName] = fieldValue;
            }
        } else {
            result[outputName] = fieldValue;
        }
    }

    void processSelections(Selection[] sels, bool[string] expanding = null) {
        foreach (sel; sels) {
            if (sel.ruleSelection == SelectionEnum.Field) {
                auto field = sel.field;
                if (!shouldIncludeField(field.dirs, variables)) continue;
                processField(field);
            } else if (sel.ruleSelection == SelectionEnum.Spread) {
                auto spread = sel.frag;
                if (!shouldIncludeField(spread.dirs, variables)) continue;
                if (fragments is null) continue;
                auto fragName = spread.name.value;
                if (expanding !is null && fragName in expanding) continue;
                auto fragDefPtr = fragName in fragments;
                if (fragDefPtr is null) continue;
                auto fragDef = *fragDefPtr;
                if (expanding is null)
                    expanding = [fragName: true];
                else
                    expanding[fragName] = true;
                processSelections(iterateSelections(fragDef.ss), expanding);
                expanding.remove(fragName);
            } else if (sel.ruleSelection == SelectionEnum.IFrag) {
                auto ifrag = sel.ifrag;
                if (!shouldIncludeField(ifrag.dirs, variables)) continue;
                processSelections(iterateSelections(ifrag.ss), expanding);
            }
        }
    }

    processSelections(selections);

    return result;
}

/// Filter array items by includeDeprecated argument.
private JSONValue filterDeprecated(JSONValue fieldValue, Field field, JSONValue variables) {
    if (fieldValue.type != JSONType.array) return fieldValue;

    // Check for includeDeprecated argument (default: false)
    bool includeDeprecated = false;
    auto lookup = findArgumentValue(field.args, "includeDeprecated");
    if (!lookup.isNull) {
        if (lookup.isVariable) {
            if (lookup.variableName in variables) {
                auto v = variables[lookup.variableName];
                if (v.type == JSONType.true_) includeDeprecated = true;
            }
        } else {
            includeDeprecated = extractBool(lookup.value);
        }
    }

    if (includeDeprecated) return fieldValue;

    // Filter out deprecated items
    JSONValue[] filtered;
    foreach (item; fieldValue.array) {
        if (item.type == JSONType.object) {
            if ("isDeprecated" in item && item["isDeprecated"].type == JSONType.true_) {
                continue;  // Skip deprecated
            }
        }
        filtered ~= item;
    }
    return JSONValue(filtered);
}

// ============================================================================
// Internal helpers for JSON assembly
// ============================================================================

private JSONValue scalarTypeJson(string name) {
    return JSONValue([
        "kind": JSONValue("SCALAR"),
        "name": JSONValue(name),
        "description": JSONValue(null),
        "fields": JSONValue(null),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(null),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
    ]);
}

private JSONValue buildObjectTypeJsonFromFields(T, AllAbstractTypes...)(string typeName) {
    enum rtFields = getRuntimeFields!T;
    JSONValue[] fields;
    static foreach (f; rtFields) {{
        static if (!f.hidden) {
            JSONValue[] argJsons;
            static foreach (arg; f.args) {
                argJsons ~= inputValueJson(arg.name, "", arg.typeJson, arg.defaultValue);
            }

            fields ~= fieldJsonFull(f.name, f.description, f.typeJson, f.deprecation, argJsons);
        }
    }}

    // Build interfaces list
    JSONValue[] interfaces;
    static if (AllAbstractTypes.length > 0) {
        static foreach (AbstractT; AllAbstractTypes) {
            // Interface = abstract type with schema fields, and T is a member
            static if (getSchemaFields!AbstractT.length > 0 &&
                       _staticContainsType!(T, getImplementedByMembers!AbstractT)) {
                interfaces ~= namedType("INTERFACE", getGraphQLTypeName!AbstractT);
            }
        }
    }

    return objectTypeJson(typeName, fields, interfaces);
}

/// Check if T is in a type tuple
private template _staticContainsType(T, Types...) {
    enum _staticContainsType = () {
        static foreach (U; Types) {
            static if (is(T == U)) return true;
        }
        return false;
    }();
}

private JSONValue buildEnumTypeJson(E)() {
    import std.traits : EnumMembers;

    JSONValue[] enumValues;
    static foreach (member; EnumMembers!E) {
        enumValues ~= JSONValue([
            "name": JSONValue(__traits(identifier, member)),
            "description": JSONValue(null),
            "isDeprecated": JSONValue(false),
            "deprecationReason": JSONValue(null)
        ]);
    }

    return JSONValue([
        "kind": JSONValue("ENUM"),
        "name": JSONValue(getGraphQLTypeName!E),
        "description": JSONValue(null),
        "fields": JSONValue(null),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(null),
        "enumValues": JSONValue(enumValues),
        "possibleTypes": JSONValue(null)
    ]);
}

private JSONValue buildInputObjectTypeJson(T)() {
    JSONValue[] inputFields;
    static foreach (f; getRuntimeInputFields!T) {
        inputFields ~= inputValueJson(f.name, "", f.typeJson, f.defaultValue);
    }

    return JSONValue([
        "kind": JSONValue("INPUT_OBJECT"),
        "name": JSONValue(getGraphQLTypeName!T),
        "description": JSONValue(null),
        "fields": JSONValue(null),
        "inputFields": JSONValue(inputFields),
        "interfaces": JSONValue(null),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
    ]);
}

private JSONValue objectTypeJson(string typeName, JSONValue[] fields, JSONValue[] interfaces = []) {
    return JSONValue([
        "kind": JSONValue("OBJECT"),
        "name": JSONValue(typeName),
        "description": JSONValue(null),
        "fields": JSONValue(fields),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(interfaces),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
    ]);
}

private JSONValue buildUnionTypeJson(Union, AllTypes...)() {
    alias Members = getAbstractTypeMembers!(Union, AllTypes);
    JSONValue[] possibleTypes;
    static foreach (Member; Members) {
        possibleTypes ~= namedType("OBJECT", getGraphQLTypeName!Member);
    }

    return JSONValue([
        "kind": JSONValue("UNION"),
        "name": JSONValue(getGraphQLTypeName!Union),
        "description": JSONValue(null),
        "fields": JSONValue(null),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(null),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(possibleTypes)
    ]);
}

private JSONValue buildInterfaceTypeJson(T, AllTypes...)() {
    // Interface has fields from AbstractField
    enum rtFields = getRuntimeFields!T;
    JSONValue[] fields;
    static foreach (f; rtFields) {{
        static if (!f.hidden) {
            JSONValue[] argJsons;
            static foreach (arg; f.args) {
                argJsons ~= inputValueJson(arg.name, "", arg.typeJson, arg.defaultValue);
            }
            fields ~= fieldJsonFull(f.name, f.description, f.typeJson, f.deprecation, argJsons);
        }
    }}

    alias Members = getAbstractTypeMembers!(T, AllTypes);
    JSONValue[] possibleTypes;
    static foreach (Member; Members) {
        possibleTypes ~= namedType("OBJECT", getGraphQLTypeName!Member);
    }

    return JSONValue([
        "kind": JSONValue("INTERFACE"),
        "name": JSONValue(getGraphQLTypeName!T),
        "description": JSONValue(null),
        "fields": JSONValue(fields),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(null),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(possibleTypes)
    ]);
}

private JSONValue fieldJsonFull(string name, string description, JSONValue typeJson, string deprecation, JSONValue[] argJsons) {
    return JSONValue([
        "name": JSONValue(name),
        "description": JSONValue(description.length > 0 ? description : null),
        "args": JSONValue(argJsons),
        "type": typeJson,
        "isDeprecated": JSONValue(deprecation.length > 0),
        "deprecationReason": JSONValue(deprecation.length > 0 ? deprecation : null)
    ]);
}

private JSONValue inputValueJson(string name, string description, JSONValue typeJson, string defaultValue) {
    return JSONValue([
        "name": JSONValue(name),
        "description": JSONValue(description.length > 0 ? description : null),
        "type": typeJson,
        "defaultValue": defaultValue.length > 0 ? JSONValue(defaultValue) : JSONValue(null)
    ]);
}

private JSONValue directiveJson(string name, string description, string[] locations, JSONValue[] args) {
    JSONValue[] locs;
    foreach (loc; locations) {
        locs ~= JSONValue(loc);
    }
    return JSONValue([
        "name": JSONValue(name),
        "description": JSONValue(description),
        "locations": JSONValue(locs),
        "args": JSONValue(args)
    ]);
}

/// Hardcoded introspection meta-types (__Schema, __Type, __Field, etc.)
private JSONValue[] introspectionMetaTypes() {
    JSONValue[] types;

    // __Schema
    types ~= JSONValue([
        "kind": JSONValue("OBJECT"),
        "name": JSONValue("__Schema"),
        "description": JSONValue("A GraphQL Schema defines the capabilities of a GraphQL server."),
        "fields": JSONValue([
            fieldJson("types", "A list of all types supported by this server.", nonNullOf(listOf(nonNullOf(namedType("OBJECT", "__Type"))))),
            fieldJson("queryType", "The type that query operations will be rooted at.", nonNullOf(namedType("OBJECT", "__Type"))),
            fieldJson("mutationType", "If this server supports mutation, the type that mutation operations will be rooted at.", namedType("OBJECT", "__Type")),
            fieldJson("subscriptionType", "If this server supports subscriptions, the type that subscription operations will be rooted at.", namedType("OBJECT", "__Type")),
            fieldJson("directives", "A list of all directives supported by this server.", nonNullOf(listOf(nonNullOf(namedType("OBJECT", "__Directive")))))
        ]),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(cast(JSONValue[]) []),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
    ]);

    // __Type
    types ~= JSONValue([
        "kind": JSONValue("OBJECT"),
        "name": JSONValue("__Type"),
        "description": JSONValue(null),
        "fields": JSONValue([
            fieldJson("kind", null, nonNullOf(namedType("ENUM", "__TypeKind"))),
            fieldJson("name", null, namedType("SCALAR", "String")),
            fieldJson("description", null, namedType("SCALAR", "String")),
            fieldJsonWithArgs("fields", null, listOf(nonNullOf(namedType("OBJECT", "__Field"))),
                [inputValueJson("includeDeprecated", null, namedType("SCALAR", "Boolean"), "false")]),
            fieldJson("interfaces", null, listOf(nonNullOf(namedType("OBJECT", "__Type")))),
            fieldJson("possibleTypes", null, listOf(nonNullOf(namedType("OBJECT", "__Type")))),
            fieldJsonWithArgs("enumValues", null, listOf(nonNullOf(namedType("OBJECT", "__EnumValue"))),
                [inputValueJson("includeDeprecated", null, namedType("SCALAR", "Boolean"), "false")]),
            fieldJson("inputFields", null, listOf(nonNullOf(namedType("OBJECT", "__InputValue")))),
            fieldJson("ofType", null, namedType("OBJECT", "__Type"))
        ]),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(cast(JSONValue[]) []),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
    ]);

    // __Field
    types ~= JSONValue([
        "kind": JSONValue("OBJECT"),
        "name": JSONValue("__Field"),
        "description": JSONValue(null),
        "fields": JSONValue([
            fieldJson("name", null, nonNullOf(namedType("SCALAR", "String"))),
            fieldJson("description", null, namedType("SCALAR", "String")),
            fieldJson("args", null, nonNullOf(listOf(nonNullOf(namedType("OBJECT", "__InputValue"))))),
            fieldJson("type", null, nonNullOf(namedType("OBJECT", "__Type"))),
            fieldJson("isDeprecated", null, nonNullOf(namedType("SCALAR", "Boolean"))),
            fieldJson("deprecationReason", null, namedType("SCALAR", "String"))
        ]),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(cast(JSONValue[]) []),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
    ]);

    // __InputValue
    types ~= JSONValue([
        "kind": JSONValue("OBJECT"),
        "name": JSONValue("__InputValue"),
        "description": JSONValue(null),
        "fields": JSONValue([
            fieldJson("name", null, nonNullOf(namedType("SCALAR", "String"))),
            fieldJson("description", null, namedType("SCALAR", "String")),
            fieldJson("type", null, nonNullOf(namedType("OBJECT", "__Type"))),
            fieldJson("defaultValue", null, namedType("SCALAR", "String"))
        ]),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(cast(JSONValue[]) []),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
    ]);

    // __EnumValue
    types ~= JSONValue([
        "kind": JSONValue("OBJECT"),
        "name": JSONValue("__EnumValue"),
        "description": JSONValue(null),
        "fields": JSONValue([
            fieldJson("name", null, nonNullOf(namedType("SCALAR", "String"))),
            fieldJson("description", null, namedType("SCALAR", "String")),
            fieldJson("isDeprecated", null, nonNullOf(namedType("SCALAR", "Boolean"))),
            fieldJson("deprecationReason", null, namedType("SCALAR", "String"))
        ]),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(cast(JSONValue[]) []),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
    ]);

    // __Directive
    types ~= JSONValue([
        "kind": JSONValue("OBJECT"),
        "name": JSONValue("__Directive"),
        "description": JSONValue(null),
        "fields": JSONValue([
            fieldJson("name", null, nonNullOf(namedType("SCALAR", "String"))),
            fieldJson("description", null, namedType("SCALAR", "String")),
            fieldJson("locations", null, nonNullOf(listOf(nonNullOf(namedType("ENUM", "__DirectiveLocation"))))),
            fieldJson("args", null, nonNullOf(listOf(nonNullOf(namedType("OBJECT", "__InputValue")))))
        ]),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(cast(JSONValue[]) []),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
    ]);

    // __TypeKind enum
    types ~= JSONValue([
        "kind": JSONValue("ENUM"),
        "name": JSONValue("__TypeKind"),
        "description": JSONValue("An enum describing what kind of type a given __Type is."),
        "fields": JSONValue(null),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(null),
        "enumValues": JSONValue([
            enumValueJson("SCALAR"), enumValueJson("OBJECT"), enumValueJson("INTERFACE"),
            enumValueJson("UNION"), enumValueJson("ENUM"), enumValueJson("INPUT_OBJECT"),
            enumValueJson("LIST"), enumValueJson("NON_NULL")
        ]),
        "possibleTypes": JSONValue(null)
    ]);

    // __DirectiveLocation enum
    types ~= JSONValue([
        "kind": JSONValue("ENUM"),
        "name": JSONValue("__DirectiveLocation"),
        "description": JSONValue(null),
        "fields": JSONValue(null),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(null),
        "enumValues": JSONValue([
            enumValueJson("QUERY"), enumValueJson("MUTATION"), enumValueJson("SUBSCRIPTION"),
            enumValueJson("FIELD"), enumValueJson("FRAGMENT_DEFINITION"), enumValueJson("FRAGMENT_SPREAD"),
            enumValueJson("INLINE_FRAGMENT"), enumValueJson("SCHEMA"), enumValueJson("SCALAR"),
            enumValueJson("OBJECT"), enumValueJson("FIELD_DEFINITION"), enumValueJson("ARGUMENT_DEFINITION"),
            enumValueJson("INTERFACE"), enumValueJson("UNION"), enumValueJson("ENUM"),
            enumValueJson("ENUM_VALUE"), enumValueJson("INPUT_OBJECT"), enumValueJson("INPUT_FIELD_DEFINITION")
        ]),
        "possibleTypes": JSONValue(null)
    ]);

    return types;
}

private JSONValue fieldJson(string name, string description, JSONValue typeJson) {
    return fieldJsonWithArgs(name, description, typeJson, []);
}

private JSONValue fieldJsonWithArgs(string name, string description, JSONValue typeJson, JSONValue[] args) {
    return JSONValue([
        "name": JSONValue(name),
        "description": JSONValue(description),
        "args": JSONValue(args),
        "type": typeJson,
        "isDeprecated": JSONValue(false),
        "deprecationReason": JSONValue(null)
    ]);
}

private JSONValue enumValueJson(string name) {
    return JSONValue([
        "name": JSONValue(name),
        "description": JSONValue(null),
        "isDeprecated": JSONValue(false),
        "deprecationReason": JSONValue(null)
    ]);
}

// ============================================================================
// Re-exports from compiler.d (package-visible AST helpers)
// ============================================================================

// These are used by applySelectionSet and need to be imported from compiler.d.
// They require package visibility in compiler.d.
import graphql.ast : Selection, SelectionSet, Selections, SelectionEnum,
    Field, Arguments, Argument, ArgumentList, Value, Directives,
    FragmentDefinition, FragmentSpread, InlineFragment;

package {
    // Forward declarations - these come from compiler.d with package visibility
    import dunamis.graphql.compiler : iterateSelections, getFieldName, getOutputName,
        findArgumentValue, extractBool, shouldIncludeField, FragmentMap;
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    import dunamis.graphql.operations : parseOperationFields;

    auto selection = parseOperationFields(
        "query { root { cells { value } } }",
        JSONValue.emptyObject)[0].selection;
    auto data = JSONValue([
        "cells": JSONValue([
            JSONValue([JSONValue(["value": JSONValue(1), "ignored": JSONValue(2)])]),
            JSONValue([JSONValue(["value": JSONValue(3), "ignored": JSONValue(4)])]),
        ]),
    ]);

    auto expected = JSONValue([
        "cells": JSONValue([
            JSONValue([JSONValue(["value": JSONValue(1)])]),
            JSONValue([JSONValue(["value": JSONValue(3)])]),
        ]),
    ]);
    assert(applySelectionSet(data, selection, JSONValue.emptyObject) == expected);
}

unittest {
    import std.json;

    // Test typeRefJson for basic scalar types
    {
        // string → NON_NULL { SCALAR "String" }
        auto j = typeRefJson!string;
        assert(j["kind"].str == "NON_NULL");
        assert(j["ofType"]["kind"].str == "SCALAR");
        assert(j["ofType"]["name"].str == "String");
    }

    {
        // Nullable!string → SCALAR "String" (no NON_NULL)
        auto j = typeRefJson!(Nullable!string);
        assert(j["kind"].str == "SCALAR");
        assert(j["name"].str == "String");
    }

    {
        // int → NON_NULL { SCALAR "Int" }
        auto j = typeRefJson!int;
        assert(j["kind"].str == "NON_NULL");
        assert(j["ofType"]["kind"].str == "SCALAR");
        assert(j["ofType"]["name"].str == "Int");
    }

    {
        // bool → NON_NULL { SCALAR "Boolean" }
        auto j = typeRefJson!bool;
        assert(j["kind"].str == "NON_NULL");
        assert(j["ofType"]["kind"].str == "SCALAR");
        assert(j["ofType"]["name"].str == "Boolean");
    }

    {
        // string[] → NON_NULL { LIST { NON_NULL { SCALAR "String" } } }
        auto j = typeRefJson!(string[]);
        assert(j["kind"].str == "NON_NULL");
        assert(j["ofType"]["kind"].str == "LIST");
        assert(j["ofType"]["ofType"]["kind"].str == "NON_NULL");
        assert(j["ofType"]["ofType"]["ofType"]["kind"].str == "SCALAR");
        assert(j["ofType"]["ofType"]["ofType"]["name"].str == "String");
    }
}

// Test with mock entities (same pattern as compiler.d tests)
unittest {
    import std.json;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct TestUser {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        @GqlDeprecated("Use fullName")
        mixin Col!("name", string);

        @GqlHidden
        mixin Col!("secret", string);

        static auto fullName(Expr!TestUser u) {
            return u.firstName ~ " " ~ u.lastName;
        }
    }

    static struct TestQuery {
        mixin Table!(TestUser, "users");
    }

    // Test getRuntimeFields
    enum fields = getRuntimeFields!TestUser;

    // Find firstName field
    bool foundFirstName = false;
    bool foundDeprecated = false;
    bool foundHidden = false;
    foreach (f; fields) {
        if (f.name == "firstName") {
            foundFirstName = true;
            assert(f.typeJson["kind"].str == "NON_NULL");
            assert(f.typeJson["ofType"]["kind"].str == "SCALAR");
            assert(f.typeJson["ofType"]["name"].str == "String");
            assert(!f.hidden);
        }
        if (f.name == "name") {
            foundDeprecated = true;
            assert(f.deprecation == "Use fullName");
        }
        if (f.name == "secret") {
            foundHidden = true;
            assert(f.hidden);
        }
    }
    assert(foundFirstName, "Should find firstName field");
    assert(foundDeprecated, "Should find deprecated name field");
    assert(foundHidden, "Should find hidden secret field");

    // Test buildIntrospectionJson
    auto schemaJson = buildIntrospectionJson!TestQuery();
    assert(schemaJson["queryType"]["name"].str == "Query");
    assert(schemaJson["mutationType"].isNull);

    // Verify types array contains expected types
    bool hasQuery = false;
    bool hasTestUser = false;
    bool hasString = false;
    foreach (t; schemaJson["types"].array) {
        auto name = t["name"].str;
        if (name == "Query") hasQuery = true;
        if (name == "TestUser") hasTestUser = true;
        if (name == "String") hasString = true;

        // Check TestUser fields
        if (name == "TestUser") {
            assert(t["kind"].str == "OBJECT");
            auto typeFields = t["fields"].array;
            // Hidden field should be excluded
            bool hasSecret = false;
            bool hasFieldFirstName = false;
            foreach (f; typeFields) {
                if (f["name"].str == "secret") hasSecret = true;
                if (f["name"].str == "firstName") hasFieldFirstName = true;
                if (f["name"].str == "name") {
                    assert(f["isDeprecated"].type == JSONType.true_);
                    assert(f["deprecationReason"].str == "Use fullName");
                }
            }
            assert(!hasSecret, "Hidden field should not appear");
            assert(hasFieldFirstName, "firstName should appear");
        }
    }
    assert(hasQuery, "Should have Query type");
    assert(hasTestUser, "Should have TestUser type");
    assert(hasString, "Should have String scalar");

    // Test buildTypeLookup
    auto lookup = buildTypeLookup!TestQuery();
    assert("Query" in lookup);
    assert("TestUser" in lookup);
    assert("String" in lookup);
    assert("NonExistent" !in lookup);
    assert(lookup["TestUser"]["kind"].str == "OBJECT");
}

// Test enum type introspection
unittest {
    import std.json;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    enum Color { red, green, blue }

    @DemoEntity!(db, "items")
    static struct Item {
        mixin DemoId;
        mixin Col!("name", string);
        mixin Col!("color", Color);
    }

    static struct ItemQuery {
        mixin Table!(Item, "items");
    }

    auto schemaJson = buildIntrospectionJson!ItemQuery();

    bool foundColorEnum = false;
    foreach (t; schemaJson["types"].array) {
        if (t["name"].str == "Color") {
            foundColorEnum = true;
            assert(t["kind"].str == "ENUM");
            auto enumValues = t["enumValues"].array;
            assert(enumValues.length == 3);
            assert(enumValues[0]["name"].str == "red");
            assert(enumValues[1]["name"].str == "green");
            assert(enumValues[2]["name"].str == "blue");
        }
    }
    assert(foundColorEnum, "Should have Color enum type");
}

// Test input type introspection
unittest {
    import std.json;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    struct FormatOptions {
        string prefix;
        Nullable!string suffix;
    }

    @DemoEntity!(db, "users")
    static struct FmtUser {
        mixin DemoId;
        mixin Col!("firstName", string);

        static auto formattedName(Expr!FmtUser u, FormatOptions options) {
            return u.firstName;
        }
    }

    static struct FmtQuery {
        mixin Table!(FmtUser, "users");
    }

    auto schemaJson = buildIntrospectionJson!FmtQuery();

    bool foundInput = false;
    foreach (t; schemaJson["types"].array) {
        if (t["name"].str == "FormatOptions") {
            foundInput = true;
            assert(t["kind"].str == "INPUT_OBJECT");
            auto inputFields = t["inputFields"].array;

            // prefix: String!
            bool hasPrefix = false;
            bool hasSuffix = false;
            foreach (f; inputFields) {
                if (f["name"].str == "prefix") {
                    hasPrefix = true;
                    assert(f["type"]["kind"].str == "NON_NULL");
                    assert(f["type"]["ofType"]["name"].str == "String");
                }
                if (f["name"].str == "suffix") {
                    hasSuffix = true;
                    // Nullable → no NON_NULL wrapper
                    assert(f["type"]["kind"].str == "SCALAR");
                    assert(f["type"]["name"].str == "String");
                }
            }
            assert(hasPrefix);
            assert(hasSuffix);
        }
    }
    assert(foundInput, "Should have FormatOptions input type");

    // Also check that formattedName has an args entry
    bool foundArgs = false;
    foreach (t; schemaJson["types"].array) {
        if (t["name"].str == "FmtUser") {
            foreach (f; t["fields"].array) {
                if (f["name"].str == "formattedName") {
                    foundArgs = true;
                    assert(f["args"].array.length == 1);
                    assert(f["args"].array[0]["name"].str == "options");
                }
            }
        }
    }
    assert(foundArgs, "formattedName should have args");
}

// Abstract types are introspectable through a plugin's AllEntityTypes
unittest {
    import dunamis.core;
    import dunamis.core.expr.combinators : unionOf;
    import dunamis.core.types : AbstractField, ImplementedBy;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.schema.filtering : FilterPlugin;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct SearchResult {}

    @ImplementedBy!(User, Post)
    static struct Node {
        mixin AbstractField!("id", long);
    }

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");
        static auto search(Expr!Query q) { return unionOf!SearchResult(users(q), posts(q)); }
        static auto nodes(Expr!Query q) { return unionOf!Node(users(q), posts(q)); }
    }

    alias FilteredSchema = FilterPlugin!(Schema!Query);
    static assert(__traits(hasMember, FilteredSchema, "AllEntityTypes"));

    JSONValue[string] lookup;
    foreach (t; buildIntrospectionJson!FilteredSchema()["types"].array)
        lookup[t["name"].str] = t;

    assert("SearchResult" in lookup, "SearchResult union missing from introspection");
    assert(lookup["SearchResult"]["kind"].str == "UNION");
    string[] members;
    foreach (pt; lookup["SearchResult"]["possibleTypes"].array)
        members ~= pt["name"].str;
    assert(members.sort.release == ["Post", "User"], members.to!string);

    assert("Node" in lookup, "Node interface missing from introspection");
    assert(lookup["Node"]["kind"].str == "INTERFACE");
}

// Filter input types are introspected under their SDL names, with their
// fields' GraphQL names
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.schema.filtering : FilterPlugin;

    static MockDB!() db;

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
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

    alias FilteredSchema = FilterPlugin!(Schema!Query);
    JSONValue[string] lookup;
    foreach (t; buildIntrospectionJson!FilteredSchema()["types"].array)
        lookup[t["name"].str] = t;

    foreach (name; ["UserFilter", "PostFilter", "PostFilterListFilter", "StringFilter"])
        assert(name in lookup && lookup[name]["kind"].str == "INPUT_OBJECT", name);
    string[] stringFilterFields;
    foreach (f; lookup["StringFilter"]["inputFields"].array)
        stringFilterFields ~= f["name"].str;
    assert(stringFilterFields.canFind("in") && !stringFilterFields.canFind("in_"), stringFilterFields.to!string);
    auto postsArg = lookup["User"]["fields"].array.find!(f => f["name"].str == "posts").front["args"].array;
    assert(postsArg[0]["type"]["name"].str == "PostFilter", postsArg.to!string);
}
