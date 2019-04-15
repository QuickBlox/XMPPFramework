//
//  XMPPTransportProtocol.h
//  TestXMPP
//
//  Created by Illia Chemolosov on 3/15/19.
//  Copyright © 2019 QuickBlox. All rights reserved.
//

#import <Foundation/Foundation.h>
#if TARGET_OS_IPHONE
#import "DDXML.h"
#endif

@class XMPPJID;
@class XMPPElementReceipt;

@protocol XMPPTransportProtocol

- (NSString *)hostName;
- (void)setHostName:(NSString *)newHostName;
- (UInt16)hostPort;
- (void)setHostPort:(UInt16)newHostPort;


- (void)addDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue;
- (void)removeDelegate:(id)delegate delegateQueue:(dispatch_queue_t)delegateQueue;
- (void)removeDelegate:(id)delegate;

- (XMPPJID *)myJID;
- (void)setMyJID:(XMPPJID *)jid;

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

- (NSTimeInterval)keepAliveInterval;
- (void)setKeepAliveInterval:(NSTimeInterval)keepAliveInterval;

- (NSData *)keepAliveData;
- (void)setKeepAliveData:(NSData *)keepAliveData;

- (void)addReceipt:(XMPPElementReceipt *)receipt;

@end


@protocol XMPPTransportDelegate

@optional
- (void)transportWillConnect:(id <XMPPTransportProtocol>)transport;
- (void)transportConnectDidTimeout:(id <XMPPTransportProtocol>)transport;
- (void)transportDidStartNegotiation:(id <XMPPTransportProtocol>)transport;
- (void)transportDidConnect:(id <XMPPTransportProtocol>)transport;
- (void)transportWillDisconnect:(id <XMPPTransportProtocol>)transport;
- (void)transportWillDisconnect:(id<XMPPTransportProtocol>)transport withError:(NSError *)err;
- (void)transportDidDisconnect:(id <XMPPTransportProtocol>)transport withError:(NSError *)err;
- (void)transport:(id <XMPPTransportProtocol>)transport willSecureWithSettings:(NSMutableDictionary *)settings;
- (void)transport:(id <XMPPTransportProtocol>)transport
  didReceiveTrust:(SecTrustRef)trust
completionHandler:(void (^)(BOOL shouldTrustPeer))completionHandler;
- (void)transport:(id <XMPPTransportProtocol>)transport didReceiveStanza:(NSXMLElement *)stanza;
- (void)transport:(id <XMPPTransportProtocol>)transport didReceiveError:(id)error;
- (void)transportDidSecure:(id <XMPPTransportProtocol>)transport;
- (void)transportDidSendClosingStreamStanza:(id <XMPPTransportProtocol>)transport;

@end
