/**
 * Integration Tests
 *
 * GraphQL query and mutation tests run against a real database.
 */
module integration.tests;

import std.json;
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
}
