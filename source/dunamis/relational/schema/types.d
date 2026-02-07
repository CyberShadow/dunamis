module dunamis.relational.schema.types;

import std.traits;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, ExprResultType, isExpr;

// ============================================================================
// Entity Reference Type
// ============================================================================

/// Runtime entity reference with compile-time metadata.
/// The struct carries both the ID string and type-level metadata (db, table, typeName).
struct EntityRef(alias _db, string _tableName, string _typeName) {
    import std.string : indexOf;

    /// Data source (compile-time alias)
    alias db = _db;

    /// SQL table name (compile-time)
    enum table = _tableName;

    /// GraphQL type name (compile-time)
    enum typeName = _typeName;

    /// Runtime ID string (format: "TypeName:localId")
    string id;

    /// Construct from ID string
    this(string id) { this.id = id; }

    /// Extract the local ID portion (after the colon)
    string localId() const {
        auto sep = id.indexOf(':');
        return sep >= 0 ? id[sep + 1 .. $] : "";
    }

    /// For debugging
    string toString() const { return id; }
}

/// Extract entity metadata type from any entity struct.
/// Usage: EntityID!User.table, EntityID!User.typeName, EntityID!User.db
alias EntityID(Entity) = typeof(Entity.init.nodeId);

/// Check if an entity reference is valid (has non-empty ID).
/// Works via UFCS: entity.isValid()
bool isValid(E)(E entity) if (is(typeof(E.init.nodeId))) {
    return entity.nodeId.id.length > 0;
}

// ============================================================================
// Entity Mixin
// ============================================================================

/// The entity struct becomes a reference type - it holds a nodeId that identifies
/// a specific row in the database. Schema metadata is static, nodeId is runtime.
///
/// The data source is bound by alias, so it must be a static/module-level variable.
/// This allows both Table queries and mutations to access the same data source.
mixin template Entity(alias db, string tableName, string typeName = "") {
    import dunamis.relational.schema.types : EntityRef;

    /// Entity reference with compile-time metadata and runtime ID
    static if (typeName.length > 0)
        EntityRef!(db, tableName, typeName) nodeId;
    else
        EntityRef!(db, tableName, __traits(identifier, typeof(this))) nodeId;

    /// Construct from ID string
    this(string id) { nodeId = typeof(nodeId)(id); }

    /// For debugging
    string toString() const { return nodeId.toString(); }
}

// ============================================================================
// Foreign Key Type
// ============================================================================

/// Foreign key reference to another entity.
/// Use with Col to define FK columns that reference another entity's primary key.
struct ForeignKey(Entity, string idField = "id") {
    /// The referenced entity type
    alias referencedEntity = Entity;

    /// The referenced column name
    enum referencedColumn = idField;

    /// The underlying storage type (derived from referenced column method's return type)
    private alias _FieldMethod = __traits(getMember, Entity, idField);
    private alias _ReturnType = getMethodReturnType!(_FieldMethod, Expr!Entity);
    static assert(isExpr!_ReturnType,
        "Field '" ~ idField ~ "' in " ~ Entity.stringof ~ " must return an Expr type");
    alias StorageType = ExprResultType!_ReturnType;
}

/// Helper to get return type of a method, handling both regular and template functions.
private template getMethodReturnType(alias method, ArgType) {
    static if (__traits(compiles, ReturnType!method)) {
        alias getMethodReturnType = ReturnType!method;
    } else static if (__traits(compiles, ReturnType!(method!()))) {
        alias getMethodReturnType = ReturnType!(method!());
    } else {
        alias getMethodReturnType = typeof(method(ArgType.init));
    }
}

/// Check if a type is a ForeignKey
template isForeignKey(T) {
    static if (is(T == ForeignKey!(E, col), E, string col)) {
        enum isForeignKey = true;
    } else {
        enum isForeignKey = false;
    }
}

/// Check if a type is a Nullable ForeignKey
template isNullableForeignKey(T) {
    static if (is(T == Nullable!(ForeignKey!(E, col)), E, string col)) {
        enum isNullableForeignKey = true;
    } else {
        enum isNullableForeignKey = false;
    }
}

/// Check if a type is any kind of ForeignKey (required or nullable)
template isAnyForeignKey(T) {
    enum isAnyForeignKey = isForeignKey!T || isNullableForeignKey!T;
}

/// Get the referenced entity from a ForeignKey type
template getForeignKeyEntity(T) {
    static if (is(T == ForeignKey!(E, col), E, string col)) {
        alias getForeignKeyEntity = E;
    } else static if (is(T == Nullable!(ForeignKey!(E, col)), E, string col)) {
        alias getForeignKeyEntity = E;
    } else {
        static assert(false, "Not a ForeignKey type");
    }
}

/// Get the inner ForeignKey type from a Nullable!(ForeignKey!(...))
template getInnerForeignKey(T) {
    static if (is(T == Nullable!(ForeignKey!(E, col)), E, string col)) {
        alias getInnerForeignKey = ForeignKey!(E, col);
    } else {
        static assert(false, "Not a Nullable ForeignKey type");
    }
}

/// Get the storage type for a column type.
/// For ForeignKey types, returns the referenced column's type.
/// For Nullable FKs, preserves the Nullable wrapper.
/// For regular types, returns T itself.
template getColumnStorageType(T) {
    import std.typecons : Nullable;
    static if (isNullableForeignKey!T) {
        alias getColumnStorageType = Nullable!(getInnerForeignKey!T.StorageType);
    } else static if (isForeignKey!T) {
        alias getColumnStorageType = T.StorageType;
    } else {
        alias getColumnStorageType = T;
    }
}
