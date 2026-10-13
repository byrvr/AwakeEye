#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <math.h>
#import <string.h>

// Compile the production client below, replacing only its socket creation,
// connection, and peer-identity checks, plus observing its real writes. Every
// request stays in an anonymous socketpair; no installed helper, power setting,
// or authorization is touched.
@interface KYARegressionExchange : NSObject
@property (copy, nullable) NSString *command;
@property (copy, nullable) NSData *reply;
@property (nonatomic) uid_t peerUID;
@property (nonatomic) int connectionError;
@property (nonatomic) NSTimeInterval replyDelay;
@property (nonatomic) BOOL replyBeforeRequest;
@property (nonatomic) NSUInteger failedWrites;
@property (nonatomic) int earlyReplyDescriptor;
@end
@implementation KYARegressionExchange
@end

static NSMutableArray<KYARegressionExchange *> *KYAPendingExchanges;
static NSMutableArray<NSString *> *KYAReceivedCommands;
static NSLock *KYACommandLock;
static dispatch_group_t KYAExchangeWorkers;
static KYARegressionExchange *KYACurrentExchange;
static int KYACurrentDescriptor;

static int KYARegressionSocket(int domain, int type, int protocol)
{
    NSCAssert(NSThread.isMainThread, @"Client requests must stay on the main thread.");
    NSCAssert(domain == AF_UNIX && type == SOCK_STREAM && protocol == 0,
              @"The client changed its expected socket transport.");
    NSCAssert(KYAPendingExchanges.count > 0, @"Unexpected helper request; no real socket may be opened.");
    KYARegressionExchange *exchange = KYAPendingExchanges.firstObject;
    [KYAPendingExchanges removeObjectAtIndex:0];
    int pair[2];
    NSCAssert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, @"Could not create the test socketpair.");
    int noSignal = 1;
    setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    KYACurrentExchange = exchange;
    KYACurrentDescriptor = pair[0];
    int peer = pair[1];
    if(exchange.replyBeforeRequest)
    {
        NSCAssert(exchange.command == nil && exchange.reply.length > 0 && exchange.reply.length < 8192,
                  @"An early rejection must fit in the socket buffer and accept no command.");
        exchange.earlyReplyDescriptor = peer;
        return pair[0];
    }
    dispatch_group_async(KYAExchangeWorkers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool
        {
            NSMutableData *request = [NSMutableData new];
            char byte;
            while(request.length < 1024)
            {
                ssize_t count = read(peer, &byte, 1);
                if(count < 0 && errno == EINTR) { continue; }
                if(count <= 0 || byte == '\n') { break; }
                [request appendBytes:&byte length:1];
            }
            NSString *command = request.length ? [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding] : nil;
            NSCAssert((command == nil && exchange.command == nil) || [command isEqual:exchange.command],
                      @"Expected %@, received %@.", exchange.command, command);
            if(command != nil)
            {
                [KYACommandLock lock];
                [KYAReceivedCommands addObject:command];
                [KYACommandLock unlock];
            }
            if(exchange.replyDelay > 0) { [NSThread sleepForTimeInterval:exchange.replyDelay]; }
            const uint8_t *bytes = exchange.reply.bytes;
            NSUInteger sent = 0;
            while(sent < exchange.reply.length)
            {
                ssize_t count = write(peer, bytes + sent, exchange.reply.length - sent);
                if(count < 0 && errno == EINTR) { continue; }
                if(count <= 0) { break; } // Expected when the client has timed out.
                sent += (NSUInteger)count;
            }
            close(peer);
        }
    });
    return pair[0];
}

static int KYARegressionConnect(int descriptor, const struct sockaddr *address, socklen_t length)
{
    NSCAssert(descriptor == KYACurrentDescriptor && address->sa_family == AF_UNIX && length == sizeof(struct sockaddr_un),
              @"Unexpected helper connection.");
    if(KYACurrentExchange.connectionError)
    {
        errno = KYACurrentExchange.connectionError;
        return -1;
    }
    return 0;
}

static int KYARegressionGetPeerID(int descriptor, uid_t *uid, gid_t *gid)
{
    NSCAssert(descriptor == KYACurrentDescriptor, @"Unexpected helper identity check.");
    *uid = KYACurrentExchange.peerUID;
    *gid = 0;
    if(KYACurrentExchange.replyBeforeRequest)
    {
        // Reject after the client configures SO_NOSIGPIPE, but before it writes.
        const uint8_t *bytes = KYACurrentExchange.reply.bytes;
        NSUInteger sent = 0;
        int peer = KYACurrentExchange.earlyReplyDescriptor;
        while(sent < KYACurrentExchange.reply.length)
        {
            ssize_t count = write(peer, bytes + sent, KYACurrentExchange.reply.length - sent);
            if(count < 0 && errno == EINTR) { continue; }
            NSCAssert(count > 0, @"Could not send the early rejection.");
            sent += (NSUInteger)count;
        }
        close(peer); // The client's next real write must now fail with EPIPE.
    }
    return 0;
}

static ssize_t KYARegressionWrite(int descriptor, const void *bytes, size_t length)
{
    NSCAssert(descriptor == KYACurrentDescriptor, @"Unexpected client write.");
    ssize_t count = write(descriptor, bytes, length);
    if(KYACurrentExchange.replyBeforeRequest)
    {
        NSCAssert(count == -1 && errno == EPIPE, @"The closed helper peer did not reject the ON write with EPIPE.");
        KYACurrentExchange.failedWrites++;
    }
    return count;
}

#define socket KYARegressionSocket
#define connect KYARegressionConnect
#define getpeereid KYARegressionGetPeerID
#define write KYARegressionWrite
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import "../KeepingYouAwake/KYAClosedLidSession.m"
#pragma clang diagnostic pop
#undef socket
#undef connect
#undef getpeereid
#undef write

@interface KYARegressionSession : KYAClosedLidSession
@property (nonatomic) NSUInteger setupCalls;
@property (nonatomic) BOOL setupSucceeds;
@end

@implementation KYARegressionSession
- (BOOL)setupHelperWithError:(NSError **)error
{
    self.setupCalls++;
    if(!self.setupSucceeds && error)
    {
        *error = KYAHelperMakeError(KYAHelperSetupFailed, @"Simulated setup failure.");
    }
    return self.setupSucceeds;
}
@end

static NSDictionary *KYAOK(BOOL active)
{
    return @{@"protocol": @2, @"ok": @YES, @"active": @(active), @"owner_pid": @(active ? getpid() : 0)};
}

static NSDictionary *KYAFailure(NSString *kind, NSString *reason)
{
    return @{@"protocol": @2, @"ok": @NO, @"active": @NO, @"owner_pid": @0, @"error_code": kind, @"error": reason};
}

static KYARegressionExchange *KYAEnqueueBytes(NSString *command, NSData *reply)
{
    KYARegressionExchange *exchange = [KYARegressionExchange new];
    exchange.command = command;
    exchange.reply = reply;
    [KYAPendingExchanges addObject:exchange];
    return exchange;
}

static KYARegressionExchange *KYAEnqueue(NSString *command, id payload)
{
    NSMutableData *reply = payload ? [[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil] mutableCopy] : nil;
    if(reply) { [reply appendBytes:"\n" length:1]; }
    return KYAEnqueueBytes(command, reply);
}

static void KYAFinishCase(NSString *name, NSArray<NSString *> *expectedCommands)
{
    NSCAssert(dispatch_group_wait(KYAExchangeWorkers, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
              @"A scripted socket worker did not finish.");
    NSCAssert(KYAPendingExchanges.count == 0, @"Unused mock helper replies remain.");
    NSCAssert([KYAReceivedCommands isEqual:expectedCommands], @"Unexpected command sequence: %@.", KYAReceivedCommands);
    [KYAReceivedCommands removeAllObjects];
    KYACurrentExchange = nil;
    printf("PASS %s\n", name.UTF8String);
}

static void KYATestReplyParser(void)
{
    KYARegressionSession *session = [KYARegressionSession new];
    NSMutableArray<NSString *> *commands = [NSMutableArray new];
    NSError *error = nil;
    KYAEnqueue(@"STATUS", KYAOK(NO));
    [commands addObject:@"STATUS"];
    NSCAssert([session request:@"STATUS" error:&error] != nil && error == nil, @"Valid helper reply was rejected.");
    NSArray<NSData *> *badReplies = @[
        [@"not JSON\n" dataUsingEncoding:NSUTF8StringEncoding],
        [@"[]\n" dataUsingEncoding:NSUTF8StringEncoding],
        [@"{\"protocol\":1,\"ok\":true}\n" dataUsingEncoding:NSUTF8StringEncoding],
        [NSData data]
    ];
    for(NSData *reply in badReplies)
    {
        error = nil;
        KYAEnqueueBytes(@"STATUS", reply);
        [commands addObject:@"STATUS"];
        NSCAssert([session request:@"STATUS" error:&error] == nil && error.code == KYAHelperOperationFailed,
                  @"Invalid or missing helper reply was accepted.");
    }
    for(NSString *field in @[@"protocol", @"ok", @"active", @"owner_pid"])
    {
        for(id invalidValue in @[@[], NSNull.null, @"2"])
        {
            NSMutableDictionary *payload = [KYAOK(NO) mutableCopy];
            payload[field] = invalidValue;
            KYAEnqueue(@"STATUS", payload);
            [commands addObject:@"STATUS"];
            error = nil;
            NSCAssert([session request:@"STATUS" error:&error] == nil && error.code == KYAHelperOperationFailed,
                      @"Invalid type in helper field %@ was accepted.", field);
        }
        NSMutableDictionary *missingField = [KYAOK(NO) mutableCopy];
        [missingField removeObjectForKey:field];
        KYAEnqueue(@"STATUS", missingField);
        [commands addObject:@"STATUS"];
        error = nil;
        NSCAssert([session request:@"STATUS" error:&error] == nil && error.code == KYAHelperOperationFailed,
                  @"Missing required helper field %@ was accepted.", field);
    }
    error = nil;
    KYAEnqueue(@"STATUS", KYAFailure(@"unauthorized", @"Mock caller is unauthorized."));
    [commands addObject:@"STATUS"];
    NSCAssert([session request:@"STATUS" error:&error] == nil && error.code == KYAHelperUnauthorized &&
              [error.localizedDescription isEqual:@"Mock caller is unauthorized."], @"Authorization error was not preserved.");
    KYARegressionExchange *nonRoot = KYAEnqueue(nil, nil);
    nonRoot.peerUID = 501;
    error = nil;
    NSCAssert([session request:@"STATUS" error:&error] == nil && error.code == KYAHelperOperationFailed,
              @"A non-root helper peer was accepted.");
    NSCAssert(session.setupCalls == 0 && !session.ownsSession, @"Read-only requests triggered setup or session ownership.");
    KYAFinishCase(@"reply parser rejects malformed JSON, invalid field types, missing fields, unauthorized and non-root peers", commands);
}

static void KYATestLostONReply(void)
{
    for(NSData *reply in @[[NSData data], [@"{broken\n" dataUsingEncoding:NSUTF8StringEncoding]])
    {
        KYARegressionSession *session = [KYARegressionSession new];
        NSError *error = nil;
        KYAEnqueueBytes(@"ON", reply);
        KYAEnqueue(@"OFF", KYAOK(NO));
        NSCAssert(![session beginSessionWithError:&error] && error.code == KYAHelperOperationFailed,
                  @"An unconfirmed ON acknowledgement became a successful session.");
        NSCAssert(!session.ownsSession && session.lastCleanupError == nil && session.setupCalls == 0,
                  @"A lost ON acknowledgement did not clean up its possible lease.");
        KYAFinishCase(@"lost or malformed ON acknowledgement sends best-effort OFF", @[@"ON", @"OFF"]);
    }
}

static void KYATestRepeatedCycles(void)
{
    KYARegressionSession *session = [KYARegressionSession new];
    NSMutableArray<NSString *> *commands = [NSMutableArray new];
    for(NSUInteger iteration = 0; iteration < 100; iteration++)
    {
        NSError *error = nil;
        KYAEnqueue(@"ON", KYAOK(YES));
        NSCAssert([session beginSessionWithError:&error] && error == nil && session.ownsSession,
                  @"Authorized activation failed.");
        [commands addObject:@"ON"];
        KYAEnqueue(@"STATUS", KYAOK(YES));
        NSCAssert(session.active, @"The confirmed owned session was not active.");
        [commands addObject:@"STATUS"];
        KYAEnqueue(@"OFF", KYAOK(NO));
        [session endSession];
        [commands addObject:@"OFF"];
        NSCAssert(!session.ownsSession && !session.active && session.lastCleanupError == nil,
                  @"Successful deactivation did not clear session ownership.");
        [session endSession]; // An already-clean session makes no request.
    }
    NSCAssert(session.setupCalls == 0, @"Already-authorized mode toggles asked for setup again.");
    KYAFinishCase(@"100 authorized ON/STATUS/OFF cycles skip setup and cleanly release ownership", commands);
}

static void KYATestUnconfirmedOwnership(void)
{
    for(NSDictionary *reply in @[KYAOK(NO), @{@"protocol": @2, @"ok": @YES, @"active": @YES, @"owner_pid": @(getpid() + 1)}])
    {
        KYARegressionSession *session = [KYARegressionSession new];
        KYAEnqueue(@"ON", reply);
        KYAEnqueue(@"OFF", KYAOK(NO));
        NSError *error = nil;
        NSCAssert(![session beginSessionWithError:&error] && error.code == KYAHelperOperationFailed &&
                  !session.ownsSession && session.lastCleanupError == nil && session.setupCalls == 0,
                  @"An inactive or foreign lease was accepted as the client's owned session.");
        KYAFinishCase(@"ON must confirm an active lease owned by this process", @[@"ON", @"OFF"]);
    }
}

static void KYATestCleanupFailure(void)
{
    KYARegressionSession *session = [KYARegressionSession new];
    NSError *error = nil;
    KYAEnqueue(@"ON", KYAOK(YES));
    NSCAssert([session beginSessionWithError:&error], @"Mock activation failed.");
    KYAEnqueue(@"OFF", KYAFailure(@"operation", @"Mock sleep restoration failed."));
    [session endSession];
    NSCAssert(session.ownsSession && [session.lastCleanupError.localizedDescription isEqual:@"Mock sleep restoration failed."],
              @"Failed OFF hid the restoration failure or discarded ownership.");
    KYAEnqueue(@"OFF", nil);
    error = nil;
    NSCAssert(![session beginSessionWithError:&error] && session.ownsSession &&
              error != nil && error == session.lastCleanupError,
              @"A new ON was allowed while an owned lease still needed cleanup.");
    KYAEnqueue(@"OFF", KYAOK(YES));
    [session endSession];
    NSCAssert(session.ownsSession && session.lastCleanupError != nil,
              @"OFF still reporting active incorrectly cleared ownership.");
    KYAEnqueue(@"OFF", KYAOK(NO));
    KYAEnqueue(@"ON", KYAOK(YES));
    error = nil;
    NSCAssert([session beginSessionWithError:&error] && session.ownsSession && error == nil && session.lastCleanupError == nil,
              @"Confirmed pending cleanup did not permit a fresh activation or clear its error.");
    KYAEnqueue(@"OFF", KYAOK(NO));
    [session endSession];
    NSCAssert(!session.ownsSession && session.lastCleanupError == nil,
              @"Confirmed cleanup did not clear the retained failure.");
    NSCAssert(session.setupCalls == 0, @"Cleanup tried to request administrator authorization.");
    KYAFinishCase(@"failed cleanup blocks ON until a confirmed OFF clears the error", @[@"ON", @"OFF", @"OFF", @"OFF", @"OFF", @"ON", @"OFF"]);

    KYARegressionSession *unconfirmed = [KYARegressionSession new];
    KYAEnqueue(@"ON", nil);
    KYAEnqueue(@"OFF", KYAFailure(@"operation", @"Mock unconfirmed lease cleanup failed."));
    error = nil;
    NSCAssert(![unconfirmed beginSessionWithError:&error] && unconfirmed.ownsSession &&
              [error.localizedDescription isEqual:@"Mock unconfirmed lease cleanup failed."] && error == unconfirmed.lastCleanupError,
              @"Failed cleanup after an unconfirmed ON was not surfaced to the caller.");
    KYAEnqueue(@"OFF", KYAOK(NO));
    [unconfirmed endSession];
    KYAFinishCase(@"lost ON followed by failed OFF exposes cleanup error and keeps ownership", @[@"ON", @"OFF", @"OFF"]);
}

static void KYATestOneTimeSetup(void)
{
    for(NSNumber *unavailable in @[@NO, @YES])
    {
        KYARegressionSession *session = [KYARegressionSession new];
        session.setupSucceeds = YES;
        NSMutableArray<NSString *> *commands = [NSMutableArray new];
        if(unavailable.boolValue)
        {
            KYARegressionExchange *exchange = KYAEnqueue(nil, nil);
            exchange.connectionError = ENOENT;
        }
        else
        {
            KYAEnqueue(@"ON", KYAFailure(@"unauthorized", @"Mock new build needs authorization."));
            [commands addObject:@"ON"];
        }
        KYAEnqueue(@"ON", KYAOK(YES));
        [commands addObject:@"ON"];
        NSError *error = nil;
        NSCAssert([session beginSessionWithError:&error] && error == nil && session.setupCalls == 1,
                  @"Missing or unauthorized helper did not receive one setup attempt and one retry.");
        KYAEnqueue(@"OFF", KYAOK(NO));
        [session endSession];
        [commands addObject:@"OFF"];
        KYAFinishCase(@"missing or unauthorized helper uses intercepted setup once, then retries", commands);
    }
    KYARegressionSession *cancelled = [KYARegressionSession new];
    KYAEnqueue(@"ON", KYAFailure(@"unauthorized", @"Mock setup required."));
    NSError *error = nil;
    NSCAssert(![cancelled beginSessionWithError:&error] && error.code == KYAHelperSetupFailed &&
              cancelled.setupCalls == 1 && !cancelled.ownsSession,
              @"Failed setup retried ON or retained ownership after explicit authorization rejection.");
    KYAFinishCase(@"failed intercepted setup returns its error without acquiring a lease", @[@"ON"]);
}

static void KYATestShortRequestDeadline(void)
{
    KYARegressionSession *session = [KYARegressionSession new];
    KYARegressionExchange *exchange = KYAEnqueue(@"STATUS", KYAOK(NO));
    exchange.replyDelay = 0.5;
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    NSError *error = nil;
    NSCAssert([session request:@"STATUS" timeout:0.03 error:&error] == nil && error.code == KYAHelperOperationFailed,
              @"A reply beyond the request deadline was accepted.");
    NSCAssert(NSProcessInfo.processInfo.systemUptime - start < 0.4,
              @"A short helper probe waited for the default eight-second request timeout.");
    KYAFinishCase(@"short helper probe deadline stops waiting for a silent peer", @[@"STATUS"]);
}

static void KYATestEarlyAuthorizationRejection(void)
{
    KYARegressionSession *session = [KYARegressionSession new];
    session.setupSucceeds = YES;
    KYARegressionExchange *rejection = KYAEnqueue(nil, KYAFailure(@"unauthorized", @"Mock helper is pinned to an older build."));
    rejection.replyBeforeRequest = YES;
    KYAEnqueue(@"ON", KYAOK(YES));
    NSError *error = nil;
    NSCAssert([session beginSessionWithError:&error] && error == nil && session.ownsSession &&
              session.setupCalls == 1 && rejection.failedWrites == 1,
              @"An unauthorized reply following EPIPE did not renew setup exactly once and retry ON.");
    KYAEnqueue(@"OFF", KYAOK(NO));
    [session endSession];
    NSCAssert(!session.ownsSession && session.lastCleanupError == nil && session.setupCalls == 1,
              @"The renewed session did not clean up without another setup.");
    KYAFinishCase(@"early unauthorized reply survives real EPIPE, renews setup once, and retries ON", @[@"ON", @"OFF"]);
}

int main(void)
{
    @autoreleasepool
    {
        KYAPendingExchanges = [NSMutableArray new];
        KYAReceivedCommands = [NSMutableArray new];
        KYACommandLock = [NSLock new];
        KYAExchangeWorkers = dispatch_group_create();
        KYATestReplyParser();
        KYATestLostONReply();
        KYATestRepeatedCycles();
        KYATestUnconfirmedOwnership();
        KYATestCleanupFailure();
        KYATestOneTimeSetup();
        KYATestShortRequestDeadline();
        KYATestEarlyAuthorizationRejection();
    }
    return 0;
}
