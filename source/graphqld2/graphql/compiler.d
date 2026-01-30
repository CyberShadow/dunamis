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
auto compileQuery(Query, DataSource)(string queryString, DataSource db) {
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
// Root Selection Set Compilation
// ============================================================================

/// Compile the root selection set (fields from Query type)
auto compileRootSelectionSet(Query, DataSource)(SelectionSet ss, DataSource db) {
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
auto compileRootField(Query, DataSource)(Field field, DataSource db) {
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

/// Compile a selection set into a MapExpr with JsonObjectExpr body
auto compileMapExpr(Entity, Coll)(Coll collection, SelectionSet ss) {
    import graphqld2.core.expr : Expr, map;

    return map!(
        (Expr!Entity entity) {
            return compileSelectionSetBody!Entity(entity, ss);
        }
    )(collection);
}

/// Compile the body of a selection set (the fields to extract)
auto compileSelectionSetBody(Entity)(Expr!Entity entityRef, SelectionSet ss) {
    auto selections = iterateSelections(ss);
    if (selections.length == 0) {
        throw new CompilerException("Empty selection set for " ~ Entity._typeName);
    }

    // Build field name/value pairs for jsonObject
    return compileFieldsToJsonObject!Entity(entityRef, selections);
}

/// Compile selected fields into a jsonObject call
auto compileFieldsToJsonObject(Entity)(Expr!Entity entityRef, Selection[] selections) {
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
auto buildDynamicJsonObject(string[] names, ExprBase[] exprs) {
    import graphqld2.core.expr : DynamicJsonObjectExpr;
    return new DynamicJsonObjectExpr(names, exprs);
}

/// Compile access to a single field
ExprBase compileFieldAccess(Entity)(Expr!Entity entityRef, Field field) {
    auto fieldName = getFieldName(field);

    // Look up field in entity at compile time
    // Check columns, relationships, and computed fields
    static foreach (member; __traits(allMembers, Entity)) {{
        // Skip internal Col mixin helper symbols (they conflict when multiple Col mixins are used)
        static if (member.length >= 5 && member[0..5] == "_Col_") {
            // Skip _Col_IsForeignKey, _Col_IsNullable, etc.
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
                // BelongsTo relationship - compile nested selection
                if (field.ss is null) {
                    throw new CompilerException("Relationship field '" ~ fieldName ~ "' requires a selection set");
                }
                auto relExpr = __traits(getMember, Entity, FieldMeta.name)(entityRef);
                return compileMapExpr!(FieldMeta.parentType)(relExpr, field.ss);
            }
        }
        else static if (isComputedField!(Entity, member, __traits(getMember, Entity, member))) {
            enum gqlName = getGqlName!(__traits(getMember, Entity, member), member);

            if (fieldName == gqlName) {
                // Computed field
                // TODO: Handle arguments
                return __traits(getMember, Entity, member)(entityRef);
            }
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
