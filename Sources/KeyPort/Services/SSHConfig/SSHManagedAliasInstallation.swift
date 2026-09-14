import Foundation
import Darwin
import KeyPortCore

    /// Owns the unified workspace SSH Include and configuration transaction.
    /// Synchronous transaction used by the main-actor workspace store and isolated tests.
struct ManagedAliasInstallation {
        let home: URL
        var directory: URL { home.appendingPathComponent(".ssh/keyport-access") }
        var managed: URL { directory.appendingPathComponent("config") }
        var userConfig: URL { home.appendingPathComponent(".ssh/config") }
        private var journal: URL { directory.appendingPathComponent("transaction.json") }
        private var receipt: URL { directory.appendingPathComponent("receipt.json") }
        private var prefix: String { "# KeyPort Access managed Include\nInclude \"\(managed.path)\"\nHost *\n# End KeyPort Access Include\n" }
        var beforeWrite: ((Int) throws -> Void)? = nil

        struct Failure: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        private struct FileState: Codable {
            let path: String
            let data: Data?
            let mode: Int
        }
        private struct Transaction: Codable {
            let before: [FileState]
            let after: [FileState]
        }
        private struct Receipt: Codable { let content: Data }

        func validateAlias(_ alias: String) throws {
            let original = try text(snapshot(userConfig).data)
            let body = original.hasPrefix(prefix) ? String(original.dropFirst(prefix.count)) : original
            var visited = Set<String>()
            try inspect(body, source: userConfig, aliases: [alias.lowercased()], visited: &visited, depth: 0)
        }

        func install(entries: [SSHConfigEntry], knownHosts: URL) throws {
            try secureDirectory(home.appendingPathComponent(".ssh"))
            try secureDirectory(directory)
            let fd = Darwin.open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw Failure(message: "无法锁定 SSH 配置。") }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure(message: "SSH 配置正在由另一个操作更新。") }
            try recover()
            let original = try snapshot(userConfig)
            let previous = try snapshot(managed)
            let oldReceipt = try snapshot(receipt)
            if let data = oldReceipt.data {
                let owned = try JSONDecoder().decode(Receipt.self, from: data)
                // A removed managed file can be rebuilt; external edits must never be overwritten.
                guard previous.data == nil || previous.data == owned.content else {
                    throw Failure(message: "KeyPort 管理配置已被外部修改，请保留修改后再处理冲突。")
                }
            } else if previous.data != nil {
                throw Failure(message: "目标管理配置已存在且不属于此工作区，未覆盖。")
            }
            let existing = try text(original.data)
            let body: String
            if existing.hasPrefix(prefix) { body = String(existing.dropFirst(prefix.count)) }
            else {
                guard !existing.contains("# KeyPort Access managed Include"), !existing.contains("# End KeyPort Access Include") else {
                    throw Failure(message: "KeyPort Include 已被移动或修改，请先恢复其原位置。")
                }
                body = existing
            }
            let aliases = entries.map { $0.server.alias.lowercased() }
            guard Set(aliases).count == aliases.count else { throw Failure(message: "管理配置包含重复别名。") }
            var visited = Set<String>()
            try inspect(body, source: userConfig, aliases: aliases, visited: &visited, depth: 0)
            let content = try SSHConfigGenerator.directConfig(entries: entries, knownHostsPath: knownHosts.path)
            let newUser = entries.isEmpty ? body : prefix + body
            let next = [
                FileState(path: managed.path, data: entries.isEmpty ? nil : Data(content.utf8), mode: 0o600),
                FileState(path: userConfig.path, data: original.data == nil && newUser.isEmpty ? nil : Data(newUser.utf8), mode: original.mode),
                FileState(path: receipt.path, data: try JSONEncoder().encode(Receipt(content: Data(content.utf8))), mode: 0o600)
            ]
            let old = [previous, original, oldReceipt]
            guard zip(old, next).contains(where: { $0.data != $1.data }) else { return }
            // A durable full before-image is created before touching either configuration file.
            let transaction = Transaction(before: old, after: next)
            let encoded = try JSONEncoder().encode(transaction)
            let backup = directory.appendingPathComponent("backup-\(UUID().uuidString).json")
            try write(FileState(path: backup.path, data: encoded, mode: 0o600))
            try write(FileState(path: journal.path, data: encoded, mode: 0o600))
            do {
                for (index, file) in next.enumerated() {
                    try beforeWrite?(index)
                    guard try snapshot(URL(fileURLWithPath: old[index].path)).data == old[index].data else {
                        throw Failure(message: "SSH 配置在写入前发生变化，已停止。")
                    }
                    if old[index].data != file.data { try write(file) }
                }
                try FileManager.default.removeItem(at: journal)
            } catch {
                do { try recover() }
                catch { throw Failure(message: "SSH 配置恢复未完成；已保留 transaction.json 与备份，请先解决文件冲突。") }
                throw error
            }
        }

        private func recover() throws {
            guard let data = try snapshot(journal).data else { return }
            let transaction = try JSONDecoder().decode(Transaction.self, from: data)
            guard transaction.before.map(\.path) == [managed.path, userConfig.path, receipt.path],
                  transaction.after.map(\.path) == transaction.before.map(\.path) else {
                throw Failure(message: "SSH 配置恢复记录无效。")
            }
            for (old, next) in zip(transaction.before, transaction.after) {
                let current = try snapshot(URL(fileURLWithPath: old.path))
                guard current.data == old.data || current.data == next.data else {
                    throw Failure(message: "恢复期间发现外部修改，已保留现场。")
                }
            }
            for old in transaction.before { try write(old) }
            try FileManager.default.removeItem(at: journal)
        }

        private func inspect(_ content: String, source: URL, aliases: [String], visited: inout Set<String>, depth: Int) throws {
            guard depth < 16, visited.insert(source.path).inserted else { throw Failure(message: "SSH Include 存在循环或嵌套过深。") }
            defer { visited.remove(source.path) }
            var hasHost = false
            for (index, line) in content.components(separatedBy: .newlines).enumerated() {
                let fields = try tokens(line)
                guard let directive = fields.first?.lowercased() else { continue }
                let values = Array(fields.dropFirst())
                let location = "\(source.lastPathComponent):\(index + 1)"
                switch directive {
                case "host":
                    hasHost = true
                    for alias in aliases where matches(values, alias) {
                        throw Failure(message: "别名 \(alias) 与 \(location) 的 Host \(values.joined(separator: " ")) 冲突，未更改已有连接。")
                    }
                case "match":
                    if !aliases.isEmpty { throw Failure(message: "\(location) 包含 Match 条件，需要人工确认其与新别名的关系。") }
                case "include":
                    for value in values {
                        guard !value.contains("%"), !value.contains("$") else { throw Failure(message: "\(location) 的动态 Include 无法安全检查。") }
                        let path: String
                        if value.hasPrefix("~/") { path = home.appendingPathComponent(String(value.dropFirst(2))).path }
                        else if value.hasPrefix("/") { path = value }
                        else { path = home.appendingPathComponent(".ssh").appendingPathComponent(value).path }
                        var result = glob_t()
                        defer { globfree(&result) }
                        let status = glob(path, 0, nil, &result)
                        guard status == 0 || status == GLOB_NOMATCH else { throw Failure(message: "无法检查 \(location) 的 Include。") }
                        for i in 0..<Int(result.gl_pathc) {
                            let url = URL(fileURLWithPath: String(cString: result.gl_pathv[i]!)).standardizedFileURL
                            guard url != managed else { throw Failure(message: "管理配置已被其他 Include 引用，无法保证顺序。") }
                            try inspect(try String(contentsOf: url, encoding: .utf8), source: url, aliases: aliases, visited: &visited, depth: depth + 1)
                        }
                    }
                default:
                    // Global options could introduce proxy commands, additional keys or forwards.
                    // Preserve them and ask for a concrete resolution rather than silently changing precedence.
                    if !hasHost && !aliases.isEmpty {
                        throw Failure(message: "\(location) 含全局 \(directive) 规则，需要确认新别名是否应继承。")
                    }
                }
            }
        }
        private func matches(_ patterns: [String], _ alias: String) -> Bool {
            let excluded = patterns.filter { $0.hasPrefix("!") }.contains { fnmatch(String($0.dropFirst()).lowercased(), alias, 0) == 0 }
            return !excluded && patterns.filter { !$0.hasPrefix("!") }.contains { fnmatch($0.lowercased(), alias, 0) == 0 }
        }
        private func tokens(_ line: String) throws -> [String] {
            var result: [String] = [], token = "", quote: Character?, escaped = false
            for c in line {
                if escaped { token.append(c); escaped = false; continue }
                if c == "\\" { escaped = true; continue }
                if let q = quote { if c == q { quote = nil } else { token.append(c) }; continue }
                if c == "\"" || c == "'" { quote = c; continue }
                if c == "#" { break }
                if c.isWhitespace || (c == "=" && result.count < 2) {
                    if !token.isEmpty { result.append(token); token = "" }
                } else { token.append(c) }
            }
            guard quote == nil, !escaped else { throw Failure(message: "SSH 配置含无法解析的引号或续行。") }
            if !token.isEmpty { result.append(token) }
            return result
        }
        private func text(_ data: Data?) throws -> String {
            guard let data else { return "" }
            guard let value = String(data: data, encoding: .utf8) else { throw Failure(message: "SSH 配置不是 UTF-8，未修改。") }
            return value
        }
        private func secureDirectory(_ url: URL) throws {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw Failure(message: "SSH 目录不是本用户拥有的普通目录。") }
            } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        }
        private func snapshot(_ url: URL) throws -> FileState {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                guard errno == ENOENT else { throw Failure(message: "无法读取 SSH 配置元数据。") }
                return FileState(path: url.path, data: nil, mode: 0o600)
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw Failure(message: "SSH 配置不是本用户拥有的普通文件，未修改。") }
            return FileState(path: url.path, data: try Data(contentsOf: url), mode: Int(info.st_mode & 0o777))
        }
        private func write(_ file: FileState) throws {
            let url = URL(fileURLWithPath: file.path)
            guard let data = file.data else {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: url) }
                return
            }
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temp) }
            // Copy metadata (including ACLs/xattrs) before replacing an existing user file.
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.copyItem(at: url, to: temp)
            } else {
                let fd = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                guard fd >= 0 else { throw Failure(message: "无法创建 SSH 配置临时文件。") }
                Darwin.close(fd)
            }
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try FileManager.default.setAttributes([.posixPermissions: file.mode], ofItemAtPath: temp.path)
            try handle.synchronize()
            guard rename(temp.path, url.path) == 0 else { throw Failure(message: "无法原子写入 SSH 配置。") }
            let directoryFD = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
            if directoryFD >= 0 { _ = fsync(directoryFD); Darwin.close(directoryFD) }
        }
    }
