/**
 * Integration Tests
 *
 * GraphQL query and mutation tests run against a real database.
 */
module integration.tests;

import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
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

void testNullableObjectWithRequiredBelongsTo() {
    // A required relation of a nullable object, null for some of the batch:
    // the selection set is evaluated for placeholders of the null ones too,
    // whose parents are placeholders (it failed on their missing parents)
    auto response = graphql(`{ users(filter: {` ~ seededUsers ~ `}, orderBy: [{field: firstName, direction: ASC}]) {
        firstName latestPost { author { firstName latestPost { author { lastName } } } }
    } }`);
    assertNoErrors(response);
    assertEqual(response["data"]["users"], `[
        {"firstName": "Alice", "latestPost": {
            "author": {"firstName": "Alice", "latestPost": {"author": {"lastName": "Smith"}}}}},
        {"firstName": "Bob", "latestPost": {
            "author": {"firstName": "Bob", "latestPost": {"author": {"lastName": "Jones"}}}}},
        {"firstName": "Charlie", "latestPost": null}
    ]`);
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

// ============================================================================
// HasMany nested under BelongsTo
// ============================================================================

/// Ground truth for a FK: child id -> parent id, and parent id -> sorted child ids.
private struct FkTruth {
    string[string] parentOf;
    string[][string] childrenOf;

    string[] children(string parentId) {
        auto p = parentId in childrenOf;
        return p ? *p : null;
    }
}

/// Fetch `{ <root> { id <fkField> } }` and index it as ground truth.
private FkTruth fkTruth(string root, string fkField) {
    import std.algorithm : sort;
    auto response = graphql(`{ ` ~ root ~ ` { id ` ~ fkField ~ ` } }`);
    assertNoErrors(response);
    FkTruth t;
    foreach (row; response["data"][root].array) {
        auto id = row["id"].toString(), parentId = row[fkField].toString();
        t.parentOf[id] = parentId;
        t.childrenOf[parentId] ~= id;
    }
    foreach (parentId, ref ids; t.childrenOf)
        sort(ids);
    return t;
}

/// Sorted string forms of the `id` values of a JSON array of objects.
private string[] sortedIds(JSONValue arr) {
    import std.algorithm : map, sort;
    import std.array : array;
    auto r = arr.array.map!(o => o["id"].toString()).array;
    sort(r);
    return r;
}

/// Check a `{ <root> { id <belongsTo> { <hasMany> { id ... } } } }` response:
/// every root row's `<belongsTo>.<hasMany>` must list exactly the children of
/// that row's parent. `rootTruth` maps root row ids to the belongsTo target's
/// id; `childTruth` maps the hasMany's child ids to their parent ids.
private void checkHasManyUnderBelongsTo(string query, string root, string belongsTo,
        string hasMany, FkTruth rootTruth, FkTruth childTruth, size_t minRows) {
    auto response = graphql(query);
    assertNoErrors(response);
    auto rows = response["data"][root].array;
    assertTrue(rows.length >= minRows,
        query ~ ": expected at least " ~ minRows.to!string ~ " rows, got " ~ rows.length.to!string);
    foreach (row; rows) {
        auto id = row["id"].toString();
        auto parentId = rootTruth.parentOf[id];
        auto expected = childTruth.children(parentId);
        auto got = sortedIds(row[belongsTo][hasMany]);
        assertTrue(expected.length > 0, query ~ ": test data must give " ~ root ~ " " ~ id ~ " siblings");
        assertTrue(got == expected,
            query ~ ": " ~ root ~ " " ~ id ~ " " ~ belongsTo ~ "." ~ hasMany ~ " ids: expected " ~
            expected.to!string ~ ", got " ~ got.to!string);
    }
}

/// root list -> BelongsTo -> HasMany, where the HasMany's child type is the
/// root's own type (comment.post.comments) and where it is not
/// (post.author.posts is the same shape over Post/User), selecting only `id`
/// or also a non-key column, with and without the BelongsTo target's own id.
void testHasManyUnderBelongsTo() {
    auto commentPost = fkTruth("comments", "postId");
    auto postAuthor = fkTruth("posts", "authorId");
    foreach (sel; ["id", "id authorId"]) {
        foreach (targetSel; ["", "id "]) {
            checkHasManyUnderBelongsTo(
                `{ comments { id post { ` ~ targetSel ~ `comments { ` ~ sel ~ ` } } } }`,
                "comments", "post", "comments", commentPost, commentPost, 2);
            checkHasManyUnderBelongsTo(
                `{ posts { id author { ` ~ targetSel ~ `posts { ` ~ sel ~ ` } } } }`,
                "posts", "author", "posts", postAuthor, postAuthor, 3);
        }
    }
}

/// Same shapes, with the root list restricted by a filter on its ids.
void testHasManyUnderBelongsToFilteredRoot() {
    auto commentPost = fkTruth("comments", "postId");
    auto postAuthor = fkTruth("posts", "authorId");
    string idList(FkTruth t) {
        string ids;
        foreach (id, _; t.parentOf)
            ids ~= (ids.length ? ", " : "") ~ `"` ~ id ~ `"`;
        return ids;
    }
    foreach (sel; ["id", "id authorId"]) {
        checkHasManyUnderBelongsTo(
            `{ comments(filter: {id: {in: [` ~ idList(commentPost) ~ `]}}) { id post { id comments { ` ~ sel ~ ` } } } }`,
            "comments", "post", "comments", commentPost, commentPost, commentPost.parentOf.length);
        checkHasManyUnderBelongsTo(
            `{ posts(filter: {id: {in: [` ~ idList(postAuthor) ~ `]}}) { id author { id posts { ` ~ sel ~ ` } } } }`,
            "posts", "author", "posts", postAuthor, postAuthor, postAuthor.parentOf.length);
    }
}

/// HasMany directly under the root list, selecting only `id` or also a column.
void testHasManyUnderRoot() {
    auto commentPost = fkTruth("comments", "postId");
    foreach (sel; ["id", "id authorId"]) {
        auto query = `{ posts { id comments { ` ~ sel ~ ` } } }`;
        auto response = graphql(query);
        assertNoErrors(response);
        foreach (p; response["data"]["posts"].array) {
            auto pid = p["id"].toString();
            auto expected = commentPost.children(pid);
            auto got = sortedIds(p["comments"]);
            assertTrue(got == expected, query ~ ": post " ~ pid ~ " comments ids: expected " ~
                expected.to!string ~ ", got " ~ got.to!string);
        }
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
                some: {title: {includes: "Hello"}}
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
                none: {title: {includes: "NonExistentTitle12345"}}
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
            posts(filter: {title: {includes: "GraphQL"}}) {
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

void testFilterIncludesInsensitive() {
    // Filter users whose firstName contains "ali" (case-insensitive, should match "Alice")
    auto response = graphql(`{
        users(filter: {firstName: {includesInsensitive: "ali"}}) {
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

/// A root filter, sort and window apply alike whether or not the selection
/// reads a column of the rows (when it does not, the filter's predicate is
/// what makes the rows a query of their own, into which they are pushed).
void testRootFilterWithoutSelectedColumns() {
    import std.algorithm.searching : all;
    void check(string args, bool delegate(JSONValue[]) expect) {
        auto withTitle = graphql(`{ posts(` ~ args ~ `) { id title } }`);
        auto idOnly = graphql(`{ posts(` ~ args ~ `) { id } }`);
        assertNoErrors(withTitle);
        assertNoErrors(idOnly);
        auto expected = withTitle["data"]["posts"].array;
        auto found = idOnly["data"]["posts"].array;
        assertTrue(expect(expected), args ~ ": unexpected posts: " ~ withTitle.toString());
        bool same = found.length == expected.length;
        foreach (i; 0 .. same ? found.length : 0)
            same = same && found[i]["id"] == expected[i]["id"];
        assertTrue(same, args ~ ": selecting only the id found " ~ idOnly.toString() ~
            ", with the title " ~ withTitle.toString());
    }
    check(`filter: {title: {notEqualTo: "Hello World"}}, orderBy: [{field: title, direction: DESC}], first: 1`,
        (JSONValue[] posts) => posts.length == 1 && posts[0]["title"].str != "Hello World");
    // A relationship (belongsTo) filter beside a column's
    check(`first: 10, filter: {title: {includesInsensitive: "PROGRAM"}, author: {firstName: {equalTo: "Bob"}}}`,
        (JSONValue[] posts) => posts.length >= 1 && posts.all!(p => p["title"].str == "D Programming"));
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
        users(filter: {firstName: {includes: "ALICE"}}) {
            firstName
        }
    }`);
    assertNoErrors(responseSensitive);
    auto usersSensitive = responseSensitive["data"]["users"].array;
    // "ALICE" should not match "Alice" with case-sensitive contains
    assertTrue(usersSensitive.length == 0,
        "Case-sensitive 'includes: ALICE' should not match 'Alice'");

    // Verify case-insensitive filter DOES match different case
    auto responseInsensitive = graphql(`{
        users(filter: {firstName: {includesInsensitive: "ALICE"}}) {
            firstName
        }
    }`);
    assertNoErrors(responseInsensitive);
    auto usersInsensitive = responseInsensitive["data"]["users"].array;
    assertTrue(usersInsensitive.length >= 1,
        "Case-insensitive 'includesInsensitive: ALICE' should match 'Alice'");
}

// ============================================================================
// Request Context Tests
// ============================================================================

void testRequestContextGreeting() {
    // Test that localizedGreeting uses French locale from X-Locale header
    auto response = graphql(`{
        users {
            firstName
            localizedGreeting
        }
    }`, JSONValue.emptyObject, ["X-Locale": "fr"]);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Find Alice and check her greeting
    foreach (user; users) {
        if (user["firstName"].str == "Alice") {
            assertTrue(user["localizedGreeting"].str == "Bonjour Alice",
                "Expected 'Bonjour Alice', got: " ~ user["localizedGreeting"].str);
            return;
        }
    }
    assertTrue(false, "Alice not found");
}

void testRequestContextDefaultLocale() {
    // Test that localizedGreeting uses default English locale (no X-Locale header)
    auto response = graphql(`{
        users {
            firstName
            localizedGreeting
        }
    }`);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Find Alice and check her greeting
    foreach (user; users) {
        if (user["firstName"].str == "Alice") {
            assertTrue(user["localizedGreeting"].str == "Hello Alice",
                "Expected 'Hello Alice', got: " ~ user["localizedGreeting"].str);
            return;
        }
    }
    assertTrue(false, "Alice not found");
}

void testRequestContextSpanishLocale() {
    // Test with Spanish locale
    auto response = graphql(`{
        users {
            firstName
            localizedGreeting
        }
    }`, JSONValue.emptyObject, ["X-Locale": "es"]);

    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length >= 1, "Expected at least 1 user");

    // Find Alice and check her greeting
    foreach (user; users) {
        if (user["firstName"].str == "Alice") {
            assertTrue(user["localizedGreeting"].str == "Hola Alice",
                "Expected 'Hola Alice', got: " ~ user["localizedGreeting"].str);
            return;
        }
    }
    assertTrue(false, "Alice not found");
}

// ============================================================================
// Error Path Tracking Tests
// ============================================================================

void testFieldErrorPartialResult() {
    // Query a mix of good and failing fields — should get partial result.
    // failingField is String! (non-null) and always throws, so null bubbling
    // makes each assignee null; Task.assignee is nullable, so bubbling stops
    // there and the tasks themselves survive.
    auto response = graphql(`{ tasks { title assignee { firstName failingField } } }`);

    // Should have both data and errors
    assertPartialResult(response);

    auto tasks = response["data"]["tasks"].array;
    assertTrue(tasks.length >= 3, "Expected at least 3 tasks");
    foreach (task; tasks) {
        assertTrue(task.type == JSONType.object, "Task should survive (assignee is nullable)");
        assertTrue(task["title"].type == JSONType.string, "Task title should be present");
        assertTrue(task["assignee"].isNull, "Assignee should be null due to non-null field error");
    }
    assertErrorPath(response, [JSONValue("tasks"), JSONValue("assignee"), JSONValue("failingField")]);
}

void testFieldErrorPath() {
    // Verify the error path points to the correct field
    auto response = graphql(`{ users { firstName failingField } }`);

    assertPartialResult(response);
    assertErrorPath(response, [JSONValue("users"), JSONValue("failingField")]);
}

void testNonNullFieldErrorNullsData() {
    // failingField is String!, users is [User!]! and non-null: the error nulls
    // each User, the null items null the list, and the non-null root field
    // nulls the whole response data — including sibling root fields.
    auto response = graphql(`{ tasks { title } users(orderBy: [{field: firstName, direction: ASC}]) { firstName lastName failingField } }`);

    assertPartialResult(response);
    assertTrue(response["data"].isNull, "data should be null due to non-null field error");
    assertErrorPath(response, [JSONValue("users"), JSONValue("failingField")]);
}

void testFieldErrorBesideInFlightSibling() {
    // One input of a computed field fails for the whole batch while the other
    // is still issuing dependent queries. The request (and its session) must
    // not end until that sibling has settled: before structured joins, the
    // sibling's next query ran on the torn-down session and crashed the
    // server with a null-connection dereference.
    auto response = graphql(`{ tasks { title } users { failsBesideSlowSibling } }`);

    assertPartialResult(response);
    assertErrorPath(response, [JSONValue("users"), JSONValue("failsBesideSlowSibling")]);
    assertTrue(response["errors"].array[0]["message"].str == "intentional error in failingField",
        "Expected the failing input's own error, got: " ~ response["errors"].toString());

    // The server and its session pool are still healthy.
    auto followUp = graphql(`{ users { firstName posts { title author { firstName } } } }`);
    assertNoErrors(followUp);
    assertTrue(followUp["data"]["users"].array.length >= 2, "Expected at least 2 users");
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

void testUserBadgesRelation() {
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : isSorted;

    // HasMany keyed on part of the children's composite key, ordered by the
    // rest of it, and BelongsTo through a key field. The new badge is
    // inserted after Bob's "contributor" badge, but sorts before it.
    auto badgeName = "a-" ~ modeSuffix();
    assertNoErrors(graphql(`mutation {
        createUserBadge(userId: 2, badgeName: "` ~ badgeName ~ `", description: "Early") { userId }
    }`));

    auto response = graphql(`{
        users(filter: {firstName: {equalTo: "Bob"}}) {
            firstName
            badges { badgeName description user { firstName } }
        }
    }`);
    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    assertTrue(users.length == 1, "Expected Bob: " ~ response.toString());
    string[] names;
    foreach (badge; users[0]["badges"].array) {
        names ~= badge["badgeName"].str;
        assertTrue(badge["user"]["firstName"].str == "Bob", "Expected the badge's user: " ~ response.toString());
    }
    assertTrue(names.canFind(badgeName) && names.canFind("contributor"), "Expected Bob's badges: " ~ response.toString());
    assertTrue(names.isSorted, "Expected badges ordered by name: " ~ response.toString());
    assertTrue(users[0]["badges"][0]["description"].str == "Early", "Expected the badge's columns: " ~ response.toString());
}

void testUserBadgesTableOrder() {
    import std.algorithm.mutation : SwapStrategy;
    import std.algorithm.sorting : isSorted, sort;
    import std.typecons : tuple;

    // The table's own order: by name, then user
    auto all = graphql(`{ userBadges { userId badgeName } }`);
    assertNoErrors(all);
    auto badges = all["data"]["userBadges"].array;
    assertTrue(badges.length >= 3, "Expected the user badges: " ~ all.toString());
    typeof(tuple(string.init, long.init))[] keys;
    foreach (badge; badges)
        keys ~= tuple(badge["badgeName"].str, badge["userId"].integer);
    assertTrue(keys.isSorted, "Expected badges ordered by name, then user: " ~ all.toString());

    // A sort takes precedence, the table's order breaking its ties; the
    // window applies after both
    auto sorted = graphql(`{ userBadges(orderBy: [{field: userId, direction: DESC}], first: 3) { userId badgeName } }`);
    assertNoErrors(sorted);
    auto expected = badges.dup;
    expected.sort!((a, b) => a["userId"].integer > b["userId"].integer, SwapStrategy.stable);
    assertTrue(sorted["data"]["userBadges"] == JSONValue(expected[0 .. 3]),
        "Expected the first 3 by user (descending), then name: " ~ sorted.toString());
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
// Filtering Combined with Pagination
// ============================================================================

/// The plugin order determines whether a field's filter selects the rows its
/// first/offset window is taken from (the default schema: FilterPlugin before
/// PaginationPlugin) or is applied to the window (the `filter-last` schema),
/// and the SQL pushdown must preserve either order.  `filtered` and `windowed`
/// are the expected data for each; a null `windowed` skips the filter-last
/// schema (where the window would depend on rows other tests create).
/// Seeded users, ordered by id: Alice Smith (posts "Hello World", "GraphQL
/// Rocks"), Bob Jones ("D Programming"), Charlie Brown (no posts), then any
/// users the mutation tests created (no posts).
private void checkFilteredWindow(string query, string filtered, string windowed) {
    foreach (order; ["default", "filter-last"]) {
        auto expected = order == "default" ? filtered : windowed;
        if (expected is null) continue;
        auto response = graphql(query, JSONValue.emptyObject, ["X-Plugin-Order": order]);
        assertNoErrors(response);
        assertEqual(response["data"], parseJSON(expected), order ~ ": " ~ query);
    }
}

private enum byId = `orderBy: [{field: id, direction: ASC}]`;
private enum byIdDesc = `orderBy: [{field: id, direction: DESC}]`;

void testFilteredWindowScalar() {
    checkFilteredWindow(`{ users(first: 1, ` ~ byId ~ `, filter: {firstName: {equalTo: "Charlie"}}) { firstName } }`,
        `{"users": [{"firstName": "Charlie"}]}`, `{"users": []}`);
    checkFilteredWindow(`{ users(first: 1, offset: 1, ` ~ byId ~ `, filter: {lastName: {notEqualTo: "Smith"}}) { firstName } }`,
        `{"users": [{"firstName": "Charlie"}]}`, `{"users": [{"firstName": "Bob"}]}`);
    checkFilteredWindow(`{ posts(first: 1, ` ~ byIdDesc ~ `, filter: {title: {includes: "o"}}) { title } }`,
        `{"posts": [{"title": "D Programming"}]}`, null);
    checkFilteredWindow(`{ posts(first: 1, ` ~ byId ~ `, filter: {title: {includes: "Rocks"}}) { title } }`,
        `{"posts": [{"title": "GraphQL Rocks"}]}`, `{"posts": []}`);
    // Pushed into SQL as a whole (WHERE, ORDER BY, OFFSET, LIMIT).
    checkFilteredWindow(`{ users(first: 2, offset: 1, orderBy: [{field: firstName, direction: DESC}], ` ~
            `filter: {or: [{lastName: {equalTo: "Smith"}}, {lastName: {equalTo: "Jones"}}, ` ~
            `{lastName: {equalTo: "Brown"}}]}) { firstName } }`,
        `{"users": [{"firstName": "Bob"}, {"firstName": "Alice"}]}`, null);
}

void testFilteredWindowBelongsTo() {
    checkFilteredWindow(`{ posts(first: 1, ` ~ byId ~ `, filter: {author: {firstName: {equalTo: "Bob"}}}) { title } }`,
        `{"posts": [{"title": "D Programming"}]}`, `{"posts": []}`);
    checkFilteredWindow(`{ posts(first: 1, offset: 1, ` ~ byId ~ `, filter: {author: {firstName: {equalTo: "Alice"}}}) { title } }`,
        `{"posts": [{"title": "GraphQL Rocks"}]}`, `{"posts": [{"title": "GraphQL Rocks"}]}`);
    checkFilteredWindow(`{ comments(first: 1, ` ~ byId ~ `, filter: {post: {title: {equalTo: "GraphQL Rocks"}}}) { post { title } } }`,
        `{"comments": [{"post": {"title": "GraphQL Rocks"}}]}`, `{"comments": []}`);
}

void testFilteredWindowHasMany() {
    checkFilteredWindow(`{ users(first: 1, ` ~ byId ~ `, filter: {posts: {some: {title: {includes: "Programming"}}}}) { firstName } }`,
        `{"users": [{"firstName": "Bob"}]}`, `{"users": []}`);
    checkFilteredWindow(`{ users(first: 1, ` ~ byId ~ `, filter: {posts: {none: {title: {includes: "Hello"}}}}) { firstName } }`,
        `{"users": [{"firstName": "Bob"}]}`, `{"users": []}`);
    checkFilteredWindow(`{ users(first: 1, offset: 1, ` ~ byId ~ `, filter: {posts: {none: {title: {includes: "Hello"}}}}) { firstName } }`,
        `{"users": [{"firstName": "Charlie"}]}`, `{"users": [{"firstName": "Bob"}]}`);
    checkFilteredWindow(`{ users(first: 2, ` ~ byId ~ `, filter: {posts: {every: {title: {includes: "Programming"}}}}) { firstName } }`,
        `{"users": [{"firstName": "Bob"}, {"firstName": "Charlie"}]}`, `{"users": [{"firstName": "Bob"}]}`);
    checkFilteredWindow(`{ users(first: 1, ` ~ byIdDesc ~ `, filter: {posts: {some: {title: {includes: "o"}}}}) { firstName } }`,
        `{"users": [{"firstName": "Bob"}]}`, `{"users": []}`);
    // Without orderBy (as a search typically queries)
    checkFilteredWindow(`{ users(first: 10, filter: {posts: {some: {title: {includes: "Programming"}}}}) { firstName } }`,
        `{"users": [{"firstName": "Bob"}]}`, null);
}

void testFilteredWindowScalarAndRelationship() {
    checkFilteredWindow(`{ users(first: 10, filter: {lastName: {equalTo: "Jones"}, posts: {some: {title: {includes: "D"}}}}) { firstName } }`,
        `{"users": [{"firstName": "Bob"}]}`, null);
    checkFilteredWindow(`{ users(first: 10, filter: {lastName: {equalTo: "Smith"}, posts: {some: {title: {includes: "Programming"}}}}) { firstName } }`,
        `{"users": []}`, `{"users": []}`);
    checkFilteredWindow(`{ posts(first: 1, ` ~ byIdDesc ~ `, filter: {title: {includes: "o"}, author: {lastName: {equalTo: "Smith"}}}) { title } }`,
        `{"posts": [{"title": "GraphQL Rocks"}]}`, null);
    checkFilteredWindow(`{ posts(first: 1, ` ~ byId ~ `, filter: {title: {includes: "Rocks"}, author: {lastName: {equalTo: "Smith"}}}) { title } }`,
        `{"posts": [{"title": "GraphQL Rocks"}]}`, `{"posts": []}`);
}

void testFilteredWindowSameTableTwice() {
    checkFilteredWindow(`{
        a: users(first: 1, ` ~ byId ~ `, filter: {posts: {some: {title: {includes: "Programming"}}}}) { firstName }
        b: users(first: 1, ` ~ byId ~ `) { firstName }
    }`, `{"a": [{"firstName": "Bob"}], "b": [{"firstName": "Alice"}]}`,
        `{"a": [], "b": [{"firstName": "Alice"}]}`);
    // Each root field reads the rows of its own SQL query.
    checkFilteredWindow(`{
        a: users(first: 1, ` ~ byId ~ `, filter: {firstName: {equalTo: "Bob"}}) { firstName }
        b: users(first: 1, ` ~ byId ~ `) { firstName }
        c: users(` ~ byId ~ `, filter: {lastName: {in: ["Smith", "Brown"]}}) { firstName }
    }`, `{"a": [{"firstName": "Bob"}], "b": [{"firstName": "Alice"}], "c": [{"firstName": "Alice"}, {"firstName": "Charlie"}]}`,
        `{"a": [], "b": [{"firstName": "Alice"}], "c": [{"firstName": "Alice"}, {"firstName": "Charlie"}]}`);
}

private enum seededUsers = `lastName: {in: ["Smith", "Jones", "Brown"]}`;
private enum seededPosts = `title: {in: ["Hello World", "GraphQL Rocks", "D Programming"]}`;

/// Filters and orderings on computed fields (ComputedFieldsPlugin, applied
/// before the query plugins), combined with the window: evaluated in memory
/// where SQL cannot express them, never skipped, and with the window never
/// pushed beneath an in-memory filter or sort.  Seeded users: Alice Smith
/// (25, two posts), Bob Jones (15, one post), Charlie Brown (8, none).
void testFilteredWindowComputedInMemory() {
    // postCount: only computable in memory
    checkFilteredWindow(`{ users(first: 1, ` ~ byId ~ `, filter: {postCount: {equalTo: 1}}) { firstName } }`,
        `{"users": [{"firstName": "Bob"}]}`, `{"users": []}`);
    checkFilteredWindow(`{ users(first: 1, offset: 1, ` ~ byId ~ `, filter: {postCount: {greaterThan: 0}}) { firstName } }`,
        `{"users": [{"firstName": "Bob"}]}`, `{"users": [{"firstName": "Bob"}]}`);
    checkFilteredWindow(`{ users(first: 2, orderBy: [{field: postCount, direction: DESC}, {field: id, direction: ASC}]) { firstName } }`,
        `{"users": [{"firstName": "Alice"}, {"firstName": "Bob"}]}`,
        `{"users": [{"firstName": "Alice"}, {"firstName": "Bob"}]}`);
    checkFilteredWindow(`{ users(first: 1, offset: 1, filter: {` ~ seededUsers ~ `, postCount: {lessThan: 2}}, ` ~
            `orderBy: [{field: postCount, direction: ASC}]) { firstName } }`,
        `{"users": [{"firstName": "Bob"}]}`, null);

    // surnameFirst: an expression on columns, compared in memory
    checkFilteredWindow(`{ users(first: 1, ` ~ byId ~ `, filter: {surnameFirst: {startsWith: "Brown"}}) { firstName surnameFirst } }`,
        `{"users": [{"firstName": "Charlie", "surnameFirst": "Brown, Charlie"}]}`, `{"users": []}`);
    checkFilteredWindow(`{ users(first: 2, filter: {` ~ seededUsers ~ `}, orderBy: [{field: surnameFirst, direction: ASC}]) { firstName } }`,
        `{"users": [{"firstName": "Charlie"}, {"firstName": "Bob"}]}`, null);
}

/// The same with computed fields SQL can filter on (or sort by).
void testFilteredWindowComputedInSql() {
    // years: a column
    checkFilteredWindow(`{ users(first: 1, ` ~ byId ~ `, filter: {years: {lessThan: 10}}) { firstName } }`,
        `{"users": [{"firstName": "Charlie"}]}`, `{"users": []}`);
    checkFilteredWindow(`{ users(first: 2, filter: {` ~ seededUsers ~ `, years: {greaterThan: 10}}, ` ~
            `orderBy: [{field: years, direction: ASC}]) { firstName years } }`,
        `{"users": [{"firstName": "Bob", "years": 15}, {"firstName": "Alice", "years": 25}]}`, null);

    // authorAge: a related row's column (filtered in SQL, sorted in memory)
    checkFilteredWindow(`{ posts(first: 1, ` ~ byId ~ `, filter: {authorAge: {lessThan: 20}}) { title } }`,
        `{"posts": [{"title": "D Programming"}]}`, `{"posts": []}`);
    checkFilteredWindow(`{ posts(first: 2, filter: {` ~ seededPosts ~ `}, ` ~
            `orderBy: [{field: authorAge, direction: ASC}, {field: id, direction: DESC}]) { title authorAge } }`,
        `{"posts": [{"title": "D Programming", "authorAge": 15}, {"title": "GraphQL Rocks", "authorAge": 25}]}`, null);
    checkFilteredWindow(`{ posts(first: 1, offset: 1, filter: {` ~ seededPosts ~ `, authorAge: {greaterThan: 20}}, ` ~ byId ~ `) { title } }`,
        `{"posts": [{"title": "GraphQL Rocks"}]}`, null);
}

/// Computed fields of the root type (free functions written against Query):
/// a list root field whose own condition and the plugins' filter, ordering
/// and window apply (in SQL), with nested selections, and a root field over it.
void testComputedRootFields() {
    checkFilteredWindow(`{ usersExcept(firstName: "Bob", filter: {` ~ seededUsers ~ `}, ` ~ byId ~ `) ` ~
            `{ firstName posts(` ~ byId ~ `) { title } } }`,
        `{"usersExcept": [{"firstName": "Alice", "posts": [{"title": "Hello World"}, {"title": "GraphQL Rocks"}]}, ` ~
            `{"firstName": "Charlie", "posts": []}]}`, null);
    checkFilteredWindow(`{ usersExcept(firstName: "Alice", first: 1, filter: {` ~ seededUsers ~ `}, ` ~ byIdDesc ~ `) { firstName } }`,
        `{"usersExcept": [{"firstName": "Charlie"}]}`, null);

    auto response = graphql(`{ users { firstName } all: countExcept(firstName: "") notAlice: countExcept(firstName: "Alice") }`);
    assertNoErrors(response);
    auto users = response["data"]["users"].array;
    size_t alices;
    foreach (u; users)
        if (u["firstName"].str == "Alice")
            alices++;
    assertEqual(response["data"]["all"], JSONValue(cast(long) users.length), "countExcept over all users");
    assertEqual(response["data"]["notAlice"], JSONValue(cast(long) (users.length - alices)), "countExcept without Alices");
}

void testFilteredWindowNested() {
    checkFilteredWindow(`{ users(first: 1, ` ~ byId ~ `) { posts(first: 1, ` ~ byId ~ `, filter: {title: {includes: "Rocks"}}) { title } } }`,
        `{"users": [{"posts": [{"title": "GraphQL Rocks"}]}]}`, `{"users": [{"posts": []}]}`);
}

// ============================================================================
// Nested Relationship Filters
// ============================================================================

/// Seeded rows: users Alice Smith (25), Bob Jones (15), Charlie Brown (8);
/// posts "Hello World" and "GraphQL Rocks" by Alice, "D Programming" by Bob;
/// comments "Great post!" by Bob on "Hello World" and "Thanks for sharing"
/// by Charlie on "GraphQL Rocks"; tasks "Write tests" and "Review PR"
/// assigned to Alice, "Deploy app" to Bob.  Filters are restricted to the
/// seeded rows where other tests may add more.
private void checkNestedFilter(string query, string expectedDataJson) {
    foreach (order; ["default", "filter-last"]) {
        auto response = graphql(query, JSONValue.emptyObject, ["X-Plugin-Order": order]);
        assertNoErrors(response);
        assertEqual(response["data"], parseJSON(expectedDataJson), order ~ ": " ~ query);
    }
}

void testNestedBelongsToFilters() {
    checkNestedFilter(`{ comments(` ~ byId ~ `, filter: {post: {author: {firstName: {equalTo: "Alice"}}}}) { body } }`,
        `{"comments": [{"body": "Great post!"}, {"body": "Thanks for sharing"}]}`);
    checkNestedFilter(`{ comments(` ~ byId ~ `, filter: {post: {author: {age: {lessThan: 18}}}}) { body } }`,
        `{"comments": []}`);
    checkNestedFilter(`{ comments(` ~ byId ~ `, filter: {post: {title: {startsWith: "Hello"}}, author: {lastName: {equalTo: "Jones"}}}) { body } }`,
        `{"comments": [{"body": "Great post!"}]}`);
}

void testNestedToManyFilters() {
    checkNestedFilter(`{ users(` ~ byId ~ `, filter: {posts: {some: {comments: {some: {author: {firstName: {equalTo: "Bob"}}}}}}}) { firstName } }`,
        `{"users": [{"firstName": "Alice"}]}`);
    checkNestedFilter(`{ users(` ~ byId ~ `, filter: {posts: {some: {comments: {some: {body: {includes: "Thanks"}}}}}}) { firstName } }`,
        `{"users": [{"firstName": "Alice"}]}`);
    checkNestedFilter(`{ users(` ~ byId ~ `, filter: {lastName: {in: ["Smith", "Jones", "Brown"]}, ` ~
            `posts: {every: {comments: {some: {id: {isNull: false}}}}}}) { firstName } }`,
        `{"users": [{"firstName": "Alice"}, {"firstName": "Charlie"}]}`);
}

/// A computed field broadcasting a global root (every user) beneath a
/// client root of the same table which is filtered or windowed: the global
/// root still sees every row.
void testGlobalRootBeneathRestrictedRoot() {
    import std.algorithm : sort;

    foreach (restriction; [`filter: {firstName: {equalTo: "Alice"}}`, `first: 1, ` ~ byId]) {
        auto response = graphql(`{ all: users { firstName } users(` ~ restriction ~ `) { ` ~
            `firstName posts { comments { everyonesFirstNames } } } }`);
        assertNoErrors(response);
        string[] everyone;
        foreach (user; response["data"]["all"].array)
            everyone ~= user["firstName"].str;
        everyone.sort();
        auto users = response["data"]["users"].array;
        assertTrue(users.length == 1 && users[0]["firstName"].str == "Alice", response.toString());
        size_t comments;
        foreach (post; users[0]["posts"].array)
            foreach (comment; post["comments"].array) {
                string[] names;
                foreach (name; comment["everyonesFirstNames"].array)
                    names ~= name.str;
                names.sort();
                assertTrue(names == everyone, restriction ~ ": " ~ response.toString());
                comments++;
            }
        assertTrue(comments >= 2, "Expected Alice's seeded comments: " ~ response.toString());
    }
}

void testNestedMixedFilters() {
    // A belongs-to filter within a to-many filter, and the other way round.
    checkNestedFilter(`{ users(` ~ byId ~ `, filter: {posts: {some: {author: {age: {lessThan: 18}}}}}) { firstName } }`,
        `{"users": [{"firstName": "Bob"}]}`);
    checkNestedFilter(`{ comments(` ~ byId ~ `, filter: {post: {comments: {some: {author: {firstName: {equalTo: "Charlie"}}}}}}) { body } }`,
        `{"comments": [{"body": "Thanks for sharing"}]}`);
    checkNestedFilter(`{ posts(` ~ byId ~ `, filter: {title: {in: ["Hello World", "GraphQL Rocks", "D Programming"]}, ` ~
            `author: {posts: {some: {title: {like: "D%"}}}}}) { title } }`,
        `{"posts": [{"title": "D Programming"}]}`);
    // Through a nullable belongs-to: tasks without an assignee match nothing.
    checkNestedFilter(`{ tasks(` ~ byId ~ `, filter: {title: {in: ["Write tests", "Review PR", "Deploy app"]}, ` ~
            `assignee: {posts: {some: {title: {includes: "Rocks"}}}}}) { title } }`,
        `{"tasks": [{"title": "Write tests"}, {"title": "Review PR"}]}`);
    checkNestedFilter(`{ tasks(` ~ byId ~ `, filter: {title: {in: ["Write tests", "Review PR", "Deploy app"]}, ` ~
            `not: {assignee: {posts: {some: {title: {includes: "Rocks"}}}}}}) { title } }`,
        `{"tasks": [{"title": "Deploy app"}]}`);
    // Within a nested field's filter
    checkNestedFilter(`{ users(` ~ byId ~ `, filter: {firstName: {equalTo: "Alice"}}) { posts(` ~ byId ~
            `, filter: {comments: {some: {author: {age: {lessThan: 10}}}}}) { title } } }`,
        `{"users": [{"posts": [{"title": "GraphQL Rocks"}]}]}`);
}

void testLikeFilter() {
    checkNestedFilter(`{ posts(` ~ byId ~ `, filter: {title: {like: "%o_ld"}}) { title } }`,
        `{"posts": [{"title": "Hello World"}]}`);
    checkNestedFilter(`{ posts(` ~ byId ~ `, filter: {title: {like: "graphql%"}}) { title } }`,
        `{"posts": []}`);
}

// ============================================================================
// Unknown Input Object Fields
// ============================================================================

/// Input object fields their type does not define are validation errors,
/// with their locations, in literals and in variables.
void testUnknownInputFieldsRejected() {
    auto literal = graphql("{\n  posts(filter: {author: {firstNam: {equalTo: \"Alice\"}}}) { title }\n}");
    assertTrue("data" !in literal, "No data expected: " ~ literal.toString());
    assertEqual(literal["errors"], parseJSON(`[{"message": "Field \"firstNam\" is not defined by type \"UserFilter\".", ` ~
        `"locations": [{"line": 2, "column": 27}]}]`));

    auto variable = graphql("query($f: PostFilter) {\n  posts(filter: $f) { title }\n}",
        parseJSON(`{"f": {"author": {"posts": {"some": {"titel": {"equalTo": "x"}}}}}}`));
    assertTrue("data" !in variable, "No data expected: " ~ variable.toString());
    assertEqual(variable["errors"], parseJSON(`[{"message": "Variable \"$f\" got invalid value at ` ~
        `\"author.posts.some\"; Field \"titel\" is not defined by type \"PostFilter\".", ` ~
        `"locations": [{"line": 2, "column": 17}]}]`));

    // Mutation inputs too.
    auto mutation = graphql(`mutation { createPost(input: {title: "x", authorId: 1, published: true}) { id } }`);
    assertTrue("data" !in mutation, "No data expected: " ~ mutation.toString());
    assertTrue(mutation["errors"][0]["message"].str == `Field "published" is not defined by type "CreatePostInput".`,
        mutation.toString());
}

// ============================================================================
// Union / Interface (Abstract Type) Tests
// ============================================================================

void testUnionQueryWithTypedFragments() {
    auto response = graphql(`{
        search {
            __typename
            ... on User { firstName lastName }
            ... on Post { title }
        }
    }`);

    assertNoErrors(response);
    auto results = response["data"]["search"].array;
    // Should contain all 3 seeded users + 3 seeded posts (at least)
    assertTrue(results.length >= 5, "Expected at least 5 search results (3 users + 2+ posts), got " ~ results.length.to!string);

    int userCount = 0;
    int postCount = 0;
    foreach (item; results) {
        auto typeName = item["__typename"].str;
        if (typeName == "User") {
            userCount++;
            assertTrue(("firstName" in item) !is null, "User should have firstName");
            assertTrue(("lastName" in item) !is null, "User should have lastName");
        } else if (typeName == "Post") {
            postCount++;
            assertTrue(("title" in item) !is null, "Post should have title");
        } else {
            assertTrue(false, "Unexpected __typename: " ~ typeName);
        }
    }
    assertTrue(userCount >= 3, "Expected at least 3 users in search results, got " ~ userCount.to!string);
    assertTrue(postCount >= 2, "Expected at least 2 posts in search results, got " ~ postCount.to!string);
}

void testInterfaceQueryWithTypedFragments() {
    auto response = graphql(`{
        contentNodes {
            __typename
            id
            ... on User { firstName }
            ... on Post { title }
        }
    }`);

    assertNoErrors(response);
    auto results = response["data"]["contentNodes"].array;
    assertTrue(results.length >= 5, "Expected at least 5 content nodes, got " ~ results.length.to!string);

    foreach (item; results) {
        auto typeName = item["__typename"].str;
        assertTrue(typeName == "User" || typeName == "Post",
            "Expected User or Post, got " ~ typeName);
        // Interface field: id should be present on all items
        assertTrue(("id" in item) !is null, "ContentNode should have id field");
    }
}

void testUnionWithNamedFragmentsAndNestedSelection() {
    auto response = graphql(`
        query {
            search {
                __typename
                ...UserFields
                ...PostFields
            }
        }
        fragment UserFields on User {
            firstName
            fullName
        }
        fragment PostFields on Post {
            title
            author { firstName }
        }
    `);

    assertNoErrors(response);
    auto results = response["data"]["search"].array;
    assertTrue(results.length >= 5, "Expected at least 5 search results");

    bool foundUser = false;
    bool foundPostWithAuthor = false;
    foreach (item; results) {
        auto typeName = item["__typename"].str;
        if (typeName == "User") {
            foundUser = true;
            assertTrue(("firstName" in item) !is null, "User should have firstName");
            assertTrue(("fullName" in item) !is null, "User should have fullName");
        } else if (typeName == "Post") {
            assertTrue(("title" in item) !is null, "Post should have title");
            assertTrue(("author" in item) !is null, "Post should have author");
            auto author = item["author"];
            assertTrue(("firstName" in author) !is null, "Author should have firstName");
            if (author["firstName"].str.length > 0) foundPostWithAuthor = true;
        }
    }
    assertTrue(foundUser, "Expected at least one User in results");
    assertTrue(foundPostWithAuthor, "Expected at least one Post with nested author");
}

void testUnionIntrospection() {
    auto response = graphql(`{
        __type(name: "SearchResult") {
            kind
            possibleTypes { name }
        }
    }`);

    assertNoErrors(response);
    auto typeInfo = response["data"]["__type"];
    assertTrue(typeInfo["kind"].str == "UNION", "SearchResult should be UNION kind, got " ~ typeInfo["kind"].str);

    auto possibleTypes = typeInfo["possibleTypes"].array;
    assertTrue(possibleTypes.length == 2, "Expected 2 possibleTypes, got " ~ possibleTypes.length.to!string);

    bool foundUser = false;
    bool foundPost = false;
    foreach (pt; possibleTypes) {
        if (pt["name"].str == "User") foundUser = true;
        if (pt["name"].str == "Post") foundPost = true;
    }
    assertTrue(foundUser, "possibleTypes should contain User");
    assertTrue(foundPost, "possibleTypes should contain Post");
}

// ============================================================================
// Subscription Tests
// ============================================================================

void testSubscriptionUserCreated() {
    import core.thread : Thread;
    import core.time : msecs;

    // Result storage (heap-allocated, accessible from both threads)
    static class SubState {
        JSONValue result;
        string error;
    }
    auto state = new SubState();

    // Subscribe in background thread (blocks until event fires)
    auto subThread = new Thread({
        try {
            state.result = graphql(`subscription { userCreated { firstName } }`);
        } catch (Exception e) {
            state.error = e.msg;
        }
    });
    subThread.start();

    // Wait for subscription to register with the server
    Thread.sleep(200.msecs);

    // Send mutation — triggers event and unblocks subscription
    auto suffix = modeSuffix();
    auto firstName = "Sub" ~ suffix;
    auto mutResult = graphql(`mutation {
        createUserWithName(firstName: "` ~ firstName ~ `", lastName: "SubUser") { id }
    }`);
    assertNoErrors(mutResult);

    // Wait for subscription thread to complete
    subThread.join();

    assertTrue(state.error.length == 0,
        "Subscription failed: " ~ state.error);
    assertNoErrors(state.result);
    assertEqual(state.result["data"]["userCreated"]["firstName"],
        JSONValue(firstName));
}

/// A filter on an enum column selects the same rows whether it is pushed
/// into SQL or evaluated in memory: values are stored under their labels
/// (the D name, or an explicit `@StoredAs` label), whatever their case.
void testFilterByEnum() {
    foreach (status, title; ["inProgress": "Review PR", "completed": "Deploy app"]) {
        auto response = graphql(`{ tasks(filter: {status: {equalTo: ` ~ status ~ `}}) { title status } }`);
        assertNoErrors(response);
        auto tasks = response["data"]["tasks"].array;
        bool found;
        foreach (task; tasks) {
            assertEqual(task["status"], JSONValue(status));
            if (task["title"].str == title)
                found = true;
        }
        assertTrue(found, "Expected task " ~ title ~ " with status " ~ status ~ ", got " ~ tasks.to!string);
    }
}

/// A filter over a mapped collection (each post's author) selects mapped
/// elements; it is not a condition on the root rows (the posts) even where
/// both have a column of that name.
void testFilterOverNonRowPreservingMap() {
    auto posts = graphql(`{ posts { id author { id firstName } } }`);
    assertNoErrors(posts);
    size_t[string] authoredBy;
    string[string] nameOf;
    foreach (post; posts["data"]["posts"].array) {
        auto id = post["author"]["id"];
        auto authorId = JSONValue(id.type == JSONType.string ? id.str : id.toString()).toString();
        authoredBy[authorId]++;
        nameOf[authorId] = post["author"]["firstName"].str;
    }
    assertTrue(authoredBy.length >= 2, "Expected posts by at least 2 authors");
    foreach (authorId, count; authoredBy) {
        auto response = graphql(`{ postAuthors(filter: {id: {equalTo: ` ~ authorId ~ `}}) { id firstName } }`);
        assertNoErrors(response);
        auto authors = response["data"]["postAuthors"].array;
        assertEqual(JSONValue(authors.length), JSONValue(count),
            "Number of post authors with id " ~ authorId ~ ": " ~ authors.to!string);
        foreach (author; authors)
            assertEqual(author["firstName"], JSONValue(nameOf[authorId]));

        auto byName = graphql(`{ postAuthors(filter: {firstName: {equalTo: "` ~ nameOf[authorId] ~ `"}}) { id firstName } }`);
        assertNoErrors(byName);
        auto named = byName["data"]["postAuthors"].array;
        assertEqual(JSONValue(named.length), JSONValue(count),
            "Number of post authors named " ~ nameOf[authorId] ~ ": " ~ named.to!string);
        foreach (author; named)
            assertEqual(author["firstName"], JSONValue(nameOf[authorId]));
    }
}

// ============================================================================
// Sorting by nullable and enum columns
// ============================================================================

/// The position of a task status (as GraphQL names it) in the order of
/// TaskStatus's declaration, by which tasks sort (not by their stored
/// labels: "done" for completed sorts between "cancelled" and "inProgress").
private long taskStatusRank(string status) {
    import std.algorithm.searching : countUntil;
    auto rank = ["pending", "inProgress", "completed", "cancelled"].countUntil(status);
    assertTrue(rank >= 0, "Unknown task status " ~ status);
    return rank;
}

/// Compare two tasks by `key` ("priority": nullable, NULL as the greatest
/// value, as PostgreSQL orders it; "status": by declaration order).
private int compareTasks(JSONValue a, JSONValue b, string key) {
    if (key == "status") {
        auto x = taskStatusRank(a["status"].str), y = taskStatusRank(b["status"].str);
        return x < y ? -1 : x > y ? 1 : 0;
    }
    auto aNull = a[key].type == JSONType.null_, bNull = b[key].type == JSONType.null_;
    if (aNull || bNull)
        return aNull == bNull ? 0 : aNull ? 1 : -1;
    auto x = a[key].integer, y = b[key].integer;
    return x < y ? -1 : x > y ? 1 : 0;
}

/// The IDs of `tasks` (as a query returned them) sorted by the keys (key,
/// descending), then by ID (as the query's last key).
private long[] expectedTaskOrder(JSONValue[] tasks, string[] keys, bool[] descending) {
    import std.algorithm.sorting : sort;
    import std.algorithm.iteration : map;
    import std.array : array;
    auto sorted = tasks.dup;
    sorted.sort!((a, b) {
        foreach (i, key; keys) {
            auto c = compareTasks(a, b, key);
            if (c != 0)
                return descending[i] ? c > 0 : c < 0;
        }
        return a["id"].integer < b["id"].integer;
    });
    return sorted.map!(t => t["id"].integer).array;
}

private long[] taskIdsOf(JSONValue[] tasks) {
    long[] ids;
    foreach (t; tasks)
        ids ~= t["id"].integer;
    return ids;
}

/// Sorting by a nullable column (NULL last ascending, first descending) and
/// an enum column (in declaration order), at the root (sorted by the
/// database) and in a relationship (sorted in memory): both orders are
/// PostgreSQL's, and agree.
void testSortByNullableAndEnumColumns() {
    import std.format : format;
    // (The keys, and the directions of the cases)
    auto cases = [
        ["priority"], ["status"], ["status", "priority"], ["priority", "status"],
    ];
    foreach (keys; cases) {
        foreach (directions; [[false, false], [true, true], [false, true], [true, false]]) {
            string orderBy;
            foreach (i, key; keys)
                orderBy ~= format("{field: %s, direction: %s}, ", key, directions[i] ? "DESC" : "ASC");
            orderBy ~= "{field: id, direction: ASC}";
            auto response = graphql(`{
                tasks(orderBy: [` ~ orderBy ~ `]) { id priority status assigneeId }
                users(orderBy: [{field: id, direction: ASC}]) {
                    id
                    tasks(orderBy: [` ~ orderBy ~ `]) { id priority status }
                }
            }`);
            assertNoErrors(response);
            auto tasks = response["data"]["tasks"].array;
            assertTrue(tasks.length >= 3, "Expected at least 3 tasks");
            auto expected = expectedTaskOrder(tasks, keys, directions[0 .. keys.length]);
            assertTrue(taskIdsOf(tasks) == expected, "Root tasks sorted by " ~ orderBy ~ ": got " ~
                taskIdsOf(tasks).to!string ~ ", expected " ~ expected.to!string);

            // The tasks of each user, sorted in memory, in the order of the
            // root list (sorted by the database)
            foreach (user; response["data"]["users"].array) {
                long[] fromRoot;
                foreach (t; tasks)
                    if (t["assigneeId"].type != JSONType.null_ && t["assigneeId"].integer == user["id"].integer)
                        fromRoot ~= t["id"].integer;
                assertTrue(taskIdsOf(user["tasks"].array) == fromRoot, "Tasks of user " ~ user["id"].toString() ~
                    " sorted by " ~ orderBy ~ ": got " ~ taskIdsOf(user["tasks"].array).to!string ~
                    ", expected (as at the root) " ~ fromRoot.to!string);
            }
        }
    }
}

/// Sorting by a nullable column needs data where it is null and not null.
void testSortByNullableColumnSeeded() {
    auto response = graphql(`{ tasks(orderBy: [{field: priority, direction: ASC}, {field: id, direction: ASC}]) { priority } }`);
    assertNoErrors(response);
    auto tasks = response["data"]["tasks"].array;
    bool seenNull, nullFirst = tasks.length && tasks[0]["priority"].type == JSONType.null_;
    foreach (t; tasks)
        seenNull |= t["priority"].type == JSONType.null_;
    assertTrue(seenNull, "Expected a task without a priority");
    assertTrue(!nullFirst, "NULL priorities should come last ascending");
}

/// The string operators (PostGraphile's connection filter's) select, in the
/// database's queries, the rows their in-memory evaluation does: literal
/// operands with wildcards escaped, LIKE patterns, case-insensitivity and
/// negation.
void testStringFilterOperators() {
    import std.algorithm.sorting : sort;
    import std.uni : toLower;
    import dunamis.core.expr.operators : escapeLikePattern, likeMatch;

    auto all = graphql(`{ posts { id title } }`);
    assertNoErrors(all);
    auto posts = all["data"]["posts"].array;
    assertTrue(posts.length >= 3, "Expected at least 3 posts");

    // (operator, operand, the LIKE pattern it matches, case-insensitive, negated)
    static struct Case { string op, operand, pattern; bool insensitive, negated; }
    Case[] cases;
    foreach (operand; ["o", "O", "GraphQL", "%", "_", "D Programming"]) {
        auto literal = escapeLikePattern(operand);
        foreach (insensitive; [false, true])
            foreach (negated; [false, true]) {
                string name(string base) {
                    auto n = base ~ (insensitive ? "Insensitive" : "");
                    return negated ? "not" ~ cast(char)(n[0] - 'a' + 'A') ~ n[1 .. $] : n;
                }
                cases ~= Case(name("includes"), operand, "%" ~ literal ~ "%", insensitive, negated);
                cases ~= Case(name("startsWith"), operand, literal ~ "%", insensitive, negated);
                cases ~= Case(name("endsWith"), operand, "%" ~ literal, insensitive, negated);
                if (insensitive)
                    cases ~= Case(name("equalTo"), operand, literal, insensitive, negated);
            }
    }
    foreach (pattern; ["%o%", "G%", "%_o%", "D_Programming", "%\\_%"])
        foreach (insensitive; [false, true])
            foreach (negated; [false, true]) {
                auto n = "like" ~ (insensitive ? "Insensitive" : "");
                cases ~= Case(negated ? "notL" ~ n[1 .. $] : n, pattern, pattern, insensitive, negated);
            }

    foreach (c; cases) {
        auto literal = JSONValue(c.operand).toString();
        // (As a variable: the query lexer does not take every escape)
        auto response = graphql(`query($v: String!) { posts(filter: {title: {` ~ c.op ~ `: $v}}) { id } }`,
            JSONValue(["v": c.operand]));
        assertNoErrors(response);
        long[] found, expected;
        foreach (p; response["data"]["posts"].array)
            found ~= p["id"].integer;
        foreach (p; posts) {
            auto title = p["title"].str;
            bool match = c.insensitive ? likeMatch(title.toLower, c.pattern.toLower) : likeMatch(title, c.pattern);
            if (match != c.negated)
                expected ~= p["id"].integer;
        }
        found.sort();
        expected.sort();
        assertTrue(found == expected, c.op ~ ": " ~ literal ~ ": got " ~ found.to!string ~ ", expected " ~
            expected.to!string);
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
    registerTest("Filter over a map of each post's author", "tests", &testFilterOverNonRowPreservingMap);
    registerTest("Filter by an enum column", "tests", &testFilterByEnum);
    registerTest("Query computed field (fullName)", "tests", &testQueryComputedField);
    registerTest("Mutation: create user", "tests", &testCreateUser);
    registerTest("Mutation persistence", "tests", &testMutationPersistence);

    // Enum tests
    registerTest("Query tasks with enum status", "tests", &testQueryTasksWithEnumStatus);
    registerTest("Query task fields", "tests", &testQueryTaskFields);
    registerTest("Query task with nullable assignee", "tests", &testQueryTaskWithNullableAssignee);
    registerTest("Nullable object with a required belongs-to", "tests", &testNullableObjectWithRequiredBelongsTo);
    registerTest("Mutation: create task with enum", "tests", &testCreateTaskWithEnumStatus);
    registerTest("Enum persistence", "tests", &testEnumPersistence);

    // Sorting tests
    registerTest("Sort users ascending", "tests", &testSortUsersAscending);
    registerTest("Sort users descending", "tests", &testSortUsersDescending);
    registerTest("Sort posts by title", "tests", &testSortPostsByTitle);
    registerTest("Sort tasks by title", "tests", &testSortTasksByTitle);
    registerTest("Sort without orderBy", "tests", &testSortWithoutOrderBy);
    registerTest("Sort by a nullable column (seeded)", "tests", &testSortByNullableColumnSeeded);
    registerTest("Sort by nullable and enum columns", "tests", &testSortByNullableAndEnumColumns);

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

    // HasMany nested under BelongsTo
    registerTest("HasMany under BelongsTo (id only / with column)", "tests", &testHasManyUnderBelongsTo);
    registerTest("HasMany under BelongsTo with filtered root", "tests", &testHasManyUnderBelongsToFilteredRoot);
    registerTest("HasMany under root (id only / with column)", "tests", &testHasManyUnderRoot);

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
    registerTest("Filter includesInsensitive", "tests", &testFilterIncludesInsensitive);
    registerTest("String filter operators", "tests", &testStringFilterOperators);
    registerTest("Filter startsWithInsensitive", "tests", &testFilterStartsWithInsensitive);
    registerTest("Root filter, sort and window without selected columns", "tests", &testRootFilterWithoutSelectedColumns);
    registerTest("Filter endsWithInsensitive", "tests", &testFilterEndsWithInsensitive);
    registerTest("Filter case-sensitive vs insensitive", "tests", &testFilterCaseSensitiveVsInsensitive);

    // Request context tests
    registerTest("Request context greeting (French)", "tests", &testRequestContextGreeting);
    registerTest("Request context default locale", "tests", &testRequestContextDefaultLocale);
    registerTest("Request context greeting (Spanish)", "tests", &testRequestContextSpanishLocale);

    // Error path tracking tests
    registerTest("Field error returns partial result", "tests", &testFieldErrorPartialResult);
    registerTest("Field error has correct path", "tests", &testFieldErrorPath);
    registerTest("Non-null field error nulls the whole response data", "tests", &testNonNullFieldErrorNullsData);
    registerTest("Field error beside an in-flight sibling input", "tests", &testFieldErrorBesideInFlightSibling);

    // Composite primary key tests
    registerTest("Query all tags (composite PK)", "tests", &testQueryAllTags);
    registerTest("Query tags by category", "tests", &testQueryTagsByCategory);
    registerTest("Query tag values", "tests", &testQueryTagValues);
    registerTest("Create tag mutation (composite PK)", "tests", &testCreateTagMutation);
    registerTest("Query all user badges (composite PK)", "tests", &testQueryAllUserBadges);
    registerTest("Query user badge values", "tests", &testQueryUserBadgeValues);
    registerTest("Create user badge mutation (composite PK)", "tests", &testCreateUserBadgeMutation);
    registerTest("HasMany and BelongsTo with composite-key children", "tests", &testUserBadgesRelation);
    registerTest("Root table ordered by columns, beneath sorts and windows", "tests", &testUserBadgesTableOrder);
    registerTest("Composite PK persistence", "tests", &testCompositePkPersistence);
    registerTest("Sort tags by name (composite PK)", "tests", &testSortTagsByName);
    registerTest("Filter tags by category (composite PK)", "tests", &testFilterTagsByCategory);
    registerTest("Filtered window: scalar filter", "tests", &testFilteredWindowScalar);
    registerTest("Filtered window: belongsTo filter", "tests", &testFilteredWindowBelongsTo);
    registerTest("Filtered window: hasMany some/every/none", "tests", &testFilteredWindowHasMany);
    registerTest("Filtered window: scalar and relationship filter", "tests", &testFilteredWindowScalarAndRelationship);
    registerTest("Filtered window: same table twice", "tests", &testFilteredWindowSameTableTwice);
    registerTest("Filtered window: nested field", "tests", &testFilteredWindowNested);
    registerTest("Filtered window: computed fields in memory", "tests", &testFilteredWindowComputedInMemory);
    registerTest("Filtered window: computed fields in SQL", "tests", &testFilteredWindowComputedInSql);
    registerTest("Computed root fields", "tests", &testComputedRootFields);
    registerTest("Nested filters: belongs-to within belongs-to", "tests", &testNestedBelongsToFilters);
    registerTest("Nested filters: to-many within to-many", "tests", &testNestedToManyFilters);
    registerTest("Nested filters: belongs-to and to-many mixed", "tests", &testNestedMixedFilters);
    registerTest("Global root beneath a restricted root of its table", "tests", &testGlobalRootBeneathRestrictedRoot);
    registerTest("Filter: like", "tests", &testLikeFilter);
    registerTest("Unknown input object fields are rejected", "tests", &testUnknownInputFieldsRejected);

    // Union / Interface (abstract type) tests
    registerTest("Union query with typed fragments", "tests", &testUnionQueryWithTypedFragments);
    registerTest("Interface query with typed fragments", "tests", &testInterfaceQueryWithTypedFragments);
    registerTest("Union with named fragments and nested selection", "tests", &testUnionWithNamedFragmentsAndNestedSelection);
    registerTest("Union introspection via __type", "tests", &testUnionIntrospection);

    // Subscription tests
    registerTest("Subscription: userCreated fires on mutation", "tests", &testSubscriptionUserCreated);
}

// ============================================================================
// Evaluating one optimized tree for interleaved requests
// ============================================================================

/// The server compiles and optimizes each query once, optimizes another
/// query in between (as a concurrent request would), and evaluates the same
/// tree for several requests concurrently, interleaved so that every request
/// has bound its objects before any reads them. Each request must see only
/// its own data. Covers non-null and nullable objects, nullable lists, SQL
/// computed columns, mutation-returned entities and SubscriptionExecutor
/// redeliveries. (Needs concurrent sessions, so only registered for
/// PostgreSQL.)
void testInterleavedEvaluationsOfOneTree() {
    import std.algorithm : sort;
    import std.array : array;

    static string[] sorted(JSONValue[] values) {
        string[] result;
        foreach (v; values)
            result ~= v.str;
        return result.sort.array;
    }
    static void assertClean(JSONValue result) {
        assertTrue(result["errors"].array.length == 0, "Errors: " ~ result["errors"].toString());
    }

    auto known = graphql(`{
        users { id firstName fullName posts { id } }
        tasks { id title assignee { firstName } }
    }`);
    assertNoErrors(known);
    JSONValue[string] userByName, taskByTitle;
    JSONValue[] fullNames;
    foreach (user; known["data"]["users"].array) {
        userByName[user["firstName"].str] = user;
        fullNames ~= user["fullName"];
    }
    foreach (task; known["data"]["tasks"].array)
        taskByTitle[task["title"].str] = task;

    // Queries
    auto viewings = [
        ["Alice", "Write tests"],
        ["Bob", "Deploy app"],
        ["Charlie", "Review PR"],
    ];
    JSONValue[] viewingInputs;
    foreach (v; viewings)
        viewingInputs ~= JSONValue([
            "userId": userByName[v[0]]["id"],
            "taskId": taskByTitle[v[1]]["id"],
        ]);
    foreach (round; 0 .. 2) {
        auto results = graphqlInterleaved(JSONValue([
            "query": JSONValue(`{
                viewer { gatedId gatedFirstName gatedPostLabels { text } }
                viewerTask { gatedTitle gatedAssignee { gatedFirstName } }
                users { fullName }
            }`),
            "distractor": JSONValue(`{ users { isAdult } }`),
            "viewings": JSONValue(viewingInputs),
        ]));
        assertTrue(results.length == viewings.length, "Expected one result per viewing");
        foreach (i, v; viewings) {
            assertClean(results[i]);
            auto data = results[i]["data"];
            auto user = userByName[v[0]], task = taskByTitle[v[1]];
            auto postCount = user["posts"].array.length;
            assertEqual(data["viewer"], JSONValue([
                "gatedId": user["id"],
                "gatedFirstName": JSONValue(v[0]),
                "gatedPostLabels": postCount == 0 ? JSONValue(null) :
                    JSONValue([JSONValue(["text": JSONValue(v[0] ~ ": " ~ postCount.to!string)])]),
            ]), "viewer of " ~ v[0]);
            assertEqual(data["viewerTask"], JSONValue([
                "gatedTitle": JSONValue(v[1]),
                "gatedAssignee": task["assignee"].type == JSONType.null_ ? JSONValue(null) :
                    JSONValue(["gatedFirstName": task["assignee"]["firstName"]]),
            ]), "viewerTask " ~ v[1]);
            JSONValue[] gotFullNames;
            foreach (u; data["users"].array)
                gotFullNames ~= u["fullName"];
            assertTrue(sorted(gotFullNames) == sorted(fullNames),
                "users { fullName }: " ~ data["users"].toString());
        }
    }

    // Subscription redeliveries
    auto subscriptionResults = graphqlInterleaved(JSONValue([
        "query": JSONValue(`subscription { userCreated { gatedId gatedFirstName everyonesFullName } }`),
        "distractor": JSONValue(`{ users { isAdult } }`),
        "events": JSONValue([userByName["Alice"]["id"], userByName["Bob"]["id"]]),
    ]));
    foreach (i, name; ["Alice", "Bob"]) {
        assertClean(subscriptionResults[i]);
        auto event = subscriptionResults[i]["data"]["userCreated"];
        assertEqual(event["gatedId"], userByName[name]["id"], "event " ~ name);
        assertEqual(event["gatedFirstName"], JSONValue(name), "event " ~ name);
        assertTrue(sorted(event["everyonesFullName"].array) == sorted(fullNames),
            "everyonesFullName: " ~ event["everyonesFullName"].toString());
    }

    // Mutation-returned entities
    auto firstName = "Interleaved" ~ modeSuffix();
    auto mutationResults = graphqlInterleaved(JSONValue([
        "query": JSONValue(`mutation { createUserWithName(firstName: "` ~ firstName ~
            `", lastName: "Twice") { gatedId gatedFirstName } }`),
        "viewings": JSONValue(viewingInputs[0 .. 2]),
    ]));
    JSONValue[] createdIds;
    foreach (result; mutationResults) {
        assertClean(result);
        auto created = result["data"]["createUserWithName"];
        assertEqual(created["gatedFirstName"], JSONValue(firstName));
        createdIds ~= created["gatedId"];
    }
    assertTrue(createdIds[0] != createdIds[1],
        "Both evaluations returned the same created user: " ~ createdIds[0].toString());
}

// ============================================================================
// Procedures (perform, evaluateNested) and atomic mutation fields
// ============================================================================

/// A procedure's nested evaluation sees its write; a mutation field which
/// fails is undone, the fields before it are not (PostgreSQL: savepoints).
void testProceduresAndAtomicMutationFields() {
    auto before = graphql(`{ users { id } }`);
    assertNoErrors(before);
    auto count = before["data"]["users"].array.length;
    auto kept = "Kept" ~ modeSuffix(), undone = "Undone" ~ modeSuffix();

    auto response = graphql(`mutation {
        kept: createUserAndCount(firstName: "` ~ kept ~ `", fail: false)
        undone: createUserAndCount(firstName: "` ~ undone ~ `", fail: true)
    }`);
    // createUserAndCount is non-null, so the failure nulls the data
    assertTrue(response["data"].type == JSONType.null_, "Expected null data: " ~ response.toString());
    assertTrue(response["errors"].array.length == 1, "Expected one error: " ~ response.toString());
    assertEqual(response["errors"][0]["path"], JSONValue([JSONValue("undone")]));

    auto ok = graphql(`mutation { counted: createUserAndCount(firstName: "` ~ kept ~ `2", fail: false) }`);
    assertNoErrors(ok);
    // The first and this one are counted, not the undone one
    assertEqual(ok["data"]["counted"], JSONValue(count + 2));

    auto after = graphql(`{ users { firstName } }`);
    assertNoErrors(after);
    bool[string] names;
    foreach (user; after["data"]["users"].array)
        names[user["firstName"].str] = true;
    assertTrue((kept in names) !is null, "The first field's user should exist");
    assertTrue((undone in names) is null, "The failed field's user should not exist");
}

/// Nested evaluations of different trees on one session see their own results
void testNestedEvaluationsOfDifferentTrees() {
    auto direct = graphql(`{ users { id } posts { id } }`);
    assertNoErrors(direct);
    auto expected = direct["data"]["users"].array.length.to!string ~ " users, " ~
        direct["data"]["posts"].array.length.to!string ~ " posts";
    auto response = graphql(`mutation { nestedCounts users: createUserWithName(firstName: "Nested", lastName: "` ~ modeSuffix() ~ `") { id } }`);
    assertNoErrors(response);
    assertEqual(response["data"]["nestedCounts"], JSONValue(expected));
}

/// The columns of an entity with a composite key returned by a mutation
/// field are read by its key
void testCompositeKeyEntityOfMutation() {
    auto badgeName = "keyed-" ~ modeSuffix();
    assertNoErrors(graphql(`mutation {
        createUserBadge(userId: 1, badgeName: "` ~ badgeName ~ `", description: "Keyed") { badgeName }
    }`));
    auto response = graphql(`mutation { badgeByKey(userId: 1, badgeName: "` ~ badgeName ~ `") { badgeName description } }`);
    assertNoErrors(response);
    assertEqual(response["data"]["badgeByKey"], JSONValue([
        "badgeName": JSONValue(badgeName), "description": JSONValue("Keyed")]));
    auto list = graphql(`mutation { badgesByKeys(userId: 1, badgeNames: ["` ~ badgeName ~ `", ""]) { badgeName description } }`);
    assertNoErrors(list);
    assertEqual(list["data"]["badgesByKeys"], JSONValue([JSONValue([
        "badgeName": JSONValue(badgeName), "description": JSONValue("Keyed")]), JSONValue(null)]));
}
