#import "WFSAppleIDDownloader.h"
#import <CommonCrypto/CommonDigest.h>

NSString* const WFSAppleIDDownloaderErrorDomain = @"WFSAppleIDDownloaderErrorDomain";

static NSString* const kWFSConfiguratorUA = @"Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6";
static NSString* const kWFSFastAuthEndpoint = @"https://auth.itunes.apple.com/auth/v1/native/fast/";
static NSString* const kWFSLegacyAuthEndpoint = @"https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate";
static NSString* const kWFSInitBagEndpoint = @"https://init.itunes.apple.com/bag.xml?guid=%@";
static NSString* const kWFSBuyHost = @"buy.itunes.apple.com";

static const NSInteger kWFSMaxRedirects = 5;
static const NSInteger kWFSMaxAuthAttempts = 24;

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
@property (nonatomic, copy, readwrite) NSString* authenticatedAppleId;
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
	self.password = [NSString stringWithFormat:@"%@%@", self.password, code ?: @""];
	[self tryAuthenticateWithAttempt:2 completion:completion];
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

#pragma mark - Authentication

- (void)tryAuthenticateWithAttempt:(NSInteger)attempt completion:(WFSAppleIDAuthCompletion)completion
{
	NSMutableArray* diagnostics = [NSMutableArray array];
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
		if (resolvedEndpoint.length)
		{
			[candidates addObject:resolvedEndpoint];
		}
		[candidates addObject:kWFSFastAuthEndpoint];
		[candidates addObject:[NSString stringWithFormat:@"%@?guid=%@", kWFSLegacyAuthEndpoint, self.guid]];
		[candidates addObject:kWFSLegacyAuthEndpoint];
		[self tryAuthEndpointCandidates:candidates index:0 attempt:attempt retryCount:0 diagnostics:diagnostics completion:completion];
	}];
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
		}
		completion(endpoint);
	}] resume];
}

- (void)tryAuthEndpointCandidates:(NSArray*)candidates index:(NSUInteger)index attempt:(NSInteger)attempt retryCount:(NSInteger)retryCount diagnostics:(NSMutableArray*)diagnostics completion:(WFSAppleIDAuthCompletion)completion
{
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
	[self postPlist:body toURL:[NSURL URLWithString:candidate] contentType:@"application/x-www-form-urlencoded" authenticated:NO completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error || !data.length)
		{
			NSString* detail = error ? [NSString stringWithFormat:@"transport error: %@", error.localizedDescription] : @"empty response body";
			[diagnostics addObject:[NSString stringWithFormat:@"POST %@ -> %@ (%@)", candidate, response ? [NSString stringWithFormat:@"HTTP %ld", (long)response.statusCode] : @"no response", detail]];
			[self retryAuthWithCandidates:candidates index:index + 1 attempt:attempt retryCount:retryCount diagnostics:diagnostics completion:completion];
			return;
		}
		[diagnostics addObject:[NSString stringWithFormat:@"POST %@ -> HTTP %ld (%lu bytes)", candidate, (long)response.statusCode, (unsigned long)data.length]];
		NSError* processError = [self processAuthResponseData:data httpResponse:response];
		if (!processError)
		{
			[self finishAuth:completion error:nil];
			return;
		}
		if (processError.code == WFSAppleIDDownloaderError2FARequired || processError.code == WFSAppleIDDownloaderErrorBrowserSignInRequired)
		{
			[self finishAuth:completion error:processError];
			return;
		}
		[diagnostics addObject:[NSString stringWithFormat:@"  unusable response: %@", processError.localizedDescription]];
		[self retryAuthWithCandidates:candidates index:index + 1 attempt:attempt retryCount:retryCount diagnostics:diagnostics completion:completion];
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
	NSString* logPath = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"WaffleStore_appleid.log"];
	NSString* logContents = [NSString stringWithFormat:@"WaffleStore Apple ID sign-in diagnostics\n%@\n", [NSDate date]];
	for (NSString* line in diagnostics)
	{
		logContents = [logContents stringByAppendingFormat:@"%@\n", line];
	}
	[logContents writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

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

- (NSError*)processAuthResponseData:(NSData*)data httpResponse:(NSHTTPURLResponse*)httpResponse
{
	NSDictionary* dict = [self parsePlistResponse:data];
	if (!dict)
	{
		return [self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Apple returned an invalid response."];
	}
	NSString* failureType = [self stringForKey:@"failureType" in:dict];
	NSString* customerMessage = [self stringForKey:@"customerMessage" in:dict];
	if ([failureType isEqualToString:@"-5000"])
	{
		return [self errorWithCode:WFSAppleIDDownloaderError2FARequired message:@"Two-factor authentication code required."];
	}
	if (customerMessage && [customerMessage containsString:@"AMD-Action::SP"])
	{
		return [self errorWithCode:WFSAppleIDDownloaderErrorBrowserSignInRequired message:@"This Apple ID requires sign-in approval from a browser. Try signing in on a computer first, then try again."];
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
	[self postPlist:body toURL:[NSURL URLWithString:urlString] contentType:@"application/x-www-form-urlencoded" authenticated:YES completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			completion(nil, nil, [self networkError:error]);
			return;
		}
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
		NSError* failureError = [self failureErrorFromResponse:dict];
		if (failureError)
		{
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
	NSDictionary* body = @{
		@"guid": self.guid,
		@"salableAdamId": [NSString stringWithFormat:@"%lld", appId],
		@"appExtVrsId": @"0",
		@"price": @"0",
		@"productType": @"C",
		@"pricingParameters": @"STDQ",
		@"hasAskedToFulfillPreorder": @"true",
		@"buyWithoutAuthorization": @"true",
		@"hasDoneAgeCheck": @"true",
		@"hasConfirmedPaymentSheet": @"true",
	};
	NSString* urlString = [NSString stringWithFormat:@"https://%@/WebObjects/MZFinance.woa/wa/buyProduct", [self buyHost]];
	[self postPlist:body toURL:[NSURL URLWithString:urlString] contentType:@"application/x-apple-plist" authenticated:YES completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
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
		NSError* failureError = [self failureErrorFromResponse:dict];
		if (failureError)
		{
			completion(failureError);
			return;
		}
		NSString* docType = [self stringForKey:@"jingleDocType" in:dict];
		if ([docType isEqualToString:@"purchaseSuccess"])
		{
			completion(nil);
			return;
		}
		completion([self errorWithCode:WFSAppleIDDownloaderErrorPurchaseFailed message:[self stringForKey:@"customerMessage" in:dict] ?: @"The app could not be purchased."]);
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

- (void)postPlist:(NSDictionary*)body toURL:(NSURL*)url contentType:(NSString*)contentType authenticated:(BOOL)authenticated completion:(void (^)(NSData* data, NSHTTPURLResponse* response, NSError* error))completion
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
	if ([contentType isEqualToString:@"application/x-www-form-urlencoded"])
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
	return [NSError errorWithDomain:WFSAppleIDDownloaderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

- (NSError*)networkError:(NSError*)error
{
	return [NSError errorWithDomain:WFSAppleIDDownloaderErrorDomain code:WFSAppleIDDownloaderErrorNetwork userInfo:@{NSLocalizedDescriptionKey: error.localizedDescription ?: @"Network error.", NSUnderlyingErrorKey: error}];
}

- (void)resetSessionState
{
	self.authenticated = NO;
	self.dsid = nil;
	self.token = nil;
	self.storeFront = nil;
	self.pod = nil;
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

@end
