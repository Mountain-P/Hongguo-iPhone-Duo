import Foundation

/// Device-local discovery choices. This does not represent official account preferences or watch history.
public struct RecommendationPreferences: Codable, Equatable, Sendable {
    public static let maximumRememberedIDs = 1_000
    public var category: DirectWebService.Category
    public var skipsPreviewed: Bool
    public private(set) var notInterestedIDs: [String]
    public private(set) var previewedIDs: [String]

    public init(category: DirectWebService.Category = .realDrama, skipsPreviewed: Bool = false) {
        self.category = category; self.skipsPreviewed = skipsPreviewed
        notInterestedIDs = []; previewedIDs = []
    }

    public mutating func setNotInterested(seriesID: String, value: Bool) throws {
        try Self.validate(seriesID)
        notInterestedIDs.removeAll { $0 == seriesID }
        if value { notInterestedIDs.insert(seriesID, at: 0) }
        notInterestedIDs = Array(notInterestedIDs.prefix(Self.maximumRememberedIDs))
    }

    public mutating func markPreviewed(seriesID: String) throws {
        try Self.validate(seriesID)
        previewedIDs.removeAll { $0 == seriesID }; previewedIDs.insert(seriesID, at: 0)
        previewedIDs = Array(previewedIDs.prefix(Self.maximumRememberedIDs))
    }

    public mutating func restorePreviewed(seriesID: String) { previewedIDs.removeAll { $0 == seriesID } }
    public mutating func clearNotInterested() { notInterestedIDs = [] }
    public mutating func clearPreviewed() { previewedIDs = [] }
    public mutating func reset() { self = .init() }

    public func isNotInterested(seriesID: String) -> Bool { notInterestedIDs.contains(seriesID) }

    public func allows(seriesID: String) -> Bool {
        (try? Self.validate(seriesID)) != nil && !isNotInterested(seriesID: seriesID)
            && (!skipsPreviewed || !previewedIDs.contains(seriesID))
    }

    public func filter(_ items: [Series]) -> [Series] {
        let blocked = Set(notInterestedIDs + (skipsPreviewed ? previewedIDs : []))
        var seen: Set<String> = []
        return items.filter {
            (try? Self.validate($0.id)) != nil && !blocked.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    private static func validate(_ id: String) throws {
        try validateID(id)
        guard id.contains(where: { $0 != "0" }) else { throw CatalogError.invalidID }
    }

    private static func normalized(_ ids: [String]) throws -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for id in ids {
            try validate(id)
            if seen.insert(id).inserted, result.count < maximumRememberedIDs { result.append(id) }
        }
        return result
    }

    private enum CodingKeys: String, CodingKey { case category, skipsPreviewed, notInterestedIDs, previewedIDs }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        category = try values.decodeIfPresent(DirectWebService.Category.self, forKey: .category) ?? .realDrama
        skipsPreviewed = try values.decodeIfPresent(Bool.self, forKey: .skipsPreviewed) ?? false
        notInterestedIDs = try Self.normalized(values.decodeIfPresent([String].self, forKey: .notInterestedIDs) ?? [])
        previewedIDs = try Self.normalized(values.decodeIfPresent([String].self, forKey: .previewedIDs) ?? [])
    }
}
