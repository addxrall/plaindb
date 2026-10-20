import Foundation

// Values that point to files kept elsewhere (an S3 bucket, PocketBase's storage), and fetching them.

private let fileExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg",
                                           "pdf", "txt", "csv", "json", "xml", "xlsx", "xls", "docx", "doc", "odt", "ods",
                                           "pptx", "zip", "mp4", "mov", "m4a", "mp3", "wav"]

private func isKey(_ s: String) -> Bool {
    let n = (s as NSString).length
    guard n >= 3, n < 1024, let first = s.unicodeScalars.first, let last = s.unicodeScalars.last else { return false }
    if CharacterSet.whitespacesAndNewlines.contains(first) || CharacterSet.whitespacesAndNewlines.contains(last) { return false }
    if s.rangeOfCharacter(from: .newlines) != nil { return false }
    let lower = s.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return false }
    if lower.hasPrefix("s3://") && s3Location(key: s, bucket: "") == nil { return false }
    return s.contains("/") && fileExtensions.contains((s as NSString).pathExtension.lowercased())
}

// {a,"b c"} → [a, b c]; nil if it isn't a simple one-dimensional array literal.
private func postgresArray(_ s: String) -> [String]? {
    let chars = Array(s.dropFirst().dropLast())
    var items: [String] = [], item = ""
    var quoted = false, wasQuoted = false, i = 0
    while i < chars.count {
        let c = chars[i]
        if quoted && c == "\\" && i + 1 < chars.count {
            i += 1
            item.append(chars[i])
        } else if c == "\"" {
            quoted.toggle()
            wasQuoted = true
        } else if c == "," && !quoted {
            items.append(item)
            item = ""
            wasQuoted = false
        } else if (c == "{" || c == "}") && !quoted {
            return nil
        } else {
            item.append(c)
        }
        i += 1
    }
    if !item.isEmpty || wasQuoted { items.append(item) }
    return items
}

private func jsonStrings(_ s: String) -> [String]? {
    guard let list = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [Any] else { return nil }
    let strings = list.compactMap { $0 as? String }
    return strings.count == list.count ? strings : nil
}

// The file keys a value holds: one key ("pbc_123/abc/photo.jpeg", "s3://bucket/key.pdf"), a Postgres array or
// a JSON array of keys. A key has a "/", a known file extension and no whitespace at its ends; http(s) URLs are
// left to the image preview. Empty when the value isn't (only) keys. Cheap enough for every cell drawn.
func fileKeys(in value: DBValue) -> [String] {
    guard let s = value.string, s.count >= 3 else { return [] }
    let keys: [String]?
    if s.hasPrefix("{") && s.hasSuffix("}") { keys = postgresArray(s) }
    else if s.hasPrefix("[") && s.hasSuffix("]") { keys = jsonStrings(s) }
    else { keys = [s] }
    guard let keys, !keys.isEmpty, keys.allSatisfy(isKey) else { return [] } // all or nothing
    return keys
}

// (bucket, key) for a key: an s3:// URL names its own bucket, anything else goes to `bucket`; nil without one.
func s3Location(key: String, bucket: String) -> (bucket: String, key: String)? {
    if key.lowercased().hasPrefix("s3://") {
        let rest = key.dropFirst(5)
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex, rest.index(after: slash) != rest.endIndex else { return nil }
        return (String(rest[..<slash]), String(rest[rest.index(after: slash)...]))
    }
    return bucket.isEmpty ? nil : (bucket, key)
}

// A name PocketBase gives a collection, record or uploaded file: letters, digits, "_", "." and "-", not starting
// with "."; so joining them can't leave the storage folder.
func pocketBaseFileNameValid(_ name: String) -> Bool {
    guard !name.isEmpty, name.utf8.count < 256, let first = name.unicodeScalars.first else { return false }
    func allowed(_ c: Unicode.Scalar) -> Bool { c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "_") }
    return allowed(first) && name.unicodeScalars.allSatisfy { allowed($0) || $0 == "." || $0 == "-" }
}

// The file names in a PocketBase file field: one name, or a JSON array of names. Empty for no files.
func pocketBaseFileNames(_ value: DBValue) -> [String] {
    guard let s = value.string, !s.isEmpty else { return [] }
    return s.hasPrefix("[") ? jsonStrings(s) ?? [] : [s]
}

enum FileKind { case other, image, pdf }

func fileKind(_ data: Data) -> FileKind {
    let b = [UInt8](data.prefix(12))
    func at(_ offset: Int, _ bytes: [UInt8]) -> Bool { b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes }
    func at(_ offset: Int, _ s: String) -> Bool { at(offset, Array(s.utf8)) }
    if at(0, "%PDF") { return .pdf }
    if at(0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) || at(0, [0xff, 0xd8, 0xff]) || at(0, "GIF8")
        || (at(0, "RIFF") && at(8, "WEBP")) || at(0, [0x49, 0x49, 0x2a, 0]) || at(0, [0x4d, 0x4d, 0, 0x2a]) || at(0, "BM")
        || (at(4, "ftyp") && (at(8, "heic") || at(8, "mif1"))) {
        return .image
    }
    return .other
}

// Profile names, sorted, from the texts of ~/.aws/config ("[profile name]", "[default]") and ~/.aws/credentials
// ("[name]"); other sections and all values are skipped.
func awsProfileNames(config: String?, credentials: String?) -> [String] {
    var names = Set<String>()
    for (text, isConfig) in [(config ?? "", true), (credentials ?? "", false)] {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), line.hasSuffix("]") else { continue }
            var section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if isConfig { // config: "default" or "profile <name>"; sso-session and others aren't profiles
                if section.hasPrefix("profile ") { section = String(section.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                else if section != "default" { continue }
            }
            if !section.isEmpty { names.insert(section) }
        }
    }
    return names.sorted()
}

// The same read from the user's ~/.aws files.
func awsProfiles() -> [String] {
    let aws = (NSHomeDirectory() as NSString).appendingPathComponent(".aws") as NSString
    return awsProfileNames(config: try? String(contentsOfFile: aws.appendingPathComponent("config"), encoding: .utf8),
                           credentials: try? String(contentsOfFile: aws.appendingPathComponent("credentials"), encoding: .utf8))
}

// The aws CLI, where Homebrew or the installer put it; nil if missing.
func awsExecutable() -> String? {
    ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"].first { FileManager.default.isExecutableFile(atPath: $0) }
}

// aws's message, or plain words for the usual reasons: an expired SSO session, no access, no such object, no credentials.
private func awsError(_ stderrText: String, status: Int32, profile: String, url: String) -> DBError {
    let text = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = text.lowercased()
    let who = profile.isEmpty ? L("default") : profile
    if lower.contains("sso") && (lower.contains("expired") || lower.contains("token")) {
        let command = profile.isEmpty ? "aws sso login" : "aws sso login --profile " + profile
        return DBError(String(format: L("The AWS session has expired. Run %@ in Terminal and try again."), command))
    }
    if ["(403)", "forbidden", "accessdenied", "access denied"].contains(where: lower.contains) {
        return DBError(String(format: L("AWS refused access to %@: the profile %@ can't read it. Give it s3:GetObject on the bucket, or choose another profile in the connection."), url, who))
    }
    if ["(404)", "not found", "nosuchkey"].contains(where: lower.contains) {
        return DBError(String(format: L("There's no such file in S3: %@"), url))
    }
    if ["unable to locate credentials", "could not be found", "missing required configuration"].contains(where: lower.contains) {
        return DBError(String(format: L("The AWS profile %@ has no working credentials. Set it up with aws configure (or aws configure sso), or choose another profile. %@"), who, text))
    }
    return DBError(text.isEmpty ? String(format: L("aws ended with status %d."), status) : text)
}

// Downloads s3://bucket/key with the aws CLI into memory (the user's own profile, SSO included; PlainDB keeps no
// AWS secrets). Empty region / profile / endpoint: aws's defaults; an endpoint on amazonaws.com isn't passed.
// Stops past maxBytes.
func fetchS3File(aws: String?, bucket: String, key: String, region: String, profile: String, endpoint: String,
                 maxBytes: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { done in
        DispatchQueue.global(qos: .userInitiated).async {
            done.resume(with: Result {
                try runS3Fetch(aws: aws, bucket: bucket, key: key, region: region, profile: profile, endpoint: endpoint, maxBytes: maxBytes)
            })
        }
    }
}

private func runS3Fetch(aws: String?, bucket: String, key: String, region: String, profile: String, endpoint: String,
                        maxBytes: Int) throws -> Data {
    guard let aws, FileManager.default.isExecutableFile(atPath: aws) else {
        throw DBError(L("The aws command wasn't found. Install the AWS CLI (brew install awscli) and sign in."))
    }
    let url = "s3://\(bucket)/\(key)"
    var args = ["s3", "cp", url, "-", "--only-show-errors", "--cli-connect-timeout", "10"]
    if !region.isEmpty { args += ["--region", region] }
    if !profile.isEmpty { args += ["--profile", profile] }
    if !endpoint.isEmpty && !endpoint.lowercased().contains("amazonaws.com") { args += ["--endpoint-url", endpoint] }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: aws)
    task.arguments = args
    let output = Pipe(), errors = Pipe()
    task.standardOutput = output
    task.standardError = errors
    task.standardInput = FileHandle.nullDevice
    let lock = NSLock()
    nonisolated(unsafe) var stderrData = Data() // under `lock`
    errors.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty { h.readabilityHandler = nil }
        lock.withLock { if stderrData.count < 8192 { stderrData.append(d) } }
    }
    do { try task.run() } catch { throw DBError(error.localizedDescription) }
    var data = Data()
    var tooBig = false
    while let chunk = try? output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
        data.append(chunk)
        if data.count > maxBytes {
            tooBig = true
            task.terminate()
            break
        }
    }
    task.waitUntilExit()
    usleep(20000) // the last of stderr
    if tooBig {
        let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
        throw DBError(String(format: L("The file is bigger than %@, too big to preview."), limit))
    }
    if task.terminationStatus != 0 {
        let text = lock.withLock { String(decoding: stderrData, as: UTF8.self) }
        throw awsError(text, status: task.terminationStatus, profile: profile, url: url)
    }
    return data
}
