/**
 * Integration Tests
 *
 * GraphQL query and mutation tests run against a real database.
 */
module integration.tests;

import std.conv : to;
import std.json : JSONType, JSONValue;
import integration.test_framework;

// ============================================================================
// Query Tests
// ============================================================================

void testQueryAllUsers() {
    auto response = graphql(`{ users { firstName lastName } }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;

    assertTrue(users.length >= 2, "Expected at least 2 users");

    // Check that Alice exists
    bool foundAlice = false;
    foreach (user; users) {
        if (user["firstName"].str == "Alice" && user["lastName"].str == "Smith") {
            foundAlice = true;
            break;
        }
    }
    assertTrue(foundAlice, "Expected to find Alice Smith");
}

void testQueryUserWithPosts() {
    auto response = graphql(`{
        users {
            firstName
            posts { title }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length > 0, "Expected at least 1 user");

    // Find Alice and check her posts
    foreach (user; users) {
        if (user["firstName"].str == "Alice") {
            auto posts = user["posts"].array;
            assertTrue(posts.length >= 1, "Alice should have at least 1 post");
            return;
        }
    }
    assertTrue(false, "Alice not found");
}

void testQueryPostWithAuthor() {
    auto response = graphql(`{
        posts {
            title
            author { firstName lastName }
        }
    }`);

    assertNoErrors(response);
    auto posts = response["data"]["posts"].array;
    assertTrue(posts.length > 0, "Expected at least 1 post");

    // Check that posts have authors
    foreach (post; posts) {
        assertNotNull(post["author"], "Post should have an author");
        assertTrue(("firstName" in post["author"]) !is null, "Author should have firstName");
    }
}

void testQueryComputedField() {
    auto response = graphql(`{ users { fullName } }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length > 0, "Expected at least 1 user");

    // Find Alice's full name
    foreach (user; users) {
        if (user["fullName"].str == "Alice Smith") {
            return; // Found it
        }
    }
    assertTrue(false, "Expected to find user with fullName 'Alice Smith'");
}

// ============================================================================
// Mutation Tests
// ============================================================================

void testCreateUser() {
    auto response = graphql(`
        mutation {
            createUserWithName(firstName: "Test", lastName: "User") {
                firstName
                lastName
            }
        }
    `);

    assertNoErrors(response);
    auto user = response["data"]["createUserWithName"];
    assertTrue(user["firstName"].str == "Test", "Expected firstName to be 'Test'");
    assertTrue(user["lastName"].str == "User", "Expected lastName to be 'User'");
}

void testMutationPersistence() {
    // Create a unique user
    auto createResponse = graphql(`
        mutation {
            createUserWithName(firstName: "Persist", lastName: "Test") {
                id
                firstName
            }
        }
    `);
    assertNoErrors(createResponse);

    // Query to verify it was persisted
    auto queryResponse = graphql(`{ users { firstName lastName } }`);
    assertNoErrors(queryResponse);

    auto users = queryResponse["data"]["users"].array;
    bool found = false;
    foreach (user; users) {
        if (user["firstName"].str == "Persist" && user["lastName"].str == "Test") {
            found = true;
            break;
        }
    }
    assertTrue(found, "Created user should be queryable");
}

// ============================================================================
// Enum Tests
// ============================================================================

void testQueryTasksWithEnumStatus() {
    auto response = graphql(`{
        tasks {
            title
            status
        }
    }`);

    assertNoErrors(response);
    auto tasks = response["data"]["tasks"].array;
    assertTrue(tasks.length >= 3, "Expected at least 3 tasks");

    // Check that status values are returned as enum strings
    bool foundPending = false;
    bool foundInProgress = false;
    bool foundCompleted = false;

    foreach (task; tasks) {
        auto status = task["status"].str;
        if (status == "pending") foundPending = true;
        if (status == "inProgress") foundInProgress = true;
        if (status == "completed") foundCompleted = true;
    }

    assertTrue(foundPending, "Expected to find task with status 'pending'");
    assertTrue(foundInProgress, "Expected to find task with status 'inProgress'");
    assertTrue(foundCompleted, "Expected to find task with status 'completed'");
}

void testQueryTaskFields() {
    auto response = graphql(`{
        tasks {
            title
            status
        }
    }`);

    assertNoErrors(response);
    auto tasks = response["data"]["tasks"].array;
    assertTrue(tasks.length > 0, "Expected at least 1 task");

    // Check that each task has title and status
    foreach (task; tasks) {
        assertTrue(("title" in task) !is null, "Task should have title");
        assertTrue(("status" in task) !is null, "Task should have status");
        // Verify status is a valid enum value
        auto status = task["status"].str;
        assertTrue(
            status == "pending" || status == "inProgress" ||
            status == "completed" || status == "cancelled",
            "Status should be a valid enum value, got: " ~ status
        );
    }
}

void testQueryTaskWithNullableAssignee() {
    auto response = graphql(`{
        tasks {
            title
            status
            assignee {
                firstName
                lastName
            }
        }
    }`);

    assertNoErrors(response);
    auto tasks = response["data"]["tasks"].array;
    assertTrue(tasks.length > 0, "Expected at least 1 task");

    // Check that tasks have assignees (nullable relationship)
    bool foundWithAssignee = false;
    foreach (task; tasks) {
        if (task["assignee"].type != JSONType.null_) {
            foundWithAssignee = true;
            assertTrue(("firstName" in task["assignee"]) !is null, "Assignee should have firstName");
            assertTrue(("lastName" in task["assignee"]) !is null, "Assignee should have lastName");
        }
    }
    assertTrue(foundWithAssignee, "Expected at least one task with an assignee");
}

void testCreateTaskWithEnumStatus() {
    auto response = graphql(`
        mutation {
            createTask(input: {title: "New Task", status: "cancelled"}) {
                title
                status
            }
        }
    `);

    assertNoErrors(response);
    auto task = response["data"]["createTask"];
    assertTrue(task["title"].str == "New Task", "Expected title to be 'New Task'");
    assertTrue(task["status"].str == "cancelled", "Expected status to be 'cancelled'");
}

void testEnumPersistence() {
    // Create a task with specific status
    auto createResponse = graphql(`
        mutation {
            createTask(input: {title: "Persisted Task", status: "inProgress"}) {
                id
                title
                status
            }
        }
    `);
    assertNoErrors(createResponse);
    assertTrue(createResponse["data"]["createTask"]["status"].str == "inProgress",
        "Created task should have status 'inProgress'");

    // Query to verify the enum was persisted correctly
    auto queryResponse = graphql(`{ tasks { title status } }`);
    assertNoErrors(queryResponse);

    auto tasks = queryResponse["data"]["tasks"].array;
    bool found = false;
    foreach (task; tasks) {
        if (task["title"].str == "Persisted Task") {
            assertTrue(task["status"].str == "inProgress",
                "Persisted task should have status 'inProgress'");
            found = true;
            break;
        }
    }
    assertTrue(found, "Created task should be queryable");
}

// ============================================================================
// Sorting Tests
// ============================================================================

void testSortUsersAscending() {
    auto response = graphql(`{
        users(orderBy: [{field: firstName, direction: ASC}]) {
            firstName
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 2, "Expected at least 2 users");

    // Verify ascending order
    for (size_t i = 1; i < users.length; i++) {
        auto prev = users[i - 1]["firstName"].str;
        auto curr = users[i]["firstName"].str;
        assertTrue(prev <= curr, "Users should be sorted by firstName ascending");
    }
}

void testSortUsersDescending() {
    auto response = graphql(`{
        users(orderBy: [{field: firstName, direction: DESC}]) {
            firstName
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 2, "Expected at least 2 users");

    // Verify descending order
    for (size_t i = 1; i < users.length; i++) {
        auto prev = users[i - 1]["firstName"].str;
        auto curr = users[i]["firstName"].str;
        assertTrue(prev >= curr, "Users should be sorted by firstName descending");
    }
}

void testSortPostsByTitle() {
    auto response = graphql(`{
        posts(orderBy: [{field: title, direction: ASC}]) {
            title
        }
    }`);

    assertNoErrors(response);
    auto posts = response["data"]["posts"].array;
    assertTrue(posts.length >= 2, "Expected at least 2 posts");

    // Verify ascending order by title
    for (size_t i = 1; i < posts.length; i++) {
        auto prev = posts[i - 1]["title"].str;
        auto curr = posts[i]["title"].str;
        assertTrue(prev <= curr, "Posts should be sorted by title ascending");
    }
}

void testSortTasksByStatus() {
    auto response = graphql(`{
        tasks(orderBy: [{field: status, direction: ASC}]) {
            title
            status
        }
    }`);

    assertNoErrors(response);
    auto tasks = response["data"]["tasks"].array;
    assertTrue(tasks.length >= 2, "Expected at least 2 tasks");

    // Verify ascending order by status (enum values)
    for (size_t i = 1; i < tasks.length; i++) {
        auto prev = tasks[i - 1]["status"].str;
        auto curr = tasks[i]["status"].str;
        assertTrue(prev <= curr, "Tasks should be sorted by status ascending");
    }
}

void testSortWithoutOrderBy() {
    // Verify that queries without orderBy still work
    auto response = graphql(`{
        users {
            firstName
            lastName
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 2, "Expected at least 2 users");
}

// ============================================================================
// Nested Sorting Tests (HasMany relationships)
// ============================================================================

void testNestedSortPostsByTitleAscending() {
    // Test sorting posts within a user (HasMany relationship)
    auto response = graphql(`{
        users {
            firstName
            posts(orderBy: [{field: title, direction: ASC}]) {
                title
            }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Find a user with posts and verify they're sorted
    foreach (user; users) {
        auto posts = user["posts"].array;
        if (posts.length >= 2) {
            // Verify ascending order by title
            for (size_t i = 1; i < posts.length; i++) {
                auto prev = posts[i - 1]["title"].str;
                auto curr = posts[i]["title"].str;
                assertTrue(prev <= curr,
                    "Posts should be sorted by title ascending for user " ~ user["firstName"].str);
            }
            return; // Found a user with sortable posts
        }
    }
    // It's OK if no user has multiple posts
}

void testNestedSortPostsByTitleDescending() {
    // Test sorting posts in descending order within a user
    auto response = graphql(`{
        users {
            firstName
            posts(orderBy: [{field: title, direction: DESC}]) {
                title
            }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Find a user with posts and verify they're sorted descending
    foreach (user; users) {
        auto posts = user["posts"].array;
        if (posts.length >= 2) {
            // Verify descending order by title
            for (size_t i = 1; i < posts.length; i++) {
                auto prev = posts[i - 1]["title"].str;
                auto curr = posts[i]["title"].str;
                assertTrue(prev >= curr,
                    "Posts should be sorted by title descending for user " ~ user["firstName"].str);
            }
            return; // Found a user with sortable posts
        }
    }
}

void testNestedSortWithoutOrderBy() {
    // Verify that nested queries without orderBy still work
    auto response = graphql(`{
        users {
            firstName
            posts {
                title
            }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Just verify the query works and posts are returned
    foreach (user; users) {
        // posts should be an array (even if empty)
        assertTrue(user["posts"].type == JSONType.array, "posts should be an array");
    }
}

void testNestedSortCombinedWithRootSort() {
    // Test sorting at both root and nested levels
    auto response = graphql(`{
        users(orderBy: [{field: firstName, direction: ASC}]) {
            firstName
            posts(orderBy: [{field: title, direction: DESC}]) {
                title
            }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 2, "Expected at least 2 users");

    // Verify root users are sorted ascending by firstName
    for (size_t i = 1; i < users.length; i++) {
        auto prev = users[i - 1]["firstName"].str;
        auto curr = users[i]["firstName"].str;
        assertTrue(prev <= curr, "Users should be sorted by firstName ascending");
    }

    // Verify nested posts are sorted descending by title (if any user has multiple posts)
    foreach (user; users) {
        auto posts = user["posts"].array;
        if (posts.length >= 2) {
            for (size_t i = 1; i < posts.length; i++) {
                auto prev = posts[i - 1]["title"].str;
                auto curr = posts[i]["title"].str;
                assertTrue(prev >= curr,
                    "Posts should be sorted by title descending for user " ~ user["firstName"].str);
            }
        }
    }
}

void testNestedSortDeepNesting() {
    // Test sorting at multiple nested levels (posts -> author relationship exists)
    auto response = graphql(`{
        posts(orderBy: [{field: title, direction: ASC}]) {
            title
            author {
                firstName
                posts(orderBy: [{field: title, direction: DESC}]) {
                    title
                }
            }
        }
    }`);

    assertNoErrors(response);
    auto posts = response["data"]["posts"].array;
    assertTrue(posts.length >= 1, "Expected at least 1 post");

    // Verify root posts are sorted ascending
    for (size_t i = 1; i < posts.length; i++) {
        auto prev = posts[i - 1]["title"].str;
        auto curr = posts[i]["title"].str;
        assertTrue(prev <= curr, "Root posts should be sorted by title ascending");
    }
}

// ============================================================================
// Logic Expression Tests (Boolean operators, NOT, Ternary)
// ============================================================================

void testQueryIsAdultField() {
    auto response = graphql(`{
        users {
            firstName
            age
            isAdult
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 3, "Expected at least 3 users for age testing");

    // Verify isAdult logic: age >= 18
    foreach (user; users) {
        auto age = user["age"].integer;
        auto isAdult = user["isAdult"].boolean;
        auto name = user["firstName"].str;

        bool expectedAdult = age >= 18;
        assertTrue(isAdult == expectedAdult,
            "isAdult for " ~ name ~ " (age=" ~ user["age"].toString() ~ ") should be " ~
            (expectedAdult ? "true" : "false") ~ " but got " ~ (isAdult ? "true" : "false"));
    }
}

void testQueryIsTeenagerField() {
    auto response = graphql(`{
        users {
            firstName
            age
            isTeenager
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 3, "Expected at least 3 users for age testing");

    // Verify isTeenager logic: age >= 13 AND age < 20
    foreach (user; users) {
        auto age = user["age"].integer;
        auto isTeenager = user["isTeenager"].boolean;
        auto name = user["firstName"].str;

        bool expectedTeenager = age >= 13 && age < 20;
        assertTrue(isTeenager == expectedTeenager,
            "isTeenager for " ~ name ~ " (age=" ~ user["age"].toString() ~ ") should be " ~
            (expectedTeenager ? "true" : "false") ~ " but got " ~ (isTeenager ? "true" : "false"));
    }
}

void testQueryAgeCategoryField() {
    auto response = graphql(`{
        users {
            firstName
            age
            ageCategory
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 3, "Expected at least 3 users for age testing");

    // Verify ageCategory logic: age < 13 -> "child", age < 20 -> "teen", else "adult"
    foreach (user; users) {
        auto age = user["age"].integer;
        auto category = user["ageCategory"].str;
        auto name = user["firstName"].str;

        string expectedCategory;
        if (age < 13) expectedCategory = "child";
        else if (age < 20) expectedCategory = "teen";
        else expectedCategory = "adult";

        assertTrue(category == expectedCategory,
            "ageCategory for " ~ name ~ " (age=" ~ user["age"].toString() ~ ") should be '" ~
            expectedCategory ~ "' but got '" ~ category ~ "'");
    }
}

void testQueryCombinedLogicFields() {
    // Test that all logic fields work together in one query
    auto response = graphql(`{
        users {
            firstName
            age
            isAdult
            isTeenager
            ageCategory
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Just verify the fields are present and have correct types
    foreach (user; users) {
        assertTrue(("firstName" in user) !is null, "User should have firstName");
        assertTrue(("age" in user) !is null, "User should have age");
        assertTrue(("isAdult" in user) !is null, "User should have isAdult");
        assertTrue(("isTeenager" in user) !is null, "User should have isTeenager");
        assertTrue(("ageCategory" in user) !is null, "User should have ageCategory");

        // Verify types
        assertTrue(user["age"].type == JSONType.integer, "age should be integer");
        assertTrue(user["isAdult"].type == JSONType.true_ || user["isAdult"].type == JSONType.false_,
            "isAdult should be boolean");
        assertTrue(user["isTeenager"].type == JSONType.true_ || user["isTeenager"].type == JSONType.false_,
            "isTeenager should be boolean");
        assertTrue(user["ageCategory"].type == JSONType.string, "ageCategory should be string");
    }
}

// ============================================================================
// Transitive Field Access Tests (Pushdown through BelongsTo)
// ============================================================================

void testQueryAuthorIsAdultField() {
    auto response = graphql(`{
        posts {
            title
            authorIsAdult
            author { firstName age }
        }
    }`);

    assertNoErrors(response);
    auto posts = response["data"]["posts"].array;
    assertTrue(posts.length >= 3, "Expected at least 3 posts");

    // Verify authorIsAdult matches author's age >= 18
    foreach (post; posts) {
        auto authorAge = post["author"]["age"].integer;
        auto authorIsAdult = post["authorIsAdult"].boolean;
        auto title = post["title"].str;

        bool expectedAdult = authorAge >= 18;
        assertTrue(authorIsAdult == expectedAdult,
            "authorIsAdult for post '" ~ title ~ "' (author age=" ~ post["author"]["age"].toString() ~
            ") should be " ~ (expectedAdult ? "true" : "false") ~ " but got " ~ (authorIsAdult ? "true" : "false"));
    }
}

void testQueryAuthorAgeCategoryField() {
    auto response = graphql(`{
        posts {
            title
            authorAgeCategory
            author { firstName age }
        }
    }`);

    assertNoErrors(response);
    auto posts = response["data"]["posts"].array;
    assertTrue(posts.length >= 3, "Expected at least 3 posts");

    // Verify authorAgeCategory matches: age < 13 -> "child", age < 20 -> "teen", else "adult"
    foreach (post; posts) {
        auto authorAge = post["author"]["age"].integer;
        auto category = post["authorAgeCategory"].str;
        auto title = post["title"].str;

        string expectedCategory;
        if (authorAge < 13) expectedCategory = "child";
        else if (authorAge < 20) expectedCategory = "teen";
        else expectedCategory = "adult";

        assertTrue(category == expectedCategory,
            "authorAgeCategory for post '" ~ title ~ "' (author age=" ~ post["author"]["age"].toString() ~
            ") should be '" ~ expectedCategory ~ "' but got '" ~ category ~ "'");
    }
}

void testQueryTransitiveFieldsCombined() {
    // Test querying multiple transitive fields in one query
    auto response = graphql(`{
        posts {
            title
            authorIsAdult
            authorAgeCategory
            author {
                firstName
                age
                isAdult
                ageCategory
            }
        }
    }`);

    assertNoErrors(response);
    auto posts = response["data"]["posts"].array;
    assertTrue(posts.length >= 1, "Expected at least 1 post");

    // Verify transitive fields match author's direct fields
    foreach (post; posts) {
        auto authorIsAdultDirect = post["author"]["isAdult"].boolean;
        auto authorIsAdultTransitive = post["authorIsAdult"].boolean;
        assertTrue(authorIsAdultDirect == authorIsAdultTransitive,
            "authorIsAdult should match author.isAdult");

        auto authorAgeCategoryDirect = post["author"]["ageCategory"].str;
        auto authorAgeCategoryTransitive = post["authorAgeCategory"].str;
        assertTrue(authorAgeCategoryDirect == authorAgeCategoryTransitive,
            "authorAgeCategory should match author.ageCategory");
    }
}

// ============================================================================
// Null Check Tests (isNull/isNotNull)
// ============================================================================

void testQueryIsNullField() {
    auto response = graphql(`{
        tasks {
            title
            isUnassigned
            isAssigned
            assignee { firstName }
        }
    }`);

    assertNoErrors(response);
    auto tasks = response["data"]["tasks"].array;
    assertTrue(tasks.length >= 3, "Expected at least 3 tasks");

    foreach (task; tasks) {
        bool isUnassigned = task["isUnassigned"].boolean;
        bool isAssigned = task["isAssigned"].boolean;
        bool hasAssignee = task["assignee"].type != JSONType.null_;

        assertTrue(isUnassigned == !hasAssignee,
            "isUnassigned should be true iff assignee is null");
        assertTrue(isAssigned == hasAssignee,
            "isAssigned should be true iff assignee is not null");
        assertTrue(isUnassigned != isAssigned,
            "isUnassigned and isAssigned should be opposites");
    }
}

// ============================================================================
// Collection Predicate Tests (some/every)
// ============================================================================

void testQueryHasPostsField() {
    auto response = graphql(`{
        users {
            firstName
            hasPosts
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 3, "Expected at least 3 users");

    // Check hasPosts for each user
    // Alice and Bob have posts, Charlie does not
    foreach (user; users) {
        auto name = user["firstName"].str;
        auto hasPosts = user["hasPosts"].boolean;

        if (name == "Alice" || name == "Bob") {
            assertTrue(hasPosts, name ~ " should have posts");
        } else if (name == "Charlie") {
            assertTrue(!hasPosts, "Charlie should not have posts");
        }
    }
}

void testQueryAllPostsTitledField() {
    auto response = graphql(`{
        users {
            firstName
            allPostsTitled
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 3, "Expected at least 3 users");

    // All seeded posts have titles, and every() on empty collection is vacuous truth
    foreach (user; users) {
        auto name = user["firstName"].str;
        auto allTitled = user["allPostsTitled"].boolean;
        assertTrue(allTitled, name ~ " should have allPostsTitled=true");
    }
}

void testQuerySomeEveryWithPostDetails() {
    // Test that some/every work alongside regular post queries
    auto response = graphql(`{
        users {
            firstName
            hasPosts
            allPostsTitled
            posts {
                title
            }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 3, "Expected at least 3 users");

    // Verify consistency between hasPosts and actual posts array
    foreach (user; users) {
        auto name = user["firstName"].str;
        auto hasPosts = user["hasPosts"].boolean;
        auto posts = user["posts"].array;

        bool actuallyHasPosts = posts.length > 0;
        assertTrue(hasPosts == actuallyHasPosts,
            name ~ ": hasPosts=" ~ (hasPosts ? "true" : "false") ~
            " but posts.length=" ~ posts.length.to!string);
    }
}

// ============================================================================
// Recursive Input Type Tests
// ============================================================================

void testRecursiveFilterInput() {
    // Test with simple nested filter (and: [{field: "name", equals: "Alice"}])
    auto response = graphql(`{
        users {
            matchesFilter(filter: {
                field: "name",
                equals: "Alice",
                and: [{field: "age", equals: "25", and: [], or: []}],
                or: []
            })
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");
    // matchesFilter just returns firstName, so verify we got results
    assertTrue(users[0]["matchesFilter"].type == JSONType.string, "matchesFilter should return string");
}

void testDeepNestedFilterInput() {
    // Test 3-level nesting
    auto response = graphql(`{
        users {
            matchesFilter(filter: {
                and: [{
                    or: [{field: "a", and: [], or: []}, {field: "b", and: [], or: []}],
                    and: []
                }],
                or: []
            })
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");
}

void testPointerInputNull() {
    // Test null pointer input
    auto response = graphql(`{
        users {
            traverseList(head: null)
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");
    assertTrue(users[0]["traverseList"].type == JSONType.string, "traverseList should return string");
}

void testPointerInputWithValue() {
    // Test pointer with nested value (linked list)
    auto response = graphql(`{
        users {
            traverseList(head: {value: "first", next: {value: "second", next: null}})
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");
    assertTrue(users[0]["traverseList"].type == JSONType.string, "traverseList should return string");
}

void testEmptyRecursiveArrays() {
    // Test with empty recursive arrays
    auto response = graphql(`{
        users {
            matchesFilter(filter: {field: "name", and: [], or: []})
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");
}

// ============================================================================
// Test Registration
// ============================================================================

static this() {
    // Register all tests
    registerTest("Query all users", "tests", &testQueryAllUsers);
    registerTest("Query users with posts (HasMany)", "tests", &testQueryUserWithPosts);
    registerTest("Query posts with author (BelongsTo)", "tests", &testQueryPostWithAuthor);
    registerTest("Query computed field (fullName)", "tests", &testQueryComputedField);
    registerTest("Mutation: create user", "tests", &testCreateUser);
    registerTest("Mutation persistence", "tests", &testMutationPersistence);

    // Enum tests
    registerTest("Query tasks with enum status", "tests", &testQueryTasksWithEnumStatus);
    registerTest("Query task fields", "tests", &testQueryTaskFields);
    registerTest("Query task with nullable assignee", "tests", &testQueryTaskWithNullableAssignee);
    registerTest("Mutation: create task with enum", "tests", &testCreateTaskWithEnumStatus);
    registerTest("Enum persistence", "tests", &testEnumPersistence);

    // Sorting tests
    registerTest("Sort users ascending", "tests", &testSortUsersAscending);
    registerTest("Sort users descending", "tests", &testSortUsersDescending);
    registerTest("Sort posts by title", "tests", &testSortPostsByTitle);
    registerTest("Sort tasks by status", "tests", &testSortTasksByStatus);
    registerTest("Sort without orderBy", "tests", &testSortWithoutOrderBy);

    // Nested sorting tests (HasMany relationships)
    registerTest("Nested sort posts ascending", "tests", &testNestedSortPostsByTitleAscending);
    registerTest("Nested sort posts descending", "tests", &testNestedSortPostsByTitleDescending);
    registerTest("Nested sort without orderBy", "tests", &testNestedSortWithoutOrderBy);
    registerTest("Nested sort combined with root", "tests", &testNestedSortCombinedWithRootSort);
    registerTest("Nested sort deep nesting", "tests", &testNestedSortDeepNesting);

    // Logic expression tests (Boolean AND/OR, NOT, Ternary)
    registerTest("Query isAdult computed field (comparison)", "tests", &testQueryIsAdultField);
    registerTest("Query isTeenager computed field (AND)", "tests", &testQueryIsTeenagerField);
    registerTest("Query ageCategory computed field (ternary)", "tests", &testQueryAgeCategoryField);
    registerTest("Query combined logic fields", "tests", &testQueryCombinedLogicFields);

    // Transitive field access tests (pushdown through BelongsTo)
    registerTest("Query authorIsAdult (transitive comparison)", "tests", &testQueryAuthorIsAdultField);
    registerTest("Query authorAgeCategory (transitive ternary)", "tests", &testQueryAuthorAgeCategoryField);
    registerTest("Query transitive fields combined", "tests", &testQueryTransitiveFieldsCombined);

    // Null check tests (isNull/isNotNull)
    registerTest("Query isNull/isNotNull fields", "tests", &testQueryIsNullField);

    // Collection predicate tests (some/every)
    registerTest("Query hasPosts (some)", "tests", &testQueryHasPostsField);
    registerTest("Query allPostsTitled (every)", "tests", &testQueryAllPostsTitledField);
    registerTest("Query some/every with post details", "tests", &testQuerySomeEveryWithPostDetails);

    // Recursive input type tests
    registerTest("Recursive filter input", "tests", &testRecursiveFilterInput);
    registerTest("Deep nested filter input", "tests", &testDeepNestedFilterInput);
    registerTest("Pointer input null", "tests", &testPointerInputNull);
    registerTest("Pointer input with value", "tests", &testPointerInputWithValue);
    registerTest("Empty recursive arrays", "tests", &testEmptyRecursiveArrays);
}
