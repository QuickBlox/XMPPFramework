//
//  BoshTransport.h
//  iPhoneXMPP
//
//  Created by Satyam Shekhar on 3/17/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "XMPPTransportProtocol.h"
#import "XMPPJID.h"
#import "GCDMulticastDelegate.h"
#import "QBBoshRequest.h"

typedef enum {
    ATTR_TYPE = 0,
    NAMESPACE_TYPE = 1
} XMLNodeType;

/*
 host-unknown
 host-gone
 item-not-found
 policy-violation
 remote-connection-failed
 bad-request
 internal-server-error
 remote-stream-error
 undefined-condition
 */

typedef enum {
    HOST_UNKNOWN = 1,
    HOST_GONE = 2,
    ITEM_NOT_FOUND = 3,
    POLICY_VIOLATION = 4,
    REMOTE_CONNECTION_FAILED = 5,
    BAD_REQUEST = 6,
    INTERNAL_SERVER_ERROR = 7,
    REMOTE_STREAM_ERROR = 8,
    UNDEFINED_CONDITION = 9
} BoshTerminateConditions;

typedef enum {
    CONNECTED = 0,
    CONNECTING = 1,
    NEED_CONNECT = 2,
    DISCONNECTING = 3,
    DISCONNECTED = 4,
    NEED_DISCONNECT = 5,
    TERMINATING = 6
} BoshTransportState;

@interface RequestResponsePair : NSObject
@property(retain) NSXMLElement *request;
@property(retain) NSXMLElement *response;
- (id)initWithRequest:(NSXMLElement *)request response:(NSXMLElement *)response;
@end

#pragma mark -

/**
 * Handles the in-order processing of responses.
 **/
@interface BoshWindowManager : NSObject {
	NSUInteger maxRidReceived; // all rid value less than equal to maxRidReceived are processed.
	NSUInteger maxRidSent;
    NSMutableSet *receivedRids;
}

@property NSUInteger windowSize;
@property (readonly) NSUInteger maxRidReceived;

- (id)initWithRid:(NSUInteger)rid;
- (void)sentRequestForRid:(NSUInteger)rid;
- (void)recievedResponseForRid:(NSUInteger)rid;
- (BOOL)isWindowFull;
- (BOOL)isWindowEmpty;
@end


#pragma mark -

@interface BoshTransport : NSObject <XMPPTransportProtocol, QBBoshRequestDelegate> {
    NSString *boshVersion;

    NSUInteger nextRidToSend;
    NSUInteger maxRidProcessed;
    
    NSMutableArray *pendingXMPPStanzas;
    BoshWindowManager *boshWindowManager;
    BoshTransportState state;
    
    NSMutableDictionary *requestResponsePairs;
    
    GCDMulticastDelegate <XMPPTransportDelegate> *multicastDelegate;
    
    int retryCounter;
    NSTimeInterval nextRequestDelay;
}

@property(assign) NSUInteger wait;
@property(assign) NSUInteger hold;
@property(copy) NSString *lang;
@property(assign) NSUInteger inactivity;
@property(readonly) BOOL secure;
@property(readonly) NSUInteger requests;
@property(copy) NSString *authid;
@property(copy) NSString *sid;
@property(nonatomic, strong, readonly) NSURL *url;
@property(readonly) NSError *disconnectError;

@property (nonatomic, copy) NSString *hostName;
@property (nonatomic, assign) UInt16 hostPort;
@property (nonatomic, assign) NSTimeInterval keepAliveInterval;
@property (nonatomic, copy) NSData *keepAliveData;
@property (nonatomic, copy) XMPPJID *myJID;

/* init Methods */
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithQueue:(dispatch_queue_t)queue;

/* Protocol Methods */
- (BOOL)isConnected;

- (void)addDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue;
- (void)removeDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue;
- (void)removeDelegate:(id)delegate;

- (BOOL)connectWithTimeout:(NSTimeInterval)timeout
                     error:(NSError * _Nullable __autoreleasing *)errPtr;
- (void)disconnect;
- (void)restartStream;
- (float)serverXmppStreamVersionNumber;

- (BOOL)sendStanza:(NSXMLElement *)stanza;
- (BOOL)sendStanzaWithString:(NSString *)string;
- (BOOL)sendStanzaWithString:(NSString *)string tag:(long)tag;
@end
