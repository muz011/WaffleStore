#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const WFSAppleIDDownloaderErrorDomain;

typedef NS_ENUM(NSInteger, WFSAppleIDDownloaderErrorCode)
{
	WFSAppleIDDownloaderError2FARequired = 1,
	WFSAppleIDDownloaderErrorAuthenticationFailed,
	WFSAppleIDDownloaderErrorBrowserSignInRequired,
	WFSAppleIDDownloaderErrorPasswordTokenExpired,
	WFSAppleIDDownloaderErrorNotAuthenticated,
	WFSAppleIDDownloaderErrorLicenseNotFound,
	WFSAppleIDDownloaderErrorPurchaseFailed,
	WFSAppleIDDownloaderErrorNoSong,
	WFSAppleIDDownloaderErrorInvalidResponse,
	WFSAppleIDDownloaderErrorNetwork,
	WFSAppleIDDownloaderErrorRateLimited,
	WFSAppleIDDownloaderErrorCancelled,
};

typedef void (^WFSAppleIDAuthCompletion)(NSError* _Nullable error);
typedef void (^WFSAppleIDVersionsCompletion)(NSArray* _Nullable versions, NSDictionary* _Nullable metadata, NSError* _Nullable error);
typedef void (^WFSAppleIDDownloadInfoCompletion)(NSURL* _Nullable ipaURL, NSDictionary* _Nullable metadata, NSError* _Nullable error);
typedef void (^WFSAppleIDPurchaseSearchCompletion)(NSDictionary* _Nullable purchase, NSError* _Nullable error);
typedef void (^WFSAppleIDVersionsInfoCompletion)(NSArray* _Nullable externalVersionIds, NSDictionary* _Nullable metadata, NSError* _Nullable error);
typedef void (^WFSAppleIDHistoryCompletion)(NSArray* _Nullable purchases, NSDictionary* _Nullable response, NSError* _Nullable error);
typedef void (^WFSAppleIDAuthProgressHandler)(NSUInteger attempt, NSUInteger totalAttempts);
typedef void (^WFSAppleIDHistoryProgressHandler)(NSInteger pageNumber, NSInteger pagePurchaseCount, NSInteger totalPurchases);

@interface WFSAppleIDDownloader : NSObject

+ (instancetype)sharedDownloader;

@property (nonatomic, readonly, getter=isAuthenticated) BOOL authenticated;
@property (nonatomic, copy, readonly, nullable) NSString* authenticatedAppleId;
@property (nonatomic, copy, readonly, nullable) NSString* dsid;
@property (nonatomic, copy, readonly, nullable) NSString* storeFront;
@property (nonatomic, copy, readonly, nullable) NSString* lastAuthEndpoint;
@property (nonatomic, copy, readonly, nullable) NSString* lastDownloadEndpoint;
@property (nonatomic, readonly) BOOL anisetteAvailable;
@property (nonatomic, copy, nullable) WFSAppleIDAuthProgressHandler authProgressHandler;
@property (nonatomic, copy, nullable) WFSAppleIDHistoryProgressHandler historyProgressHandler;

- (void)authenticateWithAppleId:(NSString*)appleId password:(NSString*)password completion:(WFSAppleIDAuthCompletion)completion;
- (void)retryWithTwoFactorCode:(NSString*)code completion:(WFSAppleIDAuthCompletion)completion;
- (void)cancelAuthentication;
- (void)resetSession;

- (void)getVersionsForAppId:(long long)appId completion:(WFSAppleIDVersionsCompletion)completion;
- (void)getDownloadInfoForAppId:(long long)appId versionId:(long long)versionId completion:(WFSAppleIDDownloadInfoCompletion)completion;
- (void)getDownloadInfoForAdamId:(long long)adamId versionId:(long long)versionId autoPurchase:(BOOL)autoPurchase completion:(WFSAppleIDDownloadInfoCompletion)completion;
- (void)getExternalVersionIdsForAdamId:(long long)adamId completion:(WFSAppleIDVersionsInfoCompletion)completion;
- (void)searchPurchaseHistoryForBundleID:(NSString*)bundleID completion:(WFSAppleIDPurchaseSearchCompletion)completion;
- (void)getAllPurchaseHistoryWithCompletion:(void (^)(NSArray* _Nullable purchases, NSDictionary* _Nullable firstResponse, NSError* _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
