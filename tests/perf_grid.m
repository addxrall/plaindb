// Scroll performance of GridView on a "big table" page: `make perf`.
// Opens a real window (it shows up for a few seconds), loads 200 rows × 30 columns of realistic
// values (UUIDs, numbers, NULLs, multi-line text, 4 KB JSON) and scrolls step by step, timing each
// step including layout and Core Animation commit. Fails above the frame budget for 120 Hz.
// Timings depend on the machine, so this is not part of `make test`.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <sys/resource.h>
#import "GridView.h"

static const double Budget = 8.3; // ms per frame at 120 Hz

static DBResult *BigPage(NSUInteger rows, NSUInteger cols) {
    srand48(42);
    NSMutableArray *names = [NSMutableArray new], *data = [NSMutableArray new];
    for (NSUInteger c = 0; c < cols; c++) [names addObject:[NSString stringWithFormat:@"column_%lu", (unsigned long)c]];
    NSString *json = [@"" stringByPaddingToLength:4000 withString:@"{\"key\": \"value\", \"n\": 12345}, " startingAtIndex:0];
    for (NSUInteger r = 0; r < rows; r++) {
        NSMutableArray *row = [NSMutableArray new];
        for (NSUInteger c = 0; c < cols; c++) {
            switch (c % 6) {
                case 0: [row addObject:NSUUID.UUID.UUIDString.lowercaseString]; break;
                case 1: [row addObject:@(lrand48() % 100000).stringValue]; break;
                case 2: [row addObject:[NSString stringWithFormat:@"%.2f", drand48() * 1000]]; break;
                case 3: [row addObject:drand48() < 0.3 ? NSNull.null : @"2025-04-04 12:34:56+02"]; break;
                case 4: [row addObject:[NSString stringWithFormat:@"Some longer text value number %lu\nwith a second line", (unsigned long)r]]; break;
                default: [row addObject:json]; break;
            }
        }
        [data addObject:row];
    }
    DBResult *result = [DBResult new];
    result.columns = names;
    result.rows = data;
    return result;
}

static double Now(void) {
    return CACurrentMediaTime() * 1000;
}

// CPU time used by the process so far (user + system), ms.
static double CPU(void) {
    struct rusage u;
    getrusage(RUSAGE_SELF, &u);
    return (u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000.0 + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000.0;
}

// Memory as Activity Monitor shows it ("Memory" column), MB.
static double Footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    return info.phys_footprint / 1048576.0;
}

// Returns the average step time.
static double Report(const char *name, NSArray<NSNumber *> *times) {
    NSArray *sorted = [times sortedArrayUsingSelector:@selector(compare:)];
    double sum = 0;
    for (NSNumber *t in times) sum += t.doubleValue;
    NSUInteger slow = [times indexesOfObjectsPassingTest:^BOOL(NSNumber *t, NSUInteger i, BOOL *s) { return t.doubleValue > 2 * Budget; }].count;
    printf("%-11s %3lu steps  avg %6.2f ms  p95 %6.2f ms  max %6.2f ms  dropped frames (>%.0f ms): %lu\n", name, (unsigned long)times.count,
           sum / times.count, [sorted[(NSUInteger)(sorted.count * 0.95)] doubleValue], [sorted.lastObject doubleValue], 2 * Budget,
           (unsigned long)slow);
    return sum / times.count;
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 1100, 700)
                                                       styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        GridView *grid = [[GridView alloc] initWithFrame:NSMakeRect(0, 0, 1100, 700)];
        grid.onSort = ^(NSString *c, BOOL a) {};
        grid.onOpenImage = ^(NSInteger r, NSInteger c, NSRect rect) {}; // as in the app: every cell is checked for images
        window.contentView = grid;
        [window orderFrontRegardless];
        DBResult *page = BigPage(200, 30);
        double memoryBefore = Footprint();

        double t0 = Now();
        grid.result = page;
        [window displayIfNeeded];
        [CATransaction flush];
        double load = Now() - t0;
        printf("load page  %.1f ms\n", load);

        NSMutableArray *vertical = [NSMutableArray new], *horizontal = [NSMutableArray new];
        NSClipView *clip = grid.contentView;
        void (^step)(NSPoint, NSMutableArray *) = ^(NSPoint p, NSMutableArray *times) {
            double t = Now();
            [clip scrollToPoint:p];
            [grid reflectScrolledClipView:clip];
            [window displayIfNeeded];
            [CATransaction flush];
            [times addObject:@(Now() - t)];
        };
        double cpu0 = CPU(), wall0 = Now();
        for (int pass = 0; pass < 2; pass++) {
            for (CGFloat y = 0; y < NSHeight(grid.table.frame) - 600; y += 40) step(NSMakePoint(0, y), vertical);
            for (CGFloat x = 0; x < NSWidth(grid.table.frame) - 1000; x += 60) step(NSMakePoint(x, 0), horizontal);
        }
        double cpu = CPU() - cpu0, wall = Now() - wall0;
        double v = Report("vertical", vertical), h = Report("horizontal", horizontal);
        printf("cpu        %.0f ms of CPU for %lu steps (%.2f ms per step, %.0f%% of one core while scrolling)\n", cpu,
               (unsigned long)(vertical.count + horizontal.count), cpu / (vertical.count + horizontal.count), 100 * cpu / wall);
        printf("memory     %.1f MB for the grid with a loaded page (process %.1f MB)\n", Footprint() - memoryBefore, Footprint());
        BOOL ok = v <= Budget && h <= Budget && load < 100;
        printf("perf_grid: %s (budget %.1f ms per step, 100 ms per page)\n", ok ? "OK" : "TOO SLOW", Budget);
        return ok ? 0 : 1;
    }
}
