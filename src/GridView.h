#import <Cocoa/Cocoa.h>
#import "DBConnection.h"

NS_ASSUME_NONNULL_BEGIN

// Siatka pokazująca DBResult. Kolumny budują się z wyniku, NULL jest szarą kursywą.
@interface GridView : NSScrollView <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, readonly) NSTableView *table;
@property (nonatomic, strong, nullable) DBResult *result;
// Ustawione = nagłówki kolumn są klikalne, a sortowanie robi wywołujący (np. ORDER BY w SQL).
@property (nonatomic, copy, nullable) void (^onSort)(NSString *column, BOOL ascending);
- (void)resetSort;
@end

// Komórka tabeli z polem tekstowym (i opcjonalnie ikoną), wyśrodkowana w pionie.
NSTableCellView *TBCell(NSTableView *table, NSString *identifier, BOOL withImage);

NS_ASSUME_NONNULL_END
