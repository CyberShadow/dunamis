/**
 * Integration Tests
 *
 * GraphQL query and mutation tests run against a real database.
 */
module integration.tests;

import std.conv : to;
import std.json : JSONType, JSONValue;
import integration.test_framework;

/// Return a mode-dependent suffix to avoid UNIQUE constraint failures
/// when mutation tests run in both optimized and naive modes.
private string modeSuffix() {
    return currentOptimizeMode ? "opt" : "naive";
}

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
            createTask(input: {title: "New Task", status: cancelled}) {
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
            createTask(input: {title: "Persisted Task", status: inProgress}) {
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

void testSortTasksByTitle() {
    auto response = graphql(`{
        tasks(orderBy: [{field: title, direction: ASC}]) {
            title
        }
    }`);

    assertNoErrors(response);
    auto tasks = response["data"]["tasks"].array;
    assertTrue(tasks.length >= 2, "Expected at least 2 tasks");

    // Verify ascending order by title
    for (size_t i = 1; i < tasks.length; i++) {
        auto prev = tasks[i - 1]["title"].str;
        auto curr = tasks[i]["title"].str;
        assertTrue(prev <= curr, "Tasks should be sorted by title ascending");
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
// Eager Field Tests
// ============================================================================

void testQueryEagerField() {
    // Test that eager fields (struct instance fields with @EagerField) are populated
    auto response = graphql(`{
        users {
            firstName
            nickname
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Find Alice and check her nickname (set to "Ally" in seed data)
    foreach (user; users) {
        if (user["firstName"].str == "Alice") {
            assertTrue(user["nickname"].str == "Ally",
                "Alice's nickname should be 'Ally', got: " ~ user["nickname"].str);
            return;
        }
    }
    assertTrue(false, "Alice not found");
}

void testQueryEagerFieldWithComputedField() {
    // Test that eager fields work alongside computed fields
    auto response = graphql(`{
        users {
            fullName
            nickname
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Find Alice and verify both fields
    foreach (user; users) {
        if (user["fullName"].str == "Alice Smith") {
            assertTrue(user["nickname"].str == "Ally",
                "Alice's nickname should be 'Ally'");
            return;
        }
    }
    assertTrue(false, "Alice not found");
}

// ============================================================================
// Plain Method Tests
// ============================================================================

void testQueryPlainMethod() {
    // Test that plain methods (instance methods) work in queries
    auto response = graphql(`{
        users {
            firstName
            displayName
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Find Alice and check her displayName (should be "Ally" from nickname)
    foreach (user; users) {
        if (user["firstName"].str == "Alice") {
            assertTrue(user["displayName"].str == "Ally",
                "Alice's displayName should be 'Ally', got: " ~ user["displayName"].str);
            return;
        }
    }
    assertTrue(false, "Alice not found");
}

void testQueryPlainMethodWithComputedField() {
    // Test that plain methods work alongside computed fields
    auto response = graphql(`{
        users {
            fullName
            displayName
            hasNickname
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Find Alice - has nickname, so hasNickname=true
    foreach (user; users) {
        if (user["fullName"].str == "Alice Smith") {
            assertTrue(user["hasNickname"].boolean == true,
                "Alice's hasNickname should be true");
            assertTrue(user["displayName"].str == "Ally",
                "Alice's displayName should be 'Ally'");
            return;
        }
    }
    assertTrue(false, "Alice not found");
}

void testQueryPlainMethodNullNickname() {
    // Test plain method behavior when underlying field is null
    auto response = graphql(`{
        users {
            firstName
            nickname
            displayName
            hasNickname
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;

    // Find Bob who doesn't have a nickname
    foreach (user; users) {
        if (user["firstName"].str == "Bob") {
            assertTrue(user["nickname"].type == JSONType.null_,
                "Bob's nickname should be null");
            assertTrue(user["displayName"].str == "Anonymous",
                "Bob's displayName should be 'Anonymous' when no nickname");
            assertTrue(user["hasNickname"].boolean == false,
                "Bob's hasNickname should be false");
            return;
        }
    }
    assertTrue(false, "Bob not found");
}

void testQueryPlainMethodReturningStruct() {
    // Test plain method that returns a POD struct
    auto response = graphql(`{
        users {
            firstName
            stats {
                postCount
                commentCount
            }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // All users should have stats with expected values
    foreach (user; users) {
        auto stats = user["stats"];
        assertTrue(("postCount" in stats) !is null, "stats should have postCount");
        assertTrue(("commentCount" in stats) !is null, "stats should have commentCount");
        // Our test implementation returns UserStats(42, 99)
        assertTrue(stats["postCount"].integer == 42,
            "postCount should be 42, got: " ~ stats["postCount"].toString());
        assertTrue(stats["commentCount"].integer == 99,
            "commentCount should be 99, got: " ~ stats["commentCount"].toString());
    }
}

void testQueryPlainMethodOnPodStruct() {
    // Test querying a plain method on the POD struct itself
    auto response = graphql(`{
        users {
            firstName
            stats {
                postCount
                commentCount
                totalActivity
            }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // totalActivity should be postCount + commentCount = 42 + 99 = 141
    foreach (user; users) {
        auto stats = user["stats"];
        auto postCount = stats["postCount"].integer;
        auto commentCount = stats["commentCount"].integer;
        auto totalActivity = stats["totalActivity"].integer;
        auto expectedTotal = postCount + commentCount;
        assertTrue(totalActivity == expectedTotal,
            "totalActivity should be " ~ expectedTotal.to!string ~
            ", got: " ~ totalActivity.to!string);
        // Also verify the actual expected values
        assertTrue(postCount == 42, "postCount should be 42, got: " ~ postCount.to!string);
        assertTrue(totalActivity == 141, "totalActivity should be 141 (42+99), got: " ~ totalActivity.to!string);
    }
}

// ============================================================================
// Multi-hop BelongsTo Tests
// ============================================================================

void testQueryMultiHopBelongsTo() {
    // Test 2-hop belongsTo: comment -> post -> author
    // postAuthorName is a computed field that traverses comment.post.author.fullName
    auto response = graphql(`{
        comments {
            body
            postAuthorName
            post {
                title
                author {
                    fullName
                }
            }
        }
    }`);

    assertNoErrors(response);
    auto comments = response["data"]["comments"].array;
    assertTrue(comments.length >= 2, "Expected at least 2 comments");

    // Verify that postAuthorName matches post.author.fullName for each comment
    foreach (comment; comments) {
        auto postAuthorName = comment["postAuthorName"].str;
        auto authorFullName = comment["post"]["author"]["fullName"].str;
        auto body = comment["body"].str;

        assertTrue(postAuthorName == authorFullName,
            "postAuthorName for comment '" ~ body ~ "' should be '" ~ authorFullName ~
            "' but got '" ~ postAuthorName ~ "'");
    }
}

void testQueryMultiHopBelongsToValues() {
    // Test specific values from seed data:
    // Both comments are on Alice's posts, so postAuthorName should be "Alice Smith"
    auto response = graphql(`{
        comments {
            body
            postAuthorName
            post {
                title
                author { firstName }
            }
        }
    }`);

    assertNoErrors(response);
    auto comments = response["data"]["comments"].array;
    assertTrue(comments.length >= 2, "Expected at least 2 comments");

    foreach (comment; comments) {
        auto body = comment["body"].str;

        // First verify the BelongsTo chain resolves correctly
        auto postTitle = comment["post"]["title"].str;
        assertTrue(postTitle.length > 0,
            "post.title should be non-empty for comment '" ~ body ~ "', got '" ~ postTitle ~ "'");

        auto authorFirstName = comment["post"]["author"]["firstName"].str;
        assertTrue(authorFirstName.length > 0,
            "post.author.firstName should be non-empty for comment '" ~ body ~ "', got '" ~ authorFirstName ~ "'");

        auto postAuthorName = comment["postAuthorName"].str;

        // Both seeded comments are on Alice's posts
        if (body == "Great post!" || body == "Thanks for sharing") {
            assertTrue(postAuthorName == "Alice Smith",
                "postAuthorName for '" ~ body ~ "' should be 'Alice Smith' but got '" ~ postAuthorName ~ "'");
        }
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
// Filtering Tests
// ============================================================================

void testFilterUsersByFirstName() {
    auto response = graphql(`{
        users(filter: {firstName: {equalTo: "Alice"}}) {
            firstName
            lastName
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user matching filter");

    // All returned users should be Alice
    foreach (user; users) {
        assertTrue(user["firstName"].str == "Alice",
            "Expected firstName to be 'Alice', got '" ~ user["firstName"].str ~ "'");
    }
}

void testFilterUsersByAge() {
    auto response = graphql(`{
        users(filter: {age: {greaterThan: 18}}) {
            firstName
            age
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;

    // All returned users should have age > 18
    foreach (user; users) {
        assertTrue(user["age"].integer > 18,
            "Expected age > 18, got " ~ user["age"].toString());
    }
}

void testFilterWithAnd() {
    // Filter users with age >= 18 AND firstName starts with 'A'
    auto response = graphql(`{
        users(filter: {
            age: {greaterThanOrEqualTo: 18},
            firstName: {startsWith: "A"}
        }) {
            firstName
            age
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;

    // All returned users should satisfy both conditions
    foreach (user; users) {
        assertTrue(user["age"].integer >= 18,
            "Expected age >= 18, got " ~ user["age"].toString());
        assertTrue(user["firstName"].str.length > 0 && user["firstName"].str[0] == 'A',
            "Expected firstName to start with 'A', got '" ~ user["firstName"].str ~ "'");
    }
}

void testFilterWithOr() {
    // Filter users named Alice OR Bob
    auto response = graphql(`{
        users(filter: {
            or: [
                {firstName: {equalTo: "Alice"}},
                {firstName: {equalTo: "Bob"}}
            ]
        }) {
            firstName
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 2, "Expected at least 2 users (Alice and Bob)");

    // All returned users should be Alice or Bob
    foreach (user; users) {
        auto name = user["firstName"].str;
        assertTrue(name == "Alice" || name == "Bob",
            "Expected 'Alice' or 'Bob', got '" ~ name ~ "'");
    }
}

void testFilterWithNot() {
    // Filter users NOT named Alice
    auto response = graphql(`{
        users(filter: {
            not: {firstName: {equalTo: "Alice"}}
        }) {
            firstName
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;

    // No returned users should be Alice
    foreach (user; users) {
        assertTrue(user["firstName"].str != "Alice",
            "Expected not 'Alice', got '" ~ user["firstName"].str ~ "'");
    }
}

void testFilterTasksByEnumStatus() {
    auto response = graphql(`{
        tasks(filter: {status: {equalTo: pending}}) {
            title
            status
        }
    }`);

    assertNoErrors(response);
    auto tasks = response["data"]["tasks"].array;
    assertTrue(tasks.length >= 1, "Expected at least 1 pending task");

    // All returned tasks should have pending status
    foreach (task; tasks) {
        assertTrue(task["status"].str == "pending",
            "Expected status 'pending', got '" ~ task["status"].str ~ "'");
    }
}

void testFilterUsersWithPostsSome() {
    // Filter users who have at least one post with "Hello" in title
    auto response = graphql(`{
        users(filter: {
            posts: {
                some: {title: {contains: "Hello"}}
            }
        }) {
            firstName
            posts { title }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;

    // Each returned user should have at least one post containing "Hello"
    foreach (user; users) {
        auto posts = user["posts"].array;
        bool foundHello = false;
        foreach (post; posts) {
            import std.string : indexOf;
            if (post["title"].str.indexOf("Hello") != -1) {
                foundHello = true;
                break;
            }
        }
        assertTrue(foundHello,
            "User " ~ user["firstName"].str ~ " should have a post containing 'Hello'");
    }
}

void testFilterUsersWithPostsEvery() {
    // Filter users where ALL their posts contain a specific pattern
    // This is a vacuous truth for users with no posts
    auto response = graphql(`{
        users(filter: {
            posts: {
                every: {title: {notEqualTo: ""}}
            }
        }) {
            firstName
            posts { title }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;

    // All posts for each user should have non-empty titles (which they do)
    foreach (user; users) {
        auto posts = user["posts"].array;
        foreach (post; posts) {
            assertTrue(post["title"].str.length > 0,
                "Post should have non-empty title");
        }
    }
}

void testFilterUsersWithPostsNone() {
    // Filter users who have NO posts with "NonExistent" in title
    // This should return all users since no posts have that title
    auto response = graphql(`{
        users(filter: {
            posts: {
                none: {title: {contains: "NonExistentTitle12345"}}
            }
        }) {
            firstName
            posts { title }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;

    // No user should have a post with that title
    foreach (user; users) {
        auto posts = user["posts"].array;
        foreach (post; posts) {
            import std.string : indexOf;
            assertTrue(post["title"].str.indexOf("NonExistentTitle12345") == -1,
                "Post should not contain 'NonExistentTitle12345'");
        }
    }
}

void testFilterNestedPosts() {
    // Filter posts within a user query
    auto response = graphql(`{
        users {
            firstName
            posts(filter: {title: {contains: "GraphQL"}}) {
                title
            }
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;

    // Each user's posts should only contain those with "GraphQL" in title
    foreach (user; users) {
        auto posts = user["posts"].array;
        foreach (post; posts) {
            import std.string : indexOf;
            assertTrue(post["title"].str.indexOf("GraphQL") != -1,
                "Post title should contain 'GraphQL', got '" ~ post["title"].str ~ "'");
        }
    }
}

void testFilterContainsInsensitive() {
    // Filter users whose firstName contains "ali" (case-insensitive, should match "Alice")
    auto response = graphql(`{
        users(filter: {firstName: {containsInsensitive: "ali"}}) {
            firstName
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user matching 'ali' case-insensitively");

    // All returned users should have 'ali' in their name (case-insensitive)
    foreach (user; users) {
        import std.uni : toLower;
        import std.string : indexOf;
        auto name = user["firstName"].str.toLower;
        assertTrue(name.indexOf("ali") != -1,
            "Expected firstName to contain 'ali' (case-insensitive), got '" ~ user["firstName"].str ~ "'");
    }
}

void testFilterStartsWithInsensitive() {
    // Filter users whose firstName starts with "a" (case-insensitive, should match "Alice")
    auto response = graphql(`{
        users(filter: {firstName: {startsWithInsensitive: "a"}}) {
            firstName
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user starting with 'a' case-insensitively");

    // All returned users should have firstName starting with 'a' or 'A'
    foreach (user; users) {
        import std.uni : toLower;
        auto name = user["firstName"].str;
        assertTrue(name.length > 0 && (name[0] == 'A' || name[0] == 'a'),
            "Expected firstName to start with 'a' (case-insensitive), got '" ~ name ~ "'");
    }
}

void testFilterEndsWithInsensitive() {
    // Filter users whose firstName ends with "CE" (case-insensitive, should match "Alice")
    auto response = graphql(`{
        users(filter: {firstName: {endsWithInsensitive: "CE"}}) {
            firstName
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user ending with 'CE' case-insensitively");

    // All returned users should have firstName ending with 'ce' (case-insensitive)
    foreach (user; users) {
        import std.uni : toLower;
        import std.algorithm : endsWith;
        auto name = user["firstName"].str.toLower;
        assertTrue(name.endsWith("ce"),
            "Expected firstName to end with 'ce' (case-insensitive), got '" ~ user["firstName"].str ~ "'");
    }
}

void testFilterCaseSensitiveVsInsensitive() {
    // Verify case-sensitive filter does NOT match different case
    auto responseSensitive = graphql(`{
        users(filter: {firstName: {contains: "ALICE"}}) {
            firstName
        }
    }`);
    assertNoErrors(responseSensitive);
    auto usersSensitive = responseSensitive["data"]["users"].array;
    // "ALICE" should not match "Alice" with case-sensitive contains
    assertTrue(usersSensitive.length == 0,
        "Case-sensitive 'contains: ALICE' should not match 'Alice'");

    // Verify case-insensitive filter DOES match different case
    auto responseInsensitive = graphql(`{
        users(filter: {firstName: {containsInsensitive: "ALICE"}}) {
            firstName
        }
    }`);
    assertNoErrors(responseInsensitive);
    auto usersInsensitive = responseInsensitive["data"]["users"].array;
    assertTrue(usersInsensitive.length >= 1,
        "Case-insensitive 'containsInsensitive: ALICE' should match 'Alice'");
}

// ============================================================================
// Composite Primary Key Tests
// ============================================================================

void testQueryAllTags() {
    auto response = graphql(`{ tags { category name description } }`);

    assertNoErrors(response);
    auto tags = response["data"]["tags"].array;
    assertTrue(tags.length >= 3, "Expected at least 3 tags");

    // Verify all tags have expected fields
    foreach (tag; tags) {
        assertTrue(("category" in tag) !is null, "Tag should have category");
        assertTrue(("name" in tag) !is null, "Tag should have name");
        assertTrue(("description" in tag) !is null, "Tag should have description");
    }
}

void testQueryTagsByCategory() {
    // Query all tags and check category grouping
    auto response = graphql(`{ tags { category name } }`);

    assertNoErrors(response);
    auto tags = response["data"]["tags"].array;

    // Find language tags
    int languageTags = 0;
    int toolTags = 0;
    foreach (tag; tags) {
        if (tag["category"].str == "language") languageTags++;
        if (tag["category"].str == "tool") toolTags++;
    }
    assertTrue(languageTags >= 2, "Expected at least 2 language tags");
    assertTrue(toolTags >= 1, "Expected at least 1 tool tag");
}

void testQueryTagValues() {
    auto response = graphql(`{ tags { category name description } }`);

    assertNoErrors(response);
    auto tags = response["data"]["tags"].array;

    // Find specific tags and verify their data
    bool foundD = false;
    bool foundGraphQL = false;
    foreach (tag; tags) {
        if (tag["category"].str == "language" && tag["name"].str == "D") {
            assertTrue(tag["description"].str == "D programming language",
                "D tag description should match");
            foundD = true;
        }
        if (tag["category"].str == "tool" && tag["name"].str == "GraphQL") {
            assertTrue(tag["description"].str == "Query language for APIs",
                "GraphQL tag description should match");
            foundGraphQL = true;
        }
    }
    assertTrue(foundD, "Expected to find language/D tag");
    assertTrue(foundGraphQL, "Expected to find tool/GraphQL tag");
}

void testCreateTagMutation() {
    // Test creating a new tag with composite PK (use mode suffix for uniqueness)
    auto suffix = modeSuffix();
    auto name = "Vibe-" ~ suffix;
    auto response = graphql(`mutation {
        createTag(category: "framework", name: "` ~ name ~ `", description: "D web framework") {
            category
            name
            description
        }
    }`);

    assertNoErrors(response);
    auto tag = response["data"]["createTag"];
    assertTrue(tag["category"].str == "framework", "Expected category 'framework'");
    assertTrue(tag["name"].str == name, "Expected name '" ~ name ~ "'");
    assertTrue(tag["description"].str == "D web framework", "Expected correct description");
}

void testQueryAllUserBadges() {
    auto response = graphql(`{ userBadges { userId badgeName description } }`);

    assertNoErrors(response);
    auto badges = response["data"]["userBadges"].array;
    assertTrue(badges.length >= 3, "Expected at least 3 user badges");

    // Verify all badges have expected fields
    foreach (badge; badges) {
        assertTrue(("userId" in badge) !is null, "Badge should have userId");
        assertTrue(("badgeName" in badge) !is null, "Badge should have badgeName");
        assertTrue(("description" in badge) !is null, "Badge should have description");
    }
}

void testQueryUserBadgeValues() {
    auto response = graphql(`{ userBadges { userId badgeName description } }`);

    assertNoErrors(response);
    auto badges = response["data"]["userBadges"].array;

    // Count contributor badges (Alice and Bob both have one)
    int contributorCount = 0;
    foreach (badge; badges) {
        if (badge["badgeName"].str == "contributor") contributorCount++;
    }
    assertTrue(contributorCount >= 2, "Expected at least 2 contributor badges");
}

void testCreateUserBadgeMutation() {
    // Test creating a new user badge with composite PK (use mode suffix for uniqueness)
    auto suffix = modeSuffix();
    auto badgeName = "tester-" ~ suffix;
    auto response = graphql(`mutation {
        createUserBadge(userId: 1, badgeName: "` ~ badgeName ~ `", description: "Test writer") {
            userId
            badgeName
            description
        }
    }`);

    assertNoErrors(response);
    auto badge = response["data"]["createUserBadge"];
    assertTrue(badge["badgeName"].str == badgeName, "Expected badgeName '" ~ badgeName ~ "'");
    assertTrue(badge["description"].str == "Test writer", "Expected correct description");
}

void testCompositePkPersistence() {
    // Create a tag and verify it persists (use mode suffix for uniqueness)
    auto suffix = modeSuffix();
    auto name = "persist-" ~ suffix;
    auto createResponse = graphql(`mutation {
        createTag(category: "test", name: "` ~ name ~ `", description: "Persistence test") {
            category
            name
        }
    }`);
    assertNoErrors(createResponse);

    // Query to verify it was persisted
    auto queryResponse = graphql(`{ tags { category name description } }`);
    assertNoErrors(queryResponse);

    auto tags = queryResponse["data"]["tags"].array;
    bool found = false;
    foreach (tag; tags) {
        if (tag["category"].str == "test" && tag["name"].str == name) {
            assertTrue(tag["description"].str == "Persistence test",
                "Persisted tag should have correct description");
            found = true;
            break;
        }
    }
    assertTrue(found, "Created tag should be queryable");
}

void testSortTagsByName() {
    auto response = graphql(`{
        tags(orderBy: [{field: name, direction: ASC}]) {
            category
            name
        }
    }`);

    assertNoErrors(response);
    auto tags = response["data"]["tags"].array;
    assertTrue(tags.length >= 2, "Expected at least 2 tags");

    // Verify ascending order by name
    for (size_t i = 1; i < tags.length; i++) {
        auto prev = tags[i - 1]["name"].str;
        auto curr = tags[i]["name"].str;
        assertTrue(prev <= curr,
            "Tags should be sorted by name ascending, got '" ~ prev ~ "' before '" ~ curr ~ "'");
    }
}

void testFilterTagsByCategory() {
    auto response = graphql(`{
        tags(filter: {category: {equalTo: "language"}}) {
            category
            name
        }
    }`);

    assertNoErrors(response);
    auto tags = response["data"]["tags"].array;
    assertTrue(tags.length >= 2, "Expected at least 2 language tags");

    // All returned tags should be in the "language" category
    foreach (tag; tags) {
        assertTrue(tag["category"].str == "language",
            "Expected category 'language', got '" ~ tag["category"].str ~ "'");
    }
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
    registerTest("Sort tasks by title", "tests", &testSortTasksByTitle);
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

    // Eager field tests
    registerTest("Query eager field (nickname)", "tests", &testQueryEagerField);
    registerTest("Query eager field with computed field", "tests", &testQueryEagerFieldWithComputedField);

    // Plain method tests
    registerTest("Query plain method", "tests", &testQueryPlainMethod);
    registerTest("Query plain method with computed field", "tests", &testQueryPlainMethodWithComputedField);
    registerTest("Query plain method null nickname", "tests", &testQueryPlainMethodNullNickname);
    registerTest("Query plain method returning struct", "tests", &testQueryPlainMethodReturningStruct);
    registerTest("Query plain method on POD struct", "tests", &testQueryPlainMethodOnPodStruct);

    // Multi-hop belongsTo tests
    registerTest("Multi-hop belongsTo (comment.post.author)", "tests", &testQueryMultiHopBelongsTo);
    registerTest("Multi-hop belongsTo values", "tests", &testQueryMultiHopBelongsToValues);

    // Recursive input type tests
    registerTest("Recursive filter input", "tests", &testRecursiveFilterInput);
    registerTest("Deep nested filter input", "tests", &testDeepNestedFilterInput);
    registerTest("Pointer input null", "tests", &testPointerInputNull);
    registerTest("Pointer input with value", "tests", &testPointerInputWithValue);
    registerTest("Empty recursive arrays", "tests", &testEmptyRecursiveArrays);

    // Filtering tests
    registerTest("Filter users by firstName equalTo", "tests", &testFilterUsersByFirstName);
    registerTest("Filter users by age greaterThan", "tests", &testFilterUsersByAge);
    registerTest("Filter with AND combinator", "tests", &testFilterWithAnd);
    registerTest("Filter with OR combinator", "tests", &testFilterWithOr);
    registerTest("Filter with NOT combinator", "tests", &testFilterWithNot);
    registerTest("Filter tasks by enum status", "tests", &testFilterTasksByEnumStatus);
    registerTest("Filter users with posts (some)", "tests", &testFilterUsersWithPostsSome);
    registerTest("Filter users with all posts matching (every)", "tests", &testFilterUsersWithPostsEvery);
    registerTest("Filter users with no posts matching (none)", "tests", &testFilterUsersWithPostsNone);
    registerTest("Filter nested posts", "tests", &testFilterNestedPosts);

    // Case-insensitive filtering tests
    registerTest("Filter containsInsensitive", "tests", &testFilterContainsInsensitive);
    registerTest("Filter startsWithInsensitive", "tests", &testFilterStartsWithInsensitive);
    registerTest("Filter endsWithInsensitive", "tests", &testFilterEndsWithInsensitive);
    registerTest("Filter case-sensitive vs insensitive", "tests", &testFilterCaseSensitiveVsInsensitive);

    // Composite primary key tests
    registerTest("Query all tags (composite PK)", "tests", &testQueryAllTags);
    registerTest("Query tags by category", "tests", &testQueryTagsByCategory);
    registerTest("Query tag values", "tests", &testQueryTagValues);
    registerTest("Create tag mutation (composite PK)", "tests", &testCreateTagMutation);
    registerTest("Query all user badges (composite PK)", "tests", &testQueryAllUserBadges);
    registerTest("Query user badge values", "tests", &testQueryUserBadgeValues);
    registerTest("Create user badge mutation (composite PK)", "tests", &testCreateUserBadgeMutation);
    registerTest("Composite PK persistence", "tests", &testCompositePkPersistence);
    registerTest("Sort tags by name (composite PK)", "tests", &testSortTagsByName);
    registerTest("Filter tags by category (composite PK)", "tests", &testFilterTagsByCategory);
}
