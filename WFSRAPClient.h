#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WFSRAPAuthCompletion)(NSError* _Nullable error);
typedef void (^WFSRAPHistoryCompletion)(NSArray* _Nullable purchases, NSDictionary* _Nullable response, NSError* _Nullable error);
typedef void (^WFSRAPHistoryProgressHandler)(NSInteger pageNumber, NSInteger pagePurchaseCount, NSInteger totalPurchases);

@interface WFSRAPClient : NSObject

+ (instancetype)sharedClient;

@property (nonatomic, readonly, getter=isAuthenticated) BOOL authenticated;
@property (nonatomic, copy, readonly, nullable) NSString* authenticatedAppleId;
@property (nonatomic, copy, readonly, nullable) NSString* dsid;
@property (nonatomic, copy, nullable) WFSRAPHistoryProgressHandler historyProgressHandler;

- (void)authenticateWithAppleId:(NSString*)appleId password:(NSString*)password completion:(WFSRAPAuthCompletion)completion;
- (void)retryWithTwoFactorCode:(NSString*)code completion:(WFSRAPAuthCompletion)completion;
- (void)cancelAuthentication;
- (void)resetSession;

- (void)fetchFullPurchaseHistoryWithCompletion:(WFSRAPHistoryCompletion)completion;

@end

NS_ASSUME_NONNULL_END