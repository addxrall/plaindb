#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Values that point to files kept elsewhere (an S3 bucket, PocketBase's storage), and fetching them.

// The file keys a value holds: one key ("pbc_123/abc/photo.jpeg", "s3://bucket/key.pdf"), a Postgres array or
// a JSON array of keys. A key has a "/", a known file extension and no whitespace at its ends; http(s) URLs are
// left to the image preview. Empty when the value isn't (only) keys. Cheap enough for every cell drawn.
NSArray<NSString *> *FileKeysInValue(id _Nullable value);

// @[bucket, key] for a key: an s3:// URL names its own bucket, anything else goes to `bucket`; nil without one.
NSArray<NSString *> *_Nullable FileS3Location(NSString *key, NSString *bucket);

// A name PocketBase gives a collection, record or uploaded file: letters, digits, "_", "." and "-", not starting
// with "."; so joining them can't leave the storage folder.
BOOL PocketBaseFileNameValid(NSString *name);

// The file names in a PocketBase file field: one name, or a JSON array of names. Empty for no files.
NSArray<NSString *> *PocketBaseFileNames(id _Nullable value);

typedef NS_ENUM(NSInteger, FileKind) { FileKindOther, FileKindImage, FileKindPDF };
FileKind FileDataKind(NSData *data);

// Profile names, sorted, from the texts of ~/.aws/config ("[profile name]", "[default]") and ~/.aws/credentials
// ("[name]"); other sections and all values are skipped.
NSArray<NSString *> *AWSProfileNames(NSString *_Nullable config, NSString *_Nullable credentials);
// The same read from the user's ~/.aws files.
NSArray<NSString *> *AWSProfiles(void);

// The aws CLI, where Homebrew or the installer put it; nil if missing.
NSString *_Nullable FileAWSExecutable(void);

// Downloads s3://bucket/key with the aws CLI into memory (the user's own profile, SSO included; PlainDB keeps no
// AWS secrets). Empty region / profile / endpoint: aws's defaults; an endpoint on amazonaws.com isn't passed.
// Stops past maxBytes. `done` runs on the main queue.
void FileS3Fetch(NSString *_Nullable aws, NSString *bucket, NSString *key, NSString *region, NSString *profile, NSString *endpoint,
                 NSUInteger maxBytes, void (^done)(NSData *_Nullable data, NSError *_Nullable error));

NS_ASSUME_NONNULL_END
