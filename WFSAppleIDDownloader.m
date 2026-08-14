#import "WFSAppleIDDownloader.h"
#import <CommonCrypto/CommonDigest.h>

NSString* const WFSAppleIDDownloaderErrorDomain = @"WFSAppleIDDownloaderErrorDomain";

static NSString* const kWFSConfiguratorUA = @"Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6";
static NSString* const kWFSStoreElementsUA = @"Configurator/2.17 (Macintosh; macOS 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6";
static NSString* const kWFSCommerceUA = @"Configurator/2.18 (Macintosh; OS X 15.3.2; 24D81) AppleWebKit/0620.2.4.11.6";
static NSString* const kWFSFastAuthEndpoint = @"https://auth.itunes.apple.com/auth/v1/native/fast/";
static NSString* const kWFSLegacyAuthEndpoint = @"https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate";
static NSString* const kWFSInitBagEndpoint = @"https://init.itunes.apple.com/bag.xml?guid=%@";
static NSString* const kWFSAnisetteEndpoint = @"https://ani.sidestore.io/";
static NSString* const kWFSBuyHost = @"buy.itunes.apple.com";

static NSString* const kWFSFailureTypeInvalidCredentials = @"-5000";
static NSString* const kWFSFailureTypePasswordTokenExpired = @"2034";
static NSString* const kWFSFailureTypeSignInRequired = @"2042";
static NSString* const kWFSFailureTypeLicenseNotFound = @"9610";
static NSString* const kWFSFailureTypeTemporarilyUnavailable = @"2059";
static NSString* const kWFSFailureTypeLicenseAlreadyExists = @"5002";
static NSString* const kWFSFailureTypeDeviceVerificationFailed = @"1008";
static NSString* const kWFSBadLoginMessage = @"MZFinance.BadLogin.Configurator_message";
static NSString* const kWFSAccountDisabledMessage = @"Your account is disabled.";
static NSString* const kWFSSubscriptionRequiredMessage = @"Subscription Required";
static NSString* const kWFSPasswordChangedMessage = @"Your password has changed.";
static NSString* const kWFSPricingParameterAppStore = @"STDQ";
static NSString* const kWFSPricingParameterAppleArcade = @"GAME";

static const NSInteger kWFSMaxRedirects = 5;
static const NSInteger kWFSMaxAuthAttempts = 100;

@interface WFSAppleIDBlockingRedirectDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation WFSAppleIDBlockingRedirectDelegate

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request completionHandler:(void (^)(NSURLRequest* _Nullable))completionHandler
{
	completionHandler(nil);
}

@end

@interface WFSAppleIDDownloader ()
@property (nonatomic, strong) NSURLSession* session;
@property (nonatomic, strong) WFSAppleIDBlockingRedirectDelegate* redirectDelegate;
@property (nonatomic, copy) NSString* guid;
@property (nonatomic, copy) NSString* appleId;
@property (nonatomic, copy) NSString* password;
@property (nonatomic, copy) NSString* dsid;
@property (nonatomic, copy) NSString* token;
@property (nonatomic, copy) NSString* storeFront;
@property (nonatomic, copy) NSString* pod;
@property (nonatomic, assign) BOOL authenticated;
@property (nonatomic, assign) BOOL cancelRequested;
@property (nonatomic, assign) BOOL twoFactorCodeSent;
@property (nonatomic, copy, readwrite) NSString* authenticatedAppleId;
@property (nonatomic, copy) NSDictionary* anisetteHeaders;
@property (nonatomic, copy) NSString* lastAuthEndpoint;
@property (nonatomic, copy) NSString* lastDownloadEndpoint;
@end

@implementation WFSAppleIDDownloader

+ (instancetype)sharedDownloader
{
	static WFSAppleIDDownloader* shared = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^
	{
		shared = [[WFSAppleIDDownloader alloc] init];
	});
	return shared;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		_redirectDelegate = [WFSAppleIDBlockingRedirectDelegate new];
		NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
		config.timeoutIntervalForRequest = 60;
		config.timeoutIntervalForResource = 120;
		_session = [NSURLSession sessionWithConfiguration:config delegate:_redirectDelegate delegateQueue:nil];
	}
	return self;
}

#pragma mark - Public

- (void)authenticateWithAppleId:(NSString*)appleId password:(NSString*)password completion:(WFSAppleIDAuthCompletion)completion
{
	if (appleId.length == 0 || password.length == 0)
	{
		[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:@"Apple ID and password are required."]];
		return;
	}
	[self resetSessionState];
	self.cancelRequested = NO;
	self.appleId = appleId;
	self.password = password;
	self.authenticatedAppleId = appleId;
	if (!self.guid)
	{
		self.guid = [self generateGuidForAppleId:appleId];
	}
	[self tryAuthenticateWithAttempt:1 completion:completion];
}

- (void)retryWithTwoFactorCode:(NSString*)code completion:(WFSAppleIDAuthCompletion)completion
{
	if (self.appleId.length == 0 || self.password.length == 0)
	{
		[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:@"No sign-in in progress."]];
		return;
	}
	NSString* sanitizedCode = [(code ?: @"") stringByReplacingOccurrencesOfString:@" " withString:@""];
	self.password = [NSString stringWithFormat:@"%@%@", self.password, sanitizedCode];
	self.twoFactorCodeSent = YES;
	[self tryAuthenticateWithAttempt:1 completion:completion];
}

- (void)cancelAuthentication
{
	self.cancelRequested = YES;
}

- (BOOL)anisetteAvailable
{
	return self.anisetteHeaders.count > 0;
}

- (void)resetSession
{
	[self resetSessionState];
	self.appleId = nil;
	self.password = nil;
	self.authenticatedAppleId = nil;
	self.guid = nil;
}

- (void)getVersionsForAppId:(long long)appId completion:(WFSAppleIDVersionsCompletion)completion
{
	if (!self.authenticated)
	{
		[self finishVersions:completion versions:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNotAuthenticated message:@"Not signed in to Apple ID."]];
		return;
	}
	[self volumeStoreDownloadProductForAppId:appId versionId:0 completion:^(NSDictionary* song, NSDictionary* response, NSError* error)
	{
		if (error)
		{
			if (error.code == WFSAppleIDDownloaderErrorLicenseNotFound)
			{
				[self buyProductForAppId:appId completion:^(NSError* buyError)
				{
					if (buyError)
					{
						[self finishVersions:completion versions:nil metadata:nil error:buyError];
						return;
					}
					[self volumeStoreDownloadProductForAppId:appId versionId:0 completion:^(NSDictionary* song2, NSDictionary* response2, NSError* error2)
					{
						if (error2)
						{
							[self finishVersions:completion versions:nil metadata:nil error:error2];
							return;
						}
						[self finishVersions:completion versions:[self versionsFromSong:song2] metadata:[self metadataFromSong:song2] error:nil];
					}];
				}];
				return;
			}
			[self finishVersions:completion versions:nil metadata:nil error:error];
			return;
		}
		[self finishVersions:completion versions:[self versionsFromSong:song] metadata:[self metadataFromSong:song] error:nil];
	}];
}

- (void)getDownloadInfoForAppId:(long long)appId versionId:(long long)versionId completion:(WFSAppleIDDownloadInfoCompletion)completion
{
	if (!self.authenticated)
	{
		[self finishDownloadInfo:completion url:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNotAuthenticated message:@"Not signed in to Apple ID."]];
		return;
	}
	[self volumeStoreDownloadProductForAppId:appId versionId:versionId completion:^(NSDictionary* song, NSDictionary* response, NSError* error)
	{
		if (error)
		{
			[self finishDownloadInfo:completion url:nil metadata:nil error:error];
			return;
		}
		NSString* urlString = [self stringForKey:@"URL" in:song];
		NSURL* url = urlString.length ? [NSURL URLWithString:urlString] : nil;
		if (!url)
		{
			[self finishDownloadInfo:completion url:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNoSong message:@"Apple did not return a download URL for this app."]];
			return;
		}
		[self finishDownloadInfo:completion url:url metadata:[self metadataFromSong:song] error:nil];
	}];
}

- (void)getDownloadInfoForAdamId:(long long)adamId versionId:(long long)versionId autoPurchase:(BOOL)autoPurchase completion:(WFSAppleIDDownloadInfoCompletion)completion
{
	if (!self.authenticated)
	{
		[self finishDownloadInfo:completion url:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNotAuthenticated message:@"Not signed in to Apple ID. Use the authTest tab to sign in first."]];
		return;
	}
	NSMutableDictionary* body = [NSMutableDictionary dictionary];
	body[@"creditDisplay"] = @"";
	body[@"guid"] = self.guid;
	body[@"salableAdamId"] = [NSString stringWithFormat:@"%lld", adamId];
	if (versionId > 0)
	{
		body[@"externalVersionId"] = [NSString stringWithFormat:@"%lld", versionId];
	}
	NSString* urlString = [NSString stringWithFormat:@"https://%@/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=%@", [self buyHost], self.guid];
	self.lastDownloadEndpoint = urlString;
	[self postPlist:body toURL:[NSURL URLWithString:urlString] contentType:@"application/x-apple-plist" authenticated:YES tokenHeaders:NO completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			[self finishDownloadInfo:completion url:nil metadata:nil error:[self networkError:error]];
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"volumeStoreDownloadProduct(adamId=%lld, versionId=%lld) -> HTTP %ld (%lu bytes)", adamId, versionId, (long)response.statusCode, (unsigned long)data.length]];
		[self writeRawResponseData:data label:@"downloadTest"];
		if (response.statusCode == 429)
		{
			[self finishDownloadInfo:completion url:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorRateLimited message:@"Apple is rate limiting requests. Wait a few minutes and try again."]];
			return;
		}
		NSDictionary* dict = [self parsePlistResponse:data];
		if (!dict)
		{
			[self finishDownloadInfo:completion url:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Apple returned an invalid response."]];
			return;
		}
		NSString* failureType = [self stringForKey:@"failureType" in:dict];
		NSString* customerMessage = [self stringForKey:@"customerMessage" in:dict];
		if ([failureType isEqualToString:kWFSFailureTypeLicenseNotFound])
		{
			if (autoPurchase)
			{
				[self writeDebugLog:[NSString stringWithFormat:@"failureType %@ detected, purchasing license first", kWFSFailureTypeLicenseNotFound]];
				[self buyProductForAppId:adamId completion:^(NSError* buyError)
				{
					if (buyError)
					{
						[self finishDownloadInfo:completion url:nil metadata:nil error:buyError];
						return;
					}
					[self getDownloadInfoForAdamId:adamId versionId:versionId autoPurchase:NO completion:completion];
				}];
				return;
			}
			[self finishDownloadInfo:completion url:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorLicenseNotFound message:customerMessage.length ? customerMessage : @"No license found for this app. Enable auto-purchase to obtain one first."]];
			return;
		}
		NSError* failureError = [self failureErrorFromResponse:dict];
		if (failureError)
		{
			[self finishDownloadInfo:completion url:nil metadata:nil error:failureError];
			return;
		}
		NSArray* songList = dict[@"songList"];
		NSDictionary* song = nil;
		if ([songList isKindOfClass:[NSArray class]] && songList.count > 0)
		{
			song = songList[0];
		}
		if (![song isKindOfClass:[NSDictionary class]])
		{
			[self finishDownloadInfo:completion url:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNoSong message:@"Apple did not return download information for this app."]];
			return;
		}
		NSString* songURLString = [self stringForKey:@"URL" in:song];
		NSURL* songURL = songURLString.length ? [NSURL URLWithString:songURLString] : nil;
		if (!songURL)
		{
			[self finishDownloadInfo:completion url:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNoSong message:@"Apple did not return a download URL for this app."]];
			return;
		}
		NSDictionary* metadata = [song[@"metadata"] isKindOfClass:[NSDictionary class]] ? song[@"metadata"] : nil;
		[self finishDownloadInfo:completion url:songURL metadata:metadata error:nil];
	}];
}

- (void)getExternalVersionIdsForAdamId:(long long)adamId completion:(WFSAppleIDVersionsInfoCompletion)completion
{
	if (!self.authenticated)
	{
		[self finishVersionsInfo:completion externalVersionIds:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNotAuthenticated message:@"Not signed in to Apple ID. Use the authTest tab to sign in first."]];
		return;
	}
	NSDictionary* body = @{
		@"creditDisplay": @"",
		@"guid": self.guid,
		@"salableAdamId": [NSString stringWithFormat:@"%lld", adamId],
	};
	NSString* urlString = [NSString stringWithFormat:@"https://%@/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=%@", [self buyHost], self.guid];
	self.lastDownloadEndpoint = urlString;
	[self postPlist:body toURL:[NSURL URLWithString:urlString] contentType:@"application/x-apple-plist" authenticated:YES tokenHeaders:NO completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			[self finishVersionsInfo:completion externalVersionIds:nil metadata:nil error:[self networkError:error]];
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"listVersions(adamId=%lld) -> HTTP %ld (%lu bytes)", adamId, (long)response.statusCode, (unsigned long)data.length]];
		[self writeRawResponseData:data label:@"versionTest"];
		if (response.statusCode == 429)
		{
			[self finishVersionsInfo:completion externalVersionIds:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorRateLimited message:@"Apple is rate limiting requests. Wait a few minutes and try again."]];
			return;
		}
		NSDictionary* dict = [self parsePlistResponse:data];
		if (!dict)
		{
			[self finishVersionsInfo:completion externalVersionIds:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Apple returned an invalid response."]];
			return;
		}
		NSString* failureType = [self stringForKey:@"failureType" in:dict];
		if ([failureType isEqualToString:kWFSFailureTypeLicenseNotFound])
		{
			[self finishVersionsInfo:completion externalVersionIds:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorLicenseNotFound message:@"No license found for this app."]];
			return;
		}
		NSError* failureError = [self failureErrorFromResponse:dict];
		if (failureError)
		{
			[self finishVersionsInfo:completion externalVersionIds:nil metadata:nil error:failureError];
			return;
		}
		NSArray* songList = dict[@"songList"];
		NSDictionary* song = nil;
		if ([songList isKindOfClass:[NSArray class]] && songList.count > 0)
		{
			song = songList[0];
		}
		if (![song isKindOfClass:[NSDictionary class]])
		{
			[self finishVersionsInfo:completion externalVersionIds:nil metadata:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNoSong message:@"Apple did not return version information for this app."]];
			return;
		}
		NSDictionary* metadata = [song[@"metadata"] isKindOfClass:[NSDictionary class]] ? song[@"metadata"] : nil;
		id rawIdentifiers = metadata[@"softwareVersionExternalIdentifiers"];
		NSMutableArray* identifiers = [NSMutableArray array];
		if ([rawIdentifiers isKindOfClass:[NSArray class]])
		{
			for (id identifier in (NSArray*)rawIdentifiers)
			{
				[identifiers addObject:[self stringValueForObject:identifier]];
			}
		}
		[self finishVersionsInfo:completion externalVersionIds:identifiers metadata:metadata error:nil];
	}];
}

- (void)finishVersionsInfo:(WFSAppleIDVersionsInfoCompletion)completion externalVersionIds:(NSArray*)externalVersionIds metadata:(NSDictionary*)metadata error:(NSError*)error
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		completion(externalVersionIds, metadata, error);
	});
}

- (NSString*)stringValueForObject:(id)object
{
	if ([object isKindOfClass:[NSString class]])
	{
		return object;
	}
	if ([object isKindOfClass:[NSNumber class]])
	{
		return [object stringValue];
	}
	return @"";
}

- (void)searchPurchaseHistoryForBundleID:(NSString*)bundleID completion:(WFSAppleIDPurchaseSearchCompletion)completion
{
	if (!self.authenticated)
	{
		[self finishPurchaseSearch:completion purchase:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNotAuthenticated message:@"Not signed in to Apple ID."]];
		return;
	}
	if (bundleID.length == 0)
	{
		[self finishPurchaseSearch:completion purchase:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Bundle ID is required."]];
		return;
	}
	[self volumeStoreDownloadHistoryWithCompletion:^(NSArray* purchases, NSDictionary* response, NSError* error)
	{
		if (error)
		{
			[self finishPurchaseSearch:completion purchase:nil error:error];
			return;
		}
		NSDictionary* match = nil;
		for (NSDictionary* purchase in purchases)
		{
			NSString* candidateBundleID = [self stringForKey:@"bundleId" in:purchase];
			if (candidateBundleID.length && [candidateBundleID caseInsensitiveCompare:bundleID] == NSOrderedSame)
			{
				match = purchase;
				break;
			}
		}
		if (!match)
		{
			[self finishPurchaseSearch:completion purchase:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorLicenseNotFound message:[NSString stringWithFormat:@"No purchase found for bundle ID %@ in this Apple ID's history.", bundleID]]];
			return;
		}
		[self finishPurchaseSearch:completion purchase:match error:nil];
	}];
}

- (void)volumeStoreDownloadHistoryWithCompletion:(void (^)(NSArray* purchases, NSDictionary* response, NSError* error))completion
{
	NSDictionary* body = @{
		@"guid": self.guid,
		@"creditDisplay": @"",
	};
	NSString* urlString = [NSString stringWithFormat:@"https://%@/WebObjects/MZFinance.woa/wa/volumeStoreDownloadHistory?guid=%@", [self buyHost], self.guid];
	[self postPlist:body toURL:[NSURL URLWithString:urlString] contentType:@"application/x-apple-plist" authenticated:YES completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			completion(nil, nil, [self networkError:error]);
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"volumeStoreDownloadHistory -> HTTP %ld (%lu bytes)", (long)response.statusCode, (unsigned long)data.length]];
		[self writeRawResponseData:data label:@"history"];
		if (response.statusCode == 429)
		{
			completion(nil, nil, [self errorWithCode:WFSAppleIDDownloaderErrorRateLimited message:@"Apple is rate limiting requests. Wait a few minutes and try again."]);
			return;
		}
		NSDictionary* dict = [self parsePlistResponse:data];
		if (!dict)
		{
			completion(nil, nil, [self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Apple returned an invalid response to the purchase history request."]);
			return;
		}
		NSArray* songList = dict[@"songList"];
		NSMutableArray* purchases = [NSMutableArray array];
		if ([songList isKindOfClass:[NSArray class]])
		{
			for (id entry in songList)
			{
				NSDictionary* purchase = [self purchaseFromHistoryEntry:entry];
				if (purchase)
				{
					[purchases addObject:purchase];
				}
			}
		}
		[self writeDebugLog:[NSString stringWithFormat:@"volumeStoreDownloadHistory -> %lu purchase(s) parsed", (unsigned long)purchases.count]];
		completion(purchases, dict, nil);
	}];
}

- (void)getAllPurchaseHistoryWithCompletion:(void (^)(NSArray* purchases, NSDictionary* firstResponse, NSError* error))completion
{
	if (!self.authenticated)
	{
		[self finishHistory:completion purchases:nil response:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNotAuthenticated message:@"Not signed in to Apple ID. Use the authTest tab to sign in first."]];
		return;
	}
	[self fetchLockerDataWithRestoreMode:@"undefined" completion:^(NSArray* appIds, NSDictionary* response, NSError* error)
	{
		if (error)
		{
			[self finishHistory:completion purchases:nil response:nil error:error];
			return;
		}
		[self fetchLockerDataWithRestoreMode:@"true" completion:^(NSArray* hiddenAppIds, NSDictionary* hiddenResponse, NSError* hiddenError)
		{
			NSMutableArray* allAppIds = [NSMutableArray arrayWithArray:appIds];
			if (!hiddenError)
			{
				for (NSString* appId in hiddenAppIds)
				{
					if (appId.length && ![allAppIds containsObject:appId])
					{
						[allAppIds addObject:appId];
					}
				}
			}
			[self fetchContentDataForAppIds:allAppIds index:0 purchases:[NSMutableArray array] firstResponse:response completion:completion];
		}];
	}];
}

- (void)fetchLockerDataWithRestoreMode:(NSString*)restoreMode completion:(void (^)(NSArray* appIds, NSDictionary* response, NSError* error))completion
{
	NSString* storeFrontId = [self storeFrontIdForPurchases];
	NSString* urlString = [NSString stringWithFormat:@"https://se.itunes.apple.com/WebObjects/MZStoreElements.woa/wa/purchases?s=%@", storeFrontId];
	self.lastDownloadEndpoint = urlString;
	NSDictionary* params = @{
		@"action": @"POST",
		@"mt": @"8",
		@"vt": @"lockerData",
		@"restoreMode": restoreMode,
	};
	[self postForm:params toURL:[NSURL URLWithString:urlString] authenticated:YES completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			completion(nil, nil, [self networkError:error]);
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"purchases(lockerData, restoreMode=%@) -> HTTP %ld (%lu bytes)", restoreMode, (long)response.statusCode, (unsigned long)data.length]];
		[self writeRawResponseData:data label:@"history"];
		if (response.statusCode == 429)
		{
			completion(nil, nil, [self errorWithCode:WFSAppleIDDownloaderErrorRateLimited message:@"Apple is rate limiting requests. Wait a few minutes and try again."]);
			return;
		}
		NSDictionary* json = [self parseJSONResponse:data];
		if (!json)
		{
			NSString* upgradeMessage = [self upgradePageMessageFromData:data];
			if (upgradeMessage)
			{
				completion(nil, nil, [self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:upgradeMessage]);
				return;
			}
			NSString* contentType = response.allHeaderFields[@"Content-Type"];
			if (![contentType isKindOfClass:[NSString class]])
			{
				contentType = @"?";
			}
			NSString* excerpt = [self responseExcerptFromData:data];
			completion(nil, nil, [self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:[NSString stringWithFormat:@"Apple returned an invalid response to the purchase history request (HTTP %ld, %@): %@", (long)response.statusCode, contentType, excerpt]]);
			return;
		}
		if ([json[@"dialog"] isKindOfClass:[NSDictionary class]])
		{
			NSString* kind = [self stringForKey:@"kind" in:json[@"dialog"]];
			completion(nil, nil, [self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:[NSString stringWithFormat:@"Apple's purchases endpoint requires account sign-in (dialog: %@).", kind.length ? kind : @"authorization"]]);
			return;
		}
		NSDictionary* apps = json[@"Apps"];
		NSMutableArray* appIds = [NSMutableArray array];
		if ([apps isKindOfClass:[NSDictionary class]])
		{
			NSArray* sortedKeys = [apps.allKeys sortedArrayUsingSelector:@selector(compare:)];
			for (NSString* appId in sortedKeys)
			{
				if (appId.length)
				{
					[appIds addObject:appId];
				}
			}
		}
		[self writeDebugLog:[NSString stringWithFormat:@"purchases(lockerData, restoreMode=%@) -> %lu app(s)", restoreMode, (unsigned long)appIds.count]];
		completion(appIds, json, nil);
	}];
}

- (void)fetchContentDataForAppIds:(NSArray*)appIds index:(NSUInteger)index purchases:(NSMutableArray*)purchases firstResponse:(NSDictionary*)firstResponse completion:(void (^)(NSArray* purchases, NSDictionary* firstResponse, NSError* error))completion
{
	if (index >= appIds.count)
	{
		[self finishHistory:completion purchases:purchases response:firstResponse error:nil];
		return;
	}
	NSUInteger chunkSize = 50;
	NSUInteger count = MIN(chunkSize, appIds.count - index);
	NSArray* chunk = [appIds subarrayWithRange:NSMakeRange(index, count)];
	NSString* contentIds = [chunk componentsJoinedByString:@","];
	NSString* storeFrontId = [self storeFrontIdForPurchases];
	NSString* urlString = [NSString stringWithFormat:@"https://se.itunes.apple.com/WebObjects/MZStoreElements.woa/wa/purchases?s=%@", storeFrontId];
	NSDictionary* params = @{
		@"action": @"POST",
		@"contentIds": contentIds,
		@"pillId": @"0",
		@"mt": @"8",
		@"sortValue": @"0",
		@"vt": @"contentData",
		@"restoreMode": @"undefined",
	};
	[self postForm:params toURL:[NSURL URLWithString:urlString] authenticated:YES completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			[self finishHistory:completion purchases:purchases response:firstResponse error:[self networkError:error]];
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"purchases(contentData, %lu ids) -> HTTP %ld (%lu bytes)", (unsigned long)count, (long)response.statusCode, (unsigned long)data.length]];
		[self writeRawResponseData:data label:@"history"];
		if (response.statusCode == 429)
		{
			[self finishHistory:completion purchases:purchases response:firstResponse error:[self errorWithCode:WFSAppleIDDownloaderErrorRateLimited message:@"Apple is rate limiting requests. Wait a few minutes and try again."]];
			return;
		}
		NSDictionary* json = [self parseJSONResponse:data];
		if (!json)
		{
			NSString* upgradeMessage = [self upgradePageMessageFromData:data];
			if (upgradeMessage)
			{
				[self finishHistory:completion purchases:purchases response:firstResponse error:[self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:upgradeMessage]];
				return;
			}
			NSString* contentType = response.allHeaderFields[@"Content-Type"];
			if (![contentType isKindOfClass:[NSString class]])
			{
				contentType = @"?";
			}
			NSString* excerpt = [self responseExcerptFromData:data];
			[self finishHistory:completion purchases:purchases response:firstResponse error:[self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:[NSString stringWithFormat:@"Apple returned an invalid response for purchase metadata (HTTP %ld, %@): %@", (long)response.statusCode, contentType, excerpt]]];
			return;
		}
		NSDictionary* apps = json[@"Apps"];
		NSUInteger resolved = 0;
		if ([apps isKindOfClass:[NSDictionary class]])
		{
			for (NSString* appId in chunk)
			{
				NSDictionary* meta = apps[appId];
				NSMutableDictionary* purchase = [NSMutableDictionary dictionary];
				purchase[@"adamId"] = appId;
				if ([meta isKindOfClass:[NSDictionary class]])
				{
					resolved++;
					NSString* title = [self stringForKey:@"name" in:meta];
					if (!title.length)
					{
						title = [self stringForKey:@"displayName" in:meta];
					}
					if (title.length)
					{
						purchase[@"title"] = title;
					}
					NSString* bundleId = [self stringForKey:@"bundleId" in:meta];
					if (bundleId.length)
					{
						purchase[@"bundleId"] = bundleId;
					}
					NSString* purchaseDate = [self stringForKey:@"purchaseDate" in:meta];
					if (purchaseDate.length)
					{
						purchase[@"purchaseDate"] = purchaseDate;
					}
					purchase[@"metadata"] = meta;
				}
				[purchases addObject:purchase];
			}
		}
		[self writeDebugLog:[NSString stringWithFormat:@"purchases(contentData) -> %lu/%lu resolved", (unsigned long)resolved, (unsigned long)count]];
		if (self.historyProgressHandler)
		{
			self.historyProgressHandler((NSInteger)index, (NSInteger)count, (NSInteger)purchases.count);
		}
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^
		{
			[self fetchContentDataForAppIds:appIds index:index + count purchases:purchases firstResponse:firstResponse completion:completion];
		});
	}];
}

- (NSString*)storeFrontIdForPurchases
{
	if (self.storeFront.length)
	{
		NSArray* components = [self.storeFront componentsSeparatedByString:@"-"];
		if (components.count && [components[0] length])
		{
			return components[0];
		}
	}
	return @"143441";
}

- (void)finishCommerceHistory:(WFSAppleIDHistoryCompletion)completion purchases:(NSArray*)purchases response:(NSDictionary*)response error:(NSError*)error
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		completion(purchases, response, error);
	});
}

- (void)fetchCommercePurchaseHistoryWithRange:(NSString*)range page:(NSInteger)page paginationToken:(NSString*)paginationToken completion:(WFSAppleIDHistoryCompletion)completion
{
	NSString* tokenParam = @"";
	if (paginationToken.length)
	{
		tokenParam = [NSString stringWithFormat:@"&pagination-token=%@", [self percentEncode:paginationToken]];
	}
	NSString* urlString = [NSString stringWithFormat:@"https://%@/commerce/account/purchases?guid=%@&range=%@&page=%ld%@", [self buyHost], [self percentEncode:self.guid], [self percentEncode:range], (long)page, tokenParam];
	self.lastDownloadEndpoint = urlString;
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
	[request setValue:kWFSCommerceUA forHTTPHeaderField:@"User-Agent"];
	[request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
	[request setValue:@"en-US,en;q=0.5" forHTTPHeaderField:@"Accept-Language"];
	if (self.dsid.length)
	{
		[request setValue:self.dsid forHTTPHeaderField:@"X-Dsid"];
		[request setValue:self.dsid forHTTPHeaderField:@"iCloud-Dsid"];
	}
	NSString* storeFrontId = [self storeFrontIdForPurchases];
	if (storeFrontId.length)
	{
		[request setValue:storeFrontId forHTTPHeaderField:@"X-Apple-Store-Front"];
	}
	NSInteger tzOffsetMinutes = [[NSTimeZone localTimeZone] secondsFromGMT] / 60;
	[request setValue:[NSString stringWithFormat:@"%ld", (long)tzOffsetMinutes] forHTTPHeaderField:@"X-Apple-TZ"];
	[[self.session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		if (error)
		{
			[self finishCommerceHistory:completion purchases:nil response:nil error:[self networkError:error]];
			return;
		}
		NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
		[self writeDebugLog:[NSString stringWithFormat:@"commerce/account/purchases (range=%@, page=%ld) -> HTTP %ld (%lu bytes)", range, (long)page, (long)http.statusCode, (unsigned long)data.length]];
		[self writeRawResponseData:data label:@"commerce"];
		if (http.statusCode == 204)
		{
			[self writeDebugLog:[NSString stringWithFormat:@"commerce/account/purchases -> 204 (no purchases in range)"]];
			[self finishCommerceHistory:completion purchases:@[] response:@{} error:nil];
			return;
		}
		if (http.statusCode != 200)
		{
			NSDictionary* errorJson = [self parseJSONResponse:data];
			if (errorJson && [errorJson[@"errors"] isKindOfClass:[NSArray class]])
			{
				NSString* code = @"";
				for (id entry in errorJson[@"errors"])
				{
					if ([entry isKindOfClass:[NSDictionary class]])
					{
						code = [self stringForKey:@"code" in:(NSDictionary*)entry];
						if (code.length)
						{
							break;
						}
					}
				}
				if ([code isEqualToString:@"authentication"])
				{
					[self finishCommerceHistory:completion purchases:nil response:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:@"Apple rejected the commerce request as unauthenticated. The stored sign-in session may be expired; sign in again."]];
					return;
				}
				[self finishCommerceHistory:completion purchases:nil response:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:[NSString stringWithFormat:@"Commerce API error (HTTP %ld, code %@)", (long)http.statusCode, code.length ? code : @"?"]]];
				return;
			}
			NSString* contentType = http.allHeaderFields[@"Content-Type"];
			if (![contentType isKindOfClass:[NSString class]])
			{
				contentType = @"?";
			}
			[self finishCommerceHistory:completion purchases:nil response:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:[NSString stringWithFormat:@"Commerce API returned HTTP %ld (%@): %@", (long)http.statusCode, contentType, [self responseExcerptFromData:data]]]];
			return;
		}
		NSDictionary* json = [self parseJSONResponse:data];
		if (!json)
		{
			[self finishCommerceHistory:completion purchases:nil response:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:[NSString stringWithFormat:@"Commerce API returned invalid JSON (HTTP %ld): %@", (long)http.statusCode, [self responseExcerptFromData:data]]]];
			return;
		}
		NSMutableArray* purchases = [NSMutableArray array];
		NSArray* orders = json[@"purchases"];
		if ([orders isKindOfClass:[NSArray class]])
		{
			for (id orderObj in orders)
			{
				if (![orderObj isKindOfClass:[NSDictionary class]])
				{
					continue;
				}
				NSDictionary* order = (NSDictionary*)orderObj;
				NSString* orderId = [self stringForKey:@"order-id" in:order];
				NSString* invoiceDate = [self stringForKey:@"invoice-date" in:order];
				NSArray* items = order[@"items"];
				if ([items isKindOfClass:[NSArray class]])
				{
					for (id itemObj in items)
					{
						if (![itemObj isKindOfClass:[NSDictionary class]])
						{
							continue;
						}
						NSDictionary* item = (NSDictionary*)itemObj;
						NSMutableDictionary* purchase = [NSMutableDictionary dictionary];
						NSString* adamId = [self stringForKey:@"item-id" in:item];
						if (!adamId.length)
						{
							adamId = [self stringForKey:@"itemId" in:item];
						}
						if (adamId.length)
						{
							purchase[@"adamId"] = adamId;
						}
						NSString* title = [self stringForKey:@"item-name" in:item];
						if (!title.length)
						{
							title = [self stringForKey:@"item-title" in:item];
						}
						if (title.length)
						{
							purchase[@"title"] = title;
						}
						NSString* bundleId = [self stringForKey:@"bundle-id" in:item];
						if (!bundleId.length)
						{
							bundleId = [self stringForKey:@"bundleId" in:item];
						}
						if (bundleId.length)
						{
							purchase[@"bundleId"] = bundleId;
						}
						NSString* purchaseDate = [self stringForKey:@"purchase-date" in:item];
						if (!purchaseDate.length)
						{
							purchaseDate = invoiceDate;
						}
						if (purchaseDate.length)
						{
							purchase[@"purchaseDate"] = purchaseDate;
						}
						NSMutableDictionary* metadata = [NSMutableDictionary dictionaryWithDictionary:item];
						if (orderId.length)
						{
							metadata[@"order-id"] = orderId;
						}
						if (invoiceDate.length)
						{
							metadata[@"invoice-date"] = invoiceDate;
						}
						purchase[@"metadata"] = metadata;
						[purchases addObject:purchase];
					}
				}
			}
		}
		[self writeDebugLog:[NSString stringWithFormat:@"commerce/account/purchases -> %lu purchase(s)", (unsigned long)purchases.count]];
		[self finishCommerceHistory:completion purchases:purchases response:json error:nil];
	}] resume];
}

- (void)finishHistory:(WFSAppleIDHistoryCompletion)completion purchases:(NSArray*)purchases response:(NSDictionary*)response error:(NSError*)error
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		completion(purchases, response, error);
	});
}

- (NSDictionary*)purchaseFromHistoryEntry:(id)entry
{
	if (![entry isKindOfClass:[NSDictionary class]])
	{
		return nil;
	}
	NSDictionary* dict = (NSDictionary*)entry;
	NSDictionary* metadata = dict[@"metadata"];
	if (![metadata isKindOfClass:[NSDictionary class]])
	{
		metadata = nil;
	}
	NSString* bundleId = [self stringForKey:@"softwareVersionBundleId" in:metadata];
	if (!bundleId.length)
	{
		bundleId = [self stringForKey:@"bundleId" in:dict];
	}
	NSString* adamId = [self stringForKey:@"itemId" in:dict];
	if (!adamId.length)
	{
		adamId = [self stringForKey:@"songId" in:dict];
	}
	if (!adamId.length)
	{
		adamId = [self stringForKey:@"adamId" in:metadata];
	}
	if (!adamId.length)
	{
		return nil;
	}
	NSMutableDictionary* purchase = [NSMutableDictionary dictionary];
	purchase[@"adamId"] = adamId;
	if (bundleId.length)
	{
		purchase[@"bundleId"] = bundleId;
	}
	NSString* title = [self stringForKey:@"title" in:metadata];
	if (!title.length)
	{
		title = [self stringForKey:@"title" in:dict];
	}
	if (title.length)
	{
		purchase[@"title"] = title;
	}
	NSString* purchaseDate = [self stringForKey:@"purchaseDate" in:dict];
	if (!purchaseDate.length)
	{
		purchaseDate = [self stringForKey:@"purchaseDate" in:metadata];
	}
	if (purchaseDate.length)
	{
		purchase[@"purchaseDate"] = purchaseDate;
	}
	if (metadata)
	{
		purchase[@"metadata"] = metadata;
	}
	return purchase;
}

#pragma mark - Authentication

- (void)tryAuthenticateWithAttempt:(NSInteger)attempt completion:(WFSAppleIDAuthCompletion)completion
{
	NSMutableArray* diagnostics = [NSMutableArray array];
	[self fetchAnisetteHeadersWithCompletion:^(NSDictionary* anisetteHeaders)
	{
		self.anisetteHeaders = anisetteHeaders;
		if (anisetteHeaders.count)
		{
			[diagnostics addObject:@"ani.sidestore.io -> anisette headers received"];
		}
		else
		{
			[diagnostics addObject:@"ani.sidestore.io: anisette unavailable, continuing without"];
		}
		[self resolveFastAuthEndpoint:^(NSString* resolvedEndpoint)
		{
			if (resolvedEndpoint.length)
			{
				[diagnostics addObject:[NSString stringWithFormat:@"bag.xml -> %@", resolvedEndpoint]];
			}
			else
			{
				[diagnostics addObject:@"bag.xml: no authenticateAccount key, using built-in endpoints"];
			}
			NSMutableArray* candidates = [NSMutableArray array];
			[candidates addObject:kWFSLegacyAuthEndpoint];
			if (resolvedEndpoint.length)
			{
				[candidates addObject:resolvedEndpoint];
			}
			[candidates addObject:kWFSFastAuthEndpoint];
			[self tryAuthEndpointCandidates:candidates index:0 attempt:attempt retryCount:0 diagnostics:diagnostics completion:completion];
		}];
	}];
}

- (void)fetchAnisetteHeadersWithCompletion:(void (^)(NSDictionary* headers))completion
{
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kWFSAnisetteEndpoint]];
	request.HTTPMethod = @"GET";
	[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
	[request setTimeoutInterval:15];
	[[self.session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		if (error || !data.length)
		{
			completion(nil);
			return;
		}
		if (((NSHTTPURLResponse*)response).statusCode != 200)
		{
			completion(nil);
			return;
		}
		id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
		if (![obj isKindOfClass:[NSDictionary class]])
		{
			completion(nil);
			return;
		}
		NSMutableDictionary* headers = [NSMutableDictionary dictionary];
		for (NSString* key in (NSDictionary*)obj)
		{
			id value = ((NSDictionary*)obj)[key];
			if ([value isKindOfClass:[NSString class]] && ((NSString*)value).length)
			{
				headers[key] = value;
			}
		}
		completion(headers);
	}] resume];
}

- (void)resolveFastAuthEndpoint:(void (^)(NSString* endpoint))completion
{
	NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:kWFSInitBagEndpoint, self.guid]];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	[request setValue:@"application/xml" forHTTPHeaderField:@"Accept"];
	[request setValue:kWFSConfiguratorUA forHTTPHeaderField:@"User-Agent"];
	[[self.session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		if (error || !data.length)
		{
			completion(nil);
			return;
		}
		NSDictionary* bag = [self parsePlistResponse:data];
		NSString* endpoint = nil;
		if ([bag isKindOfClass:[NSDictionary class]])
		{
			endpoint = [self stringForKey:@"authenticateAccount" in:bag];
			if (!endpoint.length)
			{
				NSDictionary* urlBag = bag[@"urlBag"];
				if ([urlBag isKindOfClass:[NSDictionary class]])
				{
					endpoint = [self stringForKey:@"authenticateAccount" in:urlBag];
				}
			}
			if (endpoint.length)
			{
				endpoint = [self authenticateURLString:endpoint];
			}
		}
		completion(endpoint);
	}] resume];
}

- (NSString*)authenticateURLString:(NSString*)endpoint
{
	if (!endpoint.length)
	{
		return endpoint;
	}
	if ([endpoint containsString:@"/native/"] && ![endpoint hasSuffix:@"/"])
	{
		return [endpoint stringByAppendingString:@"/"];
	}
	return endpoint;
}

- (void)tryAuthEndpointCandidates:(NSArray*)candidates index:(NSUInteger)index attempt:(NSInteger)attempt retryCount:(NSInteger)retryCount diagnostics:(NSMutableArray*)diagnostics completion:(WFSAppleIDAuthCompletion)completion
{
	if (self.cancelRequested)
	{
		[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderErrorCancelled message:@"Sign-in was cancelled."]];
		return;
	}
	if (self.authProgressHandler)
	{
		NSInteger total = MAX(kWFSMaxAuthAttempts, 1);
		NSInteger reportedAttempt = MIN(retryCount + 1, total);
		dispatch_async(dispatch_get_main_queue(), ^
		{
			self.authProgressHandler((NSUInteger)reportedAttempt, (NSUInteger)total);
		});
	}
	if (retryCount >= kWFSMaxAuthAttempts)
	{
		[self finishAuth:completion error:[self authExhaustedErrorWithDiagnostics:diagnostics]];
		return;
	}
	NSString* candidate = candidates[index % candidates.count];
	NSDictionary* body = @{
		@"appleId": self.appleId,
		@"password": self.password,
		@"attempt": [NSString stringWithFormat:@"%ld", (long)attempt],
		@"guid": self.guid,
		@"rmp": @"0",
		@"why": @"signIn",
	};
	[self postAuthBody:body toURLString:candidate attempt:attempt retryCount:retryCount redirects:0 candidates:candidates index:index diagnostics:diagnostics completion:completion];
}

- (void)postAuthBody:(NSDictionary*)body toURLString:(NSString*)urlString attempt:(NSInteger)attempt retryCount:(NSInteger)retryCount redirects:(NSInteger)redirects candidates:(NSArray*)candidates index:(NSUInteger)index diagnostics:(NSMutableArray*)diagnostics completion:(WFSAppleIDAuthCompletion)completion
{
	[self postPlist:body toURL:[NSURL URLWithString:urlString] contentType:@"application/x-www-form-urlencoded" authenticated:NO tokenHeaders:NO additionalHeaders:self.anisetteHeaders completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			NSString* detail = error ? [NSString stringWithFormat:@"transport error: %@", error.localizedDescription] : @"empty response body";
			[diagnostics addObject:[NSString stringWithFormat:@"POST %@ -> %@ (%@)", urlString, response ? [NSString stringWithFormat:@"HTTP %ld", (long)response.statusCode] : @"no response", detail]];
			[self retryAuthWithCandidates:candidates index:index + 1 attempt:attempt retryCount:retryCount diagnostics:diagnostics completion:completion];
			return;
		}
		[diagnostics addObject:[NSString stringWithFormat:@"POST %@ -> HTTP %ld (%lu bytes)", urlString, (long)response.statusCode, (unsigned long)data.length]];
		self.lastAuthEndpoint = urlString;
		NSDictionary* authDict = [self parsePlistResponse:data];
		NSString* authFailureType = authDict ? [self stringForKey:@"failureType" in:authDict] : nil;
		NSString* authMessage = authDict ? [self stringForKey:@"customerMessage" in:authDict] : nil;
		[diagnostics addObject:[NSString stringWithFormat:@"  failureType=%@ customerMessage=%@", authFailureType ?: @"(non-plist)", authMessage ?: @"(none)"]];
		[self writeRawResponseData:data label:@"auth"];
		if (response.statusCode >= 300 && response.statusCode < 400)
		{
			NSString* location = response.allHeaderFields[@"Location"];
			if (location.length && redirects < kWFSMaxRedirects)
			{
				[diagnostics addObject:[NSString stringWithFormat:@"  following HTTP %ld redirect to %@", (long)response.statusCode, location]];
				[self postAuthBody:body toURLString:location attempt:attempt retryCount:retryCount redirects:redirects + 1 candidates:candidates index:index diagnostics:diagnostics completion:completion];
				return;
			}
		}
		NSError* processError = [self processAuthResponseData:data httpResponse:response attempt:attempt];
		if (!processError)
		{
			[self finishAuth:completion error:nil];
			return;
		}
		if (processError.code == WFSAppleIDDownloaderError2FARequired || processError.code == WFSAppleIDDownloaderErrorBrowserSignInRequired)
		{
			[self writeAuthDiagnostics:diagnostics];
			[self finishAuth:completion error:processError];
			return;
		}
		[diagnostics addObject:[NSString stringWithFormat:@"  unusable response: %@", processError.localizedDescription]];
		NSInteger nextAttempt = [processError.userInfo[@"wfsTransientRetry"] boolValue] ? attempt + 1 : attempt;
		[self retryAuthWithCandidates:candidates index:index + 1 attempt:nextAttempt retryCount:retryCount diagnostics:diagnostics completion:completion];
	}];
}

- (void)retryAuthWithCandidates:(NSArray*)candidates index:(NSUInteger)index attempt:(NSInteger)attempt retryCount:(NSInteger)retryCount diagnostics:(NSMutableArray*)diagnostics completion:(WFSAppleIDAuthCompletion)completion
{
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		[self tryAuthEndpointCandidates:candidates index:index attempt:attempt retryCount:retryCount + 1 diagnostics:diagnostics completion:completion];
	});
}

- (NSError*)authExhaustedErrorWithDiagnostics:(NSMutableArray*)diagnostics
{
	[self writeAuthDiagnostics:diagnostics];

	BOOL anyServerResponse = NO;
	for (NSString* line in diagnostics)
	{
		if ([line containsString:@"HTTP"])
		{
			anyServerResponse = YES;
			break;
		}
	}
	if (anyServerResponse)
	{
		NSString* message = [NSString stringWithFormat:@"Apple's servers were reached but did not return a valid sign-in response after %ld attempts. This can happen during peak times — try again in a minute, and check the Apple ID and password. Details were saved to WaffleStore_appleid.log in the Files app.", (long)kWFSMaxAuthAttempts];
		return [self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:message];
	}
	NSString* message = @"Could not reach Apple's authentication servers. Check your internet connection and try again. Details were saved to WaffleStore_appleid.log in the Files app.";
	return [self errorWithCode:WFSAppleIDDownloaderErrorNetwork message:message];
}

- (NSError*)processAuthResponseData:(NSData*)data httpResponse:(NSHTTPURLResponse*)httpResponse attempt:(NSInteger)attempt
{
	NSInteger statusCode = httpResponse.statusCode;
	if (statusCode == 204 || statusCode == 403 || statusCode == 404 || statusCode == 503 || (statusCode == 200 && !data.length))
	{
		return [self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Apple's sign-in endpoint returned an empty response."];
	}
	NSDictionary* dict = [self parsePlistResponse:data];
	if (!dict)
	{
		return [self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Apple returned an invalid response."];
	}
	NSString* failureType = [self stringForKey:@"failureType" in:dict];
	NSString* customerMessage = [self stringForKey:@"customerMessage" in:dict];
	if (attempt == 1 && [failureType isEqualToString:kWFSFailureTypeInvalidCredentials])
	{
		return [self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Apple reported a transient sign-in error; retrying." userInfo:@{@"wfsTransientRetry": @YES}];
	}
	if (failureType.length == 0 && !self.twoFactorCodeSent && [customerMessage isEqualToString:kWFSBadLoginMessage])
	{
		return [self errorWithCode:WFSAppleIDDownloaderError2FARequired message:@"Two-factor authentication code required. Apple sent a verification code to your trusted devices."];
	}
	if (self.twoFactorCodeSent && [customerMessage isEqualToString:kWFSBadLoginMessage])
	{
		return [self errorWithCode:WFSAppleIDDownloaderError2FARequired message:@"The verification code was rejected."];
	}
	if ([customerMessage isEqualToString:kWFSAccountDisabledMessage])
	{
		return [self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:kWFSAccountDisabledMessage];
	}
	if (customerMessage && [customerMessage containsString:@"AMD-Action::SP"])
	{
		return [self errorWithCode:WFSAppleIDDownloaderErrorBrowserSignInRequired message:@"This Apple ID requires sign-in approval from a browser. Try signing in on a computer first, then try again."];
	}
	if (failureType.length)
	{
		NSString* message = customerMessage.length ? customerMessage : @"Apple authentication failed.";
		if ([customerMessage isEqualToString:kWFSBadLoginMessage])
		{
			message = @"Apple ID or password was entered incorrectly.";
		}
		return [self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:message];
	}
	if (statusCode != 200)
	{
		return [self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:@"Apple returned an unexpected status for sign-in."];
	}
	NSString* passwordToken = [self stringForKey:@"passwordToken" in:dict];
	NSString* dsid = nil;
	NSDictionary* downloadQueueInfo = dict[@"download_queue_info"];
	if (![downloadQueueInfo isKindOfClass:[NSDictionary class]])
	{
		downloadQueueInfo = dict[@"downloadQueueInfo"];
	}
	if ([downloadQueueInfo isKindOfClass:[NSDictionary class]])
	{
		dsid = [self stringForKey:@"dsid" in:downloadQueueInfo];
	}
	if (!dsid.length)
	{
		dsid = [self stringForKey:@"dsPersonId" in:dict];
	}
	if (!passwordToken.length || !dsid.length)
	{
		NSString* message = customerMessage.length ? customerMessage : @"Apple authentication did not return credentials.";
		return [self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:message];
	}
	self.dsid = dsid;
	self.token = passwordToken;
	self.storeFront = nil;
	self.pod = nil;
	NSDictionary* headers = httpResponse.allHeaderFields;
	NSString* storeFront = headers[@"x-set-apple-store-front"];
	if (storeFront.length)
	{
		self.storeFront = storeFront;
	}
	NSString* pod = headers[@"pod"];
	if (!pod.length)
	{
		pod = headers[@"itspod"];
	}
	if (pod.length)
	{
		self.pod = pod;
	}
	self.authenticated = YES;
	[[NSUserDefaults standardUserDefaults] setObject:self.appleId forKey:@"wfsAppleIDEmail"];
	return nil;
}

- (void)finishAuth:(WFSAppleIDAuthCompletion)completion error:(NSError*)error
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		completion(error);
	});
}

#pragma mark - Store endpoints

- (void)volumeStoreDownloadProductForAppId:(long long)appId versionId:(long long)versionId completion:(void (^)(NSDictionary* song, NSDictionary* response, NSError* error))completion
{
	NSMutableDictionary* body = [NSMutableDictionary dictionary];
	body[@"creditDisplay"] = @"";
	body[@"guid"] = self.guid;
	body[@"salableAdamId"] = [NSString stringWithFormat:@"%lld", appId];
	if (versionId > 0)
	{
		body[@"externalVersionId"] = [NSString stringWithFormat:@"%lld", versionId];
	}
	NSString* urlString = [NSString stringWithFormat:@"https://%@/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=%@", [self buyHost], self.guid];
	[self postPlist:body toURL:[NSURL URLWithString:urlString] contentType:@"application/x-apple-plist" authenticated:YES tokenHeaders:NO completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			completion(nil, nil, [self networkError:error]);
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"volumeStoreDownloadProduct(appId=%lld, versionId=%lld) -> HTTP %ld (%lu bytes)", appId, versionId, (long)response.statusCode, (unsigned long)data.length]];
		[self writeRawResponseData:data label:@"downloadProduct"];
		if (response.statusCode == 429)
		{
			completion(nil, nil, [self errorWithCode:WFSAppleIDDownloaderErrorRateLimited message:@"Apple is rate limiting requests. Wait a few minutes and try again."]);
			return;
		}
		NSDictionary* dict = [self parsePlistResponse:data];
		if (!dict)
		{
			completion(nil, nil, [self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Apple returned an invalid response."]);
			return;
		}
		NSString* failureType = [self stringForKey:@"failureType" in:dict];
		NSString* customerMessage = [self stringForKey:@"customerMessage" in:dict];
		if ([failureType isEqualToString:kWFSFailureTypePasswordTokenExpired] ||
			[failureType isEqualToString:kWFSFailureTypeSignInRequired] ||
			[failureType isEqualToString:kWFSFailureTypeDeviceVerificationFailed] ||
			[failureType isEqualToString:kWFSFailureTypeLicenseAlreadyExists])
		{
			[self writeDebugLog:@"volumeStoreDownloadProduct: session expired (token expired / sign-in required)"];
			completion(nil, dict, [self errorWithCode:WFSAppleIDDownloaderErrorPasswordTokenExpired message:@"Your Apple ID session has expired. Sign in again."]);
			return;
		}
		if ([failureType isEqualToString:kWFSFailureTypeLicenseNotFound])
		{
			completion(nil, dict, [self errorWithCode:WFSAppleIDDownloaderErrorLicenseNotFound message:customerMessage.length ? customerMessage : @"This Apple ID has not purchased this app."]);
			return;
		}
		if (failureType.length || customerMessage.length)
		{
			NSError* failureError = [self failureErrorFromResponse:dict];
			completion(nil, dict, failureError);
			return;
		}
		NSArray* songList = dict[@"songList"];
		NSDictionary* song = nil;
		if ([songList isKindOfClass:[NSArray class]] && songList.count > 0)
		{
			song = songList[0];
		}
		if (![song isKindOfClass:[NSDictionary class]])
		{
			completion(nil, dict, [self errorWithCode:WFSAppleIDDownloaderErrorNoSong message:@"Apple did not return download information for this app."]);
			return;
		}
		completion(song, dict, nil);
	}];
}

- (void)buyProductForAppId:(long long)appId completion:(void (^)(NSError* error))completion
{
	[self buyProductForAppId:appId pricingParameters:kWFSPricingParameterAppStore completion:completion];
}

- (void)buyProductForAppId:(long long)appId pricingParameters:(NSString*)pricingParameters completion:(void (^)(NSError* error))completion
{
	NSDictionary* body = @{
		@"guid": self.guid,
		@"salableAdamId": [NSString stringWithFormat:@"%lld", appId],
		@"appExtVrsId": @"0",
		@"price": @"0",
		@"productType": @"C",
		@"pricingParameters": pricingParameters,
		@"hasAskedToFulfillPreorder": @"true",
		@"buyWithoutAuthorization": @"true",
		@"hasDoneAgeCheck": @"true",
		@"needDiv": @"0",
		@"origPage": [NSString stringWithFormat:@"Software-%lld", appId],
		@"origPageLocation": @"Buy",
	};
	NSString* urlString = [NSString stringWithFormat:@"https://%@/WebObjects/MZFinance.woa/wa/buyProduct", [self buyHost]];
	[self postPlist:body toURL:[NSURL URLWithString:urlString] contentType:@"application/x-apple-plist" authenticated:YES tokenHeaders:YES completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			completion([self networkError:error]);
			return;
		}
		if (response.statusCode == 500)
		{
			completion(nil);
			return;
		}
		NSDictionary* dict = [self parsePlistResponse:data];
		if (!dict)
		{
			completion([self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Apple returned an invalid response."]);
			return;
		}
		NSString* failureType = [self stringForKey:@"failureType" in:dict];
		NSString* customerMessage = [self stringForKey:@"customerMessage" in:dict];
		if ([failureType isEqualToString:kWFSFailureTypeTemporarilyUnavailable])
		{
			[self writeDebugLog:@"buyProduct: temporarily unavailable, retrying with GAME pricing parameter"];
			[self buyProductForAppId:appId pricingParameters:kWFSPricingParameterAppleArcade completion:completion];
			return;
		}
		if ([customerMessage isEqualToString:kWFSSubscriptionRequiredMessage])
		{
			completion([self errorWithCode:WFSAppleIDDownloaderErrorPurchaseFailed message:kWFSSubscriptionRequiredMessage]);
			return;
		}
		if ([failureType isEqualToString:kWFSFailureTypePasswordTokenExpired] ||
			[failureType isEqualToString:kWFSFailureTypeSignInRequired] ||
			[failureType isEqualToString:kWFSFailureTypeDeviceVerificationFailed] ||
			[customerMessage isEqualToString:kWFSPasswordChangedMessage])
		{
			completion([self errorWithCode:WFSAppleIDDownloaderErrorPasswordTokenExpired message:@"Your Apple ID session has expired. Sign in again."]);
			return;
		}
		if ([failureType isEqualToString:kWFSFailureTypeLicenseAlreadyExists])
		{
			completion(nil);
			return;
		}
		if (failureType.length || customerMessage.length)
		{
			completion([self errorWithCode:WFSAppleIDDownloaderErrorPurchaseFailed message:customerMessage.length ? customerMessage : @"The app could not be purchased."]);
			return;
		}
		NSString* docType = [self stringForKey:@"jingleDocType" in:dict];
		NSString* status = [self stringForKey:@"status" in:dict];
		if (![docType isEqualToString:@"purchaseSuccess"] || (status.length && ![status isEqualToString:@"0"]))
		{
			completion([self errorWithCode:WFSAppleIDDownloaderErrorPurchaseFailed message:customerMessage.length ? customerMessage : @"The app could not be purchased."]);
			return;
		}
		completion(nil);
	}];
}

- (NSError*)failureErrorFromResponse:(NSDictionary*)dict
{
	id cancelBatch = dict[@"cancel_purchase_batch"];
	if (cancelBatch == nil)
	{
		cancelBatch = dict[@"cancel-purchase-batch"];
	}
	NSString* failureType = [self stringForKey:@"failureType" in:dict];
	BOOL failed = [cancelBatch respondsToSelector:@selector(boolValue)] && [cancelBatch boolValue];
	if (!failed && failureType.length && ![failureType isEqualToString:@"0"])
	{
		failed = YES;
	}
	if (!failed)
	{
		return nil;
	}
	NSString* message = [self stringForKey:@"customerMessage" in:dict];
	if (!message.length)
	{
		message = [self stringForKey:@"failureMessage" in:dict];
	}
	if (!message.length)
	{
		message = @"Apple rejected the download request.";
	}
	WFSAppleIDDownloaderErrorCode code = WFSAppleIDDownloaderErrorPurchaseFailed;
	if ([message rangeOfString:@"licen" options:NSCaseInsensitiveSearch].location != NSNotFound ||
		[message rangeOfString:@"purchas" options:NSCaseInsensitiveSearch].location != NSNotFound)
	{
		code = WFSAppleIDDownloaderErrorLicenseNotFound;
	}
	if ([failureType isEqualToString:@"-5001"])
	{
		code = WFSAppleIDDownloaderErrorLicenseNotFound;
	}
	return [self errorWithCode:code message:message];
}

#pragma mark - Response parsing

- (void)postForm:(NSDictionary*)params toURL:(NSURL*)url authenticated:(BOOL)authenticated completion:(void (^)(NSData* data, NSHTTPURLResponse* response, NSError* error))completion
{
	NSString* bodyString = [self formEncodedStringFromDictionary:params];
	NSData* bodyData = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	request.HTTPMethod = @"POST";
	[request setValue:kWFSStoreElementsUA forHTTPHeaderField:@"User-Agent"];
	[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	[request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
	if (authenticated)
	{
		if (self.dsid.length)
		{
			[request setValue:self.dsid forHTTPHeaderField:@"X-Dsid"];
			[request setValue:self.dsid forHTTPHeaderField:@"iCloud-Dsid"];
		}
		if (self.token.length)
		{
			[request setValue:self.token forHTTPHeaderField:@"X-Token"];
		}
		if (self.storeFront.length)
		{
			[request setValue:self.storeFront forHTTPHeaderField:@"X-Apple-Store-Front"];
		}
	}
	request.HTTPBody = bodyData;
	[[self.session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		completion(data, (NSHTTPURLResponse*)response, error);
	}] resume];
}

- (NSString*)formEncodedStringFromDictionary:(NSDictionary*)dict
{
	NSMutableArray* parts = [NSMutableArray array];
	for (NSString* key in dict)
	{
		if (![key isKindOfClass:[NSString class]] || !key.length)
		{
			continue;
		}
		id value = dict[key];
		if ([value isKindOfClass:[NSString class]])
		{
			[parts addObject:[NSString stringWithFormat:@"%@=%@", [self percentEncode:key], [self percentEncode:(NSString*)value]]];
		}
		else if ([value isKindOfClass:[NSNumber class]])
		{
			[parts addObject:[NSString stringWithFormat:@"%@=%@", [self percentEncode:key], [self percentEncode:[value stringValue]]]];
		}
	}
	return [parts componentsJoinedByString:@"&"];
}

- (NSString*)percentEncode:(NSString*)string
{
	return [string stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

- (NSDictionary*)parseJSONResponse:(NSData*)data
{
	if (!data.length)
	{
		return nil;
	}
	NSError* error = nil;
	id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
	if (!error && [obj isKindOfClass:[NSDictionary class]])
	{
		return obj;
	}
	return nil;
}

- (void)postPlist:(NSDictionary*)body toURL:(NSURL*)url contentType:(NSString*)contentType authenticated:(BOOL)authenticated completion:(void (^)(NSData* data, NSHTTPURLResponse* response, NSError* error))completion
{
	[self postPlist:body toURL:url contentType:contentType authenticated:authenticated tokenHeaders:authenticated additionalHeaders:nil completion:completion];
}

- (void)postPlist:(NSDictionary*)body toURL:(NSURL*)url contentType:(NSString*)contentType authenticated:(BOOL)authenticated tokenHeaders:(BOOL)tokenHeaders completion:(void (^)(NSData* data, NSHTTPURLResponse* response, NSError* error))completion
{
	[self postPlist:body toURL:url contentType:contentType authenticated:authenticated tokenHeaders:tokenHeaders additionalHeaders:nil completion:completion];
}

- (void)postPlist:(NSDictionary*)body toURL:(NSURL*)url contentType:(NSString*)contentType authenticated:(BOOL)authenticated tokenHeaders:(BOOL)tokenHeaders additionalHeaders:(NSDictionary*)additionalHeaders completion:(void (^)(NSData* data, NSHTTPURLResponse* response, NSError* error))completion
{
	NSError* serializationError = nil;
	NSData* bodyData = [NSPropertyListSerialization dataWithPropertyList:body format:NSPropertyListXMLFormat_v1_0 options:0 error:&serializationError];
	if (!bodyData)
	{
		completion(nil, nil, [self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Failed to build request."]);
		return;
	}
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	request.HTTPMethod = @"POST";
	[request setValue:kWFSConfiguratorUA forHTTPHeaderField:@"User-Agent"];
	[request setValue:contentType forHTTPHeaderField:@"Content-Type"];
	if ([contentType isEqualToString:@"application/x-www-form-urlencoded"] || [contentType isEqualToString:@"application/x-apple-plist"])
	{
		[request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
	}
	if (authenticated)
	{
		if (self.dsid.length)
		{
			[request setValue:self.dsid forHTTPHeaderField:@"X-Dsid"];
			[request setValue:self.dsid forHTTPHeaderField:@"iCloud-Dsid"];
		}
		if (tokenHeaders)
		{
			if (self.token.length)
			{
				[request setValue:self.token forHTTPHeaderField:@"X-Token"];
			}
			if (self.storeFront.length)
			{
				[request setValue:self.storeFront forHTTPHeaderField:@"X-Apple-Store-Front"];
			}
		}
	}
	for (NSString* key in additionalHeaders)
	{
		NSString* value = additionalHeaders[key];
		if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]] && key.length && value.length)
		{
			[request setValue:value forHTTPHeaderField:key];
		}
	}
	request.HTTPBody = bodyData;
	[[self.session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		completion(data, (NSHTTPURLResponse*)response, error);
	}] resume];
}

- (NSString*)responseExcerptFromData:(NSData*)data
{
	if (!data.length)
	{
		return @"(empty body)";
	}
	NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if (text.length)
	{
		NSUInteger limit = 400;
		if (text.length > limit)
		{
			text = [[text substringToIndex:limit] stringByAppendingString:@"…"];
		}
		text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
		text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
		return text;
	}
	const unsigned char* bytes = data.bytes;
	NSUInteger limit = MIN((NSUInteger)80, data.length);
	NSMutableString* hex = [NSMutableString stringWithCapacity:limit * 2];
	for (NSUInteger i = 0; i < limit; i++)
	{
		[hex appendFormat:@"%02x", bytes[i]];
	}
	return [NSString stringWithFormat:@"(non-text body, %lu bytes) %@", (unsigned long)data.length, hex];
}

- (NSString*)upgradePageMessageFromData:(NSData*)data
{
	if (!data.length)
	{
		return nil;
	}
	NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if (!text.length)
	{
		return nil;
	}
	if ([text containsString:@"pageiTunes10Upgrade"] || [text containsString:@"<key>Goto</key>"])
	{
		return @"Apple rejected the purchase history request as an unsupported client (pageiTunes10Upgrade). The store server did not recognize the client version and returned an upgrade page instead of purchase data.";
	}
	return nil;
}

- (NSDictionary*)parsePlistResponse:(NSData*)data
{
	if (!data.length)
	{
		return nil;
	}
	NSError* error = nil;
	id obj = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
	if (!error && [obj isKindOfClass:[NSDictionary class]])
	{
		return obj;
	}
	NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if (!text.length)
	{
		return nil;
	}
	NSString* inner = text;
	NSRegularExpression* plistRegex = [NSRegularExpression regularExpressionWithPattern:@"<plist\\b[^>]*>(.*)</plist>" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
	NSTextCheckingResult* plistMatch = [plistRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
	if (plistMatch)
	{
		inner = [text substringWithRange:[plistMatch rangeAtIndex:1]];
	}
	NSString* dictXML = [self extractDictXMLFromString:inner];
	if (!dictXML)
	{
		return nil;
	}
	NSString* wrapped = [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n%@\n</plist>", dictXML];
	NSData* wrappedData = [wrapped dataUsingEncoding:NSUTF8StringEncoding];
	id wrappedObj = [NSPropertyListSerialization propertyListWithData:wrappedData options:0 format:NULL error:nil];
	return [wrappedObj isKindOfClass:[NSDictionary class]] ? wrappedObj : nil;
}

- (NSString*)extractDictXMLFromString:(NSString*)text
{
	NSInteger depth = 0;
	NSUInteger start = NSNotFound;
	NSUInteger i = 0;
	while (i < text.length)
	{
		unichar c = [text characterAtIndex:i];
		if (c == '<')
		{
			NSUInteger remaining = text.length - i;
			if (remaining >= 5 && [[text substringWithRange:NSMakeRange(i, 5)] isEqualToString:@"<dict"])
			{
				unichar next = (i + 5 < text.length) ? [text characterAtIndex:i + 5] : 0;
				if (next == '>' || next == ' ')
				{
					if (start == NSNotFound)
					{
						start = i;
					}
					depth++;
					i += 5;
					continue;
				}
			}
			if (remaining >= 7 && [[text substringWithRange:NSMakeRange(i, 7)] isEqualToString:@"</dict>"])
			{
				depth--;
				i += 7;
				if (depth <= 0)
				{
					return [text substringWithRange:NSMakeRange(start, i - start)];
				}
				continue;
			}
		}
		i++;
	}
	if (start == NSNotFound)
	{
		return nil;
	}
	return [text substringFromIndex:start];
}

- (NSString*)stringForKey:(NSString*)key in:(NSDictionary*)dict
{
	if (![dict isKindOfClass:[NSDictionary class]])
	{
		return nil;
	}
	id value = dict[key];
	if ([value isKindOfClass:[NSString class]])
	{
		return value;
	}
	if ([value isKindOfClass:[NSNumber class]])
	{
		return [value stringValue];
	}
	return nil;
}

- (NSString*)buyHost
{
	if (self.pod.length)
	{
		return [NSString stringWithFormat:@"p%@-%@", self.pod, kWFSBuyHost];
	}
	return kWFSBuyHost;
}

- (NSArray*)versionsFromSong:(NSDictionary*)song
{
	NSDictionary* metadata = [song[@"metadata"] isKindOfClass:[NSDictionary class]] ? song[@"metadata"] : nil;
	NSArray* identifiers = metadata[@"softwareVersionExternalIdentifiers"];
	NSMutableArray* versions = [NSMutableArray array];
	if ([identifiers isKindOfClass:[NSArray class]])
	{
		for (id identifier in identifiers)
		{
			long long versionId = [identifier longLongValue];
			if (versionId > 0)
			{
				[versions addObject:@{@"external_identifier": @(versionId), @"bundle_version": @""}];
			}
		}
	}
	return [[versions reverseObjectEnumerator] allObjects];
}

- (NSDictionary*)metadataFromSong:(NSDictionary*)song
{
	NSDictionary* metadata = song[@"metadata"];
	return [metadata isKindOfClass:[NSDictionary class]] ? metadata : nil;
}

#pragma mark - Helpers

- (NSString*)generateGuidForAppleId:(NSString*)appleId
{
	NSString* defaultGuid = @"000C2941396B";
	NSString* seed = [NSString stringWithFormat:@"CAFEBABE%@CAFEBABE", appleId];
	NSData* seedData = [seed dataUsingEncoding:NSUTF8StringEncoding];
	unsigned char digest[CC_SHA1_DIGEST_LENGTH];
	CC_SHA1(seedData.bytes, (CC_LONG)seedData.length, digest);
	NSMutableString* hex = [NSMutableString string];
	for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
	{
		[hex appendFormat:@"%02X", digest[i]];
	}
	NSString* prefix = [defaultGuid substringToIndex:2];
	NSString* hashPart = [hex substringWithRange:NSMakeRange(10, defaultGuid.length - 2)];
	return [prefix stringByAppendingString:hashPart];
}

- (NSError*)errorWithCode:(NSInteger)code message:(NSString*)message
{
	return [self errorWithCode:code message:message userInfo:nil];
}

- (NSError*)errorWithCode:(NSInteger)code message:(NSString*)message userInfo:(NSDictionary*)userInfo
{
	NSMutableDictionary* info = [NSMutableDictionary dictionaryWithDictionary:userInfo ?: @{}];
	info[NSLocalizedDescriptionKey] = message ?: @"Unknown error";
	return [NSError errorWithDomain:WFSAppleIDDownloaderErrorDomain code:code userInfo:info];
}

- (void)writeAuthDiagnostics:(NSArray*)diagnostics
{
	NSString* logPath = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"WaffleStore_appleid.log"];
	NSString* logContents = [NSString stringWithFormat:@"WaffleStore Apple ID sign-in diagnostics\n%@\n", [NSDate date]];
	for (NSString* line in diagnostics)
	{
		logContents = [logContents stringByAppendingFormat:@"%@\n", line];
	}
	[logContents writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSError*)networkError:(NSError*)error
{
	return [NSError errorWithDomain:WFSAppleIDDownloaderErrorDomain code:WFSAppleIDDownloaderErrorNetwork userInfo:@{NSLocalizedDescriptionKey: error.localizedDescription ?: @"Network error.", NSUnderlyingErrorKey: error}];
}

- (void)writeDebugLog:(NSString*)message
{
	NSString* directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
	NSString* path = [directory stringByAppendingPathComponent:@"WaffleStore_store.log"];
	NSString* line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
	NSString* existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
	NSString* contents = existing ? [existing stringByAppendingString:line] : line;
	[contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)writeRawResponseData:(NSData*)data label:(NSString*)label
{
	if (!data.length)
	{
		return;
	}
	NSString* directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
	NSString* path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"WaffleStore_%@_resp.plist", label]];
	[data writeToFile:path atomically:YES];
}

- (void)resetSessionState
{
	self.authenticated = NO;
	self.dsid = nil;
	self.token = nil;
	self.storeFront = nil;
	self.pod = nil;
	self.twoFactorCodeSent = NO;
	self.anisetteHeaders = nil;
	self.lastAuthEndpoint = nil;
	self.lastDownloadEndpoint = nil;
}

- (void)finishVersions:(WFSAppleIDVersionsCompletion)completion versions:(NSArray*)versions metadata:(NSDictionary*)metadata error:(NSError*)error
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		completion(versions, metadata, error);
	});
}

- (void)finishDownloadInfo:(WFSAppleIDDownloadInfoCompletion)completion url:(NSURL*)url metadata:(NSDictionary*)metadata error:(NSError*)error
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		completion(url, metadata, error);
	});
}

- (void)finishPurchaseSearch:(WFSAppleIDPurchaseSearchCompletion)completion purchase:(NSDictionary*)purchase error:(NSError*)error
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		completion(purchase, error);
	});
}

@end
