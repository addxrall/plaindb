#import "SQLCompletion.h"

@implementation SQLSuggestion
@end

static NSArray<NSString *> *Keywords(void) {
    return [@"select from where join left right inner outer full cross on as and or not in is null like ilike between exists "
             "group by order asc desc limit offset having distinct union all case when then else end insert into values update "
             "set delete returning with create table alter add column drop index primary key references default true false"
            componentsSeparatedByString:@" "];
}

static NSArray<NSString *> *Functions(void) {
    return @[@"count", @"sum", @"avg", @"min", @"max", @"coalesce", @"lower", @"upper", @"length", @"concat", @"now", @"date_trunc",
             @"round", @"cast", @"substring", @"trim", @"replace", @"json_extract"];
}

static BOOL IsWordChar(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c > 127;
}

static BOOL IsDefaultSchema(NSString *schema) {
    return [schema isEqual:@"public"] || [schema isEqual:@"main"];
}

static NSString *Unquote(NSString *s) {
    return [s hasPrefix:@"\""] && [s hasSuffix:@"\""] && s.length >= 2 ? [s substringWithRange:NSMakeRange(1, s.length - 2)] : s;
}

// "schema.table", "table" or quoted forms → the graph's table (a bare name prefers the default schema).
static SchemaTable *FindTable(SchemaGraph *schema, NSString *name) {
    NSArray *parts = [name componentsSeparatedByString:@"."];
    if (parts.count == 2) return [schema tableNamed:[NSString stringWithFormat:@"%@.%@", Unquote(parts[0]), Unquote(parts[1])]];
    NSString *bare = Unquote(name);
    SchemaTable *found = nil;
    for (SchemaTable *t in schema.tables)
        if ([t.name caseInsensitiveCompare:bare] == NSOrderedSame && (!found || IsDefaultSchema(t.schema))) found = t;
    return found;
}

// Is `cursor` inside a string literal or a comment of `text` (scanning from `start`)?
static BOOL InStringOrComment(NSString *text, NSUInteger start, NSUInteger cursor) {
    BOOL string = NO, line = NO, block = NO;
    for (NSUInteger i = start; i < cursor; i++) {
        unichar c = [text characterAtIndex:i], next = i + 1 < text.length ? [text characterAtIndex:i + 1] : 0;
        if (line) { if (c == '\n') line = NO; continue; }
        if (block) { if (c == '*' && next == '/') block = NO, i++; continue; }
        if (string) { if (c == '\'') string = NO; continue; }
        if (c == '\'') string = YES;
        else if (c == '-' && next == '-') line = YES;
        else if (c == '/' && next == '*') block = YES;
    }
    return string || line || block;
}

static SQLSuggestion *Make(NSString *text, NSString *detail, SQLSuggestionKind kind) {
    SQLSuggestion *s = [SQLSuggestion new];
    s.text = text;
    s.detail = detail;
    s.kind = kind;
    return s;
}

static NSString *TableText(SchemaTable *t) {
    return IsDefaultSchema(t.schema) ? t.name : t.qualifiedName;
}

NSArray<SQLSuggestion *> *SQLSuggestions(NSString *sql, NSUInteger cursor, SchemaGraph *schema, NSRange *replace) {
    return SQLSuggestionsAt(sql, cursor, schema, NO, replace);
}

NSArray<SQLSuggestion *> *SQLSuggestionsAt(NSString *sql, NSUInteger cursor, SchemaGraph *schema, BOOL evenWithoutWord, NSRange *replace) {
    cursor = MIN(cursor, sql.length);
    // the current statement: between the semicolons around the cursor
    NSRange before = [sql rangeOfString:@";" options:NSBackwardsSearch range:NSMakeRange(0, cursor)];
    NSUInteger start = before.location == NSNotFound ? 0 : NSMaxRange(before);
    NSRange after = [sql rangeOfString:@";" options:0 range:NSMakeRange(cursor, sql.length - cursor)];
    NSUInteger end = after.location == NSNotFound ? sql.length : after.location;
    NSString *statement = [sql substringWithRange:NSMakeRange(start, end - start)];

    // the word being typed, and "qualifier." in front of it
    NSUInteger wordStart = cursor;
    while (wordStart > start && IsWordChar([sql characterAtIndex:wordStart - 1])) wordStart--;
    if (replace) *replace = NSMakeRange(wordStart, cursor - wordStart);
    if (InStringOrComment(sql, start, wordStart)) return @[];
    NSString *prefix = [sql substringWithRange:NSMakeRange(wordStart, cursor - wordStart)];
    NSString *qualifier = nil;
    if (wordStart > start && [sql characterAtIndex:wordStart - 1] == '.') {
        NSUInteger q = wordStart - 1;
        if (q > start && [sql characterAtIndex:q - 1] == '"') { // "quoted".
            NSRange open = [sql rangeOfString:@"\"" options:NSBackwardsSearch range:NSMakeRange(start, q - 1 - start)];
            if (open.location != NSNotFound) qualifier = [sql substringWithRange:NSMakeRange(open.location + 1, q - 2 - open.location)];
        } else {
            NSUInteger qs = q;
            while (qs > start && IsWordChar([sql characterAtIndex:qs - 1])) qs--;
            if (qs < q) qualifier = [sql substringWithRange:NSMakeRange(qs, q - qs)];
        }
    }
    if (!qualifier && !prefix.length && !evenWithoutWord) return @[];

    // tables of this statement, by name and by alias
    static NSRegularExpression *sources;
    if (!sources)
        sources = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:from|join|update|into)\\s+((?:\"[^\"]+\"|\\w+)(?:\\.(?:\"[^\"]+\"|\\w+))?)(?:\\s+(?:as\\s+)?(\"[^\"]+\"|\\w+))?"
                                                            options:NSRegularExpressionCaseInsensitive error:nil];
    NSSet *notAliases = [NSSet setWithArray:[@"where join left right inner outer full cross on group order limit set values using natural "
                                              "union having select returning as" componentsSeparatedByString:@" "]];
    NSMutableDictionary<NSString *, SchemaTable *> *aliases = [NSMutableDictionary new];
    NSMutableOrderedSet<SchemaTable *> *used = [NSMutableOrderedSet new];
    for (NSTextCheckingResult *m in [sources matchesInString:statement options:0 range:NSMakeRange(0, statement.length)]) {
        SchemaTable *t = FindTable(schema, [statement substringWithRange:[m rangeAtIndex:1]]);
        if (!t) continue;
        [used addObject:t];
        aliases[t.name.lowercaseString] = t;
        if ([m rangeAtIndex:2].location != NSNotFound) {
            NSString *alias = Unquote([statement substringWithRange:[m rangeAtIndex:2]]);
            if (![notAliases containsObject:alias.lowercaseString]) aliases[alias.lowercaseString] = t;
        }
    }

    BOOL (^matches)(NSString *) = ^BOOL(NSString *candidate) {
        return !prefix.length || [candidate.lowercaseString hasPrefix:prefix.lowercaseString];
    };
    NSMutableArray<SQLSuggestion *> *out = [NSMutableArray new];

    if (qualifier) { // alias. / table. → columns; schema. → tables
        SchemaTable *t = aliases[Unquote(qualifier).lowercaseString] ?: FindTable(schema, qualifier);
        if (t) {
            for (NSArray *c in t.columns)
                if (matches(c[0])) [out addObject:Make(c[0], c[1], SQLSuggestionColumn)];
        } else {
            for (SchemaTable *s in schema.tables)
                if ([s.schema caseInsensitiveCompare:Unquote(qualifier)] == NSOrderedSame && matches(s.name))
                    [out addObject:Make(s.name, @"", SQLSuggestionTable)];
        }
        return out;
    }

    // the keyword right before the word decides between tables and everything else
    NSString *head = [[sql substringWithRange:NSMakeRange(start, wordStart - start)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRange lastWord = [head rangeOfString:@"[A-Za-z_]+$" options:NSRegularExpressionSearch];
    NSString *previous = lastWord.location == NSNotFound ? @"" : [head substringWithRange:lastWord].lowercaseString;
    NSArray<SchemaTable *> *tables = [schema.tables sortedArrayUsingComparator:^NSComparisonResult(SchemaTable *a, SchemaTable *b) {
        return [TableText(a) compare:TableText(b)];
    }];
    if ([@[@"from", @"join", @"update", @"into", @"table"] containsObject:previous]) {
        for (SchemaTable *t in tables)
            if (matches(t.name) || matches(TableText(t))) [out addObject:Make(TableText(t), @"", SQLSuggestionTable)];
        return out;
    }

    NSMutableSet *seen = [NSMutableSet new];
    for (SchemaTable *t in used)
        for (NSArray *c in t.columns)
            if (matches(c[0]) && ![seen containsObject:c[0]]) {
                [seen addObject:c[0]];
                [out addObject:Make(c[0], [NSString stringWithFormat:@"%@ · %@", c[1], t.name], SQLSuggestionColumn)];
            }
    for (SchemaTable *t in tables)
        if (matches(t.name)) [out addObject:Make(TableText(t), @"", SQLSuggestionTable)];
    BOOL upper = [prefix isEqual:prefix.uppercaseString] && ![prefix isEqual:prefix.lowercaseString];
    for (NSString *f in Functions())
        if (matches(f)) [out addObject:Make([(upper ? f.uppercaseString : f) stringByAppendingString:@"("], @"", SQLSuggestionFunction)];
    for (NSString *k in Keywords())
        if (matches(k) && ![k isEqual:prefix.lowercaseString]) [out addObject:Make(upper ? k.uppercaseString : k, @"", SQLSuggestionKeyword)];
    return out.count > 60 ? [out subarrayWithRange:NSMakeRange(0, 60)] : out;
}
