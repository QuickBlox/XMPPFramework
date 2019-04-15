//
//  QBBoshRequestTask.h
//  Pods
//
//  Created by Andrey Ivanov on 28.11.16.
//
//

#import <Foundation/Foundation.h>

@protocol QBBoshRequestDelegate;

NS_ASSUME_NONNULL_BEGIN

@interface QBBoshRequest : NSObject

@property (assign, nonatomic, readonly) NSUInteger rid;
@property (nonatomic, strong, readonly) NSNumber *ridNumber;
@property (strong, nonatomic, readonly, nullable) NSError *error;
@property (nonatomic, strong, readonly, nullable) NSMutableData *postBody;
@property (nonatomic, strong, readonly, nullable) NSData *responseData;
@property (nonatomic, strong, readonly, nullable) NSString *responseString;

@property (weak, nonatomic) id <QBBoshRequestDelegate> delegate;

- (instancetype)init NS_UNAVAILABLE;

+ (void)configureWithUrl:(NSURL *)url;

+ (instancetype)requestWithBody:(NSString *)body
                        timeout:(NSTimeInterval)timeout
                            rid:(NSUInteger)rid;

- (void)resume;;

@end

@protocol QBBoshRequestDelegate <NSObject>

- (void)didFinishRequest:(QBBoshRequest *)request;
- (void)didFailureRequest:(QBBoshRequest *)request;

@end

NS_ASSUME_NONNULL_END
