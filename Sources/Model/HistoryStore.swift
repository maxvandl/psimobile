import Foundation

/// История чатов: по файлу JSON Lines на контакт в Application Support/History.
/// Текст уже расшифрован, поэтому файлы закрыты, пока телефон заблокирован, и не попадают в резервные копии.
final class HistoryStore {
    static let shared = HistoryStore()

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Пришло, пока файлы были закрыты; допишется после разблокировки.
    private var pending: [ChatMessage] = []

    private init() {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        directory = dir

        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try? FileManager.default.setAttributes(protection, ofItemAtPath: dir.path)
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.setAttributes(protection, ofItemAtPath: file.path)
        }
    }

    func load(_ peer: String) -> [ChatMessage] {
        flush()
        guard let data = try? Data(contentsOf: file(peer)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(ChatMessage.self, from: Data($0)) }
    }

    func append(_ msg: ChatMessage) {
        pending.append(msg)
        flush()
    }

    func flush() {
        pending = pending.filter { !write($0) }
    }

    private func write(_ msg: ChatMessage) -> Bool {
        guard var line = try? encoder.encode(msg) else { return true }
        line.append(0x0A)
        let url = file(msg.peer)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (try? line.write(to: url, options: .completeFileProtection)) != nil
        }
        // Существующий файл не перезаписываем: при блокировке он просто не откроется.
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil else { return false }
        return (try? handle.write(contentsOf: line)) != nil
    }

    /// Добавляет импортированные сообщения без дублей и сортирует по дате. Возвращает итоговое число.
    @discardableResult
    func merge(_ imported: [ChatMessage], peer: String) -> Int {
        var all = load(peer)
        var seen = Set(all.map(Self.dedupKey))
        for m in imported where seen.insert(Self.dedupKey(m)).inserted { all.append(m) }
        all.sort { $0.date < $1.date }
        var data = Data()
        for m in all {
            guard let line = try? encoder.encode(m) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: file(peer), options: [.atomic, .completeFileProtection])
        return all.count
    }

    func deleteAll() {
        pending = []
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func dedupKey(_ m: ChatMessage) -> String {
        "\(m.date.timeIntervalSince1970)|\(m.direction.rawValue)|\(m.text)"
    }

    private func file(_ peer: String) -> URL {
        let name = peer.lowercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? peer
        return directory.appendingPathComponent(name + ".jsonl")
    }
}
