//
//  XMPPSocketTransport.m
//  TestXMPP
//
//  Created by Illia Chemolosov on 3/18/19.
//  Copyright © 2019 QuickBlox. All rights reserved.
//

#import "XMPPSocketTransport.h"
#import "GCDAsyncSocket.h"
#import "XMPPParser.h"
#import "XMPPJID.h"
#import "XMPPSRVResolver.h"

#import "XMPPElementReceipt.h"

#import "XMPPLogging.h"
#import "NSXMLElement+XMPP.h"

// Log levels: off, error, warn, info, verbose
#if DEBUG
static const int xmppLogLevel = XMPP_LOG_LEVEL_INFO | XMPP_LOG_FLAG_SEND_RECV; // | XMPP_LOG_FLAG_TRACE;
#else
static const int xmppLogLevel = XMPP_LOG_LEVEL_INFO | XMPP_LOG_FLAG_SEND_RECV;
#endif

// Define the timeouts (in seconds) for SRV
#define TIMEOUT_SRV_RESOLUTION 30.0

// Define the timeouts (in seconds) for retreiving various parts of the XML stream
#define TIMEOUT_XMPP_WRITE         -1
#define TIMEOUT_XMPP_READ_START    10
#define TIMEOUT_XMPP_READ_STREAM   -1

// Define the tags we'll use to differentiate what it is we're currently reading or writing
#define TAG_XMPP_READ_START         100
#define TAG_XMPP_READ_STREAM        101
#define TAG_XMPP_WRITE_START        200
#define TAG_XMPP_WRITE_STOP         201
#define TAG_XMPP_WRITE_STREAM       202
#define TAG_XMPP_WRITE_RECEIPT      203

const NSTimeInterval XMPPStreamTimeoutNone = -1;

enum xmppSocketState {
    XMPP_SOCKET_DISCONNECTED,
    XMPP_SOCKET_CONNECTING,
    XMPP_SOCKET_STARTTLS_2,
    XMPP_SOCKET_OPENING,
    XMPP_SOCKET_NEGOTIATING,
    XMPP_SOCKET_CONNECTED,
    XMPP_SOCKET_RESTARTING
};

@interface XMPPElementReceipt (PrivateAPI)

- (void)signalSuccess;
- (void)signalFailure;

@end

@interface XMPPSocketTransport () {
    dispatch_queue_t xmppQueue;
    
    dispatch_source_t connectTimer;
    
    enum xmppSocketState state;
    
    dispatch_source_t keepAliveTimer;
    NSTimeInterval lastSendReceiveTime;
    
    NSMutableArray *receipts;
    
    NSError *parserError;
}

@property (nonatomic, readonly) dispatch_queue_t xmppQueue;
@property (nonatomic, readonly) void *xmppQueueTag;
@property (nonatomic, assign) BOOL didStartNegotiation;

@end

@interface XMPPSocketTransport (SocketDelegate) <GCDAsyncSocketDelegate>
@end

@interface XMPPSocketTransport (ParserDelegate) <XMPPParserDelegate>
@end

@implementation XMPPSocketTransport

@synthesize xmppQueue;

//MARK: - Properties

//MARK: - Life Cycle

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        multicastDelegate = [[GCDMulticastDelegate<XMPPTransportDelegate> alloc] init];
        isSecure = NO;
        _keepAliveInterval = 20;
        state = XMPP_SOCKET_DISCONNECTED;
        _keepAliveInterval = 120.0;
        _keepAliveData = [@" " dataUsingEncoding:NSUTF8StringEncoding];
        receipts = [[NSMutableArray alloc] init];
        xmppQueue = queue;
        asyncSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:xmppQueue];
        asyncSocket.IPv4PreferredOverIPv6 = NO; //TODO: Ivanov A. Enable ipv6
    }
    return self;
}

- (void)dealloc {
    for (XMPPElementReceipt *receipt in receipts) {
        [receipt signalFailure];
    }
    
    [asyncSocket setDelegate:nil delegateQueue:NULL];
    [asyncSocket disconnect];
}

- (void)addDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue {
    [self->multicastDelegate addDelegate:delegate delegateQueue:delegateQueue];
}

- (void)removeDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue {
    [self->multicastDelegate removeDelegate:delegate delegateQueue:delegateQueue];
}

- (void)removeDelegate:(id)delegate {
    [self->multicastDelegate removeDelegate:delegate];
}

- (BOOL)connectWithTimeout:(NSTimeInterval)timeout
                     error:(NSError * _Nullable __autoreleasing *)errPtr {
    BOOL result = NO;
    
    if ([_hostName length] == 0) {
        
        // Resolve the hostName via myJID SRV resolution
        NSAssert(NO, @"XMPPSRVResolver not implement.");
        
    } else {
        // Open TCP connection to the configured hostName.
        
        state = XMPP_SOCKET_CONNECTING;
        
        NSError *connectErr = nil;
        result = [self connectToHost:self.hostName onPort:self.hostPort withTimeout:XMPPStreamTimeoutNone error:&connectErr];
        
        if (!result) {
            if (errPtr) {
                *errPtr = connectErr;
            }
            self->state = XMPP_SOCKET_DISCONNECTED;
        }
    }
    
    if(result) {
        [self startConnectTimeout:timeout];
    }
    
    return result;
}

- (BOOL)connectToHost:(NSString *)host
               onPort:(UInt16)port
          withTimeout:(NSTimeInterval)timeout
                error:(NSError **)errPtr {
    
    XMPPLogTrace();
    
    BOOL result = [asyncSocket connectToHost:host onPort:port error:errPtr];
    
    if(result) {
        [self startConnectTimeout:timeout];
    }
    
    return result;
}

- (void)disconnect {
    NSString *termStr = @"</stream:stream>";
    XMPPLogSend(@"SEND: %@", termStr);
    
    [self sendStanzaWithString:termStr tag:TAG_XMPP_WRITE_STOP];

    [self->asyncSocket disconnectAfterWriting];
}

- (BOOL)sendStanzaWithString:(NSString *)string tag:(long)tag {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    [asyncSocket writeData:data
               withTimeout:TIMEOUT_XMPP_WRITE
                       tag:tag];
    return NO; // FIXME: does this need to be a BOOL?
}

- (BOOL)sendStanzaWithString:(NSString *)string {
    return [self sendStanzaWithString:string tag:TAG_XMPP_WRITE_STREAM];
}

- (BOOL)sendStanza:(NSXMLElement *)stanza {
    return [self sendStanzaWithString:[stanza compactXMLString]];
}

- (void)addReceipt:(XMPPElementReceipt *)receipt {
    [receipts addObject:receipt];
}

/**
 * Returns the version attribute from the servers's <stream:stream/> element.
 * This should be at least 1.0 to be RFC 3920 compliant.
 * If no version number was set, the server is not RFC compliant, and 0 is returned.
 **/
- (float)serverXmppStreamVersionNumber {
    return [rootElement attributeFloatValueForName:@"version" withDefaultValue:0.0F];
}

- (BOOL)isSecure {
    return isSecure;
}

//MARK: - Stream Negotiation

/**
 * This method is called to start the initial negotiation process.
 **/
- (void)startNegotiation {
    NSAssert(![self didStartNegotiation], @"Invoked after initial negotiation has started");
    
    XMPPLogTrace();
    
    // Initialize the XML stream
    [self sendOpeningNegotiation];
    
    // And start reading in the server's XML stream
    [asyncSocket readDataWithTimeout:TIMEOUT_XMPP_READ_START tag:TAG_XMPP_READ_START];
}

/**
 * This method handles sending the opening <stream:stream ...> element which is needed in several situations.
 **/
- (void)sendOpeningNegotiation {
    XMPPLogTrace();
    
    if (![self didStartNegotiation]) {
        // TCP connection was just opened - We need to include the opening XML stanza
        NSString *s1 = @"<?xml version='1.0'?>";
        XMPPLogSend(@"SEND: %@", s1);
        [self sendStanzaWithString:s1 tag:TAG_XMPP_WRITE_START];
        
        [self setDidStartNegotiation:YES];
    }
    
    if (parser == nil) {
        XMPPLogVerbose(@"%@: Initializing parser...", THIS_FILE);
        
        // Need to create the parser.
        parser = [[XMPPParser alloc] initWithDelegate:self delegateQueue:xmppQueue];
    } else {
        XMPPLogVerbose(@"%@: Resetting parser...", THIS_FILE);
        
        // We're restarting our negotiation, so we need to reset the parser.
        parser = [[XMPPParser alloc] initWithDelegate:self delegateQueue:xmppQueue];
    }
    
    NSString *xmlns = @"jabber:client";
    NSString *xmlns_stream = @"http://etherx.jabber.org/streams";
    
    NSString *temp, *s2;
    if (_myJID) {
        temp = @"<stream:stream xmlns='%@' xmlns:stream='%@' version='1.0' to='%@' from='%@'>";
        s2 = [NSString stringWithFormat:temp, xmlns, xmlns_stream, [_myJID domain], [_myJID bare]];
    } else if ([self.hostName length] > 0) {
        temp = @"<stream:stream xmlns='%@' xmlns:stream='%@' version='1.0' to='%@'>";
        s2 = [NSString stringWithFormat:temp, xmlns, xmlns_stream, self.hostName];
    } else {
        temp = @"<stream:stream xmlns='%@' xmlns:stream='%@' version='1.0'>";
        s2 = [NSString stringWithFormat:temp, xmlns, xmlns_stream];
    }
    
    XMPPLogSend(@"SEND: %@", s2);
    [self sendStanzaWithString:s2 tag:TAG_XMPP_WRITE_START];
    
    // Update status
    state = XMPP_SOCKET_OPENING;
}

/**
 * This method handles starting TLS negotiation on the socket, using the proper settings.
 **/
- (void)startTLS { //secure
    XMPPLogTrace();
    // Update state (part 2 - prompting delegates)
    state = XMPP_SOCKET_STARTTLS_2;
    
    // Create a mutable dictionary for security settings
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithCapacity:5];
    
    // Prompt the delegate(s) to populate the security settings
    [multicastDelegate transport:self willSecureWithSettings:settings];
}

- (void)continueStartTLS:(NSMutableDictionary *)settings {
    XMPPLogTrace2(@"%@: %@ %@", THIS_FILE, THIS_METHOD, settings);
    
    if (state == XMPP_SOCKET_STARTTLS_2) {
        // If the delegates didn't respond
        if ([settings count] == 0)
        {
            // Use the default settings, and set the peer name
            
            NSString *expectedCertName = self.hostName;
            if (expectedCertName == nil)
            {
                expectedCertName = [_myJID domain];
            }
            
            if ([expectedCertName length] > 0)
            {
                settings[(NSString *) kCFStreamSSLPeerName] = expectedCertName;
            }
        }
        
        [asyncSocket startTLS:settings];
        isSecure = YES;
        
        // Note: We don't need to wait for asyncSocket to complete TLS negotiation.
        // We can just continue reading/writing to the socket, and it will handle queueing everything for us!
        
        if ([self didStartNegotiation])
        {
            // Now we start our negotiation over again...
            [self sendOpeningNegotiation];
            
            // We paused reading from the socket.
            // We're ready to continue now.
            [asyncSocket readDataWithTimeout:TIMEOUT_XMPP_READ_STREAM tag:TAG_XMPP_READ_STREAM];
        }
        else
        {
            // First time starting negotiation
            [self startNegotiation];
        }
    }
}

- (void)restartStream {
    
    [self sendOpeningNegotiation];
    
    if (![self isSecure])
    {
        // Normally we requeue our read operation in xmppParserDidParseData:.
        // But we just reset the parser, so that code path isn't going to happen.
        // So start read request here.
        // The state is STATE_XMPP_OPENING, set via sendOpeningNegotiation method.
        
        [asyncSocket readDataWithTimeout:TIMEOUT_XMPP_READ_START tag:TAG_XMPP_READ_START];
    }
}


//MARK - Connect Timeout

/**
 * Start Connect Timeout
 **/
- (void)startConnectTimeout:(NSTimeInterval)timeout
{
    XMPPLogTrace();
    
    if (timeout >= 0.0 && !connectTimer)
    {
        connectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, xmppQueue);
        
        dispatch_source_set_event_handler(connectTimer, ^{ @autoreleasepool {
            
            [self doConnectTimeout];
        }});
        
#if !OS_OBJECT_USE_OBJC
        dispatch_source_t theConnectTimer = connectTimer;
        dispatch_source_set_cancel_handler(connectTimer, ^{
            XMPPLogVerbose(@"%@: dispatch_release(connectTimer)", THIS_FILE);
            dispatch_release(theConnectTimer);
        });
#endif
        
        dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (timeout * NSEC_PER_SEC));
        dispatch_source_set_timer(connectTimer, tt, DISPATCH_TIME_FOREVER, 0);
        
        dispatch_resume(connectTimer);
    }
}

/**
 * End Connect Timeout
 **/
- (void)endConnectTimeout
{
    XMPPLogTrace();
    
    if (connectTimer)
    {
        dispatch_source_cancel(connectTimer);
        connectTimer = NULL;
    }
}

/**
 * Connect has timed out, so inform the delegates and close the connection
 **/
- (void)doConnectTimeout
{
    XMPPLogTrace();
    
    [self endConnectTimeout];
    
    if (state != XMPP_SOCKET_DISCONNECTED)
    {
        [multicastDelegate transportConnectDidTimeout:self];
        
        [asyncSocket disconnect];
        
        // Everthing will be handled in socketDidDisconnect:withError:
    }
    
}

//MARK: - Keep Alive

- (void)setupKeepAliveTimer {
    XMPPLogTrace();
    
    if (keepAliveTimer) {
        dispatch_source_cancel(keepAliveTimer);
        keepAliveTimer = NULL;
    }
    
    if (state == XMPP_SOCKET_CONNECTED) {
        if (_keepAliveInterval > 0) {
            keepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, xmppQueue);
            
            dispatch_source_set_event_handler(keepAliveTimer, ^{ @autoreleasepool {
                
                [self keepAlive];
            }});
            
#if !OS_OBJECT_USE_OBJC
            dispatch_source_t theKeepAliveTimer = keepAliveTimer;
            
            dispatch_source_set_cancel_handler(keepAliveTimer, ^{
                XMPPLogVerbose(@"dispatch_release(keepAliveTimer)");
                dispatch_release(theKeepAliveTimer);
            });
#endif
            
            // Everytime we send or receive data, we update our lastSendReceiveTime.
            // We set our timer to fire several times per keepAliveInterval.
            // This allows us to maintain a single timer,
            // and an acceptable timer resolution (assuming larger keepAliveIntervals).
            
            uint64_t interval = ((_keepAliveInterval / 4.0) * NSEC_PER_SEC);
            
            dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, interval);
            
            dispatch_source_set_timer(keepAliveTimer, tt, interval, 1.0);
            dispatch_resume(keepAliveTimer);
        }
    }
}

- (void)keepAlive {
    
    if (state == XMPP_SOCKET_CONNECTED) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval elapsed = (now - lastSendReceiveTime);
        
        if (elapsed < 0 || elapsed >= _keepAliveInterval)
        {
            
            [asyncSocket writeData:_keepAliveData
                       withTimeout:TIMEOUT_XMPP_WRITE
                               tag:TAG_XMPP_WRITE_STREAM];
            
            // Force update the lastSendReceiveTime here just to be safe.
            //
            // In case the TCP socket comes to a crawl with a giant element in the queue,
            // which would prevent the socket:didWriteDataWithTag: method from being called for some time.
            
            lastSendReceiveTime = [NSDate timeIntervalSinceReferenceDate];
        }
    }
}

@end

//MARK: - GCDAsyncSocket Delegate
@implementation XMPPSocketTransport (SocketDelegate)
/**
 * Called when a socket connects and is ready for reading and writing. "host" will be an IP address, not a DNS name.
 **/
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port {
    
    // This method is invoked on the xmppQueue.
    //
    // The TCP connection is now established.
    
    XMPPLogTrace();
    
    [self endConnectTimeout];
    
    [self startTLS];

}

- (void)socket:(GCDAsyncSocket *)sock
didReceiveTrust:(SecTrustRef)trust
completionHandler:(void (^)(BOOL shouldTrustPeer))completionHandler {
    
    [multicastDelegate transport:self didReceiveTrust:trust completionHandler:completionHandler];
    
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock {
    XMPPLogTrace();
    
    [multicastDelegate transportDidSecure:self];
}
/**
 * Called when a socket has completed reading the requested data. Not called if there is an error.
 **/
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    // This method is invoked on the xmppQueue.
    
    XMPPLogTrace();
    
    lastSendReceiveTime = [NSDate timeIntervalSinceReferenceDate];
    
    XMPPLogRecvPre(@"RECV: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    
    // Asynchronously parse the xml data
    [parser parseData:data];
    
    if (isSecure) {
        if (state == XMPP_SOCKET_OPENING) {
            [asyncSocket readDataWithTimeout:TIMEOUT_XMPP_READ_START tag:TAG_XMPP_READ_START];
        } else {
            [asyncSocket readDataWithTimeout:TIMEOUT_XMPP_READ_STREAM tag:TAG_XMPP_READ_STREAM];
        }
    } else {
        // Don't queue up a read on the socket as we may need to upgrade to TLS.
        // We'll read more data after we've parsed the current chunk of data.
    }
    
}
/**
 * Called after data with the given tag has been successfully sent.
 **/
- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag {
    XMPPLogTrace();
    
    lastSendReceiveTime = [NSDate timeIntervalSinceReferenceDate];
    
    if (tag == TAG_XMPP_WRITE_RECEIPT) {
        if ([receipts count] == 0)
        {
            XMPPLogWarn(@"%@: Found TAG_XMPP_WRITE_RECEIPT with no pending receipts!", THIS_FILE);
            return;
        }
        
        XMPPElementReceipt *receipt = receipts[0];
        [receipt signalSuccess];
        [receipts removeObjectAtIndex:0];
    } else if (tag == TAG_XMPP_WRITE_STOP) {
        [multicastDelegate transportDidSendClosingStreamStanza:self];
    }
}
/**
 * Called when a socket disconnects with or without error.
 **/
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    XMPPLogTrace();
    
    [self endConnectTimeout];
    
    // Update state
    state = XMPP_SOCKET_DISCONNECTED;

    // Release the parser (to free underlying resources)
    [parser setDelegate:nil delegateQueue:NULL];
    parser = nil;
        rootElement = nil;

    // Stop the keep alive timer
    if (keepAliveTimer)
    {
        dispatch_source_cancel(keepAliveTimer);
        keepAliveTimer = NULL;
    }

    // Clear any pending receipts
    for (XMPPElementReceipt *receipt in receipts) {
        [receipt signalFailure];
    }
    [receipts removeAllObjects];

    // Notify delegate

    if (parserError)
    {
        NSError *error = parserError;

        [multicastDelegate transportDidDisconnect:self withError:error];

        parserError = nil;
    }
    else
    {
        [multicastDelegate transportDidDisconnect:self withError:err];
    }
}

@end


//MARK: - XMPPParser Delegate
@implementation XMPPSocketTransport (ParserDelegate)
/**
 * Called when the xmpp parser has read in the entire root element.
 **/
- (void)xmppParser:(XMPPParser *)sender didReadRoot:(NSXMLElement *)root {
    if (sender != parser) return;
    
    XMPPLogTrace();
    XMPPLogRecvPost(@"RECV: %@", [root compactXMLString]);
    
    rootElement = root;
    state = XMPP_SOCKET_CONNECTED;
    [self setupKeepAliveTimer];
    [multicastDelegate transportDidConnect:self];
}

- (void)xmppParser:(XMPPParser *)sender didReadElement:(NSXMLElement *)element {
    if (sender != parser) return;
    
    XMPPLogTrace();
    XMPPLogRecvPost(@"RECV: %@", [element compactXMLString]);
    NSString *elementName = [element name];
    
    [multicastDelegate transport:self didReceiveStanza:element];
}

- (void)xmppParserDidParseData:(XMPPParser *)sender {
    // This method is invoked on the xmppQueue.
    
    if (sender != parser) return;
    
    XMPPLogTrace();
    
    if (![self isSecure])
    {
        // Continue reading for XML elements
        if (state == XMPP_SOCKET_OPENING)
        {
            [asyncSocket readDataWithTimeout:TIMEOUT_XMPP_READ_START tag:TAG_XMPP_READ_START];
        }
        else if (state != XMPP_SOCKET_STARTTLS_2) // Don't queue read operation prior to [asyncSocket startTLS:]
        {
            [asyncSocket readDataWithTimeout:TIMEOUT_XMPP_READ_STREAM tag:TAG_XMPP_READ_STREAM];
        }
    }
}

- (void)xmppParserDidEnd:(XMPPParser *)sender {
    // This method is invoked on the xmppQueue.
    
    if (sender != parser) return;
    
    XMPPLogTrace();
    
    [asyncSocket disconnect];
}

- (void)xmppParser:(XMPPParser *)sender didFail:(NSError *)error {
    // This method is invoked on the xmppQueue.
    
    if (sender != parser) return;
    
    XMPPLogTrace();
    
    parserError = error;
    [asyncSocket disconnect];
}

@end
