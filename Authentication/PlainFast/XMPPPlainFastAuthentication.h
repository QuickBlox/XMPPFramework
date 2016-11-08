//
//  XMPPPlainFastAuthentication.h
//  Pods
//
//  Created by Andrey Ivanov on 31/08/16.
//
//

#import <Foundation/Foundation.h>
#import "XMPPSASLAuthentication.h"
#import "XMPPStream.h"

// This class implements the XMPPSASLAuthentication protocol.
//
// See XMPPSASLAuthentication.h for more information.

@interface XMPPPlainFastAuthentication : NSObject <XMPPSASLAuthentication>

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface XMPPStream (XMPPPlainFastAuthentication)

- (BOOL)supportsPlainFastAuthentication;

@end

