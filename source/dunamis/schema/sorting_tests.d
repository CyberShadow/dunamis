/// Unit tests for SortingPlugin's mechanism (sorting by fields, including
/// nullable and enum ones, as PostgreSQL's ORDER BY orders them) and its
/// argument surfaces (the default one, and an enum surface), in both
/// execution modes: in memory (naive) and with the sorts the data source
/// can do in its queries pushed into them (optimized).
module dunamis.schema.sorting_tests;

version (unittest):

import std.algorithm : canFind;
import std.conv : to;
import std.typecons : Nullable;

import ae.utils.promise.await : awaitSync;

import dunamis.core : Executor;
import dunamis.core.sorting : compareValues, isOrderedValue, SortDirection;
import dunamis.core.types : StoredAs;
import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.schema : Schema, generateSchemaSDL;
import dunamis.relational.demo : MockDB;
import dunamis.relational.schema : Col, Entity, ForeignKeyCol, HasMany, PrimaryKey, Table;
import dunamis.schema.filtering : FilterPlugin;
import dunamis.schema.pagination : PaginationPlugin;
import dunamis.schema.plugin : ApplyPlugins, ArrayFieldElementType, getOriginalTypeName;
import dunamis.schema.sorting;

/// Declared in the order pending, active, done, cancelled; stored under
/// labels whose alphabetical order differs ("z_pending" last).
enum SoStatus {
    @StoredAs("z_pending") pending,
    active,
    @StoredAs("b_done") done,
    @StoredAs("a_cancelled") cancelled,
}

private MockDB!() soDb;

@Entity!(soDb, "so_projects")
private struct SoProject {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin HasMany!("tasks", SoTask, "project_id", ["id"]);
}

@Entity!(soDb, "so_tasks")
private struct SoTask {
    @PrimaryKey int id;
    mixin Col!("title", string);
    mixin Col!("priority", Nullable!int);
    mixin Col!("status", SoStatus);
    mixin Col!("phase", Nullable!SoStatus);
    mixin ForeignKeyCol!("projectId", SoProject);
}

private struct SoQuery {
    mixin Table!(SoProject, "projects", ["id"]);
    mixin Table!(SoTask, "tasks", ["id"]);
}

private alias SoSchema = ApplyPlugins!(Schema!SoQuery, FilterPlugin, SortingPlugin, PaginationPlugin);

/// Tasks (id: priority, status, phase), all of project 1 but task 6 (of 2):
/// 1: 2, done, null; 2: null, pending, active; 3: 1, cancelled, done;
/// 4: null, active, null; 5: 2, pending, pending; 6: 3, active, cancelled.
private void seed() {
    soDb = new MockDB!();
    soDb.setTableData("so_projects", `[{"id": 1, "name": "P1"}, {"id": 2, "name": "P2"}]`);
    soDb.setTableData("so_tasks", `[
        {"id": 1, "title": "t1", "priority": 2, "status": "b_done", "phase": null, "project_id": 1},
        {"id": 2, "title": "t2", "priority": null, "status": "z_pending", "phase": "active", "project_id": 1},
        {"id": 3, "title": "t3", "priority": 1, "status": "a_cancelled", "phase": "b_done", "project_id": 1},
        {"id": 4, "title": "t4", "priority": null, "status": "active", "phase": null, "project_id": 1},
        {"id": 5, "title": "t5", "priority": 2, "status": "z_pending", "phase": "z_pending", "project_id": 1},
        {"id": 6, "title": "t6", "priority": 3, "status": "active", "phase": "a_cancelled", "project_id": 2}
    ]`);
}

/// The IDs of the tasks `query` (a GraphQL query of `S`) lists, at `path`
/// (`tasks`: the root list; `projects.tasks`: the tasks of each project,
/// concatenated), in both execution modes (which must agree).
private long[] taskIds(alias S)(string query, string path = "tasks") {
    long[][2] found;
    foreach (optimize; [false, true]) {
        seed();
        auto result = awaitSync(new Executor().execute(compileQuery!S(query), optimize));
        import std.json : JSONType;
        assert(result.type == JSONType.object && (path == "tasks" ? "tasks" : "projects") in result &&
            result[path == "tasks" ? "tasks" : "projects"].type == JSONType.array,
            query ~ (optimize ? " (optimized)" : " (naive)") ~ ": " ~ result.toString());
        if (path == "tasks") {
            foreach (row; result["tasks"].array)
                found[optimize] ~= row["id"].integer;
        } else {
            foreach (project; result["projects"].array)
                foreach (row; project["tasks"].array)
                    found[optimize] ~= row["id"].integer;
        }
    }
    assert(found[0] == found[1], query ~ ": naive " ~ found[0].to!string ~ " != optimized " ~ found[1].to!string);
    return found[0];
}

// The order of values: nulls last (as the greatest values), enum members in
// declaration order whatever their values or labels.
unittest {
    static assert(isOrderedValue!int && isOrderedValue!(Nullable!int) && isOrderedValue!SoStatus);
    static assert(isOrderedValue!(Nullable!SoStatus) && isOrderedValue!string);
    static assert(!isOrderedValue!SoProject);

    assert(compareValues(1, 2) < 0 && compareValues(2, 1) > 0 && compareValues(2, 2) == 0);
    assert(compareValues(Nullable!int(5), Nullable!int()) < 0);
    assert(compareValues(Nullable!int(), Nullable!int(5)) > 0);
    assert(compareValues(Nullable!int(), Nullable!int()) == 0);
    assert(compareValues(SoStatus.pending, SoStatus.cancelled) < 0);
    assert(compareValues(Nullable!SoStatus(SoStatus.cancelled), Nullable!SoStatus()) < 0);

    enum Backwards { b = 2, a = 1 }  // declared out of value order
    assert(compareValues(Backwards.b, Backwards.a) < 0);
}

private alias SoTaskElement = ArrayFieldElementType!(__traits(getMember, SoSchema.Query, "tasks"));

// Nullable and enum columns are sortable fields
unittest {
    enum fields = getSortableFields!SoTaskElement;
    static assert(fields.canFind("priority") && fields.canFind("status") && fields.canFind("phase"), fields.to!string);
}

// Sorting by a nullable column: NULL last ascending, first descending (as in
// PostgreSQL), at the root and in a relationship
unittest {
    foreach (path, query; ["tasks": `{ tasks(orderBy: [{field: priority, direction: %s}]) { id } }`,
            "projects.tasks": `{ projects { tasks(orderBy: [{field: priority, direction: %s}]) { id } } }`]) {
        import std.format : format;
        auto asc = taskIds!SoSchema(format(query, "ASC"), path);
        auto desc = taskIds!SoSchema(format(query, "DESC"), path);
        if (path == "tasks") {
            assert(asc == [3, 1, 5, 6, 2, 4], asc.to!string);
            assert(desc == [2, 4, 6, 1, 5, 3], desc.to!string);
        } else {
            assert(asc == [3, 1, 5, 2, 4, 6], asc.to!string);
            assert(desc == [2, 4, 1, 5, 3, 6], desc.to!string);
        }
    }
}

// Sorting by an enum column: in declaration order, not by stored label
unittest {
    assert(taskIds!SoSchema(`{ tasks(orderBy: [{field: status, direction: ASC}]) { id } }`) == [2, 5, 4, 6, 1, 3]);
    assert(taskIds!SoSchema(`{ tasks(orderBy: [{field: status, direction: DESC}]) { id } }`) == [3, 1, 4, 6, 2, 5]);
    // A nullable enum column
    assert(taskIds!SoSchema(`{ tasks(orderBy: [{field: phase, direction: ASC}]) { id } }`) == [5, 2, 3, 6, 1, 4]);
    assert(taskIds!SoSchema(`{ tasks(orderBy: [{field: phase, direction: DESC}]) { id } }`) == [1, 4, 6, 3, 2, 5]);
    // Several keys, with a window
    assert(taskIds!SoSchema(`{ tasks(orderBy: [{field: status, direction: ASC}, {field: priority, direction: DESC}], ` ~
        `first: 4) { id } }`) == [2, 5, 4, 6]);
    assert(taskIds!SoSchema(`{ projects { tasks(orderBy: [{field: status, direction: DESC}]) { id } } }`,
        "projects.tasks") == [3, 1, 4, 2, 5, 6]);
}

/// An enum argument surface: members sorting by fields (`@SortsBy`), and
/// one keeping the list's order.
enum SoTasksOrderBy {
    NATURAL,
    @SortsBy("id") ID_ASC,
    @SortsBy("id", SortDirection.DESC) ID_DESC,
    @SortsBy("priority") PRIORITY_ASC,
    @SortsBy("priority", SortDirection.DESC) PRIORITY_DESC,
    @SortsBy("status") STATUS_ASC,
    @SortsBy("status", SortDirection.DESC) STATUS_DESC,
}

/// Lists of tasks are sorted by `SoTasksOrderBy`, others as by default.
template SoSurface(Scope, string fieldName, Element) {
    static if (getOriginalTypeName!Element == "SoTask")
        alias SoSurface = EnumSortSurface!SoTasksOrderBy;
    else
        alias SoSurface = DefaultSortSurface!(Scope, fieldName, Element);
}

private alias SoEnumSchema = ApplyPlugins!(Schema!SoQuery, FilterPlugin, SortingPluginWith!SoSurface, PaginationPlugin);

unittest {
    enum sdl = generateSchemaSDL!SoEnumSchema;
    static assert(sdl.canFind("orderBy: [SoTasksOrderBy!] = []"), sdl);
    static assert(sdl.canFind("enum SoTasksOrderBy {\n  NATURAL\n  ID_ASC\n"), sdl);
    static assert(sdl.canFind("orderBy: [_OrderByStruct_Query_projects!]"), sdl);
    static assert(!sdl.canFind("_OrderByStruct_Query_tasks") && !sdl.canFind("_OrderByStruct_SoProject_tasks"), sdl);
    // (The default surface's types are named as before)
    enum defaultSdl = generateSchemaSDL!SoSchema;
    static assert(defaultSdl.canFind("input _OrderByStruct_Query_tasks {\n  field: _OrderByFieldEnum_Query_tasks!\n"),
        defaultSdl);
    static assert(defaultSdl.canFind("enum _OrderByFieldEnum_Query_tasks {"), defaultSdl);
    static assert(defaultSdl.canFind("orderBy: [_OrderByStruct_SoProject_tasks!]"), defaultSdl);

    static assert(unsortableSortsByFields!(SoTasksOrderBy, SoTaskElement).length == 0);
    enum Bad { @SortsBy("title") A, @SortsBy("projectIdx") B }
    static assert(unsortableSortsByFields!(Bad, SoTaskElement) == ["projectIdx"]);

    assert(sortFieldsOf([SoTasksOrderBy.NATURAL, SoTasksOrderBy.STATUS_DESC, SoTasksOrderBy.ID_ASC]) ==
        [SortField("status", SortDirection.DESC), SortField("id", SortDirection.ASC)]);

    assert(taskIds!SoEnumSchema(`{ tasks(orderBy: [STATUS_ASC, PRIORITY_DESC], first: 4) { id } }`) == [2, 5, 4, 6]);
    assert(taskIds!SoEnumSchema(`{ tasks(orderBy: [PRIORITY_DESC]) { id } }`) == [2, 4, 6, 1, 5, 3]);
    // NATURAL: the list's own order
    assert(taskIds!SoEnumSchema(`{ tasks(orderBy: [NATURAL]) { id } }`) == [1, 2, 3, 4, 5, 6]);
    assert(taskIds!SoEnumSchema(`{ tasks(orderBy: [NATURAL, ID_DESC]) { id } }`) == [6, 5, 4, 3, 2, 1]);
    assert(taskIds!SoEnumSchema(`{ projects(orderBy: [{field: id, direction: DESC}]) { tasks(orderBy: [STATUS_ASC]) { id } } }`,
        "projects.tasks") == [6, 2, 5, 4, 1, 3]);
}

// Sorting by a field which is not a sortable one is an error
unittest {
    import std.exception : assertThrown;
    seed();
    static SortField[] fields = [SortField("noSuchField")];
    import dunamis.core.expr : singleton;
    assertThrown(sortByFields(SoSchema.Query.tasks(singleton(SoSchema.Query.init)), fields));
}
