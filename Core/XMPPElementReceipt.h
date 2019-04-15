//
//  XMPPElementReceipt.h
//  TestXMPP
//
//  Created by Illia Chemolosov on 3/27/19.
//  Copyright © 2019 QuickBlox. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XMPPElementReceipt : NSObject {
    uint32_t atomicFlags;
    dispatch_semaphore_t semaphore;
}

/**
 * Element receipts allow you to check to see if the element has been sent.
 * The timeout parameter allows you to do any of the following:
 *
 * - Do an instantaneous check (pass timeout == 0)
 * - Wait until the element has been sent (pass timeout < 0)
 * - Wait up to a certain amount of time (pass timeout > 0)
 *
 * It is important to understand what it means when [receipt wait:timeout] returns YES.
 * It does NOT mean the server has received the element.
 * It only means the data has been queued for sending in the underlying OS socket buffer.
 *
 * So at this point the OS will do everything in its capacity to send the data to the server,
 * which generally means the server will eventually receive the data.
 * Unless, of course, something horrible happens such as a network failure,
 * or a system crash, or the server crashes, etc.
 *
 * Even if you close the xmpp stream after this point, the OS will still do everything it can to send the data.
 **/
- (BOOL)wait:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
