module graphqld2.graphql.compiler;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.traits;
import std.typecons : Nullable;

import graphql.ast;
import graphql.lexer;
import graphql.parser;

import graphqld2.core;
import graphqld2.graphql.schema;

// ============================================================================
// Query Compiler
// ============================================================================

/// Result type for compiled GraphQL queries.
/// All GraphQL queries evaluate to an array of JSON objects.
alias GraphQLResult = Expr!(JSONValue[]);

/// Compiles a GraphQL query string into an executable Expr tree.
///
/// The compiler uses compile-time reflection on the Query type to look up
/// fields and generate the appropriate expressions. The result is an Expr
/// tree that can be executed by the Executor.
///
/// Example:
/// ---
/// struct Query {
///     mixin Table!(MockDB!(), User, "users");
/// }
///
/// auto db = new MockDB!()();
/// auto query = compileQuery!Query(`{ users { firstName, lastName } }`, db);
/// auto result = executor.execute(query);
/// ---
GraphQLResult compileQuery(Query, DataSource)(string queryString, DataSource db) {
    // Parse the GraphQL query
    auto lexer = Lexer(queryString);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();

    // Find the operation
    auto op = findOperation(doc);
    if (op is null || op.ss is null) {
        throw new CompilerException("No operation found in query");
    }

    // Compile the root selection set
    return compileRootSelectionSet!(Query, DataSource)(op.ss, db);
}

/// Exception thrown during query compilation
class CompilerException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

// ============================================================================
// Internal: AST Navigation
// ============================================================================

private:

/// Find the first operation in the document
OperationDefinition findOperation(Document doc) @safe {
    if (doc is null || doc.defs is null) return null;
    return findOperationInDefs(doc.defs);
}

OperationDefinition findOperationInDefs(Definitions defs) @safe {
    if (defs is null) return null;

    if (defs.def !is null) {
        if (defs.def.ruleSelection == DefinitionEnum.O) {
            return defs.def.op;
        }
    }

    // Check following definitions
    if (defs.follow !is null) {
        return findOperationInDefs(defs.follow);
    }

    return null;
}

/// Get field name from a Field AST node
string getFieldName(Field field) @safe {
    if (field is null || field.name is null || field.name.name is null) {
        return null;
    }
    return field.name.name.tok.value;
}

/// Get alias (if any) from a Field AST node
string getFieldAlias(Field field) @safe {
    if (field is null || field.name is null) {
        return null;
    }
    if (field.name.aka !is null) {
        return field.name.aka.tok.value;
    }
    return null;
}

/// Get the output name (alias if present, otherwise field name)
string getOutputName(Field field) @safe {
    auto alias_ = getFieldAlias(field);
    return alias_ !is null ? alias_ : getFieldName(field);
}

/// Iterate over selections in a SelectionSet
auto iterateSelections(SelectionSet ss) @safe {
    Selection[] result;
    if (ss is null || ss.sel is null) return result;

    void collect(Selections sels) {
        if (sels is null) return;
        if (sels.sel !is null) {
            result ~= sels.sel;
        }
        if (sels.follow !is null) {
            collect(sels.follow);
        }
    }

    collect(ss.sel);
    return result;
}

/// Iterate over arguments in an Arguments node
auto iterateArguments(Arguments args) @safe {
    Argument[] result;
    if (args is null || args.arg is null) return result;

    void collect(ArgumentList list) {
        if (list is null) return;
        if (list.arg !is null) {
            result ~= list.arg;
        }
        if (list.follow !is null) {
            collect(list.follow);
        }
    }

    collect(args.arg);
    return result;
}

// ============================================================================
// Argument Value Extraction
// ============================================================================

/// Find an argument by name and return its Value node, or null if not found
Value findArgumentValue(Arguments args, string name) {
    foreach (arg; iterateArguments(args)) {
        if (arg.name.value == name) {
            if (arg.vv !is null && arg.vv.val !is null) {
                return arg.vv.val;
            }
        }
    }
    return null;
}

/// Extract a string value from a GraphQL Value node
string extractString(Value val) {
    import graphql.ast : ValueEnum;
    if (val is null) return null;
    if (val.ruleSelection == ValueEnum.STR) {
        return val.tok.value;
    }
    throw new CompilerException("Expected string argument, got " ~ val.ruleSelection.to!string);
}

/// Extract a long value from a GraphQL Value node
long extractLong(Value val) {
    import graphql.ast : ValueEnum;
    if (val is null) throw new CompilerException("Missing required integer argument");
    if (val.ruleSelection == ValueEnum.INT) {
        return val.tok.value.to!long;
    }
    throw new CompilerException("Expected integer argument, got " ~ val.ruleSelection.to!string);
}

/// Extract a double value from a GraphQL Value node
double extractDouble(Value val) {
    import graphql.ast : ValueEnum;
    if (val is null) throw new CompilerException("Missing required float argument");
    if (val.ruleSelection == ValueEnum.FLOAT) {
        return val.tok.value.to!double;
    }
    if (val.ruleSelection == ValueEnum.INT) {
        return val.tok.value.to!double;  // Allow int where float expected
    }
    throw new CompilerException("Expected float argument, got " ~ val.ruleSelection.to!string);
}

/// Extract a bool value from a GraphQL Value node
bool extractBool(Value val) {
    import graphql.ast : ValueEnum;
    if (val is null) throw new CompilerException("Missing required boolean argument");
    if (val.ruleSelection == ValueEnum.T) return true;
    if (val.ruleSelection == ValueEnum.F) return false;
    throw new CompilerException("Expected boolean argument, got " ~ val.ruleSelection.to!string);
}

/// Check if a Value node is null
bool isNullValue(Value val) {
    import graphql.ast : ValueEnum;
    return val is null || val.ruleSelection == ValueEnum.N;
}

/// Extract a typed value from a GraphQL Value node
T extractValue(T)(Value val, T defaultValue = T.init) {
    import graphql.ast : ValueEnum;

    if (val is null || val.ruleSelection == ValueEnum.N) {
        return defaultValue;
    }

    static if (is(T == string)) {
        return extractString(val);
    } else static if (is(T == long) || is(T == int)) {
        return cast(T) extractLong(val);
    } else static if (is(T == double) || is(T == float)) {
        return cast(T) extractDouble(val);
    } else static if (is(T == bool)) {
        return extractBool(val);
    } else static if (is(T == Nullable!U, U)) {
        if (isNullValue(val)) {
            return T.init;  // null
        }
        return T(extractValue!U(val));
    } else {
        static assert(false, "Unsupported argument type: " ~ T.stringof);
    }
}

// ============================================================================
// Computed Field Invocation
// ============================================================================

/// Check if a type is a supported scalar argument type
template isSupportedArgType(T) {
    static if (is(T == string) || is(T == long) || is(T == int) ||
               is(T == double) || is(T == float) || is(T == bool)) {
        enum isSupportedArgType = true;
    } else static if (is(T == Nullable!U, U)) {
        enum isSupportedArgType = isSupportedArgType!U;
    } else {
        enum isSupportedArgType = false;
    }
}

/// Check if all argument types of a function are supported
template allArgTypesSupported(alias fn) {
    import std.traits : Parameters;
    alias Params = Parameters!fn;

    enum allArgTypesSupported = () {
        static foreach (i; 1 .. Params.length) {
            if (!isSupportedArgType!(Params[i])) {
                return false;
            }
        }
        return true;
    }();
}

/// Call a computed field with arguments extracted from GraphQL.
/// Uses compile-time introspection to determine parameter types and names,
/// then extracts values from the GraphQL Arguments at runtime.
auto callComputedField(alias fn, Entity)(Expr!Entity entityRef, Arguments args) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;

    alias Params = Parameters!fn;
    alias Defaults = ParameterDefaults!fn;
    enum paramNames = [ParameterIdentifierTuple!fn];

    // Number of extra parameters (excluding first Expr!Entity parameter)
    enum numArgs = Params.length - 1;

    // Extract each argument and call the function
    static if (numArgs == 0) {
        return fn(entityRef);
    } else static if (numArgs == 1) {
        auto arg0 = extractArg!(Params[1], Defaults[1])(args, paramNames[1]);
        return fn(entityRef, arg0);
    } else static if (numArgs == 2) {
        auto arg0 = extractArg!(Params[1], Defaults[1])(args, paramNames[1]);
        auto arg1 = extractArg!(Params[2], Defaults[2])(args, paramNames[2]);
        return fn(entityRef, arg0, arg1);
    } else static if (numArgs == 3) {
        auto arg0 = extractArg!(Params[1], Defaults[1])(args, paramNames[1]);
        auto arg1 = extractArg!(Params[2], Defaults[2])(args, paramNames[2]);
        auto arg2 = extractArg!(Params[3], Defaults[3])(args, paramNames[3]);
        return fn(entityRef, arg0, arg1, arg2);
    } else static if (numArgs == 4) {
        auto arg0 = extractArg!(Params[1], Defaults[1])(args, paramNames[1]);
        auto arg1 = extractArg!(Params[2], Defaults[2])(args, paramNames[2]);
        auto arg2 = extractArg!(Params[3], Defaults[3])(args, paramNames[3]);
        auto arg3 = extractArg!(Params[4], Defaults[4])(args, paramNames[4]);
        return fn(entityRef, arg0, arg1, arg2, arg3);
    } else {
        static assert(false, "Computed fields with more than 4 arguments not supported");
    }
}

/// Extract an argument value, using default if not provided
T extractArg(T, alias Default)(Arguments args, string name) {
    auto val = findArgumentValue(args, name);

    static if (is(Default == void)) {
        // Required argument - no default
        if (val is null) {
            throw new CompilerException("Missing required argument: " ~ name);
        }
        return extractValue!T(val);
    } else {
        // Optional argument - has default
        if (val is null || isNullValue(val)) {
            return Default;
        }
        return extractValue!T(val);
    }
}

// ============================================================================
// Root Selection Set Compilation
// ============================================================================

/// Compile the root selection set (fields from Query type)
GraphQLResult compileRootSelectionSet(Query, DataSource)(SelectionSet ss, DataSource db) {
    auto selections = iterateSelections(ss);

    if (selections.length == 0) {
        throw new CompilerException("Empty selection set");
    }

    if (selections.length == 1 && selections[0].ruleSelection == SelectionEnum.Field) {
        // Single root field - compile it directly
        return compileRootField!(Query, DataSource)(selections[0].field, db);
    }

    // Multiple root fields - combine into a JSON object
    // This is unusual for GraphQL but we support it
    throw new CompilerException("Multiple root fields not yet supported");
}

/// Compile a single root field (e.g., "users" from Query)
GraphQLResult compileRootField(Query, DataSource)(Field field, DataSource db) {
    auto fieldName = getFieldName(field);

    // Look up the field in Query type at compile time
    static foreach (member; __traits(allMembers, Query)) {{
        static if (member.length > 12 && member[0..12] == "_tableField_") {
            alias FieldMeta = __traits(getMember, Query, member);
            enum gqlName = FieldMeta.name;

            // Check if this is the field we're looking for
            if (fieldName == gqlName) {
                // Get the root expression
                auto rootExpr = __traits(getMember, Query, gqlName)(db);

                // Compile the nested selection set
                if (field.ss !is null) {
                    return compileMapExpr!(FieldMeta.entityType)(rootExpr, field.ss);
                } else {
                    throw new CompilerException("Root field '" ~ fieldName ~ "' requires a selection set");
                }
            }
        }
    }}

    throw new CompilerException("Unknown root field: " ~ fieldName);
}

// ============================================================================
// Selection Set Compilation (for entity types)
// ============================================================================

/// Compile a selection set into a MapExpr with DynamicJsonObjectExpr body.
/// Returns Expr!(JSONValue[]) which is the result of mapping over the collection.
/// Note: Explicit return type breaks circular template instantiation.
MapExpr!(Entity, DynamicJsonObjectExpr) compileMapExpr(Entity, Coll)(Coll collection, SelectionSet ss) {
    import graphqld2.core.expr : Expr, map;

    return map!(
        (Expr!Entity entity) => compileSelectionSetBody!Entity(entity, ss)
    )(collection);
}

/// Compile the body of a selection set (the fields to extract)
DynamicJsonObjectExpr compileSelectionSetBody(Entity)(Expr!Entity entityRef, SelectionSet ss) {
    auto selections = iterateSelections(ss);
    if (selections.length == 0) {
        throw new CompilerException("Empty selection set for " ~ Entity._typeName);
    }

    // Build field name/value pairs for jsonObject
    return compileFieldsToJsonObject!Entity(entityRef, selections);
}

/// Compile selected fields into a jsonObject call
DynamicJsonObjectExpr compileFieldsToJsonObject(Entity)(Expr!Entity entityRef, Selection[] selections) {
    // Collect field expressions
    ExprBase[] fieldExprs;
    string[] fieldNames;

    foreach (sel; selections) {
        if (sel.ruleSelection != SelectionEnum.Field) continue;
        auto field = sel.field;
        auto name = getFieldName(field);
        auto outputName = getOutputName(field);

        fieldNames ~= outputName;
        fieldExprs ~= compileFieldAccess!Entity(entityRef, field);
    }

    // Build a dynamic JSON object using runtime construction
    return buildDynamicJsonObject(fieldNames, fieldExprs);
}

/// Build a JSON object from runtime field names and expressions
DynamicJsonObjectExpr buildDynamicJsonObject(string[] names, ExprBase[] exprs) {
    import graphqld2.core.expr : DynamicJsonObjectExpr;
    return new DynamicJsonObjectExpr(names, exprs);
}

/// Compile access to a single field
ExprBase compileFieldAccess(Entity)(Expr!Entity entityRef, Field field) {
    auto fieldName = getFieldName(field);

    // Look up field in entity at compile time
    // Check columns, relationships, and computed fields
    static foreach (member; __traits(allMembers, Entity)) {{
        // Skip internal mixin helper symbols (they conflict when multiple mixins are used)
        static if (member.length >= 5 && member[0..5] == "_Col_") {
            // Skip _Col_IsForeignKey, _Col_IsNullable, etc.
        }
        else static if (member.length >= 11 && member[0..11] == "_BelongsTo_") {
            // Skip _BelongsTo_FkMeta, _BelongsTo_Parent, etc.
        }
        else static if (member.length > 10 && member[0..10] == "_colField_") {
            alias FieldMeta = __traits(getMember, Entity, member);
            enum gqlName = getGqlName!(FieldMeta, FieldMeta.name);

            if (fieldName == gqlName) {
                // Column access
                return __traits(getMember, Entity, FieldMeta.name)(entityRef);
            }
        }
        else static if (member.length > 14 && member[0..14] == "_hasManyField_") {
            alias FieldMeta = __traits(getMember, Entity, member);
            enum gqlName = getGqlName!(FieldMeta, FieldMeta.name);

            if (fieldName == gqlName) {
                // HasMany relationship - compile nested selection
                if (field.ss is null) {
                    throw new CompilerException("Relationship field '" ~ fieldName ~ "' requires a selection set");
                }
                auto relExpr = __traits(getMember, Entity, FieldMeta.name)(entityRef);
                return compileMapExpr!(FieldMeta.childType)(relExpr, field.ss);
            }
        }
        else static if (member.length > 16 && member[0..16] == "_belongsToField_") {
            alias FieldMeta = __traits(getMember, Entity, member);
            enum gqlName = getGqlName!(FieldMeta, FieldMeta.name);

            if (fieldName == gqlName) {
                // BelongsTo relationship - compile nested selection for single parent entity
                if (field.ss is null) {
                    throw new CompilerException("Relationship field '" ~ fieldName ~ "' requires a selection set");
                }
                auto relExpr = __traits(getMember, Entity, FieldMeta.name)(entityRef);
                // BelongsTo returns Expr!ParentEntity (single entity), not a collection
                return compileSelectionSetBody!(FieldMeta.parentType)(relExpr, field.ss);
            }
        }
        else static if (isComputedField!(Entity, member, __traits(getMember, Entity, member))) {
            alias fn = __traits(getMember, Entity, member);
            // Only support computed fields with scalar argument types
            static if (allArgTypesSupported!fn) {
                enum gqlName = getGqlName!(fn, member);

                if (fieldName == gqlName) {
                    // Computed field - call with arguments extracted from GraphQL
                    return callComputedField!(fn, Entity)(entityRef, field.args);
                }
            }
            // Skip computed fields with unsupported argument types (e.g., input objects)
        }
    }}

    throw new CompilerException("Unknown field '" ~ fieldName ~ "' on type " ~ Entity._typeName);
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import graphqld2.core;
    import graphqld2.relational.schema;
    import graphqld2.relational.demo;
    import graphqld2.relational.eval_context;

    // Define test entities
    static struct User {
        mixin DemoEntity!"users";
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto fullName(Expr!User u) {
            return firstName(u) ~ " " ~ lastName(u);
        }
    }

    alias DB = MockDB!();

    static struct Query {
        mixin Table!(DB, User, "users");
    }

    // Set up mock data
    auto db = new DB();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"}
    ]`);

    // Compile a simple query
    auto query = compileQuery!Query(`{ users { firstName, lastName } }`, db);

    // Execute
    auto executor = new Executor();
    auto results = awaitSync(executor.execute(query));

    // Verify results (executor returns JSONValue[])
    assert(results.length == 2);
    assert(results[0]["firstName"].str == "Alice");
    assert(results[0]["lastName"].str == "Smith");
    assert(results[1]["firstName"].str == "Bob");
    assert(results[1]["lastName"].str == "Jones");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import graphqld2.core;
    import graphqld2.relational.schema;
    import graphqld2.relational.demo;
    import graphqld2.relational.eval_context;

    // Test computed fields
    static struct User {
        mixin DemoEntity!"users";
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto fullName(Expr!User u) {
            return firstName(u) ~ " " ~ lastName(u);
        }
    }

    alias DB = MockDB!();

    static struct Query {
        mixin Table!(DB, User, "users");
    }

    auto db = new DB();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto query = compileQuery!Query(`{ users { fullName } }`, db);

    auto executor = new Executor();
    auto results = awaitSync(executor.execute(query));

    assert(results.length == 1);
    assert(results[0]["fullName"].str == "Alice Smith");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import graphqld2.core;
    import graphqld2.relational.schema;
    import graphqld2.relational.demo;
    import graphqld2.relational.eval_context;

    // Test nested hasMany relationships
    static struct Post {
        mixin DemoEntity!"posts";
        mixin Col!("title", string);
    }

    static struct User {
        mixin DemoEntity!"users";
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    alias DB = MockDB!();

    static struct Query {
        mixin Table!(DB, User, "users");
    }

    auto db = new DB();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 1, "title": "World"},
        {"id": 3, "author_id": 2, "title": "Test"}
    ]`);

    auto query = compileQuery!Query(`{ users { firstName, posts { title } } }`, db);

    auto executor = new Executor();
    auto results = awaitSync(executor.execute(query));

    assert(results.length == 2);

    // Alice has 2 posts
    assert(results[0]["firstName"].str == "Alice");
    assert(results[0]["posts"].array.length == 2);
    assert(results[0]["posts"][0]["title"].str == "Hello");
    assert(results[0]["posts"][1]["title"].str == "World");

    // Bob has 1 post
    assert(results[1]["firstName"].str == "Bob");
    assert(results[1]["posts"].array.length == 1);
    assert(results[1]["posts"][0]["title"].str == "Test");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import graphqld2.core;
    import graphqld2.relational.schema;
    import graphqld2.relational.demo;
    import graphqld2.relational.eval_context;

    // Test computed fields with arguments
    static struct User {
        mixin DemoEntity!"users";
        mixin Col!("firstName", string);

        // Computed field with required argument
        static auto greeting(Expr!User u, string prefix) {
            return prefix ~ " " ~ firstName(u);
        }

        // Computed field with optional argument (has default)
        static auto greetingWithSuffix(Expr!User u, string prefix, string suffix = "!") {
            return prefix ~ " " ~ firstName(u) ~ suffix;
        }
    }

    alias DB = MockDB!();

    static struct Query {
        mixin Table!(DB, User, "users");
    }

    auto db = new DB();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);

    // Test with required argument
    auto query1 = compileQuery!Query(`{ users { greeting(prefix: "Hello") } }`, db);
    auto executor = new Executor();
    auto results1 = awaitSync(executor.execute(query1));

    assert(results1.length == 2);
    assert(results1[0]["greeting"].str == "Hello Alice");
    assert(results1[1]["greeting"].str == "Hello Bob");

    // Test with optional argument using default
    auto query2 = compileQuery!Query(`{ users { greetingWithSuffix(prefix: "Hi") } }`, db);
    auto results2 = awaitSync(executor.execute(query2));

    assert(results2.length == 2);
    assert(results2[0]["greetingWithSuffix"].str == "Hi Alice!");
    assert(results2[1]["greetingWithSuffix"].str == "Hi Bob!");

    // Test with optional argument overridden
    auto query3 = compileQuery!Query(`{ users { greetingWithSuffix(prefix: "Hey", suffix: "?") } }`, db);
    auto results3 = awaitSync(executor.execute(query3));

    assert(results3.length == 2);
    assert(results3[0]["greetingWithSuffix"].str == "Hey Alice?");
    assert(results3[1]["greetingWithSuffix"].str == "Hey Bob?");
}
