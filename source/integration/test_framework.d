/**
 * Integration Test Framework
 *
 * Provides utilities for defining and running integration tests:
 * - Test registration via @Test UDA
 * - HTTP client for GraphQL requests
 * - JSON comparison with helpful diffs
 * - Test runner with reporting
 */
module integration.test_framework;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.stdio;
import std.string;

// ============================================================================
// Test Registration
// ============================================================================

/// UDA to mark a function as a test
struct Test {
    string name;
}

/// Collected test information
struct TestInfo {
    string name;
    string moduleName;
    void function() func;
}

/// Global test registry
__gshared TestInfo[] registeredTests;

/// Register a test function (prevents duplicates)
void registerTest(string name, string moduleName, void function() func) {
    // Check if already registered (prevent duplicate registration)
    foreach (t; registeredTests) {
        if (t.name == name && t.moduleName == moduleName) {
            return;  // Already registered
        }
    }
    registeredTests ~= TestInfo(name, moduleName, func);
}

// ============================================================================
// Test Results
// ============================================================================

struct TestResult {
    string name;
    bool passed;
    string error;
    long durationMs;
}

struct TestResults {
    TestResult[] results;

    @property size_t passed() {
        return results.count!(r => r.passed);
    }

    @property size_t failed() {
        return results.count!(r => !r.passed);
    }

    @property bool allPassed() {
        return failed == 0;
    }

    @property long totalDurationMs() {
        return results.map!(r => r.durationMs).sum;
    }

    void print() {
        writeln();
        writeln("═══════════════════════════════════════════════════════════════");
        writefln("  Test Results: %d passed, %d failed (%.2fs)",
            passed, failed, totalDurationMs / 1000.0);
        writeln("═══════════════════════════════════════════════════════════════");
        writeln();

        foreach (r; results) {
            if (r.passed) {
                writefln("  ✓ %s (%.0fms)", r.name, r.durationMs);
            } else {
                writefln("  ✗ %s (%.0fms)", r.name, r.durationMs);
                // Indent error message
                foreach (line; r.error.splitLines) {
                    writefln("      %s", line);
                }
            }
        }

        writeln();
        if (allPassed) {
            writeln("  All tests passed!");
        } else {
            writefln("  %d test(s) failed.", failed);
        }
        writeln();
    }
}

// ============================================================================
// Test Runner
// ============================================================================

/// Run tests with a specific optimization mode
private TestResults runTestsWithMode(bool optimize) {
    import core.time : MonoTime;

    currentOptimizeMode = optimize;
    TestResults results;

    foreach (test; registeredTests) {
        write("  Running: ", test.name, " ... ");
        stdout.flush();

        auto startTime = MonoTime.currTime;
        TestResult result;
        result.name = test.name;

        try {
            test.func();
            result.passed = true;
            writeln("✓");
        } catch (AssertError e) {
            result.passed = false;
            result.error = e.msg;
            writeln("✗");
        } catch (Exception e) {
            result.passed = false;
            result.error = e.msg;
            writeln("✗");
        }

        auto endTime = MonoTime.currTime;
        result.durationMs = (endTime - startTime).total!"msecs";
        results.results ~= result;
    }

    return results;
}

/// Run all registered tests in both optimized and unoptimized modes
TestResults runAllTests() {
    TestResults combinedResults;

    // Run with optimization enabled
    writeln();
    writeln("───────────────────────────────────────────────────────────────");
    writeln("  Running tests WITH optimization");
    writeln("───────────────────────────────────────────────────────────────");
    writeln();
    auto optimizedResults = runTestsWithMode(true);

    // Copy results with mode prefix
    foreach (r; optimizedResults.results) {
        TestResult prefixed = r;
        prefixed.name = "[optimized] " ~ r.name;
        combinedResults.results ~= prefixed;
    }

    // Run without optimization
    writeln();
    writeln("───────────────────────────────────────────────────────────────");
    writeln("  Running tests WITHOUT optimization (naive path)");
    writeln("───────────────────────────────────────────────────────────────");
    writeln();
    auto unoptimizedResults = runTestsWithMode(false);

    // Copy results with mode prefix
    foreach (r; unoptimizedResults.results) {
        TestResult prefixed = r;
        prefixed.name = "[naive] " ~ r.name;
        combinedResults.results ~= prefixed;
    }

    return combinedResults;
}

// ============================================================================
// GraphQL Client
// ============================================================================

private __gshared string graphqlEndpoint = "http://localhost:8080/graphql";

/// Current optimization mode for tests (controlled by runAllTests)
__gshared bool currentOptimizeMode = true;

/// Set the GraphQL endpoint URL
void setGraphQLEndpoint(string url) {
    graphqlEndpoint = url;
}

/// Execute a GraphQL query/mutation and return the parsed response
/// Uses the current optimization mode set by runAllTests
JSONValue graphql(string query, JSONValue variables = JSONValue.emptyObject) {
    import std.net.curl : HTTP, CurlException;
    import std.exception : enforce;

    auto http = HTTP(graphqlEndpoint);
    http.addRequestHeader("Content-Type", "application/json");
    http.addRequestHeader("X-Optimize", currentOptimizeMode ? "true" : "false");

    auto requestBody = JSONValue([
        "query": JSONValue(query),
        "variables": variables
    ]);

    http.setPostData(requestBody.toString(), "application/json");

    string responseBody;
    http.onReceive = (ubyte[] data) {
        responseBody ~= cast(string) data;
        return data.length;
    };

    http.perform();

    auto statusCode = http.statusLine.code;
    enforce(statusCode == 200,
        "GraphQL request failed with status " ~ statusCode.to!string ~ ": " ~ responseBody);

    return parseJSON(responseBody);
}

// ============================================================================
// Assertions
// ============================================================================

class AssertError : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/// Assert that two JSON values are equal
void assertEqual(JSONValue actual, JSONValue expected, string msg = null) {
    if (actual != expected) {
        string error = msg ? msg ~ "\n" : "";
        error ~= "Expected:\n" ~ prettyPrint(expected) ~ "\n";
        error ~= "Actual:\n" ~ prettyPrint(actual);
        throw new AssertError(error);
    }
}

/// Assert that a JSON value equals the given JSON string
void assertEqual(JSONValue actual, string expectedJson, string msg = null) {
    assertEqual(actual, parseJSON(expectedJson), msg);
}

/// Assert that the response has no errors
void assertNoErrors(JSONValue response) {
    if ("errors" in response) {
        auto errors = response["errors"].array;
        if (errors.length > 0) {
            string msg = "GraphQL errors:\n";
            foreach (e; errors) {
                msg ~= "  - " ~ e["message"].str ~ "\n";
            }
            throw new AssertError(msg);
        }
    }
}

/// Assert that response.data equals expected
void assertData(JSONValue response, string expectedDataJson) {
    assertNoErrors(response);
    if ("data" !in response) {
        throw new AssertError("Response has no 'data' field");
    }
    assertEqual(response["data"], parseJSON(expectedDataJson));
}

/// Assert that response.data.field equals expected
void assertField(JSONValue response, string field, JSONValue expected) {
    assertNoErrors(response);
    if ("data" !in response) {
        throw new AssertError("Response has no 'data' field");
    }
    auto data = response["data"];
    if (field !in data) {
        throw new AssertError("Response data has no '" ~ field ~ "' field");
    }
    assertEqual(data[field], expected);
}

/// Assert that a condition is true
void assertTrue(bool condition, lazy string msg = "Assertion failed") {
    if (!condition) {
        throw new AssertError(msg);
    }
}

/// Assert that a value is not null
void assertNotNull(T)(T value, lazy string msg = "Value is null") {
    static if (is(T == JSONValue)) {
        if (value.isNull) {
            throw new AssertError(msg);
        }
    } else static if (is(T == class) || is(T == U*, U)) {
        if (value is null) {
            throw new AssertError(msg);
        }
    }
}

// ============================================================================
// JSON Utilities
// ============================================================================

/// Pretty print JSON with indentation
string prettyPrint(JSONValue json, int indent = 2) {
    return json.toPrettyString();
}

/// Parse JSON string, throwing a helpful error on failure
JSONValue parseJSON(string s) {
    import std.json : parseJSON, JSONException;
    try {
        return std.json.parseJSON(s);
    } catch (JSONException e) {
        throw new AssertError("Invalid JSON: " ~ e.msg ~ "\nInput: " ~ s);
    }
}
