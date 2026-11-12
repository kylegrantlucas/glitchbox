/// Section order for Simple mode's Looks gallery and effect picker.
enum SimpleCatalog {
    /// Where chains without a category (the user's saved looks) go.
    static let userLooks = "My Looks"
    static let lookCategories = [userLooks, "Tape", "Film", "Datamosh", "Digital", "Colour", "Trippy", "Sound", "Stills"]
    static let effectCategories = ["Tape & TV", "Film & Light", "Datamosh", "Digital", "Colour", "Time", "Warp", "Photo"]

    /// Non-empty sections in `order`, then any other category alphabetically; items keep their input order.
    static func sections<T>(_ items: [T], order: [String], category: (T) -> String) -> [(title: String, items: [T])] {
        var byCategory: [String: [T]] = [:]
        for item in items { byCategory[category(item), default: []].append(item) }
        let titles = order + byCategory.keys.filter { !order.contains($0) }.sorted()
        return titles.compactMap { title in byCategory[title].map { (title, $0) } }
    }
}
