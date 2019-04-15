//
//  QBBoshRequestTask.m
//  Pods
//
//  Created by Andrey Ivanov on 28.11.16.
//
//

#import "QBBoshRequest.h"

@interface QBSessionDelegate : NSObject <NSURLSessionDelegate>
@end

@implementation QBSessionDelegate

/* The last message a session receives.  A session will only become
 * invalid because of a systemic error or when it has been
 * explicitly invalidated, in which case the error parameter will be nil.
 */
- (void)URLSession:(NSURLSession *)session
didBecomeInvalidWithError:(nullable NSError *)error {
    
}

/* If implemented, when a connection level authentication challenge
 * has occurred, this delegate will be given the opportunity to
 * provide authentication credentials to the underlying
 * connection. Some types of authentication will apply to more than
 * one request on a given connection to a server (SSL Server Trust
 * challenges).  If this delegate message is not implemented, the
 * behavior will be to use the default handling, which may involve user
 * interaction.
 */
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition,
                             NSURLCredential * _Nullable credential))completionHandler {
    //Creates credentials for logged in user (username/pass)
    completionHandler(NSURLSessionAuthChallengeUseCredential,
                      [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
}

/* If an application has received an
 * -application:handleEventsForBackgroundURLSession:completionHandler:
 * message, the session delegate will receive this message to indicate
 * that all messages previously enqueued for this session have been
 * delivered.  At this time it is safe to invoke the previously stored
 * completion handler, or to begin any internal updates that will
 * result in invoking the completion handler.
 */
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    
}

@end

@interface QBBoshRequest()

@property (copy, nonatomic) NSString *label;
@property (nonatomic, strong) NSString *body;
@property (nonatomic, assign) NSTimeInterval timeout;

@end

@implementation QBBoshRequest

static NSURLSession *_session = nil;
static NSURL *_url = nil;
static QBSessionDelegate *_sessionDelegate = nil;

+ (void)configureWithUrl:(NSURL *)url {
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        
        NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration defaultSessionConfiguration];
        
        configuration.HTTPAdditionalHeaders = @
        {
            @"Content-Type" : @"text/xml; charset=utf-8",
            @"Accept-Encoding" : @"gzip, deflate"
        };
        
        [configuration setHTTPMaximumConnectionsPerHost:2];
        
        _sessionDelegate = [QBSessionDelegate new];
        
        _session = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:_sessionDelegate
                                            delegateQueue:nil];
    });
    
    _url = url;
}

+ (instancetype)requestWithBody:(NSString *)body
                        timeout:(NSTimeInterval)timeout
                            rid:(NSUInteger)rid {
    
    return [[QBBoshRequest alloc] initWithBody:body timeout:timeout rid:rid];
}

- (instancetype)initWithBody:(NSString *)body
                     timeout:(NSTimeInterval)timeout
                         rid:(NSUInteger)rid {
    self = [super init];
    if (self) {
        _rid = rid;
        _ridNumber = @(rid);
        _body = body;
        _timeout = timeout;
        
        const char *currentLabel = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
        self.label = [NSString stringWithUTF8String:currentLabel];
    }
    
    return self;
}

//- (NSString *)description {
//
//    return [NSString
//            stringWithFormat:@"<%@:%p>\nrid:%tu\nAttributes:%@\nStanzas:\n\%@\nQueue lable:%@",
//            NSStringFromClass(self.class),
//            self,
//            _rid,
//            _attributes,
//            _stanzas, _label];
//}

- (NSString *)responseString {
    if (_responseData) {
        return [[NSString alloc] initWithData:_responseData encoding:NSUTF8StringEncoding];
    }
    return nil;
}

- (void)resume {
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = self.timeout;
    
    NSData *bodyData = [self.body dataUsingEncoding:NSUTF8StringEncoding];
    request.HTTPBody = bodyData;
    _postBody = bodyData.mutableCopy;
    
    __weak __typeof(self)weakSelf = self;
    NSURLSessionDataTask *dataTask =
    [_session dataTaskWithRequest:request
                completionHandler:^(NSData *data,
                                    NSURLResponse *response,
                                    NSError *error) {
                    //                    __strong __typeof(weakSelf)strongSelf = weakSelf;
                    if (error) {
                        [weakSelf setError:error];
                        if ([weakSelf.delegate respondsToSelector:@selector(didFailureRequest:)]) {
                            [weakSelf.delegate didFailureRequest:weakSelf];
                        }
                    } else {
                        [weakSelf setResponseData:data];
                        if ([weakSelf.delegate respondsToSelector:@selector(didFinishRequest:)]) {
                            [weakSelf.delegate didFinishRequest:self];
                        }
                    }
                }];
    
    [dataTask resume];
}

- (void)setResponseData:(NSData * _Nullable)responseData {
    _responseData = responseData;
}

- (void)setError:(NSError * _Nullable)error {
    _error = error;
}

@end
