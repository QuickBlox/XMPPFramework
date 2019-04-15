//
//  BoshTransport.m
//  iPhoneXMPP
//
//  Created by Satyam Shekhar on 3/17/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "BoshTransport.h"
#import "DDXML.h"
#import "NSXMLElement+XMPP.h"
#import "XMPPLogging.h"

// Log levels: off, error, warn, info, verbose
#if DEBUG
static const int xmppLogLevel = XMPP_LOG_LEVEL_WARN  | XMPP_LOG_FLAG_INFO; // | XMPP_LOG_FLAG_TRACE;
#else
static const int xmppLogLevel = XMPP_LOG_LEVEL_INFO | XMPP_LOG_FLAG_SEND_RECV;
#endif

#pragma -
#pragma RequestResponsePair Class
@implementation RequestResponsePair

@synthesize request=request_;
@synthesize response=response_;

- (id) initWithRequest:(NSXMLElement *)request response:(NSXMLElement *)response
{
    if( (self = [super init]) )
    {
        request_ = request;
        response_ = response;
    }
    return self;
}

@end

#pragma -
#pragma BoshWindowManager Class

@implementation BoshWindowManager

@synthesize windowSize;
@synthesize maxRidReceived;

- (id)initWithRid:(NSUInteger)rid
{
    if((self = [super init]))
    {
        windowSize = 0;
        maxRidSent = rid;
        maxRidReceived = rid;
        receivedRids = [[NSMutableSet alloc] initWithCapacity:2];
    }
    return self;
}

- (void)sentRequestForRid:(NSUInteger)rid {
    NSAssert(![self isWindowFull], @"Sending request when should not be: Exceeding request count" );
    NSAssert2(rid == maxRidSent + 1, @"Sending request with rid = %@ greater than expected rid = %@", @(rid), @(maxRidSent + 1));
    ++maxRidSent;
}

- (void)recievedResponseForRid:(NSUInteger)rid
{
    NSNumber *ridNumber = @(rid);
    NSAssert2(rid > maxRidReceived, @"Recieving response for rid = %@ where maxRidReceived = %@", ridNumber, @(maxRidReceived));
    NSAssert3(rid <= maxRidReceived + windowSize, @"Recieved response for a request outside the rid window. responseRid = %@, maxRidReceived = %@, windowSize = %@", ridNumber, @(maxRidReceived), @(windowSize));
    [receivedRids addObject:ridNumber];
    
    while ( [receivedRids containsObject:@(maxRidReceived + 1)] )
    {
        ++maxRidReceived;
    }
}

- (BOOL)isWindowFull
{
    return (maxRidSent - maxRidReceived) == windowSize;
}

- (BOOL)isWindowEmpty
{
    return (maxRidSent - maxRidReceived) < 1;
}

@end

static const int RETRY_COUNT_LIMIT = 4;
static const NSTimeInterval DELAY_EXPONENTIATING_FACTOR = 2.0;
static const NSTimeInterval INITIAL_RETRY_DELAY = 1.0;

static const NSString *CONTENT_TYPE = @"text/xml; charset=utf-8";
static const NSString *BODY_NS = @"http://jabber.org/protocol/httpbind";
static const NSString *XMPP_NS = @"urn:xmpp:xbosh";

@interface BoshTransport() {
    dispatch_queue_t xmppQueue;
}
@property(nonatomic, strong) NSError *disconnectError;
- (void)setInactivityFromString:(NSString *)givenInactivity;
- (void)setSecureFromString:(NSString *)isSecure;
- (void)setRequestsFromString:(NSString *)maxRequests;
- (void)setSidFromString:(NSString *)sid;
- (BOOL)canConnect;
- (void)handleAttributesInResponse:(NSXMLElement *)parsedResponse;
- (void)createSessionResponseHandler:(NSXMLElement *)parsedResponse;
- (void)handleDisconnection;
- (NSUInteger)generateRid;
- (SEL)setterForProperty:(NSString *)property;
- (NSNumber *)numberFromString:(NSString *)stringNumber;
- (void)sendHTTPRequestWithBody:(NSXMLElement *)body rid:(NSUInteger)rid;
- (void)broadcastStanzas:(NSXMLNode *)node;
- (void)trySendingStanzas;
- (void)makeBodyAndSendHTTPRequestWithPayload:(NSArray *)bodyPayload 
                                   attributes:(NSMutableDictionary *)attributes
                                   namespaces:(NSMutableDictionary *)namespaces;
- (NSXMLElement *)newBodyElementWithPayload:(NSArray *)payload 
                                 attributes:(NSMutableDictionary *)attributes
                                 namespaces:(NSMutableDictionary *)namespaces;
- (NSArray *)newXMLNodeArrayFromDictionary:(NSDictionary *)dict 
                                    ofType:(XMLNodeType)type;
- (NSXMLElement *)parseXMLData:(NSData *)xml;
- (NSXMLElement *)parseXMLString:(NSString *)xml;
- (BOOL) createSession:(NSError **)error;
@end

#pragma -
#pragma BoshTranshport Class
@implementation BoshTransport

@synthesize wait = wait_;
@synthesize hold = hold_;
@synthesize lang = lang_;
@synthesize sid = sid_;
@synthesize url = url_;
@synthesize inactivity;
@synthesize secure;
@synthesize authid;
@synthesize requests;
@synthesize disconnectError = disconnectError_;

#pragma mark -
#pragma mark Private Accessor Method Implementation

- (void)setSidFromString:(NSString *)sid {
    self.sid = sid;
}

- (void)setInactivityFromString:(NSString *)inactivityString
{
    XMPPLogSend(@"Setting inactiviey");
    NSNumber *givenInactivity = [self numberFromString:inactivityString];
    inactivity = [givenInactivity unsignedIntValue];
}

- (void)setRequestsFromString:(NSString *)requestsString
{
    NSNumber *maxRequests = [self numberFromString:requestsString];
    [boshWindowManager setWindowSize:[maxRequests unsignedIntValue]];
    requests = [maxRequests unsignedIntValue];
}

- (void)setSecureFromString:(NSString *)isSecure
{
    if ([isSecure isEqualToString:@"true"]) secure=YES;
    else secure = NO;
}

#pragma mark -
#pragma mark init

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        boshVersion = @"1.6";
        lang_ = @"en";
        wait_ = 60.0;
        hold_ = 1;
        
        nextRidToSend = [self generateRid];
        maxRidProcessed = nextRidToSend - 1;
        
        multicastDelegate = [[GCDMulticastDelegate<XMPPTransportDelegate> alloc] init];
        xmppQueue = queue;
        
        sid_ = nil;
        inactivity = 48 * 3600;
        requests = 2;
        
        state = DISCONNECTED;
        disconnectError_ = nil;
        
        /* Keeping a random capacity right now */
        pendingXMPPStanzas = [[NSMutableArray alloc] initWithCapacity:25];
        requestResponsePairs = [[NSMutableDictionary alloc] initWithCapacity:3];
        retryCounter = 0;
        nextRequestDelay = INITIAL_RETRY_DELAY;
        
        boshWindowManager = [[BoshWindowManager alloc] initWithRid:(nextRidToSend - 1)];
        [boshWindowManager setWindowSize:1];
    }
    return self;
}

#pragma mark -
#pragma mark Transport Protocols
/* Implemet this as well */
- (float)serverXmppStreamVersionNumber
{
    return 1.0;
}

- (NSURL *)url {
    if (!url_) {
        NSString *stringUrl = [NSString stringWithFormat:@"https://%@:%tu/http-bind", _hostName, _hostPort];
        url_ = [NSURL URLWithString:stringUrl];
    }
    return url_;
}

- (BOOL)connectWithTimeout:(NSTimeInterval)timeout
                     error:(NSError *__autoreleasing  _Nullable *)errPtr {
//    if (state == CONNECTED) {
//        [self restartStream];
//        return NO;
//    }
    XMPPLogSend(@"BOSH: Connecting to %@ with jid = %@", self.hostName, [self.myJID bare]);
    
    if(![self canConnect]) return NO;
    state = CONNECTING;
    [multicastDelegate transportWillConnect:self];
    return [self createSession:errPtr];
}

- (void)restartStream
{
    if(![self isConnected])
    {
        XMPPLogSend(@"BOSH: Need to be connected to restart the stream.");
        return ;
    }
    XMPPLogSend(@"Bosh: Will Restart Stream");
    NSMutableDictionary *attr = [NSMutableDictionary dictionaryWithObjectsAndKeys: @"true", @"xmpp:restart", nil];
    NSMutableDictionary *ns = [NSMutableDictionary dictionaryWithObjectsAndKeys:XMPP_NS, @"xmpp", nil];
    [self makeBodyAndSendHTTPRequestWithPayload:nil attributes:attr namespaces:nil];
}

- (void)disconnect
{
    if(![self isConnected])
    {
        XMPPLogSend(@"BOSH: Need to be connected to disconnect");
        return;
    }
    XMPPLogSend(@"Bosh: Will Terminate Session");
    state = DISCONNECTING;
    [multicastDelegate transportWillDisconnect:self];
    [self trySendingStanzas];
}

- (BOOL)sendStanza:(NSXMLElement *)stanza
{
    if (![self isConnected])
    {
        XMPPLogSend(@"BOSH: Need to be connected to be able to send stanza");
        return NO;
    }
    [pendingXMPPStanzas addObject:stanza];
    [self trySendingStanzas];
    return YES;
}

- (BOOL)sendStanzaWithString:(NSString *)string
{
    NSXMLElement *payload = [self parseXMLString:string];
    return [self sendStanza:payload];
}

- (BOOL)sendStanzaWithString:(NSString *)string tag:(long)tag {
    return [self sendStanzaWithString:string];
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


// not needed
- (void)addReceipt:(XMPPElementReceipt *)receipt {
    
}


- (void)continueStartTLS:(NSMutableDictionary *)settings {
    
}

- (BOOL)isSecure {
    return YES;
}


- (void)startTLS {
    
}


#pragma mark -
#pragma mark BOSH

- (BOOL)isConnected
{
    return state == CONNECTED;
}

- (BOOL)canConnect
{
    if( state != DISCONNECTED ) {
        XMPPLogSend(@"@BOSH: Either disconnecting or still connected to the server. Disconnect First.");
        return NO;
    }
    if(!self.hostName.length) {
        XMPPLogSend(@"BOSH: Called Connect with specifying the domain");
        return NO;
    }
    if(!self.myJID) {
        XMPPLogSend(@"BOSH: Called connect without setting the jid");
        return NO;
    }
    return YES;
}

- (BOOL)createSession:(NSError **)error
{
    NSMutableDictionary *attr = [NSMutableDictionary dictionaryWithCapacity:8];
    
    [attr setObject:CONTENT_TYPE forKey:@"content"];
    [attr setObject:[NSString stringWithFormat:@"%@", @(self.hold)] forKey:@"hold"];
    [attr setObject:self.hostName forKey:@"to"];
    [attr setObject:boshVersion forKey:@"ver"];
    [attr setObject:[NSString stringWithFormat:@"%@", @(self.wait)] forKey:@"wait"];
    [attr setObject:[self.myJID full] forKey:@"from"];
    [attr setObject:@"false" forKey:@"secure"];
    [attr setObject:@"en" forKey:@"xml:lang"];
    [attr setObject:@"1.0" forKey:@"xmpp:version"];
    [attr setObject:[NSString stringWithFormat:@"%@", @(self.inactivity)] forKey:@"inactivity"];
//    [attr setObject:@"iphone" forKey:@"ua"];
    
    NSMutableDictionary *ns = [NSMutableDictionary dictionaryWithObjectsAndKeys: XMPP_NS, @"xmpp", nil];
    
    [self makeBodyAndSendHTTPRequestWithPayload:nil attributes:attr namespaces:nil];
    
    return YES;
}

- (void)makeBodyAndSendHTTPRequestWithPayload:(NSArray *)bodyPayload
                                   attributes:(NSMutableDictionary *)attributes
                                   namespaces:(NSMutableDictionary *)namespaces
{
    NSXMLElement *requestPayload = [self newBodyElementWithPayload:bodyPayload
                                                        attributes:attributes
                                                        namespaces:namespaces];
    [self sendHTTPRequestWithBody:requestPayload rid:nextRidToSend];
    [boshWindowManager sentRequestForRid:nextRidToSend];
    ++nextRidToSend;
}

- (void)sendTerminateRequest
{
    NSMutableDictionary *attr = [NSMutableDictionary dictionaryWithObjectsAndKeys: @"terminate", @"type", nil];
    [self makeBodyAndSendHTTPRequestWithPayload:nil attributes:attr namespaces:nil];
}

- (void)trySendingStanzas
{
    if( state != DISCONNECTED && ![boshWindowManager isWindowFull] )
    {
        if (state == CONNECTED) {
            if ( [pendingXMPPStanzas count] > 0 ) {
                [self makeBodyAndSendHTTPRequestWithPayload:pendingXMPPStanzas
                                                 attributes:nil
                                                 namespaces:nil];
                [pendingXMPPStanzas removeAllObjects];
            } else if ( [boshWindowManager isWindowEmpty] ) {
                [self makeBodyAndSendHTTPRequestWithPayload:nil
                                                 attributes:nil
                                                 namespaces:nil];
            }
        }
        else if(state == DISCONNECTING)
        {
            [self sendTerminateRequest];
            state = TERMINATING;
        }
    }
}

/*
 For each received stanza the client might send out packets.
 We should ideally put all the request in the queue and call
 processRequestQueue with a timeOut.
 */
- (void)broadcastStanzas:(NSXMLNode *)node
{
    NSUInteger level = [node level];
    while( (node = [node nextNode]) )
    {
        if([node level] == level + 1)
        {
            [multicastDelegate transport:self
                        didReceiveStanza:[(NSXMLElement *)node copy]];
        }
    }
}

#pragma mark -
#pragma mark HTTP Request Response

- (void)handleAttributesInResponse:(NSXMLElement *)parsedResponse
{
    NSXMLNode *typeAttribute = [parsedResponse attributeForName:@"type"];
    
    if( typeAttribute != nil )
    {
        if ([[typeAttribute stringValue] isEqualToString:@"terminate"]) {
            
            NSXMLNode *conditionNode = [parsedResponse attributeForName:@"condition"];
            if(conditionNode != nil)
            {
                NSString *condition = [conditionNode stringValue];
                if( [condition isEqualToString:@"host-unknown"] )
                    disconnectError_ = [[NSError alloc] initWithDomain:@"BoshTerminateCondition"
                                                                  code:HOST_UNKNOWN userInfo:nil];
                else if ( [condition isEqualToString:@"host-gone"] )
                    disconnectError_ = [[NSError alloc] initWithDomain:@"BoshTerminateCondition"
                                                                  code:HOST_GONE userInfo:nil];
                else if( [condition isEqualToString:@"item-not-found"] )
                    disconnectError_ = [[NSError alloc] initWithDomain:@"BoshTerminateCondition"
                                                                  code:ITEM_NOT_FOUND userInfo:nil];
                else if ( [condition isEqualToString:@"policy-violation"] )
                    disconnectError_ = [[NSError alloc] initWithDomain:@"BoshTerminateCondition"
                                                                  code:POLICY_VIOLATION userInfo:nil];
                else if( [condition isEqualToString:@"remote-connection-failed"] )
                    disconnectError_ = [[NSError alloc] initWithDomain:@"BoshTerminateCondition"
                                                                  code:REMOTE_CONNECTION_FAILED userInfo:nil];
                else if ( [condition isEqualToString:@"bad-request"] )
                    disconnectError_ = [[NSError alloc] initWithDomain:@"BoshTerminateCondition"
                                                                  code:BAD_REQUEST userInfo:nil];
                else if( [condition isEqualToString:@"internal-server-error"] )
                    disconnectError_ = [[NSError alloc] initWithDomain:@"BoshTerminateCondition"
                                                                  code:INTERNAL_SERVER_ERROR userInfo:nil];
                else if ( [condition isEqualToString:@"remote-stream-error"] )
                    disconnectError_ = [[NSError alloc] initWithDomain:@"BoshTerminateCondition"
                                                                  code:REMOTE_STREAM_ERROR userInfo:nil];
                else if ( [condition isEqualToString:@"undefined-condition"] )
                    disconnectError_ = [[NSError alloc] initWithDomain:@"BoshTerminateCondition"
                                                                  code:UNDEFINED_CONDITION userInfo:nil];
                else NSAssert( false, @"Terminate Condition Not Valid");
            }
            if (state != DISCONNECTED) {
                state = NEED_DISCONNECT;
            }
        } else if ([[typeAttribute stringValue] isEqualToString:@"error"]) {
            // https://xmpp.org/extensions/xep-0124.html#errorstatus-http
            NSXMLElement *errorElement = [parsedResponse elementForName:@"error"];
            if (errorElement == nil) { return; }
            NSXMLNode *codeAttribute = [errorElement attributeForName:@"code"];
            if (codeAttribute == nil) { return; }
            NSString *stringCode = [codeAttribute stringValue];
            if (stringCode == nil) { return; }
            switch ([stringCode integerValue]) {
                case 400:
                case 403:
                case 404: {
//                    resolve "Invalid sid" errors on the transport layer
//                    state = NEED_CONNECT;
                    state = NEED_DISCONNECT;
                    return;
                }
                default: return;
            }
        }
    } else if( !self.sid ) {
        [self createSessionResponseHandler:parsedResponse];
    }
}

- (void)createSessionResponseHandler:(NSXMLElement *)parsedResponse
{
    NSArray *responseAttributes = [parsedResponse attributes];
    
    /* Setting inactivity, sid, wait, hold, lang, authid, secure, requests */
    for(NSXMLNode *attr in responseAttributes) {
        NSString *attrName = [attr name];
        NSString *attrValue = [attr stringValue];
        SEL setter = [self setterForProperty:attrName];
        
        if([self respondsToSelector:setter]) {
            [self performSelector:setter withObject:attrValue];
        }
    }
    
    /* Not doing anything with namespaces right now - because chirkut doesn't send it */
    //NSArray *responseNamespaces = [rootElement namespaces];
    
    state = CONNECTED;
    [multicastDelegate transportDidConnect:self];
    [multicastDelegate transportDidStartNegotiation:self];
}

- (void)handleDisconnection {
    if(self.disconnectError != nil) {
        [multicastDelegate transportWillDisconnect:self withError:self.disconnectError];
        self.disconnectError = nil;
    }
    [pendingXMPPStanzas removeAllObjects];
    if (state == DISCONNECTED) {
        return;
    }
    state = DISCONNECTED;
    
    [multicastDelegate transportDidDisconnect:self withError:self.disconnectError];
}

- (void)processResponses
{
    while ( maxRidProcessed < [boshWindowManager maxRidReceived] )
    {
        ++maxRidProcessed;
        RequestResponsePair *pair = [requestResponsePairs objectForKey:@(maxRidProcessed)];
        NSAssert( [pair response], @"Processing nil response" );
        [self handleAttributesInResponse:[pair response]];
        [self broadcastStanzas:[pair response]];
        [requestResponsePairs removeObjectForKey:@(maxRidProcessed)];
        if ( state == NEED_DISCONNECT ) {
            [self handleDisconnection];
        } else if ( state == NEED_CONNECT ) {
            if (state == DISCONNECTED ||
                state == CONNECTING) { return; }
            state = CONNECTING;
            self.sid = nil;
            [self createSession:nil];
        }
    }
}

- (void)resendRequest:(QBBoshRequest *)request {
    [self sendHTTPRequestWithBody:[self parseXMLData:request.postBody] rid:request.rid];
}

/*
 Should call processRequestQueue after some timeOut
 Handle terminate response sent in any request.
 */
- (void)didFinishRequest:(QBBoshRequest *)request
{
    dispatch_block_t block = ^{ @autoreleasepool {
        NSData *responseData = request.responseData;
        NSNumber *ridNumber = request.ridNumber;
        NSLog(@"BOSH: RECD[%@] = %@", ridNumber, request.responseString);
        
        self->retryCounter = 0;
        self->nextRequestDelay = INITIAL_RETRY_DELAY;
        
        NSXMLElement *parsedResponse = [self parseXMLData:responseData];
        if ( !parsedResponse )
        {
            [self didFailureRequest:request];
            return;
        }
        RequestResponsePair *requestResponsePair = [self->requestResponsePairs objectForKey:ridNumber];
        [requestResponsePair setResponse:parsedResponse];
        
        [self->boshWindowManager recievedResponseForRid:request.rid];
        [self processResponses];
        
        [self trySendingStanzas];
    }};
    dispatch_sync(xmppQueue, block);
}

- (void)didFailureRequest:(QBBoshRequest *)request {
    dispatch_block_t block = ^{ @autoreleasepool {
        NSError *error = request.error;

        XMPPLogSend(@"BOSH: Request Failed[%@]", request.ridNumber);
        XMPPLogSend(@"Failure HTTP error domain = %@, error code = %@, description = %@",[request.error domain], @(request.error.code), [error localizedDescription]);
        
        BOOL shouldReconnect = (error.code == NSURLErrorTimedOut ||
                                error.code == NSURLErrorNetworkConnectionLost ||
                                error.code == NSURLErrorNotConnectedToInternet) &&
        ( self->retryCounter < RETRY_COUNT_LIMIT ) &&
        (self->state == CONNECTED);
        
        if(shouldReconnect)
        {
            XMPPLogSend(@"Resending the request");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self->nextRequestDelay * NSEC_PER_SEC)), self->xmppQueue, ^{
                if (self->state != CONNECTED) {return;}
                [self resendRequest:request];
            });
//            [self performSelector:@selector(resendRequest:)
//                       withObject:request
//                       afterDelay:self->nextRequestDelay];
            ++self->retryCounter;
            self->nextRequestDelay *= DELAY_EXPONENTIATING_FACTOR;
        }
        else
        {
            XMPPLogSend(@"disconnecting due to request failure");
            [self->multicastDelegate transportWillDisconnect:self withError:error];
            [self handleDisconnection];
        }
    }};
    dispatch_sync(xmppQueue, block);
}


- (void)sendHTTPRequestWithBody:(NSXMLElement *)body rid:(NSUInteger)rid {

    [QBBoshRequest configureWithUrl:self.url];
    QBBoshRequest *request = [QBBoshRequest requestWithBody:[body compactXMLString]
                                                    timeout:(self.wait + 4)
                                                        rid:rid];
    request.delegate = self;
    
    RequestResponsePair *pair = [[RequestResponsePair alloc] initWithRequest:body response:nil];
    [requestResponsePairs setObject:pair forKey:request.ridNumber];
    
    [request resume];
    XMPPLogSend(@"%@", self.url);
    XMPPLogSend(@"BOSH: SEND[%@] = %@", request.ridNumber, body);
}

#pragma mark -
#pragma mark utilities

- (NSXMLElement *)newBodyElementWithPayload:(NSArray *)payload 
                                 attributes:(NSMutableDictionary *)attributes
                                 namespaces:(NSMutableDictionary *)namespaces
{
    attributes = attributes?attributes:[NSMutableDictionary dictionaryWithCapacity:3];
    namespaces = namespaces?namespaces:[NSMutableDictionary dictionaryWithCapacity:1];
    
    /* Adding ack and sid attribute on every outgoing request after sid is created */
    if( self.sid )
    {
        [attributes setValue:self.sid forKey:@"sid"];
        NSUInteger ack = maxRidProcessed;
        if( ack != nextRidToSend - 1 )
        {
            [attributes setValue:[NSString stringWithFormat:@"%@", @(ack)] forKey:@"ack"];
        }
    }
    else
    {
        [attributes setValue:@"1" forKey:@"ack"];
    }
    
    [attributes setValue:[NSString stringWithFormat:@"%@", @(nextRidToSend)] forKey:@"rid"];
    [namespaces setValue:BODY_NS forKey:@""];
    
    NSXMLElement *body = [[NSXMLElement alloc] initWithName:@"body"];
    
    NSArray *namespaceArray = [self newXMLNodeArrayFromDictionary:namespaces
                                                           ofType:NAMESPACE_TYPE];
    NSArray *attributesArray = [self newXMLNodeArrayFromDictionary:attributes
                                                            ofType:ATTR_TYPE];
    [body setNamespaces:namespaceArray];
    [body setAttributes:attributesArray];
    
    if(payload != nil)
    {
        for(NSXMLElement *child in payload)
        {
            [body addChild:[child copy]];
        }
    }
    
    return body;
}

- (NSXMLElement *)parseXMLString:(NSString *)xml
{
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithXMLString:xml
                                                          options:0
                                                            error:nil];
    return [doc rootElement];
}

- (NSXMLElement *)parseXMLData:(NSData *)xml
{
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:xml
                                                     options:0
                                                       error:nil];
    return [doc rootElement];
}

- (NSArray *)newXMLNodeArrayFromDictionary:(NSDictionary *)dict 
                                    ofType:(XMLNodeType)type {
    NSMutableArray *array = [[NSMutableArray alloc] init];
    for (NSString *key in dict) {
        NSString *value = [dict objectForKey:key];
        NSXMLNode *node;
        
        if(type == ATTR_TYPE)
            node = [NSXMLNode attributeWithName:key stringValue:value];
        else if(type == NAMESPACE_TYPE)
            node = [NSXMLNode namespaceWithName:key stringValue:value];
        else
            XMPPLogSend(@"BOSH: Wrong Type Passed to createArrayFrom Dictionary");
        
        [array addObject:node];
    }
    return array;
}

- (NSUInteger)generateRid
{
    return (arc4random() % 1000000000LL + 1000000001LL);
}

- (SEL)setterForProperty:(NSString *)property
{
    NSString *setter = @"set";
    setter = [setter stringByAppendingString:[property capitalizedString]];
    setter = [setter stringByAppendingString:@"FromString:"];
    return NSSelectorFromString(setter);
}

- (NSNumber *)numberFromString:(NSString *)stringNumber
{
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
    NSNumber *number = [formatter numberFromString:stringNumber];
    return number;
}

@end
