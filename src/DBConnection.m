#import "DBConnection.h"

@implementation DBResult
@end

static NSArray<NSNumber *> *SortedKeys(NSDictionary *d) {
    return [d.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

NSArray<NSArray *> *DBChangeStatements(NSString *schema, NSString *table, DBResult *result, NSArray<NSString *> *pkColumns,
                                      NSDictionary<NSNumber *, NSDictionary<NSNumber *, id> *> *edits, NSIndexSet *deleted,
                                      NSArray<NSDictionary<NSNumber *, id> *> *inserted) {
    if (!pkColumns.count) return @[];
    for (NSString *pk in pkColumns)
        if ([result.columns indexOfObject:pk] == NSNotFound) return @[];

    NSString *qualified = [NSString stringWithFormat:@"%@.%@", DBQuoteIdent(schema), DBQuoteIdent(table)];
    NSString *(^where)(NSUInteger, NSMutableArray *) = ^NSString *(NSUInteger row, NSMutableArray *params) {
        NSMutableArray *parts = [NSMutableArray new];
        for (NSString *pk in pkColumns) {
            [params addObject:result.rows[row][[result.columns indexOfObject:pk]]];
            [parts addObject:[NSString stringWithFormat:@"%@ = $%lu", DBQuoteIdent(pk), (unsigned long)params.count]];
        }
        return [parts componentsJoinedByString:@" AND "];
    };

    NSMutableArray *out = [NSMutableArray new];
    [deleted enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        NSMutableArray *params = [NSMutableArray new];
        NSString *w = where(row, params);
        [out addObject:@[[NSString stringWithFormat:@"DELETE FROM %@ WHERE %@", qualified, w], params, @YES]];
    }];

    for (NSNumber *row in SortedKeys(edits)) {
        if ([deleted containsIndex:row.unsignedIntegerValue] || !edits[row].count) continue;
        NSMutableArray *params = [NSMutableArray new], *sets = [NSMutableArray new];
        for (NSNumber *col in SortedKeys(edits[row])) {
            [params addObject:edits[row][col]];
            [sets addObject:[NSString stringWithFormat:@"%@ = $%lu", DBQuoteIdent(result.columns[col.unsignedIntegerValue]),
                                                       (unsigned long)params.count]];
        }
        NSString *w = where(row.unsignedIntegerValue, params);
        [out addObject:@[[NSString stringWithFormat:@"UPDATE %@ SET %@ WHERE %@", qualified, [sets componentsJoinedByString:@", "], w],
                         params, @YES]];
    }

    for (NSDictionary<NSNumber *, id> *values in inserted) {
        if (!values.count) {
            [out addObject:@[[NSString stringWithFormat:@"INSERT INTO %@ DEFAULT VALUES", qualified], @[], @NO]];
            continue;
        }
        NSMutableArray *params = [NSMutableArray new], *cols = [NSMutableArray new], *marks = [NSMutableArray new];
        for (NSNumber *col in SortedKeys(values)) {
            [params addObject:values[col]];
            [cols addObject:DBQuoteIdent(result.columns[col.unsignedIntegerValue])];
            [marks addObject:[NSString stringWithFormat:@"$%lu", (unsigned long)params.count]];
        }
        [out addObject:@[[NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES (%@)", qualified,
                                                    [cols componentsJoinedByString:@", "], [marks componentsJoinedByString:@", "]],
                         params, @NO]];
    }
    return out;
}

NSString *DBLikePattern(NSString *term) {
    NSString *escaped = [term stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"%" withString:@"\\%"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"_" withString:@"\\_"];
    return [NSString stringWithFormat:@"%%%@%%", escaped];
}

NSString *DBInlineParams(NSString *sql, NSArray *params) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\$(\\d+)" options:0 error:nil];
    NSMutableString *out = [NSMutableString new];
    __block NSUInteger last = 0;
    [re enumerateMatchesInString:sql options:0 range:NSMakeRange(0, sql.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        NSUInteger i = [sql substringWithRange:[m rangeAtIndex:1]].integerValue;
        if (i < 1 || i > params.count) return;
        id p = params[i - 1];
        [out appendString:[sql substringWithRange:NSMakeRange(last, m.range.location - last)]];
        [out appendString:p == NSNull.null ? @"NULL"
                                           : [NSString stringWithFormat:@"'%@'", [[p description] stringByReplacingOccurrencesOfString:@"'" withString:@"''"]]];
        last = NSMaxRange(m.range);
    }];
    [out appendString:[sql substringFromIndex:last]];
    return out;
}
