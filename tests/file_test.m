// File references: which values point to files, S3 locations, PocketBase names, and the aws CLI download
// (with a fake aws script). `make test`.
#import "FileRefs.h"
#import <assert.h>

static NSString *Dir(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

// A stand-in for aws: writes its arguments to args.txt next to it, then runs `body`.
static NSString *FakeAWS(NSString *dir, NSString *body) {
    NSString *path = [dir stringByAppendingPathComponent:@"aws"];
    NSString *script = [NSString stringWithFormat:@"#!/bin/sh\nprintf '%%s\\n' \"$@\" > \"$(dirname \"$0\")/args.txt\"\n%@\n", body];
    [script writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:path error:NULL];
    return path;
}

// Waits for FileS3Fetch, which answers on the main queue.
static void Fetch(NSString *aws, NSString *bucket, NSString *key, NSString *region, NSString *profile, NSString *endpoint, NSUInteger max,
                  NSData **data, NSError **error) {
    __block BOOL finished = NO;
    __block NSData *gotData = nil;
    __block NSError *gotError = nil;
    FileS3Fetch(aws, bucket, key, region, profile, endpoint, max, ^(NSData *d, NSError *e) {
        gotData = d;
        gotError = e;
        finished = YES;
    });
    while (!finished) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    *data = gotData;
    *error = gotError;
}

int main(void) {
    @autoreleasepool {
        // keys as fleet stores them, in a column, a Postgres array or a JSON array
        NSString *photo = @"pbc_1967373549/yhlcagepu9z8tod/g4r_nb_pywo_aawty_s_0cugwg1nf2.jpeg";
        assert([FileKeysInValue(photo) isEqual:@[photo]]);
        assert(([FileKeysInValue(@"{pbc_1/a/x.jpg,\"pbc_1/b/y z.png\"}") isEqual:(@[@"pbc_1/a/x.jpg", @"pbc_1/b/y z.png"])]));
        assert(([FileKeysInValue(@"[\"a/x.pdf\", \"b/y.JPG\"]") isEqual:(@[@"a/x.pdf", @"b/y.JPG"])]));
        assert(([FileKeysInValue(@"s3://other-bucket/docs/umowa.pdf") isEqual:@[@"s3://other-bucket/docs/umowa.pdf"]]));
        // and what isn't one
        for (id v in @[@"x.jpg", @"notes/readme", @" a/b.jpg", @"a/b.jpg ", @"https://example.com/a/b.jpg", @"a/b.exe", @"{}", @"[]", NSNull.null,
                       @"Zestawienie uczestników kampanii-Zdobądź dodatkowo.pdf", [@"a/" stringByPaddingToLength:1100 withString:@"x" startingAtIndex:0]])
            assert(FileKeysInValue(v).count == 0);
        assert(FileKeysInValue(@"{a/x.jpg,plain text}").count == 0); // all or nothing

        // where a key lives
        NSArray *loc = FileS3Location(photo, @"fleet-files");
        assert(([loc isEqual:(@[@"fleet-files", photo])]));
        assert(([FileS3Location(@"s3://other-bucket/docs/umowa.pdf", @"fleet-files") isEqual:(@[@"other-bucket", @"docs/umowa.pdf"])]));
        assert(FileS3Location(photo, @"") == nil && FileS3Location(@"s3://nokey", @"b") == nil);

        // PocketBase file names: what its uploads look like, nothing that could leave the storage folder
        assert(PocketBaseFileNameValid(@"protokol_pzsyf6ffav.pdf") && PocketBaseFileNameValid(@"pbc_1967373549") && PocketBaseFileNameValid(@"_pb_users_auth_"));
        for (NSString *bad in @[@"", @".", @"..", @"../x", @"a/b", @".hidden", @"a b.jpg", @"x\\y", @"zażółć.jpg"]) assert(!PocketBaseFileNameValid(bad));

        // a PocketBase file field holds a name, or a JSON array of names (several files)
        assert([PocketBaseFileNames(@"protokol_pzsyf6ffav.pdf") isEqual:@[@"protokol_pzsyf6ffav.pdf"]]);
        assert(([PocketBaseFileNames(@"[\"a_1.jpg\",\"b_2.jpg\"]") isEqual:(@[@"a_1.jpg", @"b_2.jpg"])]));
        for (id v in @[@"", @"[]", NSNull.null, @"[1]"]) assert(PocketBaseFileNames(v).count == 0);

        // what the bytes are
        assert(FileDataKind([NSData dataWithBytes:"%PDF-1.7\n" length:9]) == FileKindPDF);
        assert(FileDataKind([NSData dataWithBytes:"\x89PNG\r\n\x1a\n...." length:12]) == FileKindImage);
        assert(FileDataKind([NSData dataWithBytes:"\xff\xd8\xff\xe0" length:4]) == FileKindImage);
        assert(FileDataKind([NSData dataWithBytes:"PK\x03\x04" length:4]) == FileKindOther);
        assert(FileDataKind([NSData data]) == FileKindOther);

        // the aws CLI: the object to stdout, the user's profile and region, an endpoint only when it isn't AWS
        NSString *dir = Dir();
        NSString *aws = FakeAWS(dir, @"printf 'hello'");
        NSData *data = nil;
        NSError *error = nil;
        Fetch(aws, @"fleet-files", photo, @"eu-central-1", @"fleet", @"", 1024, &data, &error);
        assert(!error && [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] isEqual:@"hello"]);
        NSString *args = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"args.txt"] encoding:NSUTF8StringEncoding error:NULL];
        assert(([[args componentsSeparatedByString:@"\n"] isEqual:(@[@"s3", @"cp", [@"s3://fleet-files/" stringByAppendingString:photo], @"-",
                                                                   @"--only-show-errors", @"--cli-connect-timeout", @"10",
                                                                   @"--region", @"eu-central-1", @"--profile", @"fleet", @""])]));
        Fetch(aws, @"b", @"k/x.pdf", @"", @"", @"https://abc.r2.cloudflarestorage.com", 1024, &data, &error);
        args = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"args.txt"] encoding:NSUTF8StringEncoding error:NULL];
        assert(([[args componentsSeparatedByString:@"\n"] isEqual:(@[@"s3", @"cp", @"s3://b/k/x.pdf", @"-", @"--only-show-errors",
                                                                   @"--cli-connect-timeout", @"10", @"--endpoint-url", @"https://abc.r2.cloudflarestorage.com", @""])]));
        Fetch(aws, @"b", @"k/x.pdf", @"", @"", @"https://s3.eu-central-1.amazonaws.com", 1024, &data, &error); // AWS itself: not needed
        args = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"args.txt"] encoding:NSUTF8StringEncoding error:NULL];
        assert(![args containsString:@"--endpoint-url"]);

        // errors: an expired SSO session says what to run; others show aws's message
        aws = FakeAWS(dir, @"echo 'Error when retrieving token from sso: Token has expired and refresh failed' >&2; exit 255");
        Fetch(aws, @"b", @"k/x.pdf", @"", @"fleet", @"", 1024, &data, &error);
        assert(!data && [error.localizedDescription containsString:@"aws sso login --profile fleet"]);
        aws = FakeAWS(dir, @"echo 'fatal error: An error occurred (404) when calling the HeadObject operation: Key \"k/x.pdf\" does not exist' >&2; exit 1");
        Fetch(aws, @"b", @"k/x.pdf", @"", @"", @"", 1024, &data, &error);
        assert(!data && [error.localizedDescription containsString:@"does not exist"]);
        // too big: stopped, not read into memory
        aws = FakeAWS(dir, @"head -c 5000 /dev/zero");
        Fetch(aws, @"b", @"k/x.pdf", @"", @"", @"", 1024, &data, &error);
        assert(!data && error);
        // no aws at all
        Fetch([dir stringByAppendingPathComponent:@"missing-aws"], @"b", @"k/x.pdf", @"", @"", @"", 1024, &data, &error);
        assert(!data && [error.localizedDescription containsString:@"aws"]);

        puts("file_test: OK");
    }
    return 0;
}
