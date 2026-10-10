import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let description: String
}

/// Just enough SQLite: prepared statements, typed binds and columns, transactions.
/// Not thread-safe; one `Database` belongs to one task at a time.
final class Database {
    private var handle: OpaquePointer?

    /// Opens (creating if needed) the file at `url`, or a private in-memory database.
    init(url: URL?) throws {
        let path: String
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            path = url.path
        } else {
            path = ":memory:"
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(handle)
            throw DatabaseError(description: "cannot open \(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DatabaseError(description: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError(description: "\(lastError) in: \(sql)")
        }
        return Statement(statement, database: self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get throws {
            let statement = try prepare("PRAGMA user_version")
            return try statement.step() ? statement.int(0) : 0
        }
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    /// True between `BEGIN` and `COMMIT`.
    var isInTransaction: Bool { sqlite3_get_autocommit(handle) == 0 }
}

/// A prepared statement. Bind indices are 1-based (SQLite's); column indices 0-based.
final class Statement {
    private let handle: OpaquePointer
    private let database: Database

    fileprivate init(_ handle: OpaquePointer, database: Database) {
        self.handle = handle
        self.database = database
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// SQLite copies the bytes before `bind` returns, so Swift strings can be temporaries.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    @discardableResult
    func bind(_ index: Int32, _ value: String?) -> Statement {
        if let value {
            sqlite3_bind_text(handle, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(handle, index)
        }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int?) -> Statement {
        if let value { sqlite3_bind_int64(handle, index, Int64(value)) } else { sqlite3_bind_null(handle, index) }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Double?) -> Statement {
        if let value { sqlite3_bind_double(handle, index, value) } else { sqlite3_bind_null(handle, index) }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Bool) -> Statement {
        sqlite3_bind_int64(handle, index, value ? 1 : 0)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Data?) -> Statement {
        guard let value else {
            sqlite3_bind_null(handle, index)
            return self
        }
        value.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        return self
    }

    /// Advances one row. True while there is a row to read.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError(description: database.lastError)
        }
    }

    /// Ready for the next set of binds.
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }

    func double(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(handle, column)
    }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: pointer)
    }

    func data(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(handle, column) else { return isNull(column) ? nil : Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }
}
