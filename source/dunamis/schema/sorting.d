/// Sorting plugin for GraphQL schemas.
///
/// The SortingPlugin adds `orderBy` sorting arguments to the list fields of
/// the schema's types. It has two parts:
/// - the mechanism: sorting a list by fields of its elements (`SortField`s,
///   see `sortByFields`), which data sources do in their queries (e.g. SQL
///   ORDER BY) where they can, in memory otherwise;
/// - the argument surface: what the `orderBy` argument of a list field is,
///   and the fields its values sort by (see `SortingPluginWith`). The
///   default one (`SortingPlugin`) takes `{field, direction}` objects;
///   applications can compose other ones (e.g. `EnumSortSurface`).
///
/// Example:
/// ---
/// alias BaseSchema = Schema!Query;
/// alias SortedSchema = SortingPlugin!BaseSchema;
///
/// // users: [User!]! becomes users(orderBy: [_OrderByStruct_Query_users!]): [User!]!
/// ---
module dunamis.schema.sorting;

import std.traits : ReturnType, Parameters, ParameterDefaults, ParameterIdentifierTuple;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, ExprResultType;
public import dunamis.core.sorting : SortDirection, SortField;
import dunamis.schema.plugin;

// ============================================================================
// SortingPlugin
// ============================================================================

/// Plugin that adds orderBy sorting arguments to all array-returning fields,
/// including nested HasMany relationships, with the default argument
/// surface (`DefaultSortSurface`): see `SortingPluginWith`.
///
/// For each list field, generates:
/// - enum _OrderByFieldEnum_<Type>_<field> { id, field1, field2, ... } - the sortable fields of its elements
/// - struct _OrderByStruct_<Type>_<field> { <that enum> field; SortDirection direction = SortDirection.ASC; }
///
/// Transforms root Query fields:
///   users: [User!]!
/// Into:
///   users(orderBy: [_OrderByStruct_Query_users!]): [User!]!
///
/// And nested entity fields:
///   User.posts: [Post!]!
/// Into:
///   User.posts(orderBy: [_OrderByStruct_User_posts!]): [Post!]!
///
/// Example:
/// ---
/// struct Query {
///     mixin Table!(User, "users");
///     mixin Table!(Post, "posts");
/// }
///
/// alias BaseSchema = Schema!Query;
/// alias SortedSchema = SortingPlugin!BaseSchema;
///
/// // Query with sorting:
/// // { users(orderBy: [{field: lastName, direction: DESC}]) { posts(orderBy: [{field: title}]) { title } } }
/// ---
alias SortingPlugin = SortingPluginWith!DefaultSortSurface;

/// Plugin that adds an `orderBy` argument to the list fields (of objects)
/// for which the argument surface `Surface` declares one, sorting the
/// elements by the fields the argument names (see `sortByFields`).
///
/// The surface is the template `Surface!(Scope, fieldName, Element)`, for
/// the list field `fieldName` of the type `Scope` (as the plugin's source
/// schema has them) whose elements are of type `Element` (likewise). It has:
/// - `Argument`: the type of the argument (if the field gets one), and
/// - `static SortField[] sortFields(Argument)`: the fields an argument value
///   sorts by, the first the primary key of the order (none: the field's
///   own order).
///
/// Dunamis's surfaces: `DefaultSortSurface` (`{field, direction}` objects),
/// `EnumSortSurface` (members of an enum, see `SortsBy`). An application can
/// compose its own (e.g. choosing one by the element type).
template SortingPluginWith(alias Surface) {
    template SortingPluginWith(alias S) if (isSchema!S) {
        import std.meta : AliasSeq, staticMap;
        import dunamis.core.discovery : getSchemaObjectTypes, SchemaRootTypes;
        import dunamis.schema.transform : isTypeInList;

        // The schema's object types: its root types, and those reachable from them
        alias _AllEntityTypes = getSchemaObjectTypes!S;
        alias _AllTypes = AliasSeq!(SchemaRootTypes!S, _AllEntityTypes);

        // The list fields of the wrappers, sorted with the plugin's surface
        mixin template _SortedField(SourceQuery, string fieldName, alias TypeMap) {
            mixin SortedArrayField!(Surface, SourceQuery, fieldName, TypeMap);
        }

        // Generate sorted versions of each entity type.
        template SortedEntity(Entity) {
            @(RemapTypeAttributes!(EntityTypeMap, __traits(getAttributes, Entity)))
            @OriginalName(__traits(identifier, Entity))
            struct SortedEntity {
                mixin WrapFields!(Entity, EntityTypeMap, _SortedField);
            }
        }

        // Map all entity types to their sorted versions
        alias AllEntityTypes = staticMap!(SortedEntity, _AllEntityTypes);

        /// Entity type map: maps the schema's object types (the root types
        /// included) to their sorted versions.
        template EntityTypeMap(T) {
            static if (isTypeInList!(T, _AllTypes)) {
                alias EntityTypeMap = SortedEntity!T;
            } else {
                alias EntityTypeMap = T;
            }
        }

        alias Query = EntityTypeMap!(S.Query);
        alias Mutation = EntityTypeMap!(S.Mutation);
        alias Subscription = EntityTypeMap!(S.Subscription);
    }
}

// ============================================================================
// Sorting by fields (the mechanism)
// ============================================================================

/// Sort the elements of `source` by the fields `fields` (sortable fields of
/// the elements, see `getSortableFields`), the first the primary key of the
/// order: see `dunamis.core.sorting.sortByFieldsAmong`.
auto sortByFields(S)(S source, const(SortField)[] fields) {
    import dunamis.core.sorting : sortByFieldsAmong;
    alias _E = Expr;
    static assert(is(S : _E!(E[]), E), "Expected Expr!(E[]), got " ~ S.stringof);
    static if (is(S : _E!(E[]), E))
        return sortByFieldsAmong!(getSortableFields!E)(source, fields);
}

// ============================================================================
// Argument surfaces
// ============================================================================

/// The default orderBy argument surface (see `SortingPluginWith`): a list of
/// `{field, direction}` objects, of a type of the list field's own, whose
/// `field` is a member of an enum of the elements' sortable fields
/// (`_OrderByStruct_<Type>_<field>` and `_OrderByFieldEnum_<Type>_<field>`,
/// `<Type>` being the name of the type of the field). A list whose elements
/// have no sortable fields gets no argument.
template DefaultSortSurface(Scope, string fieldName, Element) {
    private enum string[] _fields = getSortableFields!Element;
    static if (_fields.length) {
        private enum string _scopeName = getOriginalTypeName!Scope;
        private enum string _enumName = "_OrderByFieldEnum_" ~ _scopeName ~ "_" ~ fieldName;
        private enum string _structName = "_OrderByStruct_" ~ _scopeName ~ "_" ~ fieldName;

        mixin("enum " ~ _enumName ~ " { " ~ () {
            string members;
            foreach (f; _fields)
                members ~= f ~ ", ";
            return members;
        }() ~ "}");
        mixin("struct " ~ _structName ~ " { " ~ _enumName ~ " field; SortDirection direction = SortDirection.ASC; }");

        /// The type of the argument
        mixin("alias Argument = " ~ _structName ~ "[];");

        /// The fields an argument sorts by
        static SortField[] sortFields(const Argument argument) {
            SortField[] result;
            foreach (ref item; argument)
                result ~= SortField(_fields[item.field], item.direction);
            return result;
        }
    }
}

/// UDA on a member of an enum whose values are orderBy arguments (see
/// `EnumSortSurface`): the field the member sorts by, and the direction.
/// A member without one sorts by no field (e.g. a `NATURAL` member, which
/// keeps the list's own order).
struct SortsBy {
    string field;
    SortDirection direction = SortDirection.ASC;
}

/// The orderBy argument surface (see `SortingPluginWith`) whose argument is
/// a list of members of the enum `E`, which sort by the fields their
/// `@SortsBy` attributes name (see `sortFieldsOf`).
template EnumSortSurface(E) if (is(E == enum)) {
    /// The type of the argument
    alias Argument = E[];

    /// The fields an argument sorts by
    static SortField[] sortFields(const Argument argument) {
        return sortFieldsOf(argument);
    }
}

/// The fields values of the enum `E` sort by, by their `@SortsBy`
/// attributes (see `EnumSortSurface`).
SortField[] sortFieldsOf(E)(const(E)[] values) if (is(E == enum)) {
    SortField[] result;
    foreach (value; values) {
        sw: final switch (value) {
            static foreach (name; __traits(allMembers, E)) {
                case __traits(getMember, E, name):
                    static foreach (attr; __traits(getAttributes, __traits(getMember, E, name)))
                        static if (is(typeof(attr) == SortsBy))
                            result ~= SortField(attr.field, attr.direction);
                    break sw;
            }
        }
    }
    return result;
}

/// The fields which the `@SortsBy` attributes of the members of the enum `E`
/// name, but which are not sortable fields of the type `Element` (see
/// `getSortableFields`): for checking at compile time that an
/// `EnumSortSurface` sorts objects of that type.
template unsortableSortsByFields(E, Element) if (is(E == enum)) {
    enum string[] unsortableSortsByFields = () {
        import std.algorithm.searching : canFind;
        string[] result;
        static foreach (name; __traits(allMembers, E))
            static foreach (attr; __traits(getAttributes, __traits(getMember, E, name)))
                static if (is(typeof(attr) == SortsBy))
                    if (!getSortableFields!Element.canFind(attr.field))
                        result ~= attr.field;
        return result;
    }();
}

// ============================================================================
// Helper Templates for OrderBy Type Generation
// ============================================================================

/// Get sortable field names from an entity type.
/// A field is sortable if its D result type is ordered (see
/// `dunamis.core.sorting.isOrderedValue`: values comparing with `<`, enum
/// members, and nullable such values) and it takes no required arguments
/// beyond the entity expression.
template getSortableFields(Entity) {
    import std.traits : Parameters;
    import dunamis.core.sorting : isOrderedValue;

    /// Check if a method can be called with just Expr!Entity (no extra required args).
    private template isZeroArgField(alias method) {
        alias Params = Parameters!method;
        static if (Params.length <= 1) {
            enum isZeroArgField = true;
        } else {
            // Check that all params beyond the first have defaults
            alias Defaults = ParameterDefaults!method;
            enum isZeroArgField = () {
                static foreach (i; 1 .. Params.length) {
                    static if (is(Defaults[i] == void))
                        return false;
                }
                return true;
            }();
        }
    }

    enum getSortableFields = () {
        string[] fields;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (!isInternalMember!member) {
                static if (__traits(compiles, __traits(getMember, Entity, member)) &&
                           is(typeof(__traits(getMember, Entity, member)) == function)) {
                    alias method = __traits(getMember, Entity, member);
                    alias ResultT = ExprResultType!(ReturnType!method);
                    // Include if:
                    // - callable with just Expr!Entity (no required extra args)
                    // - public
                    // - its values are ordered (excludes ForeignKey,
                    //   entities, arrays)
                    static if (isZeroArgField!method
                            && __traits(getVisibility, method) == "public"
                            && !isArrayResult!ResultT
                            && isOrderedValue!ResultT) {
                        fields ~= member;
                    }
                }
            }
        }}
        return fields;
    }();
}

/// Array results (lists) are not sortable; strings are scalars, not lists.
private template isArrayResult(T) {
    import std.traits : isSomeString;
    static if (isSomeString!T)
        enum isArrayResult = false;
    else static if (is(T == E[], E))
        enum isArrayResult = true;
    else
        enum isArrayResult = false;
}

// ============================================================================
// Code Template for Sorted Array Fields
// ============================================================================

/// Eponymous code template for SortedArrayField.
/// Builds the mixin string of the sorted method: the source field's method,
/// with the `orderBy` argument of the surface `Surface` (if it has one for
/// the field). All metadata stays encapsulated — no leaks.
template SortedArrayFieldCode(alias Surface, SourceQuery, string fieldName, alias TypeMap) {
    import std.conv : to;
    import dunamis.schema.forward : ForwardFieldImpl;

    private alias Impl = ForwardFieldImpl!(SourceQuery, fieldName, TypeMap);
    private alias _ElementType = ArrayFieldElementType!(Impl.srcFn);

    // .imported references for generated code
    private enum string _I = "dunamis.schema.forward.ForwardFieldImpl!(SourceQuery, \"" ~ fieldName ~ "\", TypeMap)";
    private enum string _Expr = "dunamis.core.expr.Expr";
    private enum string _entityCast = "dunamis.schema.entity_cast.pluginEntityCast";
    // (By the sortable fields of the source's elements: those of this
    // plugin's elements are not known while it is being instantiated.)
    private enum string _sortByFields = "dunamis.core.sorting.sortByFieldsAmong!(" ~
        getSortableFields!_ElementType.stringof ~ ")";
    private enum string _wrap = "dunamis.schema.transform.wrapEntityResult";
    // The field's surface
    private enum string _Surface = "Surface!(SourceQuery, \"" ~ fieldName ~
        "\", dunamis.schema.plugin.ArrayFieldElementType!(" ~ _I ~ ".srcFn))";

    enum SortedArrayFieldCode = () {
        string result = "";

        enum hasArgument = __traits(hasMember, Surface!(SourceQuery, fieldName, _ElementType), "Argument");

        // --- Build parameter list ---
        string paramList = _Expr ~ "!(typeof(this)) " ~ Impl.srcParamNames[0];
        static foreach (i; 1 .. Impl.SrcParams.length) {{
            paramList ~= ", " ~ _I ~ ".SrcParams[" ~ i.to!string ~ "] " ~ Impl.srcParamNames[i];
            static if (!is(Impl.SrcDefaults[i] == void)) {
                paramList ~= " = " ~ _I ~ ".SrcDefaults[" ~ i.to!string ~ "]";
            }
        }}
        static if (hasArgument) {
            paramList ~= ", " ~ _Surface ~ ".Argument orderBy = null";
        }

        // --- Build argument list ---
        string argList = _entityCast ~ "!(" ~ _I ~ ".SrcEntity)(" ~ Impl.srcParamNames[0] ~ ")";
        static foreach (i; 1 .. Impl.SrcParams.length) {
            argList ~= ", " ~ Impl.srcParamNames[i];
        }

        // --- Generate method ---
        // Sorting is applied AFTER wrapEntityResult so SortByExpr wraps the
        // entity-cast MapExpr, keeping it visible to the optimizer unwrapping loop.
        static if (hasArgument) {
            result ~= "@(__traits(getAttributes, " ~ _I ~ ".srcFn)) " ~
                      "static auto " ~ fieldName ~ "(" ~ paramList ~ ") { " ~
                      "return " ~ _sortByFields ~ "(" ~ _wrap ~ "!(TypeMap)(" ~
                      _I ~ ".srcFn(" ~ argList ~ ")), " ~ _Surface ~ ".sortFields(orderBy)); }";
        } else {
            result ~= "@(__traits(getAttributes, " ~ _I ~ ".srcFn)) " ~
                      "static auto " ~ fieldName ~ "(" ~ paramList ~ ") { " ~
                      "return " ~ _wrap ~ "!(TypeMap)(" ~
                      _I ~ ".srcFn(" ~ argList ~ ")); }";
        }

        return result;
    }();
}

/// Mixin template to create a sorted version of an array-returning field,
/// with the orderBy argument surface `Surface` (see `SortingPluginWith`).
/// Zero-leak: delegates to SortedArrayFieldCode eponymous template.
mixin template SortedArrayField(alias Surface, SourceQuery, string fieldName, alias TypeMap) {
    static import dunamis.schema.forward;
    static import dunamis.core.expr;
    static import dunamis.schema.entity_cast;
    // (Not this module: with it, some schemas' types would have forward
    // references.)
    static import dunamis.core.sorting;
    static import dunamis.schema.transform;
    static import dunamis.schema.plugin;
    import dunamis.core.discovery : isObjectType;
    import dunamis.schema.plugin : ArrayFieldElementType, ForwardField;
    import std.typecons : Nullable;
    // No helper declarations: they would leak into the host struct.
    static if (is(ArrayFieldElementType!(__traits(getMember, SourceQuery, fieldName)) == Nullable!U, U))
        mixin ForwardField!(SourceQuery, fieldName, TypeMap);
    else static if (isObjectType!(ArrayFieldElementType!(__traits(getMember, SourceQuery, fieldName))))
        mixin(SortedArrayFieldCode!(Surface, SourceQuery, fieldName, TypeMap));
    else
        mixin ForwardField!(SourceQuery, fieldName, TypeMap);
}
// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.core.expr : constant;
    import std.algorithm : canFind;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");

        // Non-array field - should remain unchanged
        static auto apiVersion(Expr!Query q) {
            return constant("1.0", q);
        }
    }

    alias BaseSchema = Schema!Query;
    alias SortedSchema = SortingPlugin!BaseSchema;

    // Verify it's a valid schema
    static assert(isSchema!SortedSchema);

    // Verify SDL shows sorting arguments on array field
    enum sdl = generateSchemaSDL!SortedSchema;

    // Array field should have orderBy arg
    static assert(sdl.canFind("users("), "users should have arguments: " ~ sdl);
    static assert(sdl.canFind("orderBy:"), "should have orderBy arg: " ~ sdl);

    // Non-array field should remain unchanged
    static assert(sdl.canFind("apiVersion:"), "apiVersion should exist: " ~ sdl);
    static assert(!sdl.canFind("apiVersion("), "apiVersion should not have args: " ~ sdl);
}

unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        package mixin Col!("internalField", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Test that sortable fields are correctly detected
    enum sortableFields = getSortableFields!User;
    static assert(sortableFields.length >= 2, "Should have at least firstName, lastName");

    // Verify non-public fields are not included
    import std.algorithm : canFind;
    static assert(!sortableFields.canFind("internalField"), "Non-public field should not be sortable");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.compiler : compileQuery;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias SortedSchema = SortingPlugin!(Schema!Query);

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Charlie"},
        {"id": 2, "name": "Alice"},
        {"id": 3, "name": "Bob"}
    ]`);

    // Query with sorting by name ASC
    auto query = compileQuery!SortedSchema(`{
        users(orderBy: [{field: name, direction: ASC}]) {
            name
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Should return in alphabetical order: Alice, Bob, Charlie
    assert(result["users"].array.length == 3, "Should have 3 users");
    assert(result["users"][0]["name"].str == "Alice", "First should be Alice");
    assert(result["users"][1]["name"].str == "Bob", "Second should be Bob");
    assert(result["users"][2]["name"].str == "Charlie", "Third should be Charlie");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.compiler : compileQuery;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias SortedSchema = SortingPlugin!(Schema!Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Charlie"},
        {"id": 2, "name": "Alice"},
        {"id": 3, "name": "Bob"}
    ]`);

    // Query with sorting by name DESC
    auto query = compileQuery!SortedSchema(`{
        users(orderBy: [{field: name, direction: DESC}]) {
            name
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Should return in reverse alphabetical order: Charlie, Bob, Alice
    assert(result["users"][0]["name"].str == "Charlie", "First should be Charlie");
    assert(result["users"][1]["name"].str == "Bob", "Second should be Bob");
    assert(result["users"][2]["name"].str == "Alice", "Third should be Alice");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.compiler : compileQuery;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias SortedSchema = SortingPlugin!(Schema!Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Charlie"},
        {"id": 2, "name": "Alice"},
        {"id": 3, "name": "Bob"}
    ]`);

    // Query without orderBy - should return in default (insertion) order
    auto query = compileQuery!SortedSchema(`{
        users {
            name
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Should return all users (order may vary)
    assert(result["users"].array.length == 3, "Should have all 3 users");
}

// Test nested HasMany sorting - SDL should show orderBy args on nested fields
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

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

    alias SortedSchema = SortingPlugin!(Schema!Query);

    // Verify SDL shows sorting arguments on NESTED array fields
    enum sdl = generateSchemaSDL!SortedSchema;

    // Root Query fields should have sorting
    static assert(sdl.canFind("users("), "Query.users should have arguments: " ~ sdl);

    // User.posts (HasMany) should have sorting
    static assert(sdl.canFind("posts(orderBy:"), "User.posts should have orderBy arg: " ~ sdl);
}

// Test nested HasMany sorting - runtime execution
unittest {
    import std.json;
    import std.conv : to;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema, GqlHidden;
    import dunamis.graphql.compiler : compileQuery;

    // Wrap in struct to allow forward references
    struct TestSchema {
        static MockDB!() db;

        @DemoEntity!(db, "posts")
        struct Post {
            mixin DemoId;
            mixin Col!("title", string);
            @GqlHidden mixin Col!("authorId", long, "author_id");
        }

        @DemoEntity!(db, "users")
        struct User {
            mixin DemoId;
            mixin Col!("name", string);
            mixin HasMany!("posts", Post, "author_id");
        }

        struct Query {
            mixin Table!(User, "users");
        }
    }

    alias db = TestSchema.db;
    alias Query = TestSchema.Query;

    alias SortedSchema = SortingPlugin!(Schema!Query);

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "title": "Zebra", "author_id": 1},
        {"id": 2, "title": "Apple", "author_id": 1},
        {"id": 3, "title": "Mango", "author_id": 1}
    ]`);

    // Query with nested sorting: sort posts by title ASC
    auto query = compileQuery!SortedSchema(`{
        users {
            name
            posts(orderBy: [{field: title, direction: ASC}]) {
                title
            }
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    string debugInfo = "Result: " ~ result.to!string;

    // Should have 1 user
    assert(result["users"].array.length == 1, "Should have 1 user. " ~ debugInfo);

    // Posts should be sorted alphabetically
    auto posts = result["users"][0]["posts"].array;
    assert(posts.length == 3, "Should have 3 posts. " ~ debugInfo);
    assert(posts[0]["title"].str == "Apple", "First should be Apple. " ~ debugInfo);
    assert(posts[1]["title"].str == "Mango", "Second should be Mango. " ~ debugInfo);
    assert(posts[2]["title"].str == "Zebra", "Third should be Zebra. " ~ debugInfo);
}

// Test multiple entity types with nested HasMany (User -> Post -> Comment chain)
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    // Wrap in struct to allow forward references between types
    struct TestSchema {
        static MockDB!() db;

        @DemoEntity!(db, "comments")
        struct Comment {
            mixin DemoId;
            mixin Col!("text", string);
        }

        @DemoEntity!(db, "posts")
        struct Post {
            mixin DemoId;
            mixin Col!("title", string);
            mixin HasMany!("comments", Comment, "post_id");
        }

        @DemoEntity!(db, "users")
        struct User {
            mixin DemoId;
            mixin Col!("name", string);
            mixin HasMany!("posts", Post, "author_id");
        }

        struct Query {
            mixin Table!(User, "users");
            mixin Table!(Post, "posts");
        }
    }

    alias Query = TestSchema.Query;

    // This should compile without infinite recursion
    alias SortedSchema = SortingPlugin!(Schema!Query);

    // Verify it's a valid schema
    static assert(isSchema!SortedSchema);

    // Verify SDL is generated correctly
    enum sdl = generateSchemaSDL!SortedSchema;

    // Root fields should have sorting
    static assert(sdl.canFind("users(orderBy:"), "Query.users should have orderBy: " ~ sdl);
    static assert(sdl.canFind("posts(orderBy:"), "Query.posts should have orderBy: " ~ sdl);

    // Nested HasMany should have sorting
    // User.posts and Post.comments
    static assert(sdl.canFind("comments(orderBy:"), "HasMany fields should have orderBy: " ~ sdl);
}

// Test that verifies firstName is correctly converted to first_name SQL column
unittest {
    import std.algorithm : canFind;
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.compiler : compileQuery;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);  // firstName -> first_name in SQL
        mixin Col!("lastName", string);   // lastName -> last_name in SQL
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias SortedSchema = SortingPlugin!(Schema!Query);

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Charlie", "last_name": "Zebra"},
        {"id": 2, "first_name": "Alice", "last_name": "Young"},
        {"id": 3, "first_name": "Bob", "last_name": "Xavier"}
    ]`);

    // Query with sorting by firstName ASC
    auto query = compileQuery!SortedSchema(`{
        users(orderBy: [{field: firstName, direction: ASC}]) {
            firstName
            lastName
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Verify sorting by firstName worked
    assert(result["users"].array.length == 3, "Should have 3 users");
    assert(result["users"][0]["firstName"].str == "Alice", "First by firstName should be Alice");
    assert(result["users"][1]["firstName"].str == "Bob", "Second by firstName should be Bob");
    assert(result["users"][2]["firstName"].str == "Charlie", "Third by firstName should be Charlie");

    // Now test sorting by lastName
    auto query2 = compileQuery!SortedSchema(`{
        users(orderBy: [{field: lastName, direction: DESC}]) {
            firstName
            lastName
        }
    }`);

    auto result2 = awaitSync(new Executor().execute(query2));

    // Verify sorting by lastName DESC worked (Zebra, Young, Xavier)
    assert(result2["users"][0]["lastName"].str == "Zebra", "First by lastName DESC should be Zebra");
    assert(result2["users"][1]["lastName"].str == "Young", "Second by lastName DESC should be Young");
    assert(result2["users"][2]["lastName"].str == "Xavier", "Third by lastName DESC should be Xavier");
}
