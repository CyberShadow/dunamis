/// Encapsulated code-generation templates for field forwarding.
///
/// These are regular (non-mixin) templates that compute complete mixin strings.
/// All internal aliases stay encapsulated — only the eponymous string member is visible.
/// Separated from plugin.d to avoid circular forward references when used via .imported.
module dunamis.graphql.forward;

// ============================================================================
// ForwardField
// ============================================================================

/// Top-level template holding metadata for a forwarded field.
/// Encapsulates all introspection aliases so they don't leak into the target struct.
template ForwardFieldImpl(SourceType, string fieldName, alias TypeMap) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import dunamis.core.expr : ExprResultType;

    alias srcFn = __traits(getMember, SourceType, fieldName);
    alias SrcParams = Parameters!srcFn;
    alias SrcDefaults = ParameterDefaults!srcFn;
    enum string[] srcParamNames = [ParameterIdentifierTuple!srcFn];
    alias SrcEntity = ExprResultType!(SrcParams[0]);
}

/// Eponymous template that builds the complete mixin string for a forwarded field.
/// All internal computation stays encapsulated — only the result string is visible.
template ForwardFieldCode(SourceType, string fieldName, alias TypeMap) {
    import std.conv : to;

    private alias Impl = ForwardFieldImpl!(SourceType, fieldName, TypeMap);
    private enum string _I = "dunamis.graphql.forward.ForwardFieldImpl!(SourceType, fieldName, TypeMap)";

    private enum string _paramListStr = () {
        string result = "dunamis.core.expr.Expr!(typeof(this)) " ~ Impl.srcParamNames[0];
        static foreach (i; 1 .. Impl.SrcParams.length) {{
            result ~= ", " ~ _I ~ ".SrcParams[" ~ i.to!string ~ "] " ~ Impl.srcParamNames[i];
            static if (!is(Impl.SrcDefaults[i] == void))
                result ~= " = " ~ _I ~ ".SrcDefaults[" ~ i.to!string ~ "]";
        }}
        return result;
    }();

    private enum string _argListStr = () {
        string result = "dunamis.graphql.entity_cast.pluginEntityCast!(" ~ _I ~ ".SrcEntity)(" ~ Impl.srcParamNames[0] ~ ")";
        static foreach (i; 1 .. Impl.SrcParams.length)
            result ~= ", " ~ Impl.srcParamNames[i];
        return result;
    }();

    enum ForwardFieldCode =
        "@(__traits(getAttributes, " ~ _I ~ ".srcFn)) " ~
        "static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
        "return dunamis.graphql.transform.wrapEntityResult!(TypeMap)(" ~
        _I ~ ".srcFn(" ~ _argListStr ~ ")); }";
}

// ============================================================================
// ForwardPlainMethod
// ============================================================================

/// Eponymous template that builds the mixin string for a forwarded plain method.
template ForwardPlainMethodCode(SourceType, string methodName) {
    enum ForwardPlainMethodCode =
        "@(__traits(getAttributes, __traits(getMember, SourceType, \"" ~ methodName ~ "\"))) " ~
        "std.traits.ReturnType!(__traits(getMember, SourceType, \"" ~ methodName ~ "\")) " ~
        methodName ~ "() { return (cast(SourceType*) &this)." ~ methodName ~ "(); }";
}
