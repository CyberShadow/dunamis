module graphqld2.core.fetcher;

import std.json;
import ae.utils.promise;

import graphqld2.relational.types;

/// Interface for fetching data from a data source.
/// Implementations translate layer requirements into actual data fetches.
interface DataFetcher {
    /// Fetch data for the given layers.
    /// Root layer filter info (FilterType, IDs) is in the layer itself.
    /// Returns a promise that resolves to JSON in the format:
    /// {"layer0": [...], "layer1": [...], ...}
    Promise!JSONValue fetch(Layer[] layers);
}
