#import "FileRefs.h"
#import "DBConnection.h"

static NSSet<NSString *> *Extensions(void) {
    static NSSet *set;
    if (!set) set = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"heif", @"tif", @"tiff", @"bmp", @"svg",
                                          @"pdf", @"txt", @"csv", @"json", @"xml", @"xlsx", @"xls", @"docx", @"doc", @"odt", @"ods",
                                          @"pptx", @"zip", @"mp4", @"mov", @"m4a", @"mp3", @"wav"]];
    return set;
}

static BOOL IsKey(NSString *s) {
    if (s.length < 3 || s.length >= 1024) return NO;
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if ([space characterIsMember:[s characterAtIndex:0]] || [space characterIsMember:[s characterAtIndex:s.length - 1]]) return NO;
    if ([s rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return NO;
    NSString *lower = s.lowercaseString;
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) return NO;
    if ([lower hasPrefix:@"s3://"] && !FileS3Location(s, @"")) return NO;
    return [s containsString:@"/"] && [Extensions() containsObject:s.pathExtension.lowercaseString];
}

// {a,"b c"} → @[a, b c]; nil if it isn't a simple one-dimensional array literal.
static NSArray<NSString *> *PostgresArray(NSString *s) {
    NSMutableArray *items = [NSMutableArray new];
    NSMutableString *item = [NSMutableString new];
    BOOL quoted = NO, wasQuoted = NO;
    for (NSUInteger i = 1; i + 1 < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (quoted && c == '\\' && i + 2 < s.length) [item appendFormat:@"%C", [s characterAtIndex:++i]];
        else if (c == '"') quoted = !quoted, wasQuoted = YES;
        else if (c == ',' && !quoted) {
            [items addObject:[item copy]];
            [item setString:@""];
            wasQuoted = NO;
        } else if ((c == '{' || c == '}') && !quoted) return nil;
        else [item appendFormat:@"%C", c];
    }
    if (item.length || wasQuoted) [items addObject:item];
    return items;
}

NSArray<NSString *> *FileKeysInValue(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] < 3) return @[];
    NSString *s = value;
    NSArray *keys;
    if ([s hasPrefix:@"{"] && [s hasSuffix:@"}"]) keys = PostgresArray(s);
    else if ([s hasPrefix:@"["] && [s hasSuffix:@"]"]) keys = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    else keys = @[s];
    if (![keys isKindOfClass:NSArray.class] || !keys.count) return @[];
    for (id k in keys)
        if (![k isKindOfClass:NSString.class] || !IsKey(k)) return @[]; // all or nothing
    return keys;
}

NSArray<NSString *> *FileS3Location(NSString *key, NSString *bucket) {
    if ([key.lowercaseString hasPrefix:@"s3://"]) {
        NSString *rest = [key substringFromIndex:5];
        NSRange slash = [rest rangeOfString:@"/"];
        if (slash.location == NSNotFound || slash.location == 0 || NSMaxRange(slash) == rest.length) return nil;
        return @[[rest substringToIndex:slash.location], [rest substringFromIndex:NSMaxRange(slash)]];
    }
    return bucket.length ? @[bucket, key] : nil;
}

BOOL PocketBaseFileNameValid(NSString *name) {
    static NSRegularExpression *valid;
    if (!valid) valid = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_][A-Za-z0-9_.-]*$" options:0 error:NULL];
    return name.length && name.length < 256 && [valid firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

NSArray<NSString *> *PocketBaseFileNames(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return @[];
    if (![value hasPrefix:@"["]) return @[value];
    NSArray *names = [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (![names isKindOfClass:NSArray.class]) return @[];
    for (id n in names)
        if (![n isKindOfClass:NSString.class]) return @[];
    return names;
}

FileKind FileDataKind(NSData *data) {
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;
    if (n >= 4 && !memcmp(b, "%PDF", 4)) return FileKindPDF;
    if ((n >= 8 && !memcmp(b, "\x89PNG\r\n\x1a\n", 8)) || (n >= 3 && !memcmp(b, "\xff\xd8\xff", 3)) || (n >= 4 && !memcmp(b, "GIF8", 4)) ||
        (n >= 12 && !memcmp(b, "RIFF", 4) && !memcmp(b + 8, "WEBP", 4)) || (n >= 4 && (!memcmp(b, "II*\0", 4) || !memcmp(b, "MM\0*", 4))) ||
        (n >= 2 && !memcmp(b, "BM", 2)) || (n >= 12 && !memcmp(b + 4, "ftyp", 4) && (!memcmp(b + 8, "heic", 4) || !memcmp(b + 8, "mif1", 4))))
        return FileKindImage;
    return FileKindOther;
}

NSArray<NSString *> *AWSProfileNames(NSString *config, NSString *credentials) {
    NSMutableSet *names = [NSMutableSet new];
    for (NSArray *file in @[@[config ?: @"", @YES], @[credentials ?: @"", @NO]]) {
        for (NSString *raw in [file[0] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (![line hasPrefix:@"["] || ![line hasSuffix:@"]"]) continue;
            NSString *section = [[line substringWithRange:NSMakeRange(1, line.length - 2)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([file[1] boolValue]) { // config: "default" or "profile <name>"; sso-session and others aren't profiles
                if ([section hasPrefix:@"profile "]) section = [[section substringFromIndex:8] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                else if (![section isEqual:@"default"]) continue;
            }
            if (section.length) [names addObject:section];
        }
    }
    return [names.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

NSArray<NSString *> *AWSProfiles(void) {
    NSString *aws = [NSHomeDirectory() stringByAppendingPathComponent:@".aws"];
    return AWSProfileNames([NSString stringWithContentsOfFile:[aws stringByAppendingPathComponent:@"config"] encoding:NSUTF8StringEncoding error:NULL],
                           [NSString stringWithContentsOfFile:[aws stringByAppendingPathComponent:@"credentials"] encoding:NSUTF8StringEncoding error:NULL]);
}

NSString *FileAWSExecutable(void) {
    for (NSString *path in @[@"/opt/homebrew/bin/aws", @"/usr/local/bin/aws", @"/usr/bin/aws"])
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    return nil;
}

// aws's message, or plain words for the usual reasons: an expired SSO session, no access, no such object, no credentials.
static NSError *AWSError(NSString *stderrText, int status, NSString *profile, NSString *url) {
    NSString *text = [stderrText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *lower = text.lowercaseString;
    NSString *who = profile.length ? profile : L(@"default");
    if ([lower containsString:@"sso"] && ([lower containsString:@"expired"] || [lower containsString:@"token"])) {
        NSString *command = profile.length ? [@"aws sso login --profile " stringByAppendingString:profile] : @"aws sso login";
        return DBError([NSString stringWithFormat:L(@"The AWS session has expired. Run %@ in Terminal and try again."), command], nil);
    }
    if ([lower containsString:@"(403)"] || [lower containsString:@"forbidden"] || [lower containsString:@"accessdenied"] || [lower containsString:@"access denied"])
        return DBError([NSString stringWithFormat:L(@"AWS refused access to %@: the profile %@ can't read it. Give it s3:GetObject on the bucket, or choose another profile in the connection."), url, who], nil);
    if ([lower containsString:@"(404)"] || [lower containsString:@"not found"] || [lower containsString:@"nosuchkey"])
        return DBError([NSString stringWithFormat:L(@"There's no such file in S3: %@"), url], nil);
    if ([lower containsString:@"unable to locate credentials"] || [lower containsString:@"could not be found"] || [lower containsString:@"missing required configuration"])
        return DBError([NSString stringWithFormat:L(@"The AWS profile %@ has no working credentials. Set it up with aws configure (or aws configure sso), or choose another profile. %@"), who, text], nil);
    return DBError(text.length ? text : [NSString stringWithFormat:L(@"aws ended with status %d."), status], nil);
}

void FileS3Fetch(NSString *aws, NSString *bucket, NSString *key, NSString *region, NSString *profile, NSString *endpoint,
                 NSUInteger maxBytes, void (^done)(NSData *data, NSError *error)) {
    void (^finish)(NSData *, NSError *) = ^(NSData *data, NSError *error) { dispatch_async(dispatch_get_main_queue(), ^{ done(data, error); }); };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!aws || ![NSFileManager.defaultManager isExecutableFileAtPath:aws])
            return finish(nil, DBError(L(@"The aws command wasn't found. Install the AWS CLI (brew install awscli) and sign in."), nil));
        NSMutableArray *args = [@[@"s3", @"cp", [NSString stringWithFormat:@"s3://%@/%@", bucket, key], @"-", @"--only-show-errors",
                                  @"--cli-connect-timeout", @"10"] mutableCopy];
        if (region.length) [args addObjectsFromArray:@[@"--region", region]];
        if (profile.length) [args addObjectsFromArray:@[@"--profile", profile]];
        if (endpoint.length && ![endpoint.lowercaseString containsString:@"amazonaws.com"]) [args addObjectsFromArray:@[@"--endpoint-url", endpoint]];
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:aws];
        task.arguments = args;
        NSPipe *output = [NSPipe pipe], *errors = [NSPipe pipe];
        task.standardOutput = output;
        task.standardError = errors;
        task.standardInput = NSFileHandle.fileHandleWithNullDevice;
        NSMutableData *stderrData = [NSMutableData new];
        errors.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
            NSData *d = h.availableData;
            if (!d.length) h.readabilityHandler = nil;
            @synchronized (stderrData) { if (stderrData.length < 8192) [stderrData appendData:d]; }
        };
        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) return finish(nil, DBError(launchError.localizedDescription, nil));
        NSMutableData *data = [NSMutableData new];
        BOOL tooBig = NO;
        while (YES) {
            NSData *chunk = output.fileHandleForReading.availableData;
            if (!chunk.length) break;
            [data appendData:chunk];
            if (data.length > maxBytes) {
                tooBig = YES;
                [task terminate];
                break;
            }
        }
        [task waitUntilExit];
        usleep(20000); // the last of stderr
        if (tooBig) {
            NSString *limit = [NSByteCountFormatter stringFromByteCount:(long long)maxBytes countStyle:NSByteCountFormatterCountStyleFile];
            return finish(nil, DBError([NSString stringWithFormat:L(@"The file is bigger than %@, too big to preview."), limit], nil));
        }
        if (task.terminationStatus != 0) {
            NSString *text;
            @synchronized (stderrData) { text = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @""; }
            return finish(nil, AWSError(text, task.terminationStatus, profile, [NSString stringWithFormat:@"s3://%@/%@", bucket, key]));
        }
        finish(data, nil);
    });
}
