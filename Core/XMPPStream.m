#import "XMPP.h"
#import "XMPPParser.h"
#import "XMPPLogging.h"
#import "XMPPInternal.h"
#import "XMPPIDTracker.h"
#import "XMPPSRVResolver.h"
#import "NSData+XMPP.h"

#import <objc/runtime.h>
#import <libkern/OSAtomic.h>

#import "XMPPSocketTransport.h"
#import "BoshTransport.h"

#if TARGET_OS_IPHONE
// Note: You may need to add the CFNetwork Framework to your project
#import <CFNetwork/CFNetwork.h>
#endif

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

// Log levels: off, error, warn, info, verbose
#if DEBUG
static const int xmppLogLevel = XMPP_LOG_LEVEL_INFO | XMPP_LOG_FLAG_SEND_RECV; // | XMPP_LOG_FLAG_TRACE;
#else
static const int xmppLogLevel = XMPP_LOG_LEVEL_INFO | XMPP_LOG_FLAG_SEND_RECV;
#endif

/**
 * Seeing a return statements within an inner block
 * can sometimes be mistaken for a return point of the enclosing method.
 * This makes inline blocks a bit easier to read.
 **/
#define return_from_block  return

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

NSString *const XMPPStreamErrorDomain = @"XMPPStreamErrorDomain";
NSString *const XMPPStreamDidChangeMyJIDNotification = @"XMPPStreamDidChangeMyJID";

enum XMPPStreamFlags
{
    kP2PInitiator                 = 1 << 0,  // If set, we are the P2P initializer
    kIsSecure                     = 1 << 1,  // If set, connection has been secured via SSL/TLS
    kIsAuthenticated              = 1 << 2,  // If set, authentication has succeeded
    kDidStartNegotiation          = 1 << 3,  // If set, negotiation has started at least once
};

enum XMPPStreamConfig
{
    kP2PMode                      = 1 << 0,  // If set, the XMPPStream was initialized in P2P mode
    kResetByteCountPerConnection  = 1 << 1,  // If set, byte count should be reset per connection
#if TARGET_OS_IPHONE
    kEnableBackgroundingOnSocket  = 1 << 2,  // If set, the VoIP flag should be set on the socket
#endif
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface XMPPStream ()
{
    dispatch_queue_t xmppQueue;
    void *xmppQueueTag;
    
    dispatch_queue_t willSendIqQueue;
    dispatch_queue_t willSendMessageQueue;
    dispatch_queue_t willSendPresenceQueue;
    
    dispatch_queue_t willReceiveStanzaQueue;
    
    dispatch_queue_t didReceiveIqQueue;
    
    
    GCDMulticastDelegate <XMPPStreamDelegate> *multicastDelegate;
    
    XMPPStreamState state;
    
    QBTransportType transportType;
    
    id<XMPPTransportProtocol> transport;
    
    NSString *hostName;
    UInt16 hostPort;
    
    NSTimeInterval keepAliveInterval;
    NSData *keepAliveData;
    
    NSError *otherError;
    
    Byte flags;
    
    XMPPStreamStartTLSPolicy startTLSPolicy;
    BOOL skipStartSession;
    BOOL validatesResponses;
    
    id <XMPPSASLAuthentication> auth;
    id <XMPPCustomBinding> customBinding;
    NSDate *authenticationDate;
    
    XMPPJID *myJID_setByClient;
    XMPPJID *myJID_setByServer;
    
    XMPPPresence *myPresence;
    NSXMLElement *rootElement;
    
    NSMutableArray *registeredModules;
    NSMutableDictionary *autoDelegateDict;
    
    XMPPIDTracker *idTracker;
    
    NSCountedSet *customElementNames;
    
    id userTag;
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation XMPPStream

@synthesize tag = userTag;

/**
 * Shared initialization between the various init methods.
 **/
- (void)commonInit
{
    xmppQueueTag = &xmppQueueTag;
    xmppQueue = dispatch_queue_create("xmpp", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(xmppQueue, xmppQueueTag, xmppQueueTag, NULL);
    
    willSendIqQueue = dispatch_queue_create("xmpp.willSendIq", DISPATCH_QUEUE_SERIAL);
    willSendMessageQueue = dispatch_queue_create("xmpp.willSendMessage", DISPATCH_QUEUE_SERIAL);
    willSendPresenceQueue = dispatch_queue_create("xmpp.willSendPresence", DISPATCH_QUEUE_SERIAL);
    
    didReceiveIqQueue = dispatch_queue_create("xmpp.didReceiveIq", DISPATCH_QUEUE_SERIAL);
    
    multicastDelegate = (GCDMulticastDelegate <XMPPStreamDelegate> *)[[GCDMulticastDelegate alloc] init];
    
    state = STATE_XMPP_DISCONNECTED;
    
    flags = 0;

    self.hostPort = 5222;
    
    registeredModules = [[NSMutableArray alloc] init];
    autoDelegateDict = [[NSMutableDictionary alloc] init];
    
    transportType = QBTransportTypeSocket;
    
    idTracker = [[XMPPIDTracker alloc] initWithStream:self dispatchQueue:xmppQueue];
}

/**
 * Standard XMPP initialization.
 * The stream is a standard client to server connection.
 **/
- (id)init
{
    if ((self = [super init]))
    {
        // Common initialization
        [self commonInit];
        
        //TODO: implement - (id)initWithTransport:(id<XMPPTransportProtocol>)transport;
        transport = [[XMPPSocketTransport alloc] initWithQueue:xmppQueue];
        [transport addDelegate:self delegateQueue:xmppQueue];
    }
    return self;
}

- (id)initWithTransportType:(QBTransportType)type {
    if (self = [super init]) {
        // Common initialization
        [self commonInit];
        
        transportType = type;
    }
    return self;
}

/**
 * Peer to Peer XMPP initialization.
 * The stream is a direct client to client connection as outlined in XEP-0174.
 **/
- (id)initP2PFrom:(XMPPJID *)jid
{
    if ((self = [super init]))
    {
        NSAssert(NO, @"is not implemented.");
    }
    return self;
}

- (NSXMLElement *)newRootElement {
    NSString *streamNamespaceURI = @"http://etherx.jabber.org/streams";
    NSXMLElement *element = [[NSXMLElement alloc] initWithName:@"stream" URI:streamNamespaceURI];
    [element addNamespaceWithPrefix:@"stream" stringValue:streamNamespaceURI];
    [element addNamespaceWithPrefix:@"" stringValue:@"jabber:client"];
    return element;
}

/**
 * Standard deallocation method.
 * Every object variable declared in the header file should be released here.
 **/
- (void)dealloc
{
#if !OS_OBJECT_USE_OBJC
    dispatch_release(xmppQueue);
    
    dispatch_release(willSendIqQueue);
    dispatch_release(willSendMessageQueue);
    dispatch_release(willSendPresenceQueue);
    
    if (willReceiveStanzaQueue) {
        dispatch_release(willReceiveStanzaQueue);
    }
    
    dispatch_release(didReceiveIqQueue);
#endif
    
    [idTracker removeAllIDs];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Properties
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@synthesize xmppQueue;
@synthesize xmppQueueTag;

- (XMPPStreamState)state
{
    __block XMPPStreamState result = STATE_XMPP_DISCONNECTED;
    
    dispatch_block_t block = ^{
        result = self->state;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

- (NSString *)hostName
{
    if (dispatch_get_specific(xmppQueueTag))
    {
        return hostName;
    }
    else
    {
        __block NSString *result;
        
        dispatch_sync(xmppQueue, ^{
            result = self->hostName;
        });
        
        return result;
    }
}

- (void)setHostName:(NSString *)newHostName
{
    if (dispatch_get_specific(xmppQueueTag))
    {
        if (hostName != newHostName)
        {
            hostName = [newHostName copy];
        }
    }
    else
    {
        NSString *newHostNameCopy = [newHostName copy];
        
        dispatch_async(xmppQueue, ^{
            self->hostName = newHostNameCopy;
        });
        
    }
}

- (UInt16)hostPort
{
    if (dispatch_get_specific(xmppQueueTag))
    {
        return hostPort;
    }
    else
    {
        __block UInt16 result;
        
        dispatch_sync(xmppQueue, ^{
            result = self->hostPort;
        });
        
        return result;
    }
}

- (void)setHostPort:(UInt16)newHostPort
{
    dispatch_block_t block = ^{
        self->hostPort = newHostPort;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (XMPPStreamStartTLSPolicy)startTLSPolicy
{
    __block XMPPStreamStartTLSPolicy result;
    
    dispatch_block_t block = ^{
        result = self->startTLSPolicy;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

- (void)setStartTLSPolicy:(XMPPStreamStartTLSPolicy)flag
{
    dispatch_block_t block = ^{
        self->startTLSPolicy = flag;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (XMPPJID *)myJID
{
    __block XMPPJID *result = nil;
    
    dispatch_block_t block = ^{
        
        if (self->myJID_setByServer)
            result = self->myJID_setByServer;
        else
            result = self->myJID_setByClient;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

- (void)setMyJID_setByClient:(XMPPJID *)newMyJID
{
    // XMPPJID is an immutable class (copy == retain)
    
    dispatch_block_t block = ^{
        
        if (![self->myJID_setByClient isEqualToJID:newMyJID])
        {
            self->myJID_setByClient = newMyJID;
            
            if (self->myJID_setByServer == nil)
            {
                [[NSNotificationCenter defaultCenter] postNotificationName:XMPPStreamDidChangeMyJIDNotification
                                                                    object:self];
                [self->multicastDelegate xmppStreamDidChangeMyJID:self];
            }
        }
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (void)setMyJID_setByServer:(XMPPJID *)newMyJID
{
    // XMPPJID is an immutable class (copy == retain)
    
    dispatch_block_t block = ^{
        
        if (![self->myJID_setByServer isEqualToJID:newMyJID])
        {
            XMPPJID *oldMyJID;
            if (self->myJID_setByServer)
                oldMyJID = self->myJID_setByServer;
            else
                oldMyJID = self->myJID_setByClient;
            
            self->myJID_setByServer = newMyJID;
            
            if (![oldMyJID isEqualToJID:newMyJID])
            {
                [[NSNotificationCenter defaultCenter] postNotificationName:XMPPStreamDidChangeMyJIDNotification
                                                                    object:self];
                [self->multicastDelegate xmppStreamDidChangeMyJID:self];
            }
        }
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (void)setMyJID:(XMPPJID *)newMyJID
{
    [self setMyJID_setByClient:newMyJID];
}

- (XMPPJID *)remoteJID
{
    NSAssert(NO, @"is not implemented.");
    return nil;
}

- (XMPPPresence *)myPresence
{
    if (dispatch_get_specific(xmppQueueTag))
    {
        return myPresence;
    }
    else
    {
        __block XMPPPresence *result;
        
        dispatch_sync(xmppQueue, ^{
            result = self->myPresence;
        });
        
        return result;
    }
}

- (NSTimeInterval)keepAliveInterval
{
    __block NSTimeInterval result = 0.0;
    
    dispatch_block_t block = ^{
        result = self->keepAliveInterval;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

- (void)setKeepAliveInterval:(NSTimeInterval)interval
{
    dispatch_block_t block = ^{
        if (self->keepAliveInterval != interval)
        {
            if (interval <= 0.0)
                self->keepAliveInterval = interval;
            else
                self->keepAliveInterval = MAX(interval, MIN_KEEPALIVE_INTERVAL);
        }
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (char)keepAliveWhitespaceCharacter
{
    __block char keepAliveChar = ' ';
    
    dispatch_block_t block = ^{
        
        NSString *keepAliveString = [[NSString alloc] initWithData:self->keepAliveData encoding:NSUTF8StringEncoding];
        if ([keepAliveString length] > 0)
        {
            keepAliveChar = (char)[keepAliveString characterAtIndex:0];
        }
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return keepAliveChar;
}

- (void)setKeepAliveWhitespaceCharacter:(char)keepAliveChar
{
    dispatch_block_t block = ^{
        
        if (keepAliveChar == ' ' || keepAliveChar == '\n' || keepAliveChar == '\t')
        {
            self->keepAliveData = [[NSString stringWithFormat:@"%c", keepAliveChar] dataUsingEncoding:NSUTF8StringEncoding];
        }
        else
        {
            XMPPLogWarn(@"Invalid whitespace character! Must be: space, newline, or tab");
        }
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (uint64_t)numberOfBytesSent
{
    NSAssert(NO, @"is not implemented.");
    
    return 0;
}

- (uint64_t)numberOfBytesReceived
{
    NSAssert(NO, @"is not implemented.");
    
    return 0;
}

- (void)getNumberOfBytesSent:(uint64_t *)bytesSentPtr numberOfBytesReceived:(uint64_t *)bytesReceivedPtr
{
    NSAssert(NO, @"is not implemented.");
}

- (BOOL)resetByteCountPerConnection
{
    NSAssert(NO, @"is not implemented.");
    
    return NO;
}

- (void)setResetByteCountPerConnection:(BOOL)flag
{
    NSAssert(NO, @"is not implemented.");
}

- (BOOL)skipStartSession
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{
        result = self->skipStartSession;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

- (void)setSkipStartSession:(BOOL)flag
{
    dispatch_block_t block = ^{
        self->skipStartSession = flag;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (BOOL)validatesResponses
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{
        result = self->validatesResponses;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

- (void)setValidatesResponses:(BOOL)flag
{
    dispatch_block_t block = ^{
        self->validatesResponses = flag;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

#if TARGET_OS_IPHONE

- (BOOL)enableBackgroundingOnSocket
{
    NSAssert(NO, @"is not implemented.");
    
    return NO;
}

- (void)setEnableBackgroundingOnSocket:(BOOL)flag
{
    if (flag == YES) {
        NSAssert(NO, @"is not implemented.");
    }
}

#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Configuration
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)addDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue
{
    // Asynchronous operation (if outside xmppQueue)
    
    dispatch_block_t block = ^{
        [self->multicastDelegate addDelegate:delegate delegateQueue:delegateQueue];
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (void)removeDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue
{
    // Synchronous operation
    
    dispatch_block_t block = ^{
        [self->multicastDelegate removeDelegate:delegate delegateQueue:delegateQueue];
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
}

- (void)removeDelegate:(id)delegate
{
    // Synchronous operation
    
    dispatch_block_t block = ^{
        [self->multicastDelegate removeDelegate:delegate];
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Connection State
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Returns YES if the connection is closed, and thus no stream is open.
 * If the stream is neither disconnected, nor connected, then a connection is currently being established.
 **/
- (BOOL)isDisconnected
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{
        result = (self->state == STATE_XMPP_DISCONNECTED);
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

/**
 * Returns YES is the connection is currently connecting
 **/

- (BOOL)isConnecting
{
    XMPPLogTrace();
    
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        result = (self->state == STATE_XMPP_CONNECTING);
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}
/**
 * Returns YES if the connection is open, and the stream has been properly established.
 * If the stream is neither disconnected, nor connected, then a connection is currently being established.
 **/
- (BOOL)isConnected
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{
        result = (self->state == STATE_XMPP_CONNECTED);
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark C2S Connection
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)connectWithTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr
{
    XMPPLogTrace();
    
    __block BOOL result = NO;
    __block NSError *err = nil;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state != STATE_XMPP_DISCONNECTED)
        {
            NSString *errMsg = @"Attempting to connect while already connected or connecting.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamInvalidState userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        if (self->myJID_setByClient == nil)
        {
            // Note: If you wish to use anonymous authentication, you should still set myJID prior to calling connect.
            // You can simply set it to something like "anonymous@<domain>", where "<domain>" is the proper domain.
            // After the authentication process, you can query the myJID property to see what your assigned JID is.
            //
            // Setting myJID allows the framework to follow the xmpp protocol properly,
            // and it allows the framework to connect to servers without a DNS entry.
            //
            // For example, one may setup a private xmpp server for internal testing on their local network.
            // The xmpp domain of the server may be something like "testing.mycompany.com",
            // but since the server is internal, an IP (192.168.1.22) is used as the hostname to connect.
            //
            // Proper connection requires a TCP connection to the IP (192.168.1.22),
            // but the xmpp handshake requires the xmpp domain (testing.mycompany.com).
            
            NSString *errMsg = @"You must set myJID before calling connect.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamInvalidProperty userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        // Notify delegates
        [self->multicastDelegate xmppStreamWillConnect:self];
        
        if (self->transport) {
            [self->transport removeDelegate:self delegateQueue:self->xmppQueue];
        }
        
        switch (self->transportType) {
            case QBTransportTypeSocket:
                self->transport = [[XMPPSocketTransport alloc] initWithQueue:self->xmppQueue];
                break;
            case QBTransportTypeBosh:
                self->transport = [[BoshTransport alloc] initWithQueue:self->xmppQueue];
                break;
            default:
                NSAssert(NO, @"It transport type is not implemented.");
                break;
        }
        [self->transport addDelegate:self delegateQueue:self->xmppQueue];
        
        [self->transport setHostName:self->hostName];
        [self->transport setHostPort:self->hostPort];
        [self->transport setKeepAliveData:self->keepAliveData];
        [self->transport setKeepAliveInterval:self->keepAliveInterval];
        
        [self->transport setMyJID:self->myJID_setByClient];
        
        result = [self->transport connectWithTimeout:timeout error:&err];
        
        self->state = result ? STATE_XMPP_CONNECTING : STATE_XMPP_DISCONNECTED;
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    if (errPtr)
        *errPtr = err;
    
    return result;
}

- (BOOL)oldSchoolSecureConnectWithTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr
{
    XMPPLogTrace();
    
    __block BOOL result = NO;
    __block NSError *err = nil;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // Go through the regular connect routine
        NSError *connectErr = nil;
        result = [self connectWithTimeout:timeout error:&connectErr];
        
        if (result)
        {
            // Mark the secure flag.
            // We will check the flag in socket:didConnectToHost:port:
            
            [self setIsSecure:YES];
        }
        else
        {
            err = connectErr;
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    if (errPtr)
        *errPtr = err;
    
    return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark P2P Connection
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Starts a P2P connection to the given user and given address.
 * This method only works with XMPPStream objects created using the initP2P method.
 *
 * The given address is specified as a sockaddr structure wrapped in a NSData object.
 * For example, a NSData object returned from NSNetservice's addresses method.
 **/
- (BOOL)connectTo:(XMPPJID *)jid withAddress:(NSData *)remoteAddr withTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr
{
    XMPPLogTrace();
    
    NSAssert(NO, @"is not implemented.");
    
    return nil;
}

/**
 * Starts a P2P connection with the given accepted socket.
 * This method only works with XMPPStream objects created using the initP2P method.
 *
 * The given socket should be a socket that has already been accepted.
 * The remoteJID will be extracted from the opening stream negotiation.
 **/
- (BOOL)connectP2PWithSocket:(GCDAsyncSocket *)acceptedSocket error:(NSError **)errPtr
{
    XMPPLogTrace();
    
    NSAssert(NO, @"is not implemented.");
    
    return nil;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Disconnect
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Closes the connection to the remote host.
 **/
- (void)disconnect
{
    XMPPLogTrace();
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state != STATE_XMPP_DISCONNECTED)
        {
            [self->multicastDelegate xmppStreamWasToldToDisconnect:self];
            
            [self->transport disconnect];
            
            // Everthing will be handled in socketDidDisconnect:withError:
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
}

- (void)disconnectAfterSending
{
    XMPPLogTrace();
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state != STATE_XMPP_DISCONNECTED)
        {
            [self->multicastDelegate xmppStreamWasToldToDisconnect:self];
            
            [self->transport disconnect];
            
            // Everthing will be handled in socketDidDisconnect:withError:
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Security
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Returns YES if SSL/TLS has been used to secure the connection.
 **/
- (BOOL)isSecure
{
    if (dispatch_get_specific(xmppQueueTag))
    {
        return (flags & kIsSecure) ? YES : NO;
    }
    else
    {
        __block BOOL result;
        
        dispatch_sync(xmppQueue, ^{
            result = (self->flags & kIsSecure) ? YES : NO;
        });
        
        return result;
    }
}

- (void)setIsSecure:(BOOL)flag
{
    dispatch_block_t block = ^{
        if(flag)
            self->flags |= kIsSecure;
        else
            self->flags &= ~kIsSecure;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (BOOL)supportsStartTLS
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // The root element can be properly queried for authentication mechanisms anytime after the
        // stream:features are received, and TLS has been setup (if required)
        if (self->state >= STATE_XMPP_POST_NEGOTIATION)
        {
            NSXMLElement *features = [self->rootElement elementForName:@"stream:features"];
            NSXMLElement *starttls = [features elementForName:@"starttls" xmlns:@"urn:ietf:params:xml:ns:xmpp-tls"];
            
            result = (starttls != nil);
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

- (void)sendStartTLSRequest
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    XMPPLogTrace();
    
    NSString *starttls = @"<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>";
    XMPPLogSend(@"SEND: %@", starttls);
    
    [transport sendStanzaWithString:starttls];
}

- (BOOL)secureConnection:(NSError **)errPtr
{
    XMPPLogTrace();
    
    __block BOOL result = YES;
    __block NSError *err = nil;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state != STATE_XMPP_CONNECTED)
        {
            NSString *errMsg = @"Please wait until the stream is connected.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamInvalidState userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        if ([self isSecure])
        {
            NSString *errMsg = @"The connection is already secure.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamInvalidState userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        if (![self supportsStartTLS])
        {
            NSString *errMsg = @"The server does not support startTLS.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamUnsupportedAction userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        // Update state
        self->state = STATE_XMPP_STARTTLS_1;
        
        // Send the startTLS XML request
        [self sendStartTLSRequest];
        
        // We do not mark the stream as secure yet.
        // We're waiting to receive the <proceed/> response from the
        // server before we actually start the TLS handshake.
        
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    if (errPtr)
        *errPtr = err;
    
    return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Registration
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * This method checks the stream features of the connected server to determine if in-band registartion is supported.
 * If we are not connected to a server, this method simply returns NO.
 **/
- (BOOL)supportsInBandRegistration
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // The root element can be properly queried for authentication mechanisms anytime after the
        // stream:features are received, and TLS has been setup (if required)
        if (self->state >= STATE_XMPP_POST_NEGOTIATION)
        {
            NSXMLElement *features = [self->rootElement elementForName:@"stream:features"];
            NSXMLElement *reg = [features elementForName:@"register" xmlns:@"http://jabber.org/features/iq-register"];
            
            result = (reg != nil);
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

/**
 * This method attempts to register a new user on the server using the given elements.
 * The result of this action will be returned via the delegate methods.
 *
 * If the XMPPStream is not connected, or the server doesn't support in-band registration, this method does nothing.
 **/
- (BOOL)registerWithElements:(NSArray *)elements error:(NSError **)errPtr
{
    XMPPLogTrace();
    
    __block BOOL result = YES;
    __block NSError *err = nil;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state != STATE_XMPP_CONNECTED)
        {
            NSString *errMsg = @"Please wait until the stream is connected.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamInvalidState userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        if (![self supportsInBandRegistration])
        {
            NSString *errMsg = @"The server does not support in band registration.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamUnsupportedAction userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        NSXMLElement *queryElement = [NSXMLElement elementWithName:@"query" xmlns:@"jabber:iq:register"];
        
        for(NSXMLElement *element in elements)
        {
            [queryElement addChild:element];
        }
        
        XMPPIQ *iq = [XMPPIQ iqWithType:@"set"];
        [iq addChild:queryElement];
        
        NSString *outgoingStr = [iq compactXMLString];
        XMPPLogSend(@"SEND: %@", outgoingStr);
        [self->transport sendStanzaWithString:outgoingStr];
        
        // Update state
        self->state = STATE_XMPP_REGISTERING;
        
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    if (errPtr)
        *errPtr = err;
    
    return result;
    
}

/**
 * This method attempts to register a new user on the server using the given username and password.
 * The result of this action will be returned via the delegate methods.
 *
 * If the XMPPStream is not connected, or the server doesn't support in-band registration, this method does nothing.
 **/
- (BOOL)registerWithPassword:(NSString *)password error:(NSError **)errPtr
{
    XMPPLogTrace();
    
    __block BOOL result = YES;
    __block NSError *err = nil;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->myJID_setByClient == nil)
        {
            NSString *errMsg = @"You must set myJID before calling registerWithPassword:error:.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamInvalidProperty userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        NSString *username = [self->myJID_setByClient user];
        
        NSMutableArray *elements = [NSMutableArray array];
        [elements addObject:[NSXMLElement elementWithName:@"username" stringValue:username]];
        [elements addObject:[NSXMLElement elementWithName:@"password" stringValue:password]];
        
        [self registerWithElements:elements error:errPtr];
        
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    if (errPtr)
        *errPtr = err;
    
    return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Authentication
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSArray *)supportedAuthenticationMechanisms
{
    __block NSMutableArray *result = [[NSMutableArray alloc] init];
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // The root element can be properly queried for authentication mechanisms anytime after the
        // stream:features are received, and TLS has been setup (if required).
        
        if (self->state >= STATE_XMPP_POST_NEGOTIATION)
        {
            NSXMLElement *features = [self->rootElement elementForName:@"stream:features"];
            NSXMLElement *mech = [features elementForName:@"mechanisms" xmlns:@"urn:ietf:params:xml:ns:xmpp-sasl"];
            
            NSArray *mechanisms = [mech elementsForName:@"mechanism"];
            
            for (NSXMLElement *mechanism in mechanisms)
            {
                [result addObject:[mechanism stringValue]];
            }
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

/**
 * This method checks the stream features of the connected server to determine
 * if the given authentication mechanism is supported.
 *
 * If we are not connected to a server, this method simply returns NO.
 **/
- (BOOL)supportsAuthenticationMechanism:(NSString *)mechanismType
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // The root element can be properly queried for authentication mechanisms anytime after the
        // stream:features are received, and TLS has been setup (if required).
        
        if (self->state >= STATE_XMPP_POST_NEGOTIATION)
        {
            NSXMLElement *features = [self->rootElement elementForName:@"stream:features"];
            NSXMLElement *mech = [features elementForName:@"mechanisms" xmlns:@"urn:ietf:params:xml:ns:xmpp-sasl"];
            
            NSArray *mechanisms = [mech elementsForName:@"mechanism"];
            
            for (NSXMLElement *mechanism in mechanisms)
            {
                if ([[mechanism stringValue] isEqualToString:mechanismType])
                {
                    result = YES;
                    break;
                }
            }
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

- (BOOL)authenticate:(id <XMPPSASLAuthentication>)inAuth error:(NSError **)errPtr
{
    XMPPLogTrace();
    
    __block BOOL result = NO;
    __block NSError *err = nil;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state != STATE_XMPP_CONNECTED)
        {
            NSString *errMsg = @"Please wait until the stream is connected.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamInvalidState userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        if (self->myJID_setByClient == nil)
        {
            NSString *errMsg = @"You must set myJID before calling authenticate:error:.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamInvalidProperty userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        // Change state.
        // We do this now because when we invoke the start method below,
        // it may in turn invoke our sendAuthElement method, which expects us to be in STATE_XMPP_AUTH.
        self->state = STATE_XMPP_AUTH;
        
        if ([inAuth start:&err])
        {
            self->auth = inAuth;
            result = YES;
        }
        else
        {
            // Unable to start authentication for some reason.
            // Revert back to connected state.
            self->state = STATE_XMPP_CONNECTED;
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    if (errPtr)
        *errPtr = err;
    
    return result;
}

/**
 * This method applies to standard password authentication schemes only.
 * This is NOT the primary authentication method.
 *
 * @see authenticate:error:
 *
 * This method exists for backwards compatibility, and may disappear in future versions.
 **/
- (BOOL)authenticateWithPassword:(NSString *)inPassword error:(NSError **)errPtr
{
    XMPPLogTrace();
    
    // The given password parameter could be mutable
    NSString *password = [inPassword copy];
    
    
    __block BOOL result = YES;
    __block NSError *err = nil;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state != STATE_XMPP_CONNECTED)
        {
            NSString *errMsg = @"Please wait until the stream is connected.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamInvalidState userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        if (self->myJID_setByClient == nil)
        {
            NSString *errMsg = @"You must set myJID before calling authenticate:error:.";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamInvalidProperty userInfo:info];
            
            result = NO;
            return_from_block;
        }
        
        // Choose the best authentication method.
        //
        // P.S. - This method is deprecated.
        
        id <XMPPSASLAuthentication> someAuth = nil;
        
        if ([self supportsPlainAuthentication])
        {
            someAuth = [[XMPPPlainAuthentication alloc] initWithStream:self password:password];
            result = [self authenticate:someAuth error:&err];
        }
        else
        {
            NSString *errMsg = @"No suitable authentication method found";
            NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
            
            err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamUnsupportedAction userInfo:info];
            
            result = NO;
        }
        /*
         if ([self supportsSCRAMSHA1Authentication])
         {
         someAuth = [[XMPPSCRAMSHA1Authentication alloc] initWithStream:self password:password];
         result = [self authenticate:someAuth error:&err];
         }
         else if ([self supportsDigestMD5Authentication])
         {
         someAuth = [[XMPPDigestMD5Authentication alloc] initWithStream:self password:password];
         result = [self authenticate:someAuth error:&err];
         }
         else if ([self supportsPlainAuthentication])
         {
         someAuth = [[XMPPPlainAuthentication alloc] initWithStream:self password:password];
         result = [self authenticate:someAuth error:&err];
         }
         else if ([self supportsDeprecatedDigestAuthentication])
         {
         someAuth = [[XMPPDeprecatedDigestAuthentication alloc] initWithStream:self password:password];
         result = [self authenticate:someAuth error:&err];
         }
         else if ([self supportsDeprecatedPlainAuthentication])
         {
         someAuth = [[XMPPDeprecatedDigestAuthentication alloc] initWithStream:self password:password];
         result = [self authenticate:someAuth error:&err];
         }
         else
         {
         NSString *errMsg = @"No suitable authentication method found";
         NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
         
         err = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamUnsupportedAction userInfo:info];
         
         result = NO;
         }
         */
    }};
    
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    if (errPtr)
        *errPtr = err;
    
    return result;
}

- (BOOL)isAuthenticating
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        result = (self->state == STATE_XMPP_AUTH);
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

- (BOOL)isAuthenticated
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{
        result = (self->flags & kIsAuthenticated) ? YES : NO;
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

- (void)setIsAuthenticated:(BOOL)flag
{
    dispatch_block_t block = ^{
        if(flag)
        {
            self->flags |= kIsAuthenticated;
            self->authenticationDate = [NSDate date];
        }
        else
        {
            self->flags &= ~kIsAuthenticated;
            self->authenticationDate = nil;
        }
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (NSDate *)authenticationDate
{
    __block NSDate *result = nil;
    
    dispatch_block_t block = ^{
        if(self->flags & kIsAuthenticated)
        {
            result = self->authenticationDate;
        }
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Compression
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSArray *)supportedCompressionMethods
{
    __block NSMutableArray *result = [[NSMutableArray alloc] init];
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // The root element can be properly queried for compression methods anytime after the
        // stream:features are received, and TLS has been setup (if required).
        
        if (self->state >= STATE_XMPP_POST_NEGOTIATION)
        {
            NSXMLElement *features = [self->rootElement elementForName:@"stream:features"];
            NSXMLElement *compression = [features elementForName:@"compression" xmlns:@"http://jabber.org/features/compress"];
            
            NSArray *methods = [compression elementsForName:@"method"];
            
            for (NSXMLElement *method in methods)
            {
                [result addObject:[method stringValue]];
            }
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

/**
 * This method checks the stream features of the connected server to determine
 * if the given compression method is supported.
 *
 * If we are not connected to a server, this method simply returns NO.
 **/
- (BOOL)supportsCompressionMethod:(NSString *)compressionMethod
{
    __block BOOL result = NO;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // The root element can be properly queried for compression methods anytime after the
        // stream:features are received, and TLS has been setup (if required).
        
        if (self->state >= STATE_XMPP_POST_NEGOTIATION)
        {
            NSXMLElement *features = [self->rootElement elementForName:@"stream:features"];
            NSXMLElement *compression = [features elementForName:@"compression" xmlns:@"http://jabber.org/features/compress"];
            
            NSArray *methods = [compression elementsForName:@"method"];
            
            for (NSXMLElement *method in methods)
            {
                if ([[method stringValue] isEqualToString:compressionMethod])
                {
                    result = YES;
                    break;
                }
            }
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
    
    return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark General Methods
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * This method will return the root element of the document.
 * This element contains the opening <stream:stream/> and <stream:features/> tags received from the server
 * when the XML stream was opened.
 *
 * Note: The rootElement is empty, and does not contain all the XML elements the stream has received during it's
 * connection.  This is done for performance reasons and for the obvious benefit of being more memory efficient.
 **/
- (NSXMLElement *)rootElement
{
    if (dispatch_get_specific(xmppQueueTag))
    {
        return rootElement;
    }
    else
    {
        __block NSXMLElement *result = nil;
        
        dispatch_sync(xmppQueue, ^{
            result = [self->rootElement copy];
        });
        
        return result;
    }
}

/**
 * Returns the version attribute from the servers's <stream:stream/> element.
 * This should be at least 1.0 to be RFC 3920 compliant.
 * If no version number was set, the server is not RFC compliant, and 0 is returned.
 **/
- (float)serverXmppStreamVersionNumber
{
    if (dispatch_get_specific(xmppQueueTag))
    {
        return [self->rootElement attributeFloatValueForName:@"version" withDefaultValue:0.0F];
    }
    else
    {
        __block float result;
        
        dispatch_sync(xmppQueue, ^{
            result = [self->rootElement attributeFloatValueForName:@"version" withDefaultValue:0.0F];
        });
        
        return result;
    }
}

- (void)sendIQ:(XMPPIQ *)iq withTag:(long)tag
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_XMPP_CONNECTED, @"Invoked with incorrect state");
    
    // We're getting ready to send an IQ.
    // Notify delegates to allow them to optionally alter/filter the outgoing IQ.
    
    SEL selector = @selector(xmppStream:willSendIQ:);
    
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        // None of the delegates implement the method.
        // Use a shortcut.
        
        [self continueSendIQ:iq withTag:tag];
    }
    else
    {
        // Notify all interested delegates.
        // This must be done serially to allow them to alter the element in a thread-safe manner.
        
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        dispatch_async(willSendIqQueue, ^{ @autoreleasepool {
            
            // Allow delegates to modify and/or filter outgoing element
            
            __block XMPPIQ *modifiedIQ = iq;
            
            id del;
            dispatch_queue_t dq;
            
            while (modifiedIQ && [delegateEnumerator getNextDelegate:&del delegateQueue:&dq forSelector:selector])
            {
#if DEBUG
                {
                    char methodReturnType[32];
                    
                    Method method = class_getInstanceMethod([del class], selector);
                    method_getReturnType(method, methodReturnType, sizeof(methodReturnType));
                    
                    if (strcmp(methodReturnType, @encode(XMPPIQ*)) != 0)
                    {
                        NSAssert(NO, @"Method xmppStream:willSendIQ: is no longer void (see XMPPStream.h). "
                                 @"Culprit = %@", NSStringFromClass([del class]));
                    }
                }
#endif
                
                dispatch_sync(dq, ^{ @autoreleasepool {
                    
                    modifiedIQ = [del xmppStream:self willSendIQ:modifiedIQ];
                    
                }});
            }
            
            if (modifiedIQ)
            {
                dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                    
                    if (self->state == STATE_XMPP_CONNECTED) {
                        [self continueSendIQ:modifiedIQ withTag:tag];
                    } else {
                        [self failToSendIQ:modifiedIQ];
                    }
                }});
            }
        }});
    }
}

- (void)sendMessage:(XMPPMessage *)message withTag:(long)tag
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_XMPP_CONNECTED, @"Invoked with incorrect state");
    
    // We're getting ready to send a message.
    // Notify delegates to allow them to optionally alter/filter the outgoing message.
    
    SEL selector = @selector(xmppStream:willSendMessage:);
    
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        // None of the delegates implement the method.
        // Use a shortcut.
        
        [self continueSendMessage:message withTag:tag];
    }
    else
    {
        // Notify all interested delegates.
        // This must be done serially to allow them to alter the element in a thread-safe manner.
        
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        dispatch_async(willSendMessageQueue, ^{ @autoreleasepool {
            
            // Allow delegates to modify outgoing element
            
            __block XMPPMessage *modifiedMessage = message;
            
            id del;
            dispatch_queue_t dq;
            
            while (modifiedMessage && [delegateEnumerator getNextDelegate:&del delegateQueue:&dq forSelector:selector])
            {
#if DEBUG
                {
                    char methodReturnType[32];
                    
                    Method method = class_getInstanceMethod([del class], selector);
                    method_getReturnType(method, methodReturnType, sizeof(methodReturnType));
                    
                    if (strcmp(methodReturnType, @encode(XMPPMessage*)) != 0)
                    {
                        NSAssert(NO, @"Method xmppStream:willSendMessage: is no longer void (see XMPPStream.h). "
                                 @"Culprit = %@", NSStringFromClass([del class]));
                    }
                }
#endif
                
                dispatch_sync(dq, ^{ @autoreleasepool {
                    
                    modifiedMessage = [del xmppStream:self willSendMessage:modifiedMessage];
                    
                }});
            }
            
            if (modifiedMessage)
            {
                dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                    
                    if (self->state == STATE_XMPP_CONNECTED) {
                        [self continueSendMessage:modifiedMessage withTag:tag];
                    }
                    else {
                        [self failToSendMessage:modifiedMessage];
                    }
                }});
            }
        }});
    }
}

- (void)sendPresence:(XMPPPresence *)presence withTag:(long)tag
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_XMPP_CONNECTED, @"Invoked with incorrect state");
    
    // We're getting ready to send a presence element.
    // Notify delegates to allow them to optionally alter/filter the outgoing presence.
    
    SEL selector = @selector(xmppStream:willSendPresence:);
    
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        // None of the delegates implement the method.
        // Use a shortcut.
        
        [self continueSendPresence:presence withTag:tag];
    }
    else
    {
        // Notify all interested delegates.
        // This must be done serially to allow them to alter the element in a thread-safe manner.
        
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        dispatch_async(willSendPresenceQueue, ^{ @autoreleasepool {
            
            // Allow delegates to modify outgoing element
            
            __block XMPPPresence *modifiedPresence = presence;
            
            id del;
            dispatch_queue_t dq;
            
            while (modifiedPresence && [delegateEnumerator getNextDelegate:&del delegateQueue:&dq forSelector:selector])
            {
#if DEBUG
                {
                    char methodReturnType[32];
                    
                    Method method = class_getInstanceMethod([del class], selector);
                    method_getReturnType(method, methodReturnType, sizeof(methodReturnType));
                    
                    if (strcmp(methodReturnType, @encode(XMPPPresence*)) != 0)
                    {
                        NSAssert(NO, @"Method xmppStream:willSendPresence: is no longer void (see XMPPStream.h). "
                                 @"Culprit = %@", NSStringFromClass([del class]));
                    }
                }
#endif
                
                dispatch_sync(dq, ^{ @autoreleasepool {
                    
                    modifiedPresence = [del xmppStream:self willSendPresence:modifiedPresence];
                    
                }});
            }
            
            if (modifiedPresence)
            {
                dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                    
                    if (self->state == STATE_XMPP_CONNECTED) {
                        [self continueSendPresence:modifiedPresence withTag:tag];
                    } else {
                        [self failToSendPresence:modifiedPresence];
                    }
                }});
            }
        }});
    }
}

- (void)continueSendIQ:(XMPPIQ *)iq withTag:(long)tag
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_XMPP_CONNECTED, @"Invoked with incorrect state");
    
    NSString *outgoingStr = [iq compactXMLString];
    XMPPLogSend(@"SEND: %@", outgoingStr);
    
    [transport sendStanzaWithString:outgoingStr tag:tag];
    
    [multicastDelegate xmppStream:self didSendIQ:iq];
}

- (void)continueSendMessage:(XMPPMessage *)message withTag:(long)tag
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_XMPP_CONNECTED, @"Invoked with incorrect state");
    
    NSString *outgoingStr = [message compactXMLString];
    XMPPLogSend(@"SEND: %@", outgoingStr);
    
    [transport sendStanzaWithString:outgoingStr tag:tag];
    
    [multicastDelegate xmppStream:self didSendMessage:message];
}

- (void)continueSendPresence:(XMPPPresence *)presence withTag:(long)tag
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_XMPP_CONNECTED, @"Invoked with incorrect state");
    
    NSString *outgoingStr = [presence compactXMLString];
    XMPPLogSend(@"SEND: %@", outgoingStr);
    
    [transport sendStanzaWithString:outgoingStr tag:tag];
    
    // Update myPresence if this is a normal presence element.
    // In other words, ignore presence subscription stuff, MUC room stuff, etc.
    //
    // We use the built-in [presence type] which guarantees lowercase strings,
    // and will return @"available" if there was no set type (as available is implicit).
    
    NSString *type = [presence type];
    if ([type isEqualToString:@"available"] || [type isEqualToString:@"unavailable"])
    {
        if ([presence toStr] == nil && myPresence != presence)
        {
            myPresence = presence;
        }
    }
    
    [multicastDelegate xmppStream:self didSendPresence:presence];
}

- (void)continueSendElement:(NSXMLElement *)element withTag:(long)tag
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_XMPP_CONNECTED, @"Invoked with incorrect state");
    
    NSString *outgoingStr = [element compactXMLString];
    XMPPLogSend(@"SEND: %@", outgoingStr);
    
    [transport sendStanzaWithString:outgoingStr tag:tag];
    
    if ([customElementNames countForObject:[element name]])
    {
        [multicastDelegate xmppStream:self didSendCustomElement:element];
    }
}

/**
 * Private method.
 * Presencts a common method for the various public sendElement methods.
 **/
- (void)sendElement:(NSXMLElement *)element withTag:(long)tag
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    
    if ([element isKindOfClass:[XMPPIQ class]])
    {
        [self sendIQ:(XMPPIQ *)element withTag:tag];
    }
    else if ([element isKindOfClass:[XMPPMessage class]])
    {
        [self sendMessage:(XMPPMessage *)element withTag:tag];
    }
    else if ([element isKindOfClass:[XMPPPresence class]])
    {
        [self sendPresence:(XMPPPresence *)element withTag:tag];
    }
    else
    {
        NSString *elementName = [element name];
        
        if ([elementName isEqualToString:@"iq"])
        {
            [self sendIQ:[XMPPIQ iqFromElement:element] withTag:tag];
        }
        else if ([elementName isEqualToString:@"message"])
        {
            [self sendMessage:[XMPPMessage messageFromElement:element] withTag:tag];
        }
        else if ([elementName isEqualToString:@"presence"])
        {
            [self sendPresence:[XMPPPresence presenceFromElement:element] withTag:tag];
        }
        else
        {
            [self continueSendElement:element withTag:tag];
        }
    }
}

/**
 * This methods handles sending an XML stanza.
 * If the XMPPStream is not connected, this method does nothing.
 **/
- (void)sendElement:(NSXMLElement *)element
{
    if (element == nil) return;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state == STATE_XMPP_CONNECTED)
        {
            [self sendElement:element withTag:TAG_XMPP_WRITE_STREAM];
        }
        else
        {
            [self failToSendElement:element];
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

/**
 * This method handles sending an XML stanza.
 * If the XMPPStream is not connected, this method does nothing.
 *
 * After the element has been successfully sent,
 * the xmppStream:didSendElementWithTag: delegate method is called.
 **/
- (void)sendElement:(NSXMLElement *)element andGetReceipt:(XMPPElementReceipt **)receiptPtr
{
    if (element == nil) return;
    
    if (receiptPtr == nil)
    {
        [self sendElement:element];
    }
    else
    {
        __block XMPPElementReceipt *receipt = nil;
        
        dispatch_block_t block = ^{ @autoreleasepool {
            
            if (self->state == STATE_XMPP_CONNECTED)
            {
                receipt = [[XMPPElementReceipt alloc] init];
                [self->transport addReceipt:receipt];
                
                [self sendElement:element withTag:TAG_XMPP_WRITE_RECEIPT];
            }
            else
            {
                [self failToSendElement:element];
            }
        }};
        
        if (dispatch_get_specific(xmppQueueTag))
            block();
        else
            dispatch_sync(xmppQueue, block);
        
        *receiptPtr = receipt;
    }
}

- (void)failToSendElement:(NSXMLElement *)element
{
    
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    if ([element isKindOfClass:[XMPPIQ class]])
    {
        [self failToSendIQ:(XMPPIQ *)element];
    }
    else if ([element isKindOfClass:[XMPPMessage class]])
    {
        [self failToSendMessage:(XMPPMessage *)element];
    }
    else if ([element isKindOfClass:[XMPPPresence class]])
    {
        [self failToSendPresence:(XMPPPresence *)element];
    }
    else
    {
        NSString *elementName = [element name];
        
        if ([elementName isEqualToString:@"iq"])
        {
            [self failToSendIQ:[XMPPIQ iqFromElement:element]];
        }
        else if ([elementName isEqualToString:@"message"])
        {
            [self failToSendMessage:[XMPPMessage messageFromElement:element]];
        }
        else if ([elementName isEqualToString:@"presence"])
        {
            [self failToSendPresence:[XMPPPresence presenceFromElement:element]];
        }
    }
}

- (void)failToSendIQ:(XMPPIQ *)iq
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    NSError *error = [NSError errorWithDomain:XMPPStreamErrorDomain
                                         code:XMPPStreamInvalidState
                                     userInfo:nil];
    
    [multicastDelegate xmppStream:self didFailToSendIQ:iq error:error];
}

- (void)failToSendMessage:(XMPPMessage *)message
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    NSError *error = [NSError errorWithDomain:XMPPStreamErrorDomain
                                         code:XMPPStreamInvalidState
                                     userInfo:nil];
    
    [multicastDelegate xmppStream:self didFailToSendMessage:message error:error];
}

- (void)failToSendPresence:(XMPPPresence *)presence
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    NSError *error = [NSError errorWithDomain:XMPPStreamErrorDomain
                                         code:XMPPStreamInvalidState
                                     userInfo:nil];
    
    [multicastDelegate xmppStream:self didFailToSendPresence:presence error:error];
}

/**
 * Retrieves the current presence and resends it in once atomic operation.
 * Useful for various components that need to update injected information in the presence stanza.
 **/
- (void)resendMyPresence
{
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->myPresence && [[self->myPresence type] isEqualToString:@"available"])
        {
            [self sendElement:self->myPresence];
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

/**
 * This method is for use by xmpp authentication mechanism classes.
 * They should send elements using this method instead of the public sendElement methods,
 * as those methods don't send the elements while authentication is in progress.
 *
 * @see XMPPSASLAuthentication
 **/
- (void)sendAuthElement:(NSXMLElement *)element
{
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state == STATE_XMPP_AUTH)
        {
            NSString *outgoingStr = [element compactXMLString];
            XMPPLogSend(@"SEND: %@", outgoingStr);
            
            [self->transport sendStanzaWithString:outgoingStr];
        }
        else
        {
            XMPPLogWarn(@"Unable to send element while not in STATE_XMPP_AUTH: %@", [element compactXMLString]);
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

/**
 * This method is for use by xmpp custom binding classes.
 * They should send elements using this method instead of the public sendElement methods,
 * as those methods don't send the elements while authentication/binding is in progress.
 *
 * @see XMPPCustomBinding
 **/
- (void)sendBindElement:(NSXMLElement *)element
{
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state == STATE_XMPP_BINDING)
        {
            NSString *outgoingStr = [element compactXMLString];
            XMPPLogSend(@"SEND: %@", outgoingStr);
            
            [transport sendStanzaWithString:outgoingStr];
        }
        else
        {
            XMPPLogWarn(@"Unable to send element while not in STATE_XMPP_BINDING: %@", [element compactXMLString]);
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (void)receiveIQ:(XMPPIQ *)iq
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_XMPP_CONNECTED, @"Invoked with incorrect state");
    
    // We're getting ready to receive an IQ.
    // Notify delegates to allow them to optionally alter/filter the incoming IQ element.
    
    SEL selector = @selector(xmppStream:willReceiveIQ:);
    
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        // None of the delegates implement the method.
        // Use a shortcut.
        
        if (willReceiveStanzaQueue)
        {
            // But still go through the stanzaQueue in order to guarantee in-order-delivery of all received stanzas.
            
            dispatch_async(willReceiveStanzaQueue, ^{
                dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                    if (self->state == STATE_XMPP_CONNECTED) {
                        [self continueReceiveIQ:iq];
                    }
                }});
            });
        }
        else
        {
            [self continueReceiveIQ:iq];
        }
    }
    else
    {
        // Notify all interested delegates.
        // This must be done serially to allow them to alter the element in a thread-safe manner.
        
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        if (willReceiveStanzaQueue == NULL)
            willReceiveStanzaQueue = dispatch_queue_create("xmpp.willReceiveStanza", DISPATCH_QUEUE_SERIAL);
        
        dispatch_async(willReceiveStanzaQueue, ^{ @autoreleasepool {
            
            // Allow delegates to modify and/or filter incoming element
            
            __block XMPPIQ *modifiedIQ = iq;
            
            id del;
            dispatch_queue_t dq;
            
            while (modifiedIQ && [delegateEnumerator getNextDelegate:&del delegateQueue:&dq forSelector:selector])
            {
                dispatch_sync(dq, ^{ @autoreleasepool {
                    
                    modifiedIQ = [del xmppStream:self willReceiveIQ:modifiedIQ];
                    
                }});
            }
            
            dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                
                if (self->state == STATE_XMPP_CONNECTED)
                {
                    if (modifiedIQ)
                        [self continueReceiveIQ:modifiedIQ];
                    else
                        [self->multicastDelegate xmppStreamDidFilterStanza:self];
                }
            }});
        }});
    }
}

- (void)receiveMessage:(XMPPMessage *)message
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_XMPP_CONNECTED, @"Invoked with incorrect state");
    
    // We're getting ready to receive a message.
    // Notify delegates to allow them to optionally alter/filter the incoming message.
    
    SEL selector = @selector(xmppStream:willReceiveMessage:);
    
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        // None of the delegates implement the method.
        // Use a shortcut.
        
        if (willReceiveStanzaQueue)
        {
            // But still go through the stanzaQueue in order to guarantee in-order-delivery of all received stanzas.
            
            dispatch_async(willReceiveStanzaQueue, ^{
                dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                    
                    if (self->state == STATE_XMPP_CONNECTED) {
                        [self continueReceiveMessage:message];
                    }
                }});
            });
        }
        else
        {
            [self continueReceiveMessage:message];
        }
    }
    else
    {
        // Notify all interested delegates.
        // This must be done serially to allow them to alter the element in a thread-safe manner.
        
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        if (willReceiveStanzaQueue == NULL)
            willReceiveStanzaQueue = dispatch_queue_create("xmpp.willReceiveStanza", DISPATCH_QUEUE_SERIAL);
        
        dispatch_async(willReceiveStanzaQueue, ^{ @autoreleasepool {
            
            // Allow delegates to modify incoming element
            
            __block XMPPMessage *modifiedMessage = message;
            
            id del;
            dispatch_queue_t dq;
            
            while (modifiedMessage && [delegateEnumerator getNextDelegate:&del delegateQueue:&dq forSelector:selector])
            {
                dispatch_sync(dq, ^{ @autoreleasepool {
                    
                    modifiedMessage = [del xmppStream:self willReceiveMessage:modifiedMessage];
                    
                }});
            }
            
            dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                
                if (self->state == STATE_XMPP_CONNECTED)
                {
                    if (modifiedMessage)
                        [self continueReceiveMessage:modifiedMessage];
                    else
                        [self->multicastDelegate xmppStreamDidFilterStanza:self];
                }
            }});
        }});
    }
}

- (void)receivePresence:(XMPPPresence *)presence
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    NSAssert(state == STATE_XMPP_CONNECTED, @"Invoked with incorrect state");
    
    // We're getting ready to receive a presence element.
    // Notify delegates to allow them to optionally alter/filter the incoming presence.
    
    SEL selector = @selector(xmppStream:willReceivePresence:);
    
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        // None of the delegates implement the method.
        // Use a shortcut.
        
        if (willReceiveStanzaQueue)
        {
            // But still go through the stanzaQueue in order to guarantee in-order-delivery of all received stanzas.
            
            dispatch_async(willReceiveStanzaQueue, ^{
                dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                    
                    if (self->state == STATE_XMPP_CONNECTED) {
                        [self continueReceivePresence:presence];
                    }
                }});
            });
        }
        else
        {
            [self continueReceivePresence:presence];
        }
    }
    else
    {
        // Notify all interested delegates.
        // This must be done serially to allow them to alter the element in a thread-safe manner.
        
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        if (willReceiveStanzaQueue == NULL)
            willReceiveStanzaQueue = dispatch_queue_create("xmpp.willReceiveStanza", DISPATCH_QUEUE_SERIAL);
        
        dispatch_async(willReceiveStanzaQueue, ^{ @autoreleasepool {
            
            // Allow delegates to modify outgoing element
            
            __block XMPPPresence *modifiedPresence = presence;
            
            id del;
            dispatch_queue_t dq;
            
            while (modifiedPresence && [delegateEnumerator getNextDelegate:&del delegateQueue:&dq forSelector:selector])
            {
                dispatch_sync(dq, ^{ @autoreleasepool {
                    
                    modifiedPresence = [del xmppStream:self willReceivePresence:modifiedPresence];
                    
                }});
            }
            
            dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                
                if (self->state == STATE_XMPP_CONNECTED)
                {
                    if (modifiedPresence)
                        [self continueReceivePresence:presence];
                    else
                        [self->multicastDelegate xmppStreamDidFilterStanza:self];
                }
            }});
        }});
    }
}

- (void)continueReceiveIQ:(XMPPIQ *)iq
{
    if ([iq requiresResponse])
    {
        // As per the XMPP specificiation, if the IQ requires a response,
        // and we don't have any delegates or modules that can properly respond to the IQ,
        // we MUST send back and error IQ.
        //
        // So we notifiy all interested delegates and modules about the received IQ,
        // keeping track of whether or not any of them have handled it.
        
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        id del;
        dispatch_queue_t dq;
        
        SEL selector = @selector(xmppStream:didReceiveIQ:);
        
        dispatch_semaphore_t delSemaphore = dispatch_semaphore_create(0);
        dispatch_group_t delGroup = dispatch_group_create();
        
        while ([delegateEnumerator getNextDelegate:&del delegateQueue:&dq forSelector:selector])
        {
            dispatch_group_async(delGroup, dq, ^{ @autoreleasepool {
                
                if ([del xmppStream:self didReceiveIQ:iq])
                {
                    dispatch_semaphore_signal(delSemaphore);
                }
                
            }});
        }
        
        dispatch_async(didReceiveIqQueue, ^{ @autoreleasepool {
            
            dispatch_group_wait(delGroup, DISPATCH_TIME_FOREVER);
            
            // Did any of the delegates handle the IQ? (handle == will response)
            
            BOOL handled = (dispatch_semaphore_wait(delSemaphore, DISPATCH_TIME_NOW) == 0);
            
            // An entity that receives an IQ request of type "get" or "set" MUST reply
            // with an IQ response of type "result" or "error".
            //
            // The response MUST preserve the 'id' attribute of the request.
            
            if (!handled)
            {
                // Return error message:
                //
                // <iq to="jid" type="error" id="id">
                //   <query xmlns="ns"/>
                //   <error type="cancel" code="501">
                //     <feature-not-implemented xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>
                //   </error>
                // </iq>
                
                NSXMLElement *reason = [NSXMLElement elementWithName:@"feature-not-implemented"
                                                               xmlns:@"urn:ietf:params:xml:ns:xmpp-stanzas"];
                
                NSXMLElement *error = [NSXMLElement elementWithName:@"error"];
                [error addAttributeWithName:@"type" stringValue:@"cancel"];
                [error addAttributeWithName:@"code" stringValue:@"501"];
                [error addChild:reason];
                
                XMPPIQ *iqResponse = [XMPPIQ iqWithType:@"error"
                                                     to:[iq from]
                                              elementID:[iq elementID]
                                                  child:error];
                
                NSXMLElement *iqChild = [iq childElement];
                if (iqChild)
                {
                    NSXMLNode *iqChildCopy = [iqChild copy];
                    [iqResponse insertChild:iqChildCopy atIndex:0];
                }
                
                // Purposefully go through the sendElement: method
                // so that it gets dispatched onto the xmppQueue,
                // and so that modules may get notified of the outgoing error message.
                
                [self sendElement:iqResponse];
            }
            
#if !OS_OBJECT_USE_OBJC
            dispatch_release(delSemaphore);
            dispatch_release(delGroup);
#endif
            
        }});
    }
    else
    {
        // The IQ doesn't require a response.
        // So we can just fire the delegate method and ignore the responses.
        
        [multicastDelegate xmppStream:self didReceiveIQ:iq];
    }
}

- (void)continueReceiveMessage:(XMPPMessage *)message
{
    [multicastDelegate xmppStream:self didReceiveMessage:message];
}

- (void)continueReceivePresence:(XMPPPresence *)presence
{
    [multicastDelegate xmppStream:self didReceivePresence:presence];
}

/**
 * This method allows you to inject an element into the stream as if it was received on the socket.
 * This is an advanced technique, but makes for some interesting possibilities.
 **/
- (void)injectElement:(NSXMLElement *)element
{
    if (element == nil) return;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (self->state != STATE_XMPP_CONNECTED)
        {
            return_from_block;
        }
        
        if ([element isKindOfClass:[XMPPIQ class]])
        {
            [self receiveIQ:(XMPPIQ *)element];
        }
        else if ([element isKindOfClass:[XMPPMessage class]])
        {
            [self receiveMessage:(XMPPMessage *)element];
        }
        else if ([element isKindOfClass:[XMPPPresence class]])
        {
            [self receivePresence:(XMPPPresence *)element];
        }
        else
        {
            NSString *elementName = [element name];
            
            if ([elementName isEqualToString:@"iq"])
            {
                [self receiveIQ:[XMPPIQ iqFromElement:element]];
            }
            else if ([elementName isEqualToString:@"message"])
            {
                [self receiveMessage:[XMPPMessage messageFromElement:element]];
            }
            else if ([elementName isEqualToString:@"presence"])
            {
                [self receivePresence:[XMPPPresence presenceFromElement:element]];
            }
            else if ([self->customElementNames countForObject:elementName])
            {
                [self->multicastDelegate xmppStream:self didReceiveCustomElement:element];
            }
            else
            {
                [self->multicastDelegate xmppStream:self didReceiveError:element];
            }
        }
    }};
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (void)registerCustomElementNames:(NSSet *)names
{
    dispatch_block_t block = ^{
        
        if (self->customElementNames == nil)
            self->customElementNames = [[NSCountedSet alloc] init];
        
        for (NSString *name in names)
        {
            [self->customElementNames addObject:name];
        }
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
}

- (void)unregisterCustomElementNames:(NSSet *)names
{
    dispatch_block_t block = ^{
        
        for (NSString *name in names)
        {
            [self->customElementNames removeObject:name];
        }
    };
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
}

/**
 * This method is called anytime we receive the server's stream features.
 * This method looks at the stream features, and handles any requirements so communication can continue.
 **/
- (void)handleStreamFeatures
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    XMPPLogTrace();
    
    // Extract the stream features
    NSXMLElement *features = [rootElement elementForName:@"stream:features"];
    
    // Check to see if TLS is required
    // Don't forget about that NSXMLElement bug you reported to apple (xmlns is required or element won't be found)
    NSXMLElement *f_starttls = [features elementForName:@"starttls" xmlns:@"urn:ietf:params:xml:ns:xmpp-tls"];
    
    if (f_starttls)
    {
        if ([f_starttls elementForName:@"required"] || [self startTLSPolicy] >= XMPPStreamStartTLSPolicyPreferred)
        {
            // TLS is required for this connection
            
            // Update state
            state = STATE_XMPP_STARTTLS_1;
            
            // Send the startTLS XML request
            [self sendStartTLSRequest];
            
            // We do not mark the stream as secure yet.
            // We're waiting to receive the <proceed/> response from the
            // server before we actually start the TLS handshake.
            
            // We're already listening for the response...
            return;
        }
    }
    else if (![self isSecure] && [self startTLSPolicy] == XMPPStreamStartTLSPolicyRequired)
    {
        // We must abort the connection as the server doesn't support our requirements.
        
        NSString *errMsg = @"The server does not support startTLS. And the startTLSPolicy is Required.";
        NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
        
        otherError = [NSError errorWithDomain:XMPPStreamErrorDomain code:XMPPStreamUnsupportedAction userInfo:info];
        
        // Close the TCP connection.
        [self disconnect];
        
        // The socketDidDisconnect:withError: method will handle everything else
        return;
    }
    
    // Check to see if resource binding is required
    // Don't forget about that NSXMLElement bug you reported to apple (xmlns is required or element won't be found)
    NSXMLElement *f_bind = [features elementForName:@"bind" xmlns:@"urn:ietf:params:xml:ns:xmpp-bind"];
    
    if (f_bind)
    {
        // Start the binding process
        [self startBinding];
        
        // We're already listening for the response...
        return;
    }
    
    // It looks like all has gone well, and the connection should be ready to use now
    state = STATE_XMPP_CONNECTED;
    
    if (![self isAuthenticated])
    {
        // Notify delegates
        [multicastDelegate xmppStreamDidConnect:self];
    }
}

- (void)handleStartTLSResponse:(NSXMLElement *)response
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    XMPPLogTrace();
    
    // We're expecting a proceed response
    // If we get anything else we can safely assume it's the equivalent of a failure response
    if ( ![[response name] isEqualToString:@"proceed"])
    {
        // We can close our TCP connection now
        [self disconnect];
        
        // The socketDidDisconnect:withError: method will handle everything else
        return;
    }
    
    // Start TLS negotiation
    [transport startTLS];
}

/**
 * After the registerUser:withPassword: method is invoked, a registration message is sent to the server.
 * We're waiting for the result from this registration request.
 **/
- (void)handleRegistration:(NSXMLElement *)response
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    XMPPLogTrace();
    
    if ([[response attributeStringValueForName:@"type"] isEqualToString:@"error"])
    {
        // Revert back to connected state (from authenticating state)
        state = STATE_XMPP_CONNECTED;
        
        [multicastDelegate xmppStream:self didNotRegister:response];
    }
    else
    {
        // Revert back to connected state (from authenticating state)
        state = STATE_XMPP_CONNECTED;
        
        [multicastDelegate xmppStreamDidRegister:self];
    }
}

/**
 * After the authenticate:error: or authenticateWithPassword:error: methods are invoked, some kind of
 * authentication message is sent to the server.
 * This method forwards the response to the authentication module, and handles the resulting authentication state.
 **/
- (void)handleAuth:(NSXMLElement *)authResponse
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    XMPPLogTrace();
    
    XMPPHandleAuthResponse result = [auth handleAuth:authResponse];
    
    if (result == XMPP_AUTH_SUCCESS)
    {
        // We are successfully authenticated (via sasl:digest-md5)
        [self setIsAuthenticated:YES];
        
        BOOL shouldRenegotiate = NO;
        if ([auth respondsToSelector:@selector(shouldResendOpeningNegotiationAfterSuccessfulAuthentication)])
        {
            shouldRenegotiate = [auth shouldResendOpeningNegotiationAfterSuccessfulAuthentication];
        }
        
        if (shouldRenegotiate)
        {
            [transport restartStream];
        }
        else
        {
            [self startStandardBinding];
            // Revert back to connected state (from authenticating state)
            state = STATE_XMPP_CONNECTED;
            
            [multicastDelegate xmppStreamDidAuthenticate:self];
        }
        
        // Done with auth
        auth = nil;
        
    }
    else if (result == XMPP_AUTH_FAIL)
    {
        // Revert back to connected state (from authenticating state)
        state = STATE_XMPP_CONNECTED;
        
        // Notify delegate
        [multicastDelegate xmppStream:self didNotAuthenticate:authResponse];
        
        // Done with auth
        auth = nil;
        
    }
    else if (result == XMPP_AUTH_CONTINUE)
    {
        // Authentication continues.
        // State doesn't change.
    }
    else
    {
        XMPPLogError(@"Authentication class (%@) returned invalid response code (%i)",
                     NSStringFromClass([auth class]), (int)result);
        
        NSAssert(NO, @"Authentication class (%@) returned invalid response code (%i)",
                 NSStringFromClass([auth class]), (int)result);
    }
}

- (void)startBinding
{
    XMPPLogTrace();
    
    state = STATE_XMPP_BINDING;
    
    SEL selector = @selector(xmppStreamWillBind:);
    
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        [self startStandardBinding];
    }
    else
    {
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        dispatch_queue_t concurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        dispatch_async(concurrentQueue, ^{ @autoreleasepool {
            
            __block id <XMPPCustomBinding> delegateCustomBinding = nil;
            
            id delegate;
            dispatch_queue_t dq;
            
            while ([delegateEnumerator getNextDelegate:&delegate delegateQueue:&dq forSelector:selector])
            {
                dispatch_sync(dq, ^{ @autoreleasepool {
                    
                    delegateCustomBinding = [delegate xmppStreamWillBind:self];
                }});
                
                if (delegateCustomBinding) {
                    break;
                }
            }
            
            dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                
                if (delegateCustomBinding)
                    [self startCustomBinding:delegateCustomBinding];
                else
                    [self startStandardBinding];
            }});
        }});
    }
}

- (void)startCustomBinding:(id <XMPPCustomBinding>)delegateCustomBinding
{
    XMPPLogTrace();
    
    customBinding = delegateCustomBinding;
    
    NSError *bindError = nil;
    XMPPBindResult result = [customBinding start:&bindError];
    
    if (result == XMPP_BIND_CONTINUE)
    {
        // Expected result
        // Wait for reply from server, and forward to customBinding module.
    }
    else
    {
        if (result == XMPP_BIND_SUCCESS)
        {
            // It appears binding isn't needed (perhaps handled via auth)
            
            BOOL skipStartSessionOverride = NO;
            if ([customBinding respondsToSelector:@selector(shouldSkipStartSessionAfterSuccessfulBinding)]) {
                skipStartSessionOverride = [customBinding shouldSkipStartSessionAfterSuccessfulBinding];
            }
            
            [self continuePostBinding:skipStartSessionOverride];
        }
        else if (result == XMPP_BIND_FAIL_FALLBACK)
        {
            // Custom binding isn't available for whatever reason,
            // but the module has requested we fallback to standard binding.
            
            [self startStandardBinding];
        }
        else if (result == XMPP_BIND_FAIL_ABORT)
        {
            // Custom binding failed,
            // and the module requested we abort.
            
            otherError = bindError;
            [self disconnect];
        }
        
        customBinding = nil;
    }
}

- (void)handleCustomBinding:(NSXMLElement *)response
{
    XMPPLogTrace();
    
    NSError *bindError = nil;
    XMPPBindResult result = [customBinding handleBind:response withError:&bindError];
    
    if (result == XMPP_BIND_CONTINUE)
    {
        // Binding still in progress
    }
    else
    {
        if (result == XMPP_BIND_SUCCESS)
        {
            // Binding complete. Continue.
            
            BOOL skipStartSessionOverride = NO;
            if ([customBinding respondsToSelector:@selector(shouldSkipStartSessionAfterSuccessfulBinding)]) {
                skipStartSessionOverride = [customBinding shouldSkipStartSessionAfterSuccessfulBinding];
            }
            
            [self continuePostBinding:skipStartSessionOverride];
        }
        else if (result == XMPP_BIND_FAIL_FALLBACK)
        {
            // Custom binding failed for whatever reason,
            // but the module has requested we fallback to standard binding.
            
            [self startStandardBinding];
        }
        else if (result == XMPP_BIND_FAIL_ABORT)
        {
            // Custom binding failed,
            // and the module requested we abort.
            
            otherError = bindError;
            [self disconnect];
        }
        
        customBinding = nil;
    }
}

- (void)startStandardBinding
{
    XMPPLogTrace();
    
    NSString *requestedResource = [myJID_setByClient resource];
    
    if ([requestedResource length] > 0)
    {
        // Ask the server to bind the user specified resource
        
        NSXMLElement *resource = [NSXMLElement elementWithName:@"resource"];
        [resource setStringValue:requestedResource];
        
        NSXMLElement *bind = [NSXMLElement elementWithName:@"bind" xmlns:@"urn:ietf:params:xml:ns:xmpp-bind"];
        [bind addChild:resource];
        
        XMPPIQ *iq = [XMPPIQ iqWithType:@"set" elementID:[self generateUUID]];
        [iq addChild:bind];
        
        NSString *outgoingStr = [iq compactXMLString];
        XMPPLogSend(@"SEND: %@", outgoingStr);
        [transport sendStanzaWithString:outgoingStr];
        
        [idTracker addElement:iq
                       target:nil
                     selector:NULL
                      timeout:XMPPIDTrackerTimeoutNone];
    }
    else
    {
        // The user didn't specify a resource, so we ask the server to bind one for us
        
        NSXMLElement *bind = [NSXMLElement elementWithName:@"bind" xmlns:@"urn:ietf:params:xml:ns:xmpp-bind"];
        
        XMPPIQ *iq = [XMPPIQ iqWithType:@"set" elementID:[self generateUUID]];
        [iq addChild:bind];
        
        NSString *outgoingStr = [iq compactXMLString];
        XMPPLogSend(@"SEND: %@", outgoingStr);
        [transport sendStanzaWithString:outgoingStr];
        
        [idTracker addElement:iq
                       target:nil
                     selector:NULL
                      timeout:XMPPIDTrackerTimeoutNone];
    }
}

- (void)handleStandardBinding:(NSXMLElement *)response
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    XMPPLogTrace();
    
    NSXMLElement *r_bind = [response elementForName:@"bind" xmlns:@"urn:ietf:params:xml:ns:xmpp-bind"];
    NSXMLElement *r_jid = [r_bind elementForName:@"jid"];
    
    if (r_jid)
    {
        // We're properly binded to a resource now
        // Extract and save our resource (it may not be what we originally requested)
        NSString *fullJIDStr = [r_jid stringValue];
        
        [self setMyJID_setByServer:[XMPPJID jidWithString:fullJIDStr]];
        
        // On to the next step
        BOOL skipStartSessionOverride = NO;
        [self continuePostBinding:skipStartSessionOverride];
    }
    else
    {
        // It appears the server didn't allow our resource choice
        // First check if we want to try an alternative resource
        
        NSXMLElement *r_error = [response elementForName:@"error"];
        NSXMLElement *r_conflict = [r_error elementForName:@"conflict" xmlns:@"urn:ietf:params:xml:ns:xmpp-stanzas"];
        
        if (r_conflict)
        {
            SEL selector = @selector(xmppStream:alternativeResourceForConflictingResource:);
            
            if (![multicastDelegate hasDelegateThatRespondsToSelector:selector])
            {
                // None of the delegates implement the method.
                // Use a shortcut.
                
                [self continueHandleStandardBinding:nil];
            }
            else
            {
                // Query all interested delegates.
                // This must be done serially to maintain thread safety.
                
                GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
                
                dispatch_queue_t concurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
                dispatch_async(concurrentQueue, ^{ @autoreleasepool {
                    
                    // Query delegates for alternative resource
                    
                    NSString *currentResource = [[self myJID] resource];
                    __block NSString *alternativeResource = nil;
                    
                    id delegate;
                    dispatch_queue_t dq;
                    
                    while ([delegateEnumerator getNextDelegate:&delegate delegateQueue:&dq forSelector:selector])
                    {
                        dispatch_sync(dq, ^{ @autoreleasepool {
                            
                            NSString *delegateAlternativeResource =
                            [delegate xmppStream:self alternativeResourceForConflictingResource:currentResource];
                            
                            if (delegateAlternativeResource)
                            {
                                alternativeResource = delegateAlternativeResource;
                            }
                        }});
                        
                        if (alternativeResource) {
                            break;
                        }
                    }
                    
                    dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                        
                        [self continueHandleStandardBinding:alternativeResource];
                        
                    }});
                    
                }});
            }
        }
        else
        {
            // Appears to be a conflicting resource, but server didn't specify conflict
            [self continueHandleStandardBinding:nil];
        }
    }
}

- (void)continueHandleStandardBinding:(NSString *)alternativeResource
{
    XMPPLogTrace();
    
    if ([alternativeResource length] > 0)
    {
        // Update myJID
        
        [self setMyJID_setByClient:[myJID_setByClient jidWithNewResource:alternativeResource]];
        
        NSXMLElement *resource = [NSXMLElement elementWithName:@"resource"];
        [resource setStringValue:alternativeResource];
        
        NSXMLElement *bind = [NSXMLElement elementWithName:@"bind" xmlns:@"urn:ietf:params:xml:ns:xmpp-bind"];
        [bind addChild:resource];
        
        XMPPIQ *iq = [XMPPIQ iqWithType:@"set"];
        [iq addChild:bind];
        
        NSString *outgoingStr = [iq compactXMLString];
        XMPPLogSend(@"SEND: %@", outgoingStr);
        [transport sendStanzaWithString:outgoingStr];
        
        [idTracker addElement:iq
                       target:nil
                     selector:NULL
                      timeout:XMPPIDTrackerTimeoutNone];
        
        // The state remains in STATE_XMPP_BINDING
    }
    else
    {
        // We'll simply let the server choose then
        
        NSXMLElement *bind = [NSXMLElement elementWithName:@"bind" xmlns:@"urn:ietf:params:xml:ns:xmpp-bind"];
        
        XMPPIQ *iq = [XMPPIQ iqWithType:@"set"];
        [iq addChild:bind];
        
        NSString *outgoingStr = [iq compactXMLString];
        XMPPLogSend(@"SEND: %@", outgoingStr);
        [transport sendStanzaWithString:outgoingStr];
        
        [idTracker addElement:iq
                       target:nil
                     selector:NULL
                      timeout:XMPPIDTrackerTimeoutNone];
        
        // The state remains in STATE_XMPP_BINDING
    }
}

- (void)continuePostBinding:(BOOL)skipStartSessionOverride
{
    XMPPLogTrace();
    
    // And we may now have to do one last thing before we're ready - start an IM session
    NSXMLElement *features = [rootElement elementForName:@"stream:features"];
    
    // Check to see if a session is required
    // Don't forget about that NSXMLElement bug you reported to apple (xmlns is required or element won't be found)
    NSXMLElement *f_session = [features elementForName:@"session" xmlns:@"urn:ietf:params:xml:ns:xmpp-session"];
    
    if (f_session && !skipStartSession && !skipStartSessionOverride)
    {
        NSXMLElement *session = [NSXMLElement elementWithName:@"session"];
        [session setXmlns:@"urn:ietf:params:xml:ns:xmpp-session"];
        
        XMPPIQ *iq = [XMPPIQ iqWithType:@"set" elementID:[self generateUUID]];
        [iq addChild:session];
        
        NSString *outgoingStr = [iq compactXMLString];
        XMPPLogSend(@"SEND: %@", outgoingStr);
        [transport sendStanzaWithString:outgoingStr];
        
        [idTracker addElement:iq
                       target:nil
                     selector:NULL
                      timeout:XMPPIDTrackerTimeoutNone];
        
        // Update state
        state = STATE_XMPP_START_SESSION;
    }
    else
    {
        // Revert back to connected state (from binding state)
        state = STATE_XMPP_CONNECTED;
        
        [multicastDelegate xmppStreamDidAuthenticate:self];
    }
}

- (void)handleStartSessionResponse:(NSXMLElement *)response
{
    NSAssert(dispatch_get_specific(xmppQueueTag), @"Invoked on incorrect queue");
    
    XMPPLogTrace();
    
    if ([[response attributeStringValueForName:@"type"] isEqualToString:@"result"])
    {
        // Revert back to connected state (from start session state)
        state = STATE_XMPP_CONNECTED;
        
        [multicastDelegate xmppStreamDidAuthenticate:self];
    }
    else
    {
        // Revert back to connected state (from start session state)
        state = STATE_XMPP_CONNECTED;
        
        [multicastDelegate xmppStream:self didNotAuthenticate:response];
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Transport Delegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)transportConnectDidTimeout:(id<XMPPTransportProtocol>)transport {
    [multicastDelegate xmppStreamConnectDidTimeout:self];
}

- (void)transport:(id<XMPPTransportProtocol>)transport
willSecureWithSettings:(NSMutableDictionary *)settings {
    // Update state (part 2 - prompting delegates)
    state = STATE_XMPP_STARTTLS_2;
    
    SEL selector = @selector(xmppStream:willSecureWithSettings:);
    
    if (![multicastDelegate hasDelegateThatRespondsToSelector:selector]) {
        // None of the delegates implement the method.
        // Use a shortcut.
        
        [transport continueStartTLS:settings];
        if (state == STATE_XMPP_STARTTLS_2) {
            [self setIsSecure:YES];
        }
    } else {
        // Query all interested delegates.
        // This must be done serially to maintain thread safety.
        
        GCDMulticastDelegateEnumerator *delegateEnumerator = [multicastDelegate delegateEnumerator];
        
        dispatch_queue_t concurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        dispatch_async(concurrentQueue, ^{ @autoreleasepool {
            
            // Prompt the delegate(s) to populate the security settings
            
            id delegate;
            dispatch_queue_t delegateQueue;
            
            while ([delegateEnumerator getNextDelegate:&delegate delegateQueue:&delegateQueue forSelector:selector])
            {
                dispatch_sync(delegateQueue, ^{ @autoreleasepool {
                    
                    [delegate xmppStream:self willSecureWithSettings:settings];
                    
                }});
            }
            
            dispatch_async(self->xmppQueue, ^{ @autoreleasepool {
                
                [transport continueStartTLS:settings];
                if (self->state == STATE_XMPP_STARTTLS_2) {
                    [self setIsSecure:YES];
                }
                
            }});
            
        }});
    }
}

- (void)transport:(id<XMPPTransportProtocol>)transport
  didReceiveTrust:(SecTrustRef)trust
completionHandler:(void (^)(BOOL))completionHandler {
    XMPPLogTrace();
    
    SEL selector = @selector(xmppStream:didReceiveTrust:completionHandler:);
    
    if ([multicastDelegate hasDelegateThatRespondsToSelector:selector])
    {
        [multicastDelegate xmppStream:self didReceiveTrust:trust completionHandler:completionHandler];
    }
    else
    {
        XMPPLogWarn(@"%@: Stream secured with (GCDAsyncSocketManuallyEvaluateTrust == YES),"
                    @" but there are no delegates that implement xmppStream:didReceiveTrust:completionHandler:."
                    @" This is likely a mistake.", THIS_FILE);
        
        // The delegate method should likely have code similar to this,
        // but will presumably perform some extra security code stuff.
        // For example, allowing a specific self-signed certificate that is known to the app.
        
        dispatch_queue_t bgQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        dispatch_async(bgQueue, ^{
            
            SecTrustResultType result = kSecTrustResultDeny;
            OSStatus status = SecTrustEvaluate(trust, &result);
            
            if (status == noErr && (result == kSecTrustResultProceed || result == kSecTrustResultUnspecified)) {
                completionHandler(YES);
            }
            else {
                completionHandler(NO);
            }
        });
    }
}

- (void)transportDidSecure:(id<XMPPTransportProtocol>)transport {
    [multicastDelegate xmppStreamDidSecure:self];
}

- (void)transportDidSendClosingStreamStanza:(id<XMPPTransportProtocol>)transport {
    [multicastDelegate xmppStreamDidSendClosingStreamStanza:self];
}

- (void)transportDidConnect:(id<XMPPTransportProtocol>)transport {
    // At this point we've sent our XML stream header, and we've received the response XML stream header.
    // We save the root element of our stream for future reference.
    
    rootElement = [self newRootElement];
    
    // Check for RFC compliance
    if ([transport serverXmppStreamVersionNumber] >= 1.0)
    {
        // Update state - we're now onto stream negotiations
        state = STATE_XMPP_NEGOTIATING;
        
        // Note: We're waiting for the <stream:features> now
    }
    else
    {
        // The server isn't RFC comliant, and won't be sending any stream features.
        
        // We would still like to know what authentication features it supports though,
        // so we'll use the jabber:iq:auth namespace, which was used prior to the RFC spec.
        
        // Update state - we're onto psuedo negotiation
        state = STATE_XMPP_NEGOTIATING;
        
        NSXMLElement *query = [NSXMLElement elementWithName:@"query" xmlns:@"jabber:iq:auth"];
        
        XMPPIQ *iq = [XMPPIQ iqWithType:@"get" elementID:[self generateUUID]];
        [iq addChild:query];
        
        NSString *outgoingStr = [iq compactXMLString];
        XMPPLogSend(@"SEND: %@", outgoingStr);
        
        [transport sendStanzaWithString:outgoingStr];
        
        // Now wait for the response IQ
    }
}

- (void)transport:(id<XMPPTransportProtocol>)sender didReceiveStanza:(NSXMLElement *)element {
    
    XMPPLogTrace();
    
    NSString *elementName = [element name];
    
    if ([elementName isEqualToString:@"stream:error"] || [elementName isEqualToString:@"error"])
    {
        [multicastDelegate xmppStream:self didReceiveError:element];
        
        return;
    }
    
    if (state == STATE_XMPP_NEGOTIATING)
    {
        // We've just read in the stream features
        // We consider this part of the root element, so we'll add it (replacing any previously sent features)
        [rootElement setChildren:@[element]];
        
        // Call a method to handle any requirements set forth in the features
        [self handleStreamFeatures];
    }
    else if (state == STATE_XMPP_STARTTLS_1)
    {
        // The response from our starttls message
        [self handleStartTLSResponse:element];
    }
    else if (state == STATE_XMPP_REGISTERING)
    {
        // The iq response from our registration request
        [self handleRegistration:element];
    }
    else if (state == STATE_XMPP_AUTH)
    {
        // Some response to the authentication process
        [self handleAuth:element];
    }
    else if (state == STATE_XMPP_BINDING)
    {
        if (customBinding)
        {
            [self handleCustomBinding:element];
        }
        else
        {
            BOOL invalid = NO;
            if (validatesResponses)
            {
                XMPPIQ *iq = [XMPPIQ iqFromElement:element];
                if (![idTracker invokeForElement:iq withObject:nil])
                {
                    invalid = YES;
                }
            }
            if (!invalid)
            {
                // The response from our binding request
                [self handleStandardBinding:element];
            }
        }
    }
    else if (state == STATE_XMPP_START_SESSION)
    {
        if (![elementName isEqualToString:@"iq"]) return;
        BOOL invalid = NO;
        if (validatesResponses)
        {
            XMPPIQ *iq = [XMPPIQ iqFromElement:element];
            if (![idTracker invokeForElement:iq withObject:nil])
            {
                invalid = YES;
            }
        }
        if (!invalid)
        {
            // The response from our start session request
            [self handleStartSessionResponse:element];
        }
    }
    else
    {
        if ([elementName isEqualToString:@"iq"])
        {
            [self receiveIQ:[XMPPIQ iqFromElement:element]];
        }
        else if ([elementName isEqualToString:@"message"])
        {
            [self receiveMessage:[XMPPMessage messageFromElement:element]];
        }
        else if ([elementName isEqualToString:@"presence"])
        {
            [self receivePresence:[XMPPPresence presenceFromElement:element]];
        }
        else if ([customElementNames countForObject:elementName])
        {
            [multicastDelegate xmppStream:self didReceiveCustomElement:element];
        }
        else
        {
            [multicastDelegate xmppStream:self didReceiveError:element];
        }
    }
}

- (void)transportDidDisconnect:(id<XMPPTransportProtocol>)transport withError:(NSError *)err {
    // Clear any saved authentication information
    auth = nil;
    authenticationDate = nil;
    // Clear stored elements
    myJID_setByServer = nil;
    myPresence = nil;
    rootElement = nil;
    
    // Stop tracking IDs
    [idTracker removeAllIDs];
    
    // Clear flags
    flags = 0;
    
    // Notify delegate
    self->state = STATE_XMPP_DISCONNECTED;
    
    if (err)
    {
        [multicastDelegate xmppStreamDidDisconnect:self withError:err];
    } else {
        NSError *error = otherError;
        
        [multicastDelegate xmppStreamDidDisconnect:self withError:error];
        
        otherError = nil;
    }
    
}


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Stanza Validation
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)isValidResponseElementFrom:(XMPPJID *)from forRequestElementTo:(XMPPJID *)to
{
    BOOL valid = YES;
    
    if(to)
    {
        if(![to isEqualToJID:from])
        {
            valid = NO;
        }
    }
    /**
     * Replies for Stanza's that had no TO will be accepted if the FROM is:
     *
     * No from.
     * from = the bare account JID.
     * from = the full account JID (legal in 3920, but not 6120).
     * from = the server's domain.
     **/
    else if(!to && from)
    {
        if(![from isEqualToJID:self.myJID options:XMPPJIDCompareBare]
           && ![from isEqualToJID:self.myJID options:XMPPJIDCompareFull]
           && ![from isEqualToJID:[self.myJID domainJID] options:XMPPJIDCompareFull])
        {
            valid = NO;
        }
    }
    
    return valid;
}

- (BOOL)isValidResponseElement:(XMPPElement *)response forRequestElement:(XMPPElement *)request
{
    if(!response || !request) return NO;
    
    return [self isValidResponseElementFrom:[response from] forRequestElementTo:[request to]];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Module Plug-In System
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)registerModule:(XMPPModule *)module
{
    if (module == nil) return;
    
    // Asynchronous operation
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // Register module
        
        [self->registeredModules addObject:module];
        
        // Add auto delegates (if there are any)
        
        NSString *className = NSStringFromClass([module class]);
        GCDMulticastDelegate *autoDelegates = self->autoDelegateDict[className];
        
        GCDMulticastDelegateEnumerator *autoDelegatesEnumerator = [autoDelegates delegateEnumerator];
        id delegate;
        dispatch_queue_t delegateQueue;
        
        while ([autoDelegatesEnumerator getNextDelegate:&delegate delegateQueue:&delegateQueue])
        {
            [module addDelegate:delegate delegateQueue:delegateQueue];
        }
        
        // Notify our own delegate(s)
        
        [self->multicastDelegate xmppStream:self didRegisterModule:module];
        
    }};
    
    // Asynchronous operation
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (void)unregisterModule:(XMPPModule *)module
{
    if (module == nil) return;
    
    // Synchronous operation
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        // Notify our own delegate(s)
        
        [self->multicastDelegate xmppStream:self willUnregisterModule:module];
        
        // Remove auto delegates (if there are any)
        
        NSString *className = NSStringFromClass([module class]);
        GCDMulticastDelegate *autoDelegates = self->autoDelegateDict[className];
        
        GCDMulticastDelegateEnumerator *autoDelegatesEnumerator = [autoDelegates delegateEnumerator];
        id delegate;
        dispatch_queue_t delegateQueue;
        
        while ([autoDelegatesEnumerator getNextDelegate:&delegate delegateQueue:&delegateQueue])
        {
            // The module itself has dispatch_sync'd in order to invoke its deactivate method,
            // which has in turn invoked this method. If we call back into the module,
            // and have it dispatch_sync again, we're going to get a deadlock.
            // So we must remove the delegate(s) asynchronously.
            
            [module removeDelegate:delegate delegateQueue:delegateQueue synchronously:NO];
        }
        
        // Unregister modules
        
        [self->registeredModules removeObject:module];
        
    }};
    
    // Synchronous operation
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
}

- (void)autoAddDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue toModulesOfClass:(Class)aClass
{
    if (delegate == nil) return;
    if (aClass == nil) return;
    
    // Asynchronous operation
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        NSString *className = NSStringFromClass(aClass);
        
        // Add the delegate to all currently registered modules of the given class.
        
        for (XMPPModule *module in self->registeredModules)
        {
            if ([module isKindOfClass:aClass])
            {
                [module addDelegate:delegate delegateQueue:delegateQueue];
            }
        }
        
        // Add the delegate to list of auto delegates for the given class.
        // It will be added as a delegate to future registered modules of the given class.
        
        id delegates = self->autoDelegateDict[className];
        if (delegates == nil)
        {
            delegates = [[GCDMulticastDelegate alloc] init];
            
            self->autoDelegateDict[className] = delegates;
        }
        
        [delegates addDelegate:delegate delegateQueue:delegateQueue];
        
    }};
    
    // Asynchronous operation
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_async(xmppQueue, block);
}

- (void)removeAutoDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue fromModulesOfClass:(Class)aClass
{
    if (delegate == nil) return;
    // delegateQueue may be NULL
    // aClass may be NULL
    
    // Synchronous operation
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        if (aClass == NULL)
        {
            // Remove the delegate from all currently registered modules of ANY class.
            
            for (XMPPModule *module in self->registeredModules)
            {
                [module removeDelegate:delegate delegateQueue:delegateQueue];
            }
            
            // Remove the delegate from list of auto delegates for all classes,
            // so that it will not be auto added as a delegate to future registered modules.
            
            for (GCDMulticastDelegate *delegates in [self->autoDelegateDict objectEnumerator])
            {
                [delegates removeDelegate:delegate delegateQueue:delegateQueue];
            }
        }
        else
        {
            NSString *className = NSStringFromClass(aClass);
            
            // Remove the delegate from all currently registered modules of the given class.
            
            for (XMPPModule *module in self->registeredModules)
            {
                if ([module isKindOfClass:aClass])
                {
                    [module removeDelegate:delegate delegateQueue:delegateQueue];
                }
            }
            
            // Remove the delegate from list of auto delegates for the given class,
            // so that it will not be added as a delegate to future registered modules of the given class.
            
            GCDMulticastDelegate *delegates = self->autoDelegateDict[className];
            [delegates removeDelegate:delegate delegateQueue:delegateQueue];
            
            if ([delegates count] == 0)
            {
                [self->autoDelegateDict removeObjectForKey:className];
            }
        }
        
    }};
    
    // Synchronous operation
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
}

- (void)enumerateModulesWithBlock:(void (^)(XMPPModule *module, NSUInteger idx, BOOL *stop))enumBlock
{
    if (enumBlock == NULL) return;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        NSUInteger i = 0;
        BOOL stop = NO;
        
        for (XMPPModule *module in self->registeredModules)
        {
            enumBlock(module, i, &stop);
            
            if (stop)
                break;
            else
                i++;
        }
    }};
    
    // Synchronous operation
    
    if (dispatch_get_specific(xmppQueueTag))
        block();
    else
        dispatch_sync(xmppQueue, block);
}

- (void)enumerateModulesOfClass:(Class)aClass withBlock:(void (^)(XMPPModule *module, NSUInteger idx, BOOL *stop))block
{
    [self enumerateModulesWithBlock:^(XMPPModule *module, NSUInteger idx, BOOL *stop)
     {
         if([module isKindOfClass:aClass])
         {
             block(module,idx,stop);
         }
     }];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

+ (NSString *)generateUUID
{
    NSString *result = nil;
    
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    if (uuid)
    {
        result = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, uuid);
        CFRelease(uuid);
    }
    
    return result;
}

- (NSString *)generateUUID
{
    return [[self class] generateUUID];
}

@end
