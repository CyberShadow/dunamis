/// The shapes of the D types of fields' results, as GraphQL sees them: the
/// one compile-time classification which compiling, validating and the
/// null-bubbling rules of queries dispatch on.
module dunamis.graphql.compiler.shape;

import std.traits : isSomeString;
import std.typecons : Nullable;

import dunamis.core.types : isCustomScalar, isGqlResult;

package(dunamis.graphql):

/// The shape of a type (see `shapeOf`).
enum Shape {
    /// A scalar (a primitive, a string or a custom scalar), serialized as
    /// it is, without a selection set.
    leaf,
    /// An object (a struct which is not a custom scalar), selected from
    /// with a selection set.
    object,
    /// Nullable!U: U or null.
    nullable,
    /// A list (an array which is not a string or a custom scalar).
    list,
    /// GqlResult!U: U or an error (of a field of the item it is for).
    result,
}

/// The shape of the type T.
template shapeOf(T) {
    static if (isGqlResult!T)
        enum shapeOf = Shape.result;
    else static if (is(T == Nullable!U, U))
        enum shapeOf = Shape.nullable;
    else static if (is(T == E[], E) && !isSomeString!T && !isCustomScalar!T)
        enum shapeOf = Shape.list;
    else static if (is(T == struct) && !isCustomScalar!T)
        enum shapeOf = Shape.object;
    else
        enum shapeOf = Shape.leaf;
}

/// The type a nullable, a list or a result wraps (its item's for a list).
template ShapeInner(T) {
    static if (shapeOf!T == Shape.result)
        alias ShapeInner = typeof(T.init.value);
    else static if (is(T == Nullable!U, U))
        alias ShapeInner = U;
    else static if (is(T == E[], E))
        alias ShapeInner = E;
    else
        static assert(false, T.stringof ~ " wraps no type");
}

/// Whether list items of type T are leaves (scalars, nullable ones, lists of
/// them, or results), which are serialized as they are, without a selection
/// set.
template isLeafElement(T) {
    static if (shapeOf!T == Shape.nullable || shapeOf!T == Shape.list)
        enum isLeafElement = isLeafElement!(ShapeInner!T);
    else
        enum isLeafElement = shapeOf!T != Shape.object;
}

/// Whether a null item in a list of T makes the list null (null bubbling):
/// T is non-null, and an object or a list which can itself become null.
template bubblesNullItems(T) {
    static if (shapeOf!T == Shape.list)
        enum bubblesNullItems = bubblesNullItems!(ShapeInner!T);
    else
        enum bubblesNullItems = shapeOf!T == Shape.object;
}

/// Whether a field of type T is non-null in GraphQL (Nullable!T and
/// pointers are nullable; a result is as its value).
template isNonNullType(T) {
    static if (shapeOf!T == Shape.result)
        enum isNonNullType = isNonNullType!(ShapeInner!T);
    else static if (is(T == U*, U))
        enum isNonNullType = false;
    else
        enum isNonNullType = shapeOf!T != Shape.nullable;
}

/// Whether a field of type T is a list whose non-null items can become
/// null through null bubbling: objects, or lists of them (see
/// bubblesNullItems). Scalar items cannot, and array-valued scalars must not
/// be inspected.
template isNonNullItemListType(T) {
    static if (shapeOf!T == Shape.result || shapeOf!T == Shape.nullable)
        enum isNonNullItemListType = isNonNullItemListType!(ShapeInner!T);
    else static if (shapeOf!T == Shape.list)
        enum isNonNullItemListType = bubblesNullItems!(ShapeInner!T);
    else
        enum isNonNullItemListType = false;
}

unittest {
    import dunamis.core.types : GqlResult;
    static struct Obj { int id; }

    static assert(shapeOf!int == Shape.leaf && shapeOf!string == Shape.leaf);
    static assert(shapeOf!Obj == Shape.object);
    static assert(shapeOf!(Nullable!Obj) == Shape.nullable && shapeOf!(Obj[]) == Shape.list);
    static assert(shapeOf!(GqlResult!int) == Shape.result);

    static assert(isLeafElement!int && isLeafElement!(Nullable!(int[])) && isLeafElement!(GqlResult!Obj));
    static assert(!isLeafElement!Obj && !isLeafElement!(Nullable!Obj[]));

    static assert(bubblesNullItems!Obj && bubblesNullItems!(Obj[]) && !bubblesNullItems!(Nullable!Obj));
    static assert(!bubblesNullItems!int);

    static assert(isNonNullType!int && isNonNullType!(Obj[]) && !isNonNullType!(Nullable!int));
    static assert(!isNonNullType!(GqlResult!(Nullable!int)) && !isNonNullType!(int*));

    static assert(isNonNullItemListType!(Obj[]) && isNonNullItemListType!(Nullable!(Obj[][])));
    static assert(!isNonNullItemListType!(int[]) && !isNonNullItemListType!(Nullable!Obj[]));
}
