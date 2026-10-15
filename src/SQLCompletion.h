#import <Foundation/Foundation.h>
#import "SchemaGraph.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SQLSuggestionKind) { SQLSuggestionColumn, SQLSuggestionTable, SQLSuggestionFunction, SQLSuggestionKeyword };

@interface SQLSuggestion : NSObject
@property (nonatomic, copy) NSString *text;   // what gets inserted
@property (nonatomic, copy) NSString *detail; // a column's type and table, a table's column count, …
@property (nonatomic) SQLSuggestionKind kind;
@end

// What the SQL editor offers at `cursor`: tables after FROM / JOIN / UPDATE / INTO, a table's columns after
// "alias." or "table." (also with nothing typed yet), a schema's tables after "schema.", otherwise the columns of the
// current statement's tables, tables, functions and keywords. Nothing inside strings or comments, nothing when no
// word is being typed (except after a dot). `replace` gets the range of the word being typed.
NSArray<SQLSuggestion *> *SQLSuggestions(NSString *sql, NSUInteger cursor, SchemaGraph *_Nullable schema, NSRange *replace);
// The same; with `evenWithoutWord` (asked for with ⌃Space) also when nothing is typed yet.
NSArray<SQLSuggestion *> *SQLSuggestionsAt(NSString *sql, NSUInteger cursor, SchemaGraph *_Nullable schema, BOOL evenWithoutWord,
                                           NSRange *_Nullable replace);

NS_ASSUME_NONNULL_END
