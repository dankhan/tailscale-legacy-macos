// TailscaleMenu.m — menu-bar status item for tailscaled on legacy macOS.
//
// Deliberately conservative ObjC so one x86_64 binary runs on 10.6 AND 10.9:
//   no ARC, no blocks, no @autoreleasepool, no NSJSONSerialization (10.7+),
//   no props beyond ancient AppKit.  Pure NSStatusItem + NSMenu + NSTask.
//
// Talks to:  /usr/local/bin/tailscale (falls back to /opt/local/bin/tailscale)
//            --socket=/var/run/tailscaled.socket
// Selftest:  ./TailscaleMenu --selftest   (parse + menu structure to stdout)

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <mach/mach_time.h>

@class TSCommand;
// NSTimer retains this relay, which deliberately does not retain the controller.
@interface TSPollTarget : NSObject {
@public
    id controller;
}
- (void)fire:(NSTimer *)t;
@end

@interface TSCommand : NSOperation {
@public
    id controller;
    NSString *kind;
    NSDictionary *result;
    NSDictionary *statusResult;
@private
    BOOL cancellationRequested;
}
- (id)initWithController:(id)c kind:(NSString *)k;
- (void)requestCancellation;
- (BOOL)cancellationRequested;
- (void)detachController;
@end

static NSString *kSocket = @"/var/run/tailscaled.socket";

@interface AppController : NSObject <NSMenuDelegate, NSApplicationDelegate> {
    NSStatusItem *statusItem;
    NSMenu *menu;
    NSTimer *timer;
    NSOperationQueue *commands;
    TSCommand *activeCommand;
    BOOL stopping;
    BOOL quitting;
    BOOL cleanupFailed;
    NSMutableArray *peerLines;   // parsed "ip name owner os" rows
    NSString *selfLine;          // first row: this machine
    NSString *notice;            // "Logged out." / auth URL / error
    NSString *loginURL;
}
- (id)initWithUI:(BOOL)ui;
- (void)refreshIcon;
- (void)startCommand:(NSString *)kind;
- (void)updateCommandAvailability;
- (void)commandFinished:(TSCommand *)command;
- (void)applyStatus:(NSDictionary *)result;
- (void)openURL:(NSString *)u;
- (void)stopPolling;
- (void)pollStatus:(NSTimer *)t;
- (void)menuNeedsUpdate:(NSMenu *)m;
- (void)toggle:(id)sender;
- (void)copyRow:(id)sender;
- (void)copySelfIP:(id)sender;
- (void)openLogin:(id)sender;
- (void)openAdmin:(id)sender;
- (void)quit:(id)sender;
@end

static NSString *TSBinary(void) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/local/bin/tailscale"])
        return @"/usr/local/bin/tailscale";
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:@"/opt/local/bin/tailscale"])
        return @"/opt/local/bin/tailscale";
    return nil;
}

// Monotonic deadlines work even if the wall clock changes.
static double MonotonicTime(void) {
    mach_timebase_info_data_t scale;
    mach_timebase_info(&scale);
    return (double)mach_absolute_time() * scale.numer / scale.denom / 1e9;
}

// Worker-only runner. Bound output as well as time; never wait on pipe EOF.
static NSDictionary *RunTS(NSArray *args, TSCommand *operation, double timeout) {
    NSCAssert(![NSThread isMainThread], @"CLI execution must stay off the main thread");
    NSString *error = nil;
    NSString *bin = TSBinary();
    if (!bin) return [NSDictionary dictionaryWithObject:@"Tailscale CLI unavailable" forKey:@"error"];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"--socket", kSocket, nil];
    [arguments addObjectsFromArray:args];
    [task setLaunchPath:bin];
    [task setArguments:arguments];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" forKey:@"PATH"];
    [task setEnvironment:env];
    [env release];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    NSFileHandle *reader = [pipe fileHandleForReading];
    int fd = [reader fileDescriptor];
    NSMutableData *data = [NSMutableData data];
    BOOL launched = NO;
    BOOL unreaped = NO;
    @try {
        if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == -1)
            [NSException raise:@"PipeSetup" format:@"Cannot configure command pipe"];
        if ([operation cancellationRequested]) error = @"Command cancelled";
        else {
            [task launch];
            launched = YES;
            double deadline = MonotonicTime() + timeout;
            for (;;) {
                // A flood of output must not starve timeout/cancellation checks.
                char buffer[8192];
                for (int i = 0; i < 8; i++) {
                    ssize_t n = read(fd, buffer, sizeof(buffer));
                    if (n > 0) {
                        if ([data length] + n > 1024 * 1024) {
                            error = @"Tailscale output too large";
                            break;
                        }
                        [data appendBytes:buffer length:(NSUInteger)n];
                    } else {
                        if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
                            error = @"Cannot read Tailscale output";
                        break;
                    }
                }
                if ([operation cancellationRequested]) error = @"Command cancelled";
                if (!error && MonotonicTime() >= deadline) error = @"Tailscale command timed out";
                if (error) break;
                if (![task isRunning]) {
                    // The child exited. Drain buffered bytes without relying on EOF
                    // (a descendant could still hold the write end open).
                    ssize_t n;
                    while ((n = read(fd, buffer, sizeof(buffer))) > 0) {
                        if ([data length] + n > 1024 * 1024) {
                            error = @"Tailscale output too large";
                            break;
                        }
                        [data appendBytes:buffer length:(NSUInteger)n];
                        if (MonotonicTime() >= deadline) {
                            error = @"Tailscale command timed out";
                            break;
                        }
                    }
                    if (!error && [task terminationStatus] != 0) error = @"Tailscale command failed";
                    break;
                }
                [NSThread sleepForTimeInterval:0.02];
            }
        }
    } @catch (NSException *exception) {
        error = @"Cannot execute Tailscale CLI";
    } @finally {
        if (launched && [task isRunning]) {
            // Only signal the NSTask child, never the system tailscaled daemon.
            kill([task processIdentifier], SIGTERM);
            double deadline = MonotonicTime() + 0.25;
            while ([task isRunning] && MonotonicTime() < deadline)
                [NSThread sleepForTimeInterval:0.01];
            if ([task isRunning]) kill([task processIdentifier], SIGKILL);
            deadline = MonotonicTime() + 1.0;
            while ([task isRunning] && MonotonicTime() < deadline)
                [NSThread sleepForTimeInterval:0.01];
            unreaped = [task isRunning];
        }
        [reader closeFile];
        [[pipe fileHandleForWriting] closeFile];
    }
    NSString *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!output && !error) error = @"Invalid Tailscale output";
    NSMutableDictionary *r = [NSMutableDictionary dictionaryWithObject:output ? output : @"" forKey:@"output"];
    if (error) [r setObject:error forKey:@"error"];
    if (unreaped) [r setObject:@"Child process cleanup failed; restart the menu app" forKey:@"cleanupError"];
    return r;
}

@implementation TSCommand
- (id)initWithController:(id)c kind:(NSString *)k {
    if ((self = [super init])) { controller = [c retain]; kind = [k copy]; }
    return self;
}
- (void)requestCancellation { @synchronized(self) { cancellationRequested = YES; } }
- (BOOL)cancellationRequested { @synchronized(self) { return cancellationRequested; } }
- (void)detachController { [controller release]; controller = nil; }
- (void)dealloc {
    [controller release]; [kind release]; [result release]; [statusResult release];
    [super dealloc];
}
- (void)main {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSArray *args = [kind isEqual:@"up"] ? [NSArray arrayWithObjects:@"up", @"--timeout=8s", nil]
                                           : [NSArray arrayWithObject:kind];
    result = [RunTS(args, self, ([kind isEqual:@"up"] || [kind isEqual:@"down"]) ? 10.0 : 5.0) retain];
    if (([kind isEqual:@"up"] || [kind isEqual:@"down"]) &&
        ![self cancellationRequested] && ![result objectForKey:@"cleanupError"])
        statusResult = [RunTS([NSArray arrayWithObject:@"status"], self, 5.0) retain];
    [controller performSelectorOnMainThread:@selector(commandFinished:) withObject:self
                             waitUntilDone:NO modes:[NSArray arrayWithObjects:NSRunLoopCommonModes, NSDefaultRunLoopMode, nil]];
    [pool drain];
}
@end

@implementation TSPollTarget
- (void)fire:(NSTimer *)t { [controller pollStatus:t]; }
@end

// Pull "https://login.tailscale.com/a/..." out of arbitrary output.
static NSString *FindLoginURL(NSString *s) {
    if (!s) return nil;
    NSRange found = [s rangeOfString:@"https://login.tailscale.com/"];
    if (found.location == NSNotFound) return nil;
    NSString *rest = [s substringFromIndex:found.location];
    NSRange sp = [rest rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return (sp.location == NSNotFound) ? rest : [rest substringToIndex:sp.location];
}

// Split a status row on any whitespace run (tailscale pads columns with spaces).
static NSArray *SplitFields(NSString *row) {
    NSMutableArray *out = [NSMutableArray array];
    NSScanner *sc = [NSScanner scannerWithString:row];
    [sc setCharactersToBeSkipped:[NSCharacterSet whitespaceCharacterSet]];
    NSString *tok = nil;
    while ([sc scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet]
                              intoString:&tok]) {
        [out addObject:tok]; // The array retains this non-owned scanner result.
        tok = nil;
    }
    return out;
}

@implementation AppController

- (id)init {
    return [self initWithUI:YES];
}

- (id)initWithUI:(BOOL)ui {
    self = [super init];
    if (self) {
        peerLines = [[NSMutableArray alloc] init];
        menu = [[NSMenu alloc] initWithTitle:@"Tailscale"];
        [menu setDelegate:self];
        [menu setAutoenablesItems:NO];
        commands = [[NSOperationQueue alloc] init];
        [commands setMaxConcurrentOperationCount:1];
        notice = [@"Checking Tailscale…" retain];
        if (ui) {
            statusItem = [[[NSStatusBar systemStatusBar]
                            statusItemWithLength:NSVariableStatusItemLength] retain];
            [statusItem setHighlightMode:YES];
            [statusItem setMenu:menu];
            [self refreshIcon];
            // rebuild on open + refresh every 12s
            TSPollTarget *relay = [[[TSPollTarget alloc] init] autorelease];
            relay->controller = self;
            timer = [[NSTimer scheduledTimerWithTimeInterval:12.0 target:relay
                                                    selector:@selector(fire:)
                                                    userInfo:nil repeats:YES] retain];
        }
        [self pollStatus:nil];
    }
    return self;
}

- (void)stopPolling {
    stopping = YES;
    [activeCommand requestCancellation];
    [timer invalidate];
    [timer release];
    timer = nil;
}

- (void)dealloc {
    [self stopPolling];
    [activeCommand release];
    [commands release];
    [menu setDelegate:nil];
    if (statusItem) [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
    [statusItem release];
    [menu release];
    [peerLines release];
    [selfLine release];
    [notice release];
    [loginURL release];
    [super dealloc];
}

- (void)startCommand:(NSString *)kind {
    NSAssert([NSThread isMainThread], @"Commands must be admitted on the main thread");
    if (stopping || cleanupFailed || activeCommand) return;
    activeCommand = [[TSCommand alloc] initWithController:self kind:kind];
    [commands addOperation:activeCommand];
    [self updateCommandAvailability];
}

- (void)pollStatus:(NSTimer *)t {
    (void)t;
    [self startCommand:@"status"];
}

- (void)commandFinished:(TSCommand *)command {
    NSAssert([NSThread isMainThread], @"UI completion must run on the main thread");
    if (!stopping) {
        NSDictionary *r = command->result;
        NSString *kind = command->kind;
        if ([r objectForKey:@"cleanupError"] || [command->statusResult objectForKey:@"cleanupError"]) {
            cleanupFailed = YES;
            [notice release]; notice = [@"Child process cleanup failed; restart the menu app" retain];
            [selfLine release]; selfLine = nil;
            [loginURL release]; loginURL = nil;
            [peerLines removeAllObjects];
        } else if ([kind isEqual:@"ip"]) {
            if (![r objectForKey:@"error"]) {
                NSString *ip = [[r objectForKey:@"output"] stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([ip length]) {
                    NSPasteboard *pb = [NSPasteboard generalPasteboard];
                    [pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
                    [pb setString:ip forType:NSStringPboardType];
                }
            }
        } else {
            [self applyStatus:command->statusResult ? command->statusResult : r];
            NSString *url = FindLoginURL([r objectForKey:@"output"]);
            if ([kind isEqual:@"up"] && url && !selfLine) {
                [loginURL release]; loginURL = [url copy];
                [notice release]; notice = [@"Needs login" retain];
            } else if (([kind isEqual:@"up"] || [kind isEqual:@"down"]) && [r objectForKey:@"error"]) {
                [notice release]; notice = [[r objectForKey:@"error"] copy];
            }
        }
        [self refreshIcon];
    }
    // Break the operation/controller ownership link on the main thread.
    [command detachController];
    [activeCommand release]; activeCommand = nil;
    [self updateCommandAvailability];
    if (quitting) [NSApp replyToApplicationShouldTerminate:YES];
}

- (void)updateCommandAvailability {
    NSAssert([NSThread isMainThread], @"Menu availability belongs to the main thread");
    for (NSMenuItem *item in [menu itemArray]) {
        if ([item action] == @selector(toggle:) || [item action] == @selector(copySelfIP:))
            [item setEnabled:!activeCommand && !stopping && !cleanupFailed];
    }
}

- (void)applyStatus:(NSDictionary *)result {
    NSAssert([NSThread isMainThread], @"Status state belongs to the main thread");
    NSString *out = [result objectForKey:@"output"];
    NSString *previousURL = [[loginURL retain] autorelease];
    [peerLines removeAllObjects];
    [selfLine release]; selfLine = nil;
    [notice release]; notice = nil;
    [loginURL release]; loginURL = nil;

    if ([result objectForKey:@"error"]) {
        notice = [[result objectForKey:@"error"] copy];
        loginURL = [FindLoginURL(out) copy];
        if (loginURL) { [notice release]; notice = [@"Needs login" retain]; }
    } else if ([out hasPrefix:@"Logged out"]) {
        notice = [@"Logged out" retain];
        loginURL = [FindLoginURL(out) retain];
    } else {
        NSArray *rows = [out componentsSeparatedByString:@"\n"];
        NSUInteger i = 0;
        for (NSString *row in rows) {
            if ([row length] == 0) continue;
            NSArray *f = SplitFields(row);
            // "100.x.y.z  name  owner@  os  ..."  (tab or space separated)
            if ([f count] >= 4 && [(NSString *)[f objectAtIndex:0] hasPrefix:@"100."]) {
                if (i == 0) selfLine = [[f objectAtIndex:1] copy];
                else [peerLines addObject:row];
                i++;
            } else if (i == 0 && [row rangeOfString:@"https://"].location != NSNotFound) {
                [notice release];
                notice = [@"Needs login" retain];
                [loginURL release];
                loginURL = [FindLoginURL(row) retain];
            }
        }
        if (!selfLine && !notice) notice = [@"Tailscale status unavailable" retain];
    }
    if (!selfLine && !loginURL && [out hasPrefix:@"Logged out"])
        loginURL = [previousURL copy];
    [self refreshIcon];
}

- (void)refreshIcon {
    NSAssert([NSThread isMainThread], @"AppKit must run on the main thread");
    NSString *n = notice ? NSImageNameStatusUnavailable
                         : NSImageNameStatusAvailable;
    // logged in but peers unreachable is fine; "partially" if no self line
    if (!notice && !selfLine) n = NSImageNameStatusPartiallyAvailable;
    NSImage *img = [NSImage imageNamed:n];
    [statusItem setTitle:(selfLine && !notice) ? @"" : @"TS"];
    [statusItem setImage:img];
}

- (void)menuNeedsUpdate:(NSMenu *)m {
    (void)m;
    NSAssert([NSThread isMainThread], @"Menus belong to the main thread");
    [menu removeAllItems];
    NSMenuItem *it;

    if (notice) {
        it = [[NSMenuItem alloc] initWithTitle:notice action:nil keyEquivalent:@""];
        [it setEnabled:NO];
        [menu addItem:[it autorelease]];
        if (loginURL) {
            it = [[NSMenuItem alloc] initWithTitle:@"Authenticate in Browser…"
                                            action:@selector(openLogin:)
                                     keyEquivalent:@""];
            [it setTarget:self];
            [menu addItem:[it autorelease]];
        }
    } else if (selfLine) {
        NSString *ip = [selfLine stringByAppendingString:@" — connected"];
        it = [[NSMenuItem alloc] initWithTitle:ip action:nil keyEquivalent:@""];
        [it setEnabled:NO];
        [menu addItem:[it autorelease]];
    }

    it = [[NSMenuItem alloc] initWithTitle:selfLine ? @"Disconnect" : @"Connect…"
                                    action:@selector(toggle:)
                             keyEquivalent:@""];
    [it setTarget:self];
    [it setEnabled:!activeCommand && !stopping && !cleanupFailed];
    [menu addItem:[it autorelease]];
    [menu addItem:[NSMenuItem separatorItem]];

    if ([peerLines count] > 0) {
        for (NSString *row in peerLines) {
            NSArray *f = SplitFields(row);
            if ([f count] < 2) continue;
            NSString *title = [NSString stringWithFormat:@"%@  (%@)",
                               [f objectAtIndex:1], [f objectAtIndex:0]];
            NSMenuItem *pi = [[NSMenuItem alloc] initWithTitle:title
                                                         action:@selector(copyRow:)
                                                  keyEquivalent:@""];
            [pi setTarget:self];
            [pi setRepresentedObject:[f objectAtIndex:0]];
            [pi setToolTip:@"Click to copy this peer's Tailscale IP"];
            [menu addItem:[pi autorelease]];
        }
        [menu addItem:[NSMenuItem separatorItem]];
    }

    it = [[NSMenuItem alloc] initWithTitle:@"Copy This Machine's IP"
                                    action:@selector(copySelfIP:)
                             keyEquivalent:@""];
    [it setTarget:self];
    [menu addItem:[it autorelease]];
    it = [[NSMenuItem alloc] initWithTitle:@"Admin Console…"
                                    action:@selector(openAdmin:)
                             keyEquivalent:@""];
    [it setTarget:self];
    [menu addItem:[it autorelease]];
    [menu addItem:[NSMenuItem separatorItem]];
    it = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:)
                             keyEquivalent:@"q"];
    [it setTarget:self];
    [menu addItem:[it autorelease]];
    [self updateCommandAvailability];
}

- (void)toggle:(id)sender {
    (void)sender;
    [self startCommand:(selfLine ? @"down" : @"up")];
}

- (void)copyRow:(id)sender {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [pb setString:[(NSMenuItem *)sender representedObject]
              forType:NSStringPboardType];
}

- (void)copySelfIP:(id)sender {
    (void)sender;
    [self startCommand:@"ip"];
}

- (void)openLogin:(id)sender { (void)sender; [self openURL:loginURL]; }
- (void)openAdmin:(id)sender {
    (void)sender;
    [self openURL:[NSString stringWithFormat:@"https://login.tailscale.com/admin/machines"]];
}

- (void)openURL:(NSString *)u {
    if (!u) return;
    NSURL *url = [NSURL URLWithString:u];
    if (!url) return;
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:self];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    [self stopPolling];
    if (!activeCommand) return NSTerminateNow;
    quitting = YES;
    return NSTerminateLater;
}

@end

static void SelfTest(void) {
    // Exercise parse + menu build without a GUI session (no NSStatusBar).
    AppController *c = [[AppController alloc] initWithUI:NO];
    TSCommand *command = [c valueForKey:@"activeCommand"];
    [command retain];
    while ([c valueForKey:@"activeCommand"])
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSString *out = [command->result objectForKey:@"output"];
    printf("== raw status ==\n%s", out ? [out UTF8String] : "(Tailscale CLI unavailable)\n");
    [command release];
    [c menuNeedsUpdate:nil];
    NSArray *items = [c valueForKeyPath:@"menu.itemArray"];
    printf("\n== menu (%d items) ==\n", (int)[items count]);
    for (NSMenuItem *it in items) {
        const char *t = [[it title] UTF8String];
        if (t && t[0]) printf("  %s\n", t);
        else printf("  ---\n");
    }
    [c stopPolling];
    [c release];
}

int main(int argc, const char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
        SelfTest();
        [pool release];
        return 0;
    }
    [NSApplication sharedApplication];
    AppController *c = [[AppController alloc] init];
    [NSApp setDelegate:c];
    [NSApp run];
    [NSApp setDelegate:nil];
    [c stopPolling];
    [c release];
    [pool release];
    return 0;
}
