module dunamis.mysql.connection;

import ae.net.db.mysql;
import ae.utils.promise;

/// Connect to MySQL and return a connection.
/// Uses the ae.net.db.mysql library for async MySQL access.
///
/// The connection uses the ae event loop (socketManager.loop()).
/// After the promise resolves, the connection is ready for queries.
///
/// Example:
///   connect("localhost", 3306, "mydb", "user", "pass").then((conn) {
///       conn.query("SELECT 1").array.then((rows) { ... });
///   });
Promise!MySqlConnection connect(string host, ushort port, string database,
                                 string user, string password) {
    auto conn = new MySqlConnection(host, port, user, database, password);

    // Return promise that resolves when connection is ready
    return conn.ready.then(() => conn);
}

/// Connect to MySQL using environment variables.
/// Environment variables used:
///   MYSQL_HOST - server hostname (default: localhost)
///   MYSQL_TCP_PORT - server port (default: 3306)
///   MYSQL_USER or USER - username
///   MYSQL_DATABASE - database name
///   MYSQL_PWD - password (default: none)
Promise!MySqlConnection connectFromEnv() {
    auto conn = new MySqlConnection();
    return conn.ready.then(() => conn);
}

/// Connect to MySQL using a connection string.
/// Format: mysql://user:password@host:port/database
Promise!MySqlConnection connectFromUri(string uri) {
    import std.uri : decodeComponent;
    import std.conv : to;
    import std.string : indexOf;

    // Parse mysql://user:password@host:port/database
    if (uri.length < 8 || (uri[0..8] != "mysql://" && uri[0..9] != "mysqli://")) {
        auto p = new Promise!MySqlConnection;
        p.reject(new Exception("Invalid connection string: must start with mysql:// or mysqli://"));
        return p;
    }

    auto rest = uri[0..8] == "mysql://" ? uri[8..$] : uri[9..$];

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
    ushort port = 3306;
    colonIdx = hostPort.indexOf(':');
    if (colonIdx >= 0) {
        host = hostPort[0..colonIdx];
        port = hostPort[colonIdx+1..$].to!ushort;
    } else {
        host = hostPort;
    }

    return connect(host, port, database, user, password);
}
