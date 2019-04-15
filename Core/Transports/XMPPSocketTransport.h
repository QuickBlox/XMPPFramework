//
//  XMPPSocketTransport.h
//  TestXMPP
//
//  Created by Illia Chemolosov on 3/18/19.
//  Copyright © 2019 QuickBlox. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "XMPPTransportProtocol.h"
#import "GCDMulticastDelegate.h"

#if TARGET_OS_IPHONE
#import "DDXML.h"
#endif

@class GCDAsyncSocket;
@class XMPPJID;
@class XMPPParser;
@class XMPPSRVResolver;
@class XMPPElementReceipt;

NS_ASSUME_NONNULL_BEGIN

@interface XMPPSocketTransport : NSObject <XMPPTransportProtocol> {
    GCDMulticastDelegate <XMPPTransportDelegate> *multicastDelegate;
    GCDAsyncSocket *asyncSocket;
    XMPPParser *parser;
    
    BOOL isSecure;
    
    NSXMLElement *rootElement;
}

@property (nonatomic, copy) NSString *hostName;
@property (nonatomic, assign) UInt16 hostPort;
@property (nonatomic, assign) NSTimeInterval keepAliveInterval;
@property (nonatomic, copy) NSData *keepAliveData;
@property (nonatomic, copy) XMPPJID *myJID;

@property (nonatomic, assign) BOOL enableBackgroundingOnSocket;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithQueue:(dispatch_queue_t)queue;

- (void)addDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue;
- (void)removeDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue;
- (void)removeDelegate:(id)delegate;

- (BOOL)connectWithTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr;
- (void)disconnect;
- (void)restartStream;

- (float)serverXmppStreamVersionNumber;

- (BOOL)sendStanza:(NSXMLElement *)stanza;
- (BOOL)sendStanzaWithString:(NSString *)string;
- (BOOL)sendStanzaWithString:(NSString *)string tag:(long)tag;

- (void)startTLS;
- (void)continueStartTLS:(NSMutableDictionary *)settings;
- (BOOL)isSecure;

- (void)addReceipt:(XMPPElementReceipt *)receipt;

@end

NS_ASSUME_NONNULL_END
