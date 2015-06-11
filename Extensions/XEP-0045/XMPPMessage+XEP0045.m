#import "XMPPMessage+XEP0045.h"
#import "NSXMLElement+XMPP.h"


@implementation XMPPMessage(XEP0045)

- (BOOL)isGroupChatMessage
{
	return [[[self attributeForName:@"type"] stringValue] isEqualToString:@"groupchat"];
}

- (BOOL)isGroupChatMessageWithBody
{
	if ([self isGroupChatMessage])
	{
		NSString *body = [[self elementForName:@"body"] stringValue];
		
		return ([body length] > 0);
	}
	
	return NO;
}

- (BOOL)isGroupChatMessageWithSubject
{
    if ([self isGroupChatMessage])
	{
        NSString *subject = [[self elementForName:@"subject"] stringValue];

		return ([subject length] > 0);
    }

    return NO;
}

- (BOOL)isShouldBeIgnored
{
    NSString *nick = [[self from] resource];
    
    if ([self isGroupChatMessageWithBody] &&
        nick == nil &&
        ([[self body] isEqualToString:@"Welcome! You created new Multi User Chat Room. Room is locked now. Configure it please!"]
        || [[self body] isEqualToString:@"Room is locked. Please configure."]))
    {
        return YES;
    }

    return NO;
}

@end
