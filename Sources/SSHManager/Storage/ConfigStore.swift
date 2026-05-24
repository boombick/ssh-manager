import Foundation

final class ConfigStore {
    func load() throws -> [Connection] {
        let url = Paths.configFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try save([])
            return []
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([Connection].self, from: data)
    }

    func save(_ connections: [Connection]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(connections)
        try data.write(to: Paths.configFile, options: .atomic)
    }
}
