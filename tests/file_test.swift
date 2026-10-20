// File references: which values point to files, S3 locations, PocketBase names, and the aws CLI download
// (with a fake aws script). `make test`.
@testable import PlainDBKit
import Foundation

@main enum FileTest {
    // A stand-in for aws: writes its arguments to args.txt next to it, then runs `body`.
    static func fakeAWS(_ dir: String, _ body: String) -> String {
        let path = (dir as NSString).appendingPathComponent("aws")
        try! "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/args.txt\"\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    static func args(_ dir: String) -> [String] {
        try! String(contentsOfFile: (dir as NSString).appendingPathComponent("args.txt"), encoding: .utf8).components(separatedBy: "\n")
    }

    static func fetch(_ aws: String, _ bucket: String, _ key: String, region: String = "", profile: String = "", endpoint: String = "",
                      max: Int = 1024) async -> Result<Data, DBError> {
        do {
            return .success(try await fetchS3File(aws: aws, bucket: bucket, key: key, region: region, profile: profile, endpoint: endpoint, maxBytes: max))
        } catch {
            return .failure(error as! DBError)
        }
    }

    static func message(_ r: Result<Data, DBError>) -> String {
        if case .failure(let e) = r { return e.message }
        return ""
    }

    static func main() async {
        // keys as fleet stores them, in a column, a Postgres array or a JSON array
        let photo = "pbc_1967373549/yhlcagepu9z8tod/g4r_nb_pywo_aawty_s_0cugwg1nf2.jpeg"
        check(fileKeys(in: .text(photo)) == [photo])
        check(fileKeys(in: "{pbc_1/a/x.jpg,\"pbc_1/b/y z.png\"}") == ["pbc_1/a/x.jpg", "pbc_1/b/y z.png"])
        check(fileKeys(in: "[\"a/x.pdf\", \"b/y.JPG\"]") == ["a/x.pdf", "b/y.JPG"])
        check(fileKeys(in: "s3://other-bucket/docs/umowa.pdf") == ["s3://other-bucket/docs/umowa.pdf"])
        // and what isn't one
        let notKeys: [DBValue] = ["x.jpg", "notes/readme", " a/b.jpg", "a/b.jpg ", "https://example.com/a/b.jpg", "a/b.exe", "{}", "[]", nil,
                                  "Zestawienie uczestników kampanii-Zdobądź dodatkowo.pdf", .text("a/" + String(repeating: "x", count: 1098))]
        for v in notKeys { check(fileKeys(in: v).isEmpty) }
        check(fileKeys(in: "{a/x.jpg,plain text}").isEmpty) // all or nothing

        // where a key lives
        check(s3Location(key: photo, bucket: "fleet-files").map { [$0.bucket, $0.key] } == ["fleet-files", photo])
        check(s3Location(key: "s3://other-bucket/docs/umowa.pdf", bucket: "fleet-files").map { [$0.bucket, $0.key] } == ["other-bucket", "docs/umowa.pdf"])
        check(s3Location(key: photo, bucket: "") == nil && s3Location(key: "s3://nokey", bucket: "b") == nil)

        // PocketBase file names: what its uploads look like, nothing that could leave the storage folder
        check(pocketBaseFileNameValid("protokol_pzsyf6ffav.pdf") && pocketBaseFileNameValid("pbc_1967373549") && pocketBaseFileNameValid("_pb_users_auth_"))
        for bad in ["", ".", "..", "../x", "a/b", ".hidden", "a b.jpg", "x\\y", "zażółć.jpg"] { check(!pocketBaseFileNameValid(bad)) }

        // a PocketBase file field holds a name, or a JSON array of names (several files)
        check(pocketBaseFileNames("protokol_pzsyf6ffav.pdf") == ["protokol_pzsyf6ffav.pdf"])
        check(pocketBaseFileNames("[\"a_1.jpg\",\"b_2.jpg\"]") == ["a_1.jpg", "b_2.jpg"])
        for v: DBValue in ["", "[]", nil, "[1]"] { check(pocketBaseFileNames(v).isEmpty) }

        // AWS profile names from ~/.aws/config ([profile x], [default]) and ~/.aws/credentials ([x]); no other sections, no values
        let config = "[default]\nregion = eu-central-1\n\n[profile fleet-backup]\nsso_session = fleet\n\n[sso-session fleet]\nsso_region = eu-central-1\n"
            + "  [profile  iltrans ]  \n# [profile commented]\n"
        let credentials = "[default]\naws_access_key_id = AKIAEXAMPLE\n[ci]\naws_secret_access_key = s3cr3t\n"
        check(awsProfileNames(config: config, credentials: credentials) == ["ci", "default", "fleet-backup", "iltrans"])
        check(awsProfileNames(config: nil, credentials: nil).isEmpty)

        // what the bytes are
        check(fileKind(Data("%PDF-1.7\n".utf8)) == .pdf)
        check(fileKind(Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 46, 46, 46, 46])) == .image)
        check(fileKind(Data([0xff, 0xd8, 0xff, 0xe0])) == .image)
        check(fileKind(Data([0x50, 0x4b, 3, 4])) == .other)
        check(fileKind(Data()) == .other)

        // the aws CLI: the object to stdout, the user's profile and region, an endpoint only when it isn't AWS
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var aws = fakeAWS(dir, "printf 'hello'")
        var r = await fetch(aws, "fleet-files", photo, region: "eu-central-1", profile: "fleet")
        check((try? r.get()) == Data("hello".utf8))
        check(args(dir) == ["s3", "cp", "s3://fleet-files/" + photo, "-", "--only-show-errors", "--cli-connect-timeout", "10",
                                   "--region", "eu-central-1", "--profile", "fleet", ""])
        _ = await fetch(aws, "b", "k/x.pdf", endpoint: "https://abc.r2.cloudflarestorage.com")
        check(args(dir) == ["s3", "cp", "s3://b/k/x.pdf", "-", "--only-show-errors", "--cli-connect-timeout", "10",
                                   "--endpoint-url", "https://abc.r2.cloudflarestorage.com", ""])
        _ = await fetch(aws, "b", "k/x.pdf", endpoint: "https://s3.eu-central-1.amazonaws.com") // AWS itself: not needed
        check(!args(dir).contains("--endpoint-url"))

        // errors: an expired SSO session says what to run; others show aws's message
        aws = fakeAWS(dir, "echo 'Error when retrieving token from sso: Token has expired and refresh failed' >&2; exit 255")
        check(message(await fetch(aws, "b", "k/x.pdf", profile: "fleet")).contains("aws sso login --profile fleet"))
        aws = fakeAWS(dir, "echo 'fatal error: An error occurred (404) when calling the HeadObject operation: Key \"k/x.pdf\" does not exist' >&2; exit 1")
        check(message(await fetch(aws, "b", "k/x.pdf")).contains("s3://b/k/x.pdf")) // a missing key, said plainly
        aws = fakeAWS(dir, "echo 'fatal error: Could not connect to the endpoint URL' >&2; exit 1")
        check(message(await fetch(aws, "b", "k/x.pdf")).contains("Could not connect")) // anything else: aws's own message
        // refused or missing in S3: said in plain words, naming the profile and the object
        aws = fakeAWS(dir, "echo 'download failed: s3://b/k/x.pdf to - An error occurred (403) when calling the HeadObject operation: Forbidden' >&2; exit 1")
        let refused = message(await fetch(aws, "b", "k/x.pdf", profile: "fleet-backup"))
        check(refused.contains("fleet-backup") && refused.contains("s3://b/k/x.pdf") && refused.contains("s3:GetObject"))
        aws = fakeAWS(dir, "echo 'download failed: s3://b/k/x.pdf to - An error occurred (404) when calling the HeadObject operation: Not Found' >&2; exit 1")
        let notFound = message(await fetch(aws, "b", "k/x.pdf"))
        check(notFound.contains("s3://b/k/x.pdf") && !notFound.contains("HeadObject"))
        aws = fakeAWS(dir, "echo 'Unable to locate credentials. You can configure credentials by running \"aws configure\".' >&2; exit 255")
        check(message(await fetch(aws, "b", "k/x.pdf")).contains("default"))
        // too big: stopped, not read into memory
        aws = fakeAWS(dir, "head -c 5000 /dev/zero")
        r = await fetch(aws, "b", "k/x.pdf")
        check(!message(r).isEmpty)
        // no aws at all
        check(message(await fetch((dir as NSString).appendingPathComponent("missing-aws"), "b", "k/x.pdf")).contains("aws"))
        print("file_test: OK")
    }
}
