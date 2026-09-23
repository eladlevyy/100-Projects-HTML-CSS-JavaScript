import Foundation

// Search lives with the store. This file keeps the module layout obvious for readers
// looking for full-text behavior and re-exports nothing extra.
public enum SearchRanking {
    public static func hits(in messages: [Message], query: String, limit: Int = 50) -> [SearchHit] {
        FullTextIndex(messages: messages).search(query, limit: limit)
    }
}
