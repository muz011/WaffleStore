#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const WFSAppleIDDownloaderErrorDomain;

typedef NS_ENUM(NSInteger, WFSAppleIDDownloaderErrorCode)
{
	WFSAppleIDDownloaderError2FARequired = 1,
	WFSAppleIDDownloaderErrorAuthenticationFailed,
	WFSAppleIDDownloaderErrorBrowserSignInRequired,
	WFSAppleIDDownloaderErrorNotAuthenticated,
	WFSAppleIDDownloaderErrorLicenseNotFound,
	WFSAppleIDDownloaderErrorPurchaseFailed,
	WFSAppleIDDownloaderErrorNoSong,
	WFSAppleIDDownloaderErrorInvalidResponse,
	WFSAppleIDDownloaderErrorNetwork,
	WFSAppleIDDownloaderErrorRateLimited,
};

typedef void (^WFSAppleIDAuthCompletion)(NSError* _Nullable error);
typedef void (^WFSAppleIDVersionsCompletion)(NSArray* _Nullable versions, NSDictionary* _Nullable metadata, NSError* _Nullable error);
typedef void (^WFSAppleIDDownloadInfoCompletion)(NSURL* _Nullable ipaURL, NSDictionary* _Nullable metadata, NSError* _Nullable error);
typedef void (^WFSAppleIDPurchaseSearchCompletion)(NSDictionary* _Nullable purchase, NSError* _Nullable error);

@interface WFSAppleIDDownloader : NSObject

+ (instancetype)sharedDownloader;

@property (nonatomic, readonly, getter=isAuthenticated) BOOL authenticated;
@property (nonatomic, copy, readonly, nullable) NSString* authenticatedAppleId;

- (void)authenticateWithAppleId:(NSString*)appleId password:(NSString*)password completion:(WFSAppleIDAuthCompletion)completion;
- (void)retryWithTwoFactorCode:(NSString*)code completion:(WFSAppleIDAuthCompletion)completion;
- (void)resetSession;

- (void)getVersionsForAppId:(long long)appId completion:(WFSAppleIDVersionsCompletion)completion;
- (void)getDownloadInfoForAppId:(long long)appId versionId:(long long)versionId completion:(WFSAppleIDDownloadInfoCompletion)completion;
- (void)searchPurchaseHistoryForBundleID:(NSString*)bundleID completion:(WFSAppleIDPurchaseSearchCompletion)completion;

@end

NS_ASSUME_NONNULL_END
