module graphqld2.postgres.connection;

import ae.net.asockets : socketManager;
import ae.net.db.psql;
import ae.utils.promise;

/// Connect to PostgreSQL and return a connection.
/// Uses the ae.net.db.psql library for async PostgreSQL access.
///
/// The connection uses the ae event loop (socketManager.loop()).
/// After the promise resolves, the connection is ready for queries.
///
/// Example:
///   connect("localhost", 5432, "mydb", "user", "pass").then((conn) {
///       conn.query("SELECT 1").array().then((rows) { ... });
///   });
Promise!PgSqlConnection connect(string host, ushort port, string database,
                                 string user, string password) {
    auto conn = new PgSqlConnection(host, port, user, database, password);

    // Return promise that resolves when connection is ready
    return conn.ready.then((_) => conn);
}

/// Connect to PostgreSQL using a connection string.
/// Format: postgresql://user:password@host:port/database
Promise!PgSqlConnection connectFromUri(string uri) {
    import std.uri : decodeComponent;
    import std.conv : to;

    // Parse postgresql://user:password@host:port/database
    if (uri.length < 14 || uri[0..14] != "postgresql://") {
        auto p = new Promise!PgSqlConnection;
        p.reject(new Exception("Invalid connection string: must start with postgresql://"));
        return p;
    }

    auto rest = uri[14..$];

    // Split on @ to separate credentials from host
    auto atIdx = rest.indexOf('@');
    string userPass, hostPart;
    if (atIdx >= 0) {
        userPass = rest[0..atIdx];
        hostPart = rest[atIdx+1..$];
    } else {
        userPass = "";
        hostPart = rest;
    }

    // Parse user:password
    string user, password;
    auto colonIdx = userPass.indexOf(':');
    if (colonIdx >= 0) {
        user = decodeComponent(userPass[0..colonIdx]);
        password = decodeComponent(userPass[colonIdx+1..$]);
    } else {
        user = decodeComponent(userPass);
        password = "";
    }

    // Parse host:port/database
    auto slashIdx = hostPart.indexOf('/');
    string hostPort, database;
    if (slashIdx >= 0) {
        hostPort = hostPart[0..slashIdx];
        database = decodeComponent(hostPart[slashIdx+1..$]);
    } else {
        hostPort = hostPart;
        database = "";
    }

    // Parse host:port
    string host;
    ushort port = 5432;
    colonIdx = hostPort.indexOf(':');
    if (colonIdx >= 0) {
        host = hostPort[0..colonIdx];
        port = hostPort[colonIdx+1..$].to!ushort;
    } else {
        host = hostPort;
    }

    return connect(host, port, database, user, password);
}

private ptrdiff_t indexOf(string s, char c) {
    import std.string : indexOf;
    return indexOf(s, c);
}
