/**
 * Integration Tests
 *
 * GraphQL query and mutation tests run against a real database.
 */
module integration.tests;

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
}
