module dynamo.graphql.introspection;

import std.algorithm;
import std.array;
import std.conv;
import std.json : JSONValue, JSONType;
import std.meta;
import std.traits;
import std.typecons : Nullable;

import dynamo.core.types : isCustomScalar, isPlainField, isPlainMethod, NoSchemaConfig, ResolveType;
import dynamo.core.expr : Expr, ExprResultType, isExpr;
import dynamo.graphql.schema;

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
template typeRefJson(T, alias cfg = NoSchemaConfig) {
    enum typeRefJson = buildTypeRefJson!(T, cfg)();
}

private JSONValue buildTypeRefJson(T, alias cfg = NoSchemaConfig)() {
    alias Resolved = ResolveType!(T, cfg);
    // Nullable → no NON_NULL wrapper
    static if (is(Resolved == Nullable!U, U)) {
        return buildBaseTypeRefJson!(U, cfg)();
    }
    // Pointer → nullable (no NON_NULL wrapper)
    else static if (is(Resolved == U*, U)) {
        return buildBaseTypeRefJson!(U, cfg)();
    }
    // Everything else → wrapped in NON_NULL
    else {
        return nonNullOf(buildBaseTypeRefJson!(Resolved, cfg)());
    }
}

private JSONValue buildBaseTypeRefJson(T, alias cfg = NoSchemaConfig)() {
    alias Resolved = ResolveType!(T, cfg);
    // Scalar types (check string BEFORE array since string is immutable(char)[])
    static if (is(Resolved == string)) {
        return namedType("SCALAR", "String");
    } else static if (is(Resolved == bool)) {
        return namedType("SCALAR", "Boolean");
    } else static if (is(Resolved == int) || is(Resolved == long)) {
        return namedType("SCALAR", "Int");
    } else static if (is(Resolved == float) || is(Resolved == double)) {
        return namedType("SCALAR", "Float");
    }
    // JSONValue → JSON scalar
    else static if (is(Resolved == JSONValue)) {
        return namedType("SCALAR", "JSON");
    }
    // Custom scalar
    else static if (isCustomScalar!Resolved) {
        return namedType("SCALAR", Resolved.name);
    }
    // Array → LIST (after string check since string is immutable(char)[])
    else static if (is(Resolved == E[], E)) {
        return listOf(buildTypeRefJson!(E, cfg)());
    }
    // Enum
    else static if (is(Resolved == enum)) {
        return namedType("ENUM", __traits(identifier, Resolved));
    }
    // Object type (entity or POD struct with fields)
    else static if (isObjectType!Resolved) {
        return namedType("OBJECT", getGraphQLTypeName!Resolved);
    }
    // Input type
    else static if (isInputType!Resolved) {
        return namedType("INPUT_OBJECT", Resolved.stringof);
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
/// Mirrors the three-pass pattern from getFields!T but produces JSONValue type refs.
template getRuntimeFields(T, alias cfg = NoSchemaConfig) {
    enum getRuntimeFields = buildRuntimeFields!(T, cfg)();
}

private RuntimeFieldInfo[] buildRuntimeFields(T, alias cfg = NoSchemaConfig)() {
    RuntimeFieldInfo[] fields;

    // First pass: computed fields (static methods taking Expr!T)
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            static if (is(typeof(__traits(getMember, T, member)) == function)) {
                alias fn = __traits(getMember, T, member);

                enum isHidden = hasGqlHidden!fn;
                enum gqlFieldName = getGqlName!(fn, member);
                enum description = getGqlDescription!fn;
                enum deprecation = getGqlDeprecated!fn;

                static if (isValidFieldMethod!(T, fn)) {
                    // Compute return type JSON
                    enum typeJson = computedFieldTypeRefJson!(fn, cfg)();

                    // Compute argument info
                    enum args = computedFieldRuntimeArgs!(fn, cfg)();

                    fields ~= RuntimeFieldInfo(
                        gqlFieldName,
                        typeJson,
                        isHidden,
                        description,
                        deprecation,
                        args
                    );
                }
            }
        }
    }}

    // Second pass: plain fields (struct instance fields)
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            static if (isPlainField!(T, member)) {
                alias FieldType = typeof(__traits(getMember, T.init, member));
                enum typeJson = typeRefJson!(FieldType, cfg);

                fields ~= RuntimeFieldInfo(
                    member,
                    typeJson,
                    false,  // not hidden
                    "",     // no description
                    "",     // no deprecation
                    []      // no args
                );
            }
        }
    }}

    // Third pass: plain methods (instance methods returning non-Expr types)
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            static if (isPlainMethod!(T, member)) {
                alias MethodType = typeof(__traits(getMember, T, member));
                alias RetType = ReturnType!MethodType;

                alias methodSym = __traits(getMember, T, member);
                enum isHidden = hasGqlHidden!methodSym;
                enum gqlFieldName = getGqlName!(methodSym, member);
                enum description = getGqlDescription!methodSym;
                enum deprecation = getGqlDeprecated!methodSym;
                enum typeJson = typeRefJson!(RetType, cfg);

                fields ~= RuntimeFieldInfo(
                    gqlFieldName,
                    typeJson,
                    isHidden,
                    description,
                    deprecation,
                    []  // no args for plain methods
                );
            }
        }
    }}

    return fields;
}

/// Get JSONValue type ref for a computed field's return type.
/// Mirrors computedFieldReturnType but produces JSONValue instead of string.
private JSONValue computedFieldTypeRefJson(alias member, alias cfg = NoSchemaConfig)() {
    alias Return = ReturnType!(typeof(member));
    alias RawResultT = ExprResultType!Return;
    alias ResultT = ResolveType!(RawResultT, cfg);

    static if (is(ResultT == string)) {
        return typeRefJson!(string, cfg);
    }
    else static if (is(ResultT == E[], E)) {
        static if (is(E : Expr!Inner, Inner)) {
            // Array of expressions (e.g., from map) - extract inner type → [Inner!]!
            return nonNullOf(listOf(typeRefJson!(Inner, cfg)));
        } else {
            return nonNullOf(listOf(typeRefJson!(E, cfg)));
        }
    }
    else {
        return typeRefJson!(ResultT, cfg);
    }
}

/// Extract runtime argument info from a computed field.
/// Mirrors getComputedFieldArguments but produces JSONValue type refs.
private RuntimeArgInfo[] computedFieldRuntimeArgs(alias member, alias cfg = NoSchemaConfig)() {
    alias Params = Parameters!member;
    alias Defaults = ParameterDefaults!member;
    enum string[] paramNames = [ParameterIdentifierTuple!member];

    RuntimeArgInfo[] args;

    // Skip first parameter (Expr!Entity), process rest as arguments
    static foreach (i; 1 .. Params.length) {{
        alias P = ResolveType!(Params[i], cfg);

        static if (is(Defaults[i] == void)) {
            // No default - required argument
            args ~= RuntimeArgInfo(
                paramNames[i],
                typeRefJson!(P, cfg),
                false,
                ""
            );
        } else {
            // Has default - optional argument
            static if (is(P == Nullable!U, U)) {
                args ~= RuntimeArgInfo(
                    paramNames[i],
                    buildBaseTypeRefJson!(U, cfg)(),  // nullable, no NON_NULL wrapper
                    true,
                    "null"
                );
            } else {
                args ~= RuntimeArgInfo(
                    paramNames[i],
                    buildBaseTypeRefJson!(P, cfg)(),  // nullable (has default), no NON_NULL wrapper
                    true,
                    defaultValueToString(Defaults[i])
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
template getRuntimeInputFields(T, alias cfg = NoSchemaConfig) if (isInputType!T) {
    enum getRuntimeInputFields = buildRuntimeInputFields!(T, cfg)();
}

private RuntimeInputFieldInfo[] buildRuntimeInputFields(T, alias cfg = NoSchemaConfig)() {
    RuntimeInputFieldInfo[] fields;

    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            alias RawMemberType = typeof(__traits(getMember, T, member));
            alias MemberType = ResolveType!(RawMemberType, cfg);

            static if (!is(MemberType == function) && !is(MemberType == void)) {
                static if (__traits(compiles, { auto v = __traits(getMember, T.init, member); })) {
                    // Determine type ref based on nullability
                    static if (is(MemberType == Nullable!(Nullable!U), U)) {
                        // Three-state: absent/null/value → nullable
                        enum typeJson = buildBaseTypeRefJson!(U, cfg)();
                    } else static if (is(MemberType == Nullable!U, U)) {
                        // Two-state → nullable
                        enum typeJson = buildBaseTypeRefJson!(U, cfg)();
                    } else static if (is(MemberType == U*, U)) {
                        // Pointer → nullable
                        enum typeJson = buildBaseTypeRefJson!(U, cfg)();
                    } else {
                        // Required → NON_NULL
                        enum typeJson = nonNullOf(buildBaseTypeRefJson!(MemberType, cfg)());
                    }

                    fields ~= RuntimeInputFieldInfo(member, typeJson, "");
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
    // Determine Query/Mutation types
    static if (isSchema!SchemaOrQuery) {
        alias QueryType = SchemaOrQuery.Query;
        alias MutationType = SchemaOrQuery.Mutation;
    } else {
        alias QueryType = SchemaOrQuery;
        struct MutationType {}
    }

    // Extract config from Schema if available (bare Query types have no Config)
    static if (isSchema!SchemaOrQuery) {
        alias cfg = SchemaOrQuery.Config;
    } else {
        alias cfg = NoSchemaConfig;
    }

    // Discover all types (same pattern as generateSchemaSDL)
    static if (isSchema!SchemaOrQuery && __traits(hasMember, SchemaOrQuery, "AllEntityTypes")) {
        alias AllEntityTypes = SchemaOrQuery.AllEntityTypes;
    } else {
        alias AllEntityTypes = getAllEntityTypes!(QueryType, cfg);
    }

    alias AllInputTypes_ = getAllInputTypes!(QueryType, cfg);
    static if (getFields!(MutationType, cfg).length > 0) {
        alias MutationDirectTypes = getInputTypesFromMutation!(MutationType, cfg);
        alias MutationInputTypes = expandAllInputTypes!(cfg, uniqueTypesForExpand!MutationDirectTypes);
        alias AllInputTypes = uniqueTypesForExpand!(AliasSeq!(AllInputTypes_, MutationInputTypes));
    } else {
        alias AllInputTypes = AllInputTypes_;
    }

    alias AllEnumTypes = getAllEnumTypes!(QueryType, cfg);

    // Build types array
    JSONValue[] types;

    // Built-in scalars
    types ~= scalarTypeJson("String");
    types ~= scalarTypeJson("Int");
    types ~= scalarTypeJson("Float");
    types ~= scalarTypeJson("Boolean");

    // Custom scalars
    static foreach (scalarName; getAllCustomScalarNames!(cfg, AllEntityTypes)) {
        types ~= scalarTypeJson(scalarName);
    }

    // Enum types
    static foreach (EnumType; AllEnumTypes) {
        types ~= buildEnumTypeJson!EnumType();
    }

    // Query type
    types ~= buildObjectTypeJsonFromFields!(QueryType, cfg)("Query");

    // Mutation type (if it has fields)
    static if (getFields!(MutationType, cfg).length > 0) {
        types ~= buildObjectTypeJsonFromFields!(MutationType, cfg)("Mutation");
    }

    // Entity/object types
    static foreach (Entity; AllEntityTypes) {
        types ~= buildObjectTypeJsonFromFields!(Entity, cfg)(getGraphQLTypeName!Entity);
    }

    // Input types
    static foreach (InputType; AllInputTypes) {
        types ~= buildInputObjectTypeJson!(InputType, cfg)();
    }

    // Introspection meta-types
    types ~= introspectionMetaTypes();

    // Build schema JSON
    JSONValue queryTypeRef = JSONValue(["name": JSONValue("Query")]);

    JSONValue mutationTypeRef;
    static if (getFields!(MutationType, cfg).length > 0) {
        mutationTypeRef = JSONValue(["name": JSONValue("Mutation")]);
    } else {
        mutationTypeRef = JSONValue(null);
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
        "subscriptionType": JSONValue(null),
        "types": JSONValue(types),
        "directives": JSONValue(directives)
    ]);
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
JSONValue applySelectionSet(JSONValue data, SelectionSet ss, JSONValue variables) {
    import graphql.ast : SelectionEnum;

    if (ss is null) return data;
    if (data.isNull) return data;

    auto selections = iterateSelections(ss);
    if (selections.length == 0) return data;

    JSONValue result = JSONValue.emptyObject;

    foreach (sel; selections) {
        if (sel.ruleSelection != SelectionEnum.Field) continue;
        auto field = sel.field;
        auto fieldName = getFieldName(field);
        auto outputName = getOutputName(field);

        if (fieldName is null) continue;

        // Check if the field exists in the data
        if (fieldName !in data) {
            result[outputName] = JSONValue(null);
            continue;
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
                    items ~= applySelectionSet(item, field.ss, variables);
                }
                result[outputName] = JSONValue(items);
            } else if (fieldValue.type == JSONType.object) {
                result[outputName] = applySelectionSet(fieldValue, field.ss, variables);
            } else {
                result[outputName] = fieldValue;
            }
        } else {
            result[outputName] = fieldValue;
        }
    }

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

private JSONValue buildObjectTypeJsonFromFields(T, alias cfg = NoSchemaConfig)(string typeName) {
    enum rtFields = getRuntimeFields!(T, cfg);
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
    return objectTypeJson(typeName, fields);
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
        "name": JSONValue(__traits(identifier, E)),
        "description": JSONValue(null),
        "fields": JSONValue(null),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(null),
        "enumValues": JSONValue(enumValues),
        "possibleTypes": JSONValue(null)
    ]);
}

private JSONValue buildInputObjectTypeJson(T, alias cfg = NoSchemaConfig)() {
    JSONValue[] inputFields;
    static foreach (f; getRuntimeInputFields!(T, cfg)) {
        inputFields ~= inputValueJson(f.name, "", f.typeJson, f.defaultValue);
    }

    return JSONValue([
        "kind": JSONValue("INPUT_OBJECT"),
        "name": JSONValue(T.stringof),
        "description": JSONValue(null),
        "fields": JSONValue(null),
        "inputFields": JSONValue(inputFields),
        "interfaces": JSONValue(null),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
    ]);
}

private JSONValue objectTypeJson(string typeName, JSONValue[] fields) {
    return JSONValue([
        "kind": JSONValue("OBJECT"),
        "name": JSONValue(typeName),
        "description": JSONValue(null),
        "fields": JSONValue(fields),
        "inputFields": JSONValue(null),
        "interfaces": JSONValue(cast(JSONValue[]) []),
        "enumValues": JSONValue(null),
        "possibleTypes": JSONValue(null)
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
        "defaultValue": JSONValue(defaultValue.length > 0 ? defaultValue : null)
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
    Field, Arguments, Argument, ArgumentList, Value;

package {
    // Forward declarations - these come from compiler.d with package visibility
    import dynamo.graphql.compiler : iterateSelections, getFieldName, getOutputName,
        findArgumentValue, extractBool;
}

// ============================================================================
// Tests
// ============================================================================

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
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;

    static MockDB!() db;

    static struct TestUser {
        mixin DemoEntity!(db, "users");
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
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;

    static MockDB!() db;

    enum Color { red, green, blue }

    static struct Item {
        mixin DemoEntity!(db, "items");
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
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;

    static MockDB!() db;

    struct FormatOptions {
        string prefix;
        Nullable!string suffix;
    }

    static struct FmtUser {
        mixin DemoEntity!(db, "users");
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
