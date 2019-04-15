//
//  XMPPElementReceipt.m
//  TestXMPP
//
//  Created by Illia Chemolosov on 3/27/19.
//  Copyright © 2019 QuickBlox. All rights reserved.
//

#import "XMPPElementReceipt.h"
#import <objc/runtime.h>
#import <libkern/OSAtomic.h>

@implementation XMPPElementReceipt

static const uint32_t receipt_unknown = 0 << 0;
static const uint32_t receipt_failure = 1 << 0;
static const uint32_t receipt_success = 1 << 1;


- (id)init
{
    if ((self = [super init]))
    {
        atomicFlags = receipt_unknown;
        semaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)signalSuccess
{
    uint32_t mask = receipt_success;
    OSAtomicOr32Barrier(mask, &atomicFlags);
    
    dispatch_semaphore_signal(semaphore);
}

- (void)signalFailure
{
    uint32_t mask = receipt_failure;
    OSAtomicOr32Barrier(mask, &atomicFlags);
    
    dispatch_semaphore_signal(semaphore);
}

- (BOOL)wait:(NSTimeInterval)timeout_seconds
{
    uint32_t mask = 0;
    uint32_t flags = OSAtomicOr32Barrier(mask, &atomicFlags);
    
    if (flags != receipt_unknown) return (flags == receipt_success);
    
    dispatch_time_t timeout_nanos;
    
    if (isless(timeout_seconds, 0.0))
        timeout_nanos = DISPATCH_TIME_FOREVER;
    else
        timeout_nanos = dispatch_time(DISPATCH_TIME_NOW, (timeout_seconds * NSEC_PER_SEC));
    
    // dispatch_semaphore_wait
    //
    // Decrement the counting semaphore. If the resulting value is less than zero,
    // this function waits in FIFO order for a signal to occur before returning.
    //
    // Returns zero on success, or non-zero if the timeout occurred.
    //
    // Note: If the timeout occurs, the semaphore value is incremented (without signaling).
    
    long result = dispatch_semaphore_wait(semaphore, timeout_nanos);
    
    if (result == 0)
    {
        flags = OSAtomicOr32Barrier(mask, &atomicFlags);
        
        return (flags == receipt_success);
    }
    else
    {
        // Timed out waiting...
        return NO;
    }
}

- (void)dealloc
{
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

@end
