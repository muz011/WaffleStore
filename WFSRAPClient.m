#import "WFSRAPClient.h"
#import "WFSAppleIDDownloader.h"

// reportaproblem.apple.com ("RAP") is Apple's purchase-reporting portal. It does
// NOT use the MZFinance store services; it runs on the idmsa "app" sign-in flow
// (authResponseType COOKIE). All client constants below were captured from the
// live idmsa sign-in page (authWidgetConfig JSON) served for RAP's appIdKey.

static NSString* const kWFSRAPAppIdKey = @"20379f32034f8867d352666ff2904d2152d5ff6843ee2db5ab5df863c14b1aef";
static NSString* const kWFSRAPWidgetKey = @"92f19b477c5c9be6ab17f3ec2b1b2b7db4d00a9a8c973e3d6c90dac08b91de71";
static NSString* const kWFSRAPFDClientInfo = @"<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>";
static NSString* const kWFSRAPUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

static NSString* const kWFSRAPSigninURL = @"https://idmsa.apple.com/appleauth/auth/signin?appIdKey=20379f32034f8867d352666ff2904d2152d5ff6843ee2db5ab5df863c14b1aef&language=US-EN&locale=en_US";
static NSString* const kWFSRAPAuthBase = @"https://idmsa.apple.com/appleauth";
static NSString* const kWFSRAPVerifyTrustedDeviceURL = @"https://idmsa.apple.com/appleauth/auth/verify/trusteddevice";
static NSString* const kWFSRAPAppReturnURL = @"https://daiquiri-ext.itunes.apple.com/__logged_in/reportaproblem.apple.com";
static NSString* const kWFSRAPRootURL = @"https://reportaproblem.apple.com/";
static NSString* const kWFSRAPLoginURL = @"https://reportaproblem.apple.com/api/login";
static NSString* const kWFSRAPSearchURL = @"https://reportaproblem.apple.com/api/purchase/search";

static NSString* const kWFSRAPDefaultsDsid = @"wfsRAPDsid";
static NSString* const kWFSRAPDefaultsXsrf = @"wfsRAPXsrf";

static const NSInteger kWFSRAPMaxSearchPages = 500;

@interface WFSRAPClient ()
@property (nonatomic, strong, nullable) NSURLSession* session;
@property (nonatomic, copy, nullable) NSString* appleId;
@property (nonatomic, copy, nullable) NSString* password;
@property (nonatomic, copy, nullable) NSString* sessionId;
@property (nonatomic, copy, nullable) NSString* scnt;
@property (nonatomic, copy, nullable) NSString* xsrfToken;
@property (nonatomic, copy, nullable) NSString* parsedWidgetKey;
@property (nonatomic) BOOL cancelRequested;
@property (nonatomic, readwrite, getter=isAuthenticated) BOOL authenticated;
@property (nonatomic, readwrite, copy, nullable) NSString* authenticatedAppleId;
@property (nonatomic, readwrite, copy, nullable) NSString* dsid;
@end

@implementation WFSRAPClient
{
	BOOL _twoFactorCodeSent;
	BOOL _authenticating;
}

+ (instancetype)sharedClient
{
	static WFSRAPClient* sharedClient = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^
	{
		sharedClient = [[WFSRAPClient alloc] init];
	});
	return sharedClient;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		NSURLSessionConfiguration* configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
		configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
		configuration.HTTPShouldSetCookies = YES;
		_session = [NSURLSession sessionWithConfiguration:configuration];

		NSString* storedDsid = [[NSUserDefaults standardUserDefaults] stringForKey:kWFSRAPDefaultsDsid];
		NSString* storedXsrf = [[NSUserDefaults standardUserDefaults] stringForKey:kWFSRAPDefaultsXsrf];
		BOOL hasRAPCookies = [self hasReportAProblemCookies];
		if (storedDsid.length && hasRAPCookies)
		{
			_dsid = storedDsid;
			_xsrfToken = storedXsrf;
			_authenticated = YES;
			_authenticatedAppleId = [[NSUserDefaults standardUserDefaults] stringForKey:@"wfsAppleIDEmail"];
		}
	}
	return self;
}

#pragma mark - Public API

- (BOOL)isAuthenticated
{
	return _authenticated;
}

- (void)authenticateWithAppleId:(NSString*)appleId password:(NSString*)password completion:(WFSRAPAuthCompletion)completion
{
	if (_authenticating)
	{
		[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderErrorCancelled message:@"A RAP sign-in is already in progress."]];
		return;
	}
	_authenticating = YES;
	_cancelRequested = NO;
	_twoFactorCodeSent = NO;
	_authenticated = NO;
	self.appleId = appleId;
	self.password = password;
	self.sessionId = nil;
	self.scnt = nil;

	[self writeDebugLog:[NSString stringWithFormat:@"RAP authenticate starting for %@", appleId]];

	[self loadSigninPageWithCompletion:^(NSString* widgetKey, NSError* error)
	{
		if (error)
		{
			_authenticating = NO;
			[self finishAuth:completion error:error];
			return;
		}
		if (widgetKey.length)
		{
			_parsedWidgetKey = widgetKey;
			[self writeDebugLog:[NSString stringWithFormat:@"RAP widget key from page: %@", widgetKey]];
		}
		[self submitCredentialsWithCompletion:^(NSError* authError)
		{
			_authenticating = NO;
			[self finishAuth:completion error:authError];
		}];
	}];
}

- (void)retryWithTwoFactorCode:(NSString*)code completion:(WFSRAPAuthCompletion)completion
{
	if (!self.sessionId.length || !self.scnt.length)
	{
		[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderError2FARequired message:@"No Apple ID session is active. Sign in again."]];
		return;
	}
	if (self.cancelRequested)
	{
		[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderErrorCancelled message:@"Sign-in cancelled."]];
		return;
	}
	[self writeDebugLog:@"RAP submitting two-factor code"];
	NSDictionary* body = @{ @"securityCode": @{ @"code": code } };
	NSMutableURLRequest* request = [self jsonRequestForURL:[NSURL URLWithString:kWFSRAPVerifyTrustedDeviceURL]
													  body:body
											  sessionAuth:YES
													  page:NO];
	[self performRequest:request completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			[self finishAuth:completion error:[self networkError:error]];
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"RAP verify/trusteddevice -> HTTP %ld (%lu bytes)", (long)response.statusCode, (unsigned long)data.length]];
		if (response.statusCode == 204 || response.statusCode == 200)
		{
			_twoFactorCodeSent = YES;
			[self completeAuthenticationWithCompletion:completion];
			return;
		}
		if (response.statusCode == 401 || response.statusCode == 403)
		{
			[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:@"Wrong code or session expired. Sign in again."]];
			return;
		}
		[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed
													   message:[NSString stringWithFormat:@"Two-factor verification failed (HTTP %ld).", (long)response.statusCode]]];
	}];
}

- (void)cancelAuthentication
{
	_cancelRequested = YES;
}

- (void)resetSession
{
	[self deleteRAPCookies];
	_authenticated = NO;
	_authenticatedAppleId = nil;
	_dsid = nil;
	_xsrfToken = nil;
	self.appleId = nil;
	self.password = nil;
	self.sessionId = nil;
	self.scnt = nil;
	_twoFactorCodeSent = NO;
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:kWFSRAPDefaultsDsid];
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:kWFSRAPDefaultsXsrf];
	[[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)fetchFullPurchaseHistoryWithCompletion:(WFSRAPHistoryCompletion)completion
{
	if (!self.authenticated)
	{
		[self finishHistory:completion purchases:nil response:nil error:[self errorWithCode:WFSAppleIDDownloaderErrorNotAuthenticated message:@"Not signed in to the RAP portal. Use the authTest tab to sign in first."]];
		return;
	}
	[self writeDebugLog:[NSString stringWithFormat:@"RAP purchase history starting (dsid=%@)", self.dsid]];

	NSMutableArray* allPurchases = [NSMutableArray array];
	NSDictionary* firstResponse = nil;
	NSString* batchId = @"";
	NSInteger page = 0;
	NSString* previousBatchId = @"";

	[self fetchSearchPageWithBatchId:batchId allPurchases:allPurchases firstResponse:&firstResponse page:&page previousBatchId:&previousBatchId completion:^(NSError* error)
	{
		if (error)
		{
			[self finishHistory:completion purchases:allPurchases response:firstResponse error:error];
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"RAP purchase history done: %lu purchase(s)", (unsigned long)allPurchases.count]];
		[self finishHistory:completion purchases:allPurchases response:firstResponse error:nil];
	}];
}

#pragma mark - Auth steps

- (void)loadSigninPageWithCompletion:(void (^)(NSString* widgetKey, NSError* error))completion
{
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kWFSRAPSigninURL]];
	[request setValue:kWFSRAPUserAgent forHTTPHeaderField:@"User-Agent"];
	[request setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
	[self performRequest:request completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			completion(nil, [self networkError:error]);
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"RAP signin page -> HTTP %ld (%lu bytes)", (long)response.statusCode, (unsigned long)data.length]];
		if (response.statusCode != 200 && response.statusCode != 302)
		{
			completion(nil, [self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:[NSString stringWithFormat:@"idmsa sign-in page returned HTTP %ld.", (long)response.statusCode]]);
			return;
		}
		NSString* html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
		NSString* widgetKey = [self widgetKeyFromHTML:html];
		if (!widgetKey)
		{
			widgetKey = kWFSRAPWidgetKey;
		}
		completion(widgetKey, nil);
	}];
}

- (void)submitCredentialsWithCompletion:(void (^)(NSError* error))completion
{
	if (self.cancelRequested)
	{
		completion([self errorWithCode:WFSAppleIDDownloaderErrorCancelled message:@"Sign-in cancelled."]);
		return;
	}
	NSDictionary* body = @{
		@"accountName": self.appleId ?: @"",
		@"password": self.password ?: @"",
		@"rememberMe": @NO,
	};
	NSMutableURLRequest* request = [self jsonRequestForURL:[NSURL URLWithString:kWFSRAPSigninURL]
													  body:body
											  sessionAuth:NO
													  page:YES];
	[self performRequest:request completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			completion([self networkError:error]);
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"RAP signin -> HTTP %ld (%lu bytes)", (long)response.statusCode, (unsigned long)data.length]];
		if (response.statusCode == 409)
		{
			NSString* sessionId = response.allHeaderFields[@"X-Apple-ID-Session-Id"];
			NSString* scnt = response.allHeaderFields[@"scnt"];
			[self writeDebugLog:[NSString stringWithFormat:@"RAP two-factor required (sessionId=%@, scnt=%@)", sessionId.length ? @"<captured>" : @"<missing>", scnt.length ? @"<captured>" : @"<missing>"]];
			if (!sessionId.length || !scnt.length)
			{
				completion([self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:@"idmsa requested two-factor but did not return session headers."]);
				return;
			}
			self.sessionId = sessionId;
			self.scnt = scnt;
			completion([self errorWithCode:WFSAppleIDDownloaderError2FARequired message:@"Enter the two-factor code for this Apple ID."]);
			return;
		}
		if (response.statusCode >= 300 && response.statusCode < 400)
		{
			[self writeDebugLog:[NSString stringWithFormat:@"RAP signin redirect: %@", response.allHeaderFields[@"Location"] ?: @"<none>"]];
			[self completeAuthenticationWithCompletion:completion];
			return;
		}
		NSString* message = [self errorMessageFromData:data fallback:[NSString stringWithFormat:@"Sign-in failed (HTTP %ld).", (long)response.statusCode]];
		if ([message.lowercaseString containsString:@"captcha"] || [message.lowercaseString containsString:@"recaptcha"])
		{
			completion([self errorWithCode:WFSAppleIDDownloaderErrorBrowserSignInRequired message:@"Apple is asking for a captcha. Sign in at reportaproblem.apple.com in a browser first."]);
			return;
		}
		completion([self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:message]);
	}];
}

- (void)completeAuthenticationWithCompletion:(WFSRAPAuthCompletion)completion
{
	if (self.cancelRequested)
	{
		[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderErrorCancelled message:@"Sign-in cancelled."]];
		return;
	}
	[self writeDebugLog:@"RAP completing idmsa session"];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kWFSRAPSigninURL]];
	[request setValue:kWFSRAPUserAgent forHTTPHeaderField:@"User-Agent"];
	[request setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
	[self performRequest:request completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			[self finishAuth:completion error:[self networkError:error]];
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"RAP complete -> HTTP %ld (%lu bytes)", (long)response.statusCode, (unsigned long)data.length]];
		NSMutableURLRequest* returnRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kWFSRAPAppReturnURL]];
		[returnRequest setValue:kWFSRAPUserAgent forHTTPHeaderField:@"User-Agent"];
		[returnRequest setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
		[self performRequest:returnRequest completion:^(NSData* returnData, NSHTTPURLResponse* returnResponse, NSError* returnError)
		{
			if (returnError)
			{
				[self finishAuth:completion error:[self networkError:returnError]];
				return;
			}
			[self writeDebugLog:[NSString stringWithFormat:@"RAP return URL -> HTTP %ld (%lu bytes)", (long)returnResponse.statusCode, (unsigned long)returnData.length]];
			NSMutableURLRequest* rootRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kWFSRAPRootURL]];
			[rootRequest setValue:kWFSRAPUserAgent forHTTPHeaderField:@"User-Agent"];
			[rootRequest setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
			[self performRequest:rootRequest completion:^(NSData* rootData, NSHTTPURLResponse* rootResponse, NSError* rootError)
			{
				if (rootError)
				{
					[self finishAuth:completion error:[self networkError:rootError]];
					return;
				}
				[self writeDebugLog:[NSString stringWithFormat:@"RAP root page -> HTTP %ld (%lu bytes)", (long)rootResponse.statusCode, (unsigned long)rootData.length]];
				[self fetchLoginWithCompletion:completion];
			}];
		}];
	}];
}

- (void)fetchLoginWithCompletion:(WFSRAPAuthCompletion)completion
{
	[self writeDebugLog:@"RAP calling /api/login"];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kWFSRAPLoginURL]];
	[request setValue:kWFSRAPUserAgent forHTTPHeaderField:@"User-Agent"];
	[request setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];
	[request setValue:@"https://reportaproblem.apple.com/" forHTTPHeaderField:@"Referer"];
	[self performRequest:request completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			[self finishAuth:completion error:[self networkError:error]];
			return;
		}
		[self writeDebugLog:[NSString stringWithFormat:@"RAP /api/login GET -> HTTP %ld (%lu bytes)", (long)response.statusCode, (unsigned long)data.length]];
		[self writeRawJSON:data label:@"login"];
		[self captureXsrfFromHeaders:response.allHeaderFields];
		if (response.statusCode == 200)
		{
			[self handleLoginResponse:data completion:completion];
			return;
		}
		NSDictionary* postBody = @{};
		NSMutableURLRequest* post = [self jsonRequestForURL:[NSURL URLWithString:kWFSRAPLoginURL] body:postBody sessionAuth:NO page:NO];
		[self performRequest:post completion:^(NSData* postData, NSHTTPURLResponse* postResponse, NSError* postError)
		{
			if (postError)
			{
				[self finishAuth:completion error:[self networkError:postError]];
				return;
			}
			[self writeDebugLog:[NSString stringWithFormat:@"RAP /api/login POST -> HTTP %ld (%lu bytes)", (long)postResponse.statusCode, (unsigned long)postData.length]];
			[self writeRawJSON:postData label:@"login_post"];
			[self captureXsrfFromHeaders:postResponse.allHeaderFields];
			if (postResponse.statusCode == 200)
			{
				[self handleLoginResponse:postData completion:completion];
				return;
			}
			[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:@"Could not complete RAP session: /api/login did not return 200. Check the log file."]];
		}];
	}];
}

- (void)handleLoginResponse:(NSData*)data completion:(WFSRAPAuthCompletion)completion
{
	NSDictionary* dict = [self jsonObjectForData:data];
	NSString* dsid = [self stringForKey:@"dsid" in:dict];
	if (!dsid.length)
	{
		dsid = [self stringForKey:@"dsPersonId" in:dict];
	}
	if (!dsid.length)
	{
		dsid = [self stringForKey:@"personId" in:dict];
	}
	if (!dsid.length)
	{
		NSString* snippet = dict ? [NSString stringWithFormat:@" %@", dict] : @"";
		[self finishAuth:completion error:[self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:[NSString stringWithFormat:@"RAP /api/login succeeded but no dsid was found in the response:%@", snippet]]];
		return;
	}
	self.dsid = dsid;
	self.authenticated = YES;
	self.authenticatedAppleId = self.appleId;
	[self captureXsrfFromCookies];
	[self writeDebugLog:[NSString stringWithFormat:@"RAP authenticated: dsid=%@ xsrf=%@", dsid, self.xsrfToken.length ? @"<captured>" : @"<missing>"]];
	[[NSUserDefaults standardUserDefaults] setObject:dsid forKey:kWFSRAPDefaultsDsid];
	if (self.xsrfToken.length)
	{
		[[NSUserDefaults standardUserDefaults] setObject:self.xsrfToken forKey:kWFSRAPDefaultsXsrf];
	}
	[[NSUserDefaults standardUserDefaults] setObject:self.appleId forKey:@"wfsAppleIDEmail"];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[self finishAuth:completion error:nil];
}

#pragma mark - Search pages

- (void)fetchSearchPageWithBatchId:(NSString*)batchId
					 allPurchases:(NSMutableArray*)allPurchases
					firstResponse:(NSDictionary**)firstResponse
							  page:(NSInteger*)page
					previousBatchId:(NSString**)previousBatchId
						completion:(void (^)(NSError* error))completion
{
	if (*page >= kWFSRAPMaxSearchPages)
	{
		[self writeDebugLog:@"RAP search hit the page cap; stopping."];
		completion(nil);
		return;
	}
	if (self.cancelRequested)
	{
		completion([self errorWithCode:WFSAppleIDDownloaderErrorCancelled message:@"Fetch cancelled."]);
		return;
	}
	NSDictionary* body = @{
		@"batchId": batchId,
		@"dsid": self.dsid ?: @"",
	};
	NSMutableURLRequest* request = [self jsonRequestForURL:[NSURL URLWithString:kWFSRAPSearchURL]
													  body:body
											  sessionAuth:NO
													  page:NO];
	[request setValue:@"3.0.0" forHTTPHeaderField:@"x-apple-rap2-api"];
	[request setValue:self.xsrfToken ?: @"" forHTTPHeaderField:@"x-apple-xsrf-token"];
	[request setValue:@"https://reportaproblem.apple.com/" forHTTPHeaderField:@"Origin"];
	[request setValue:@"https://reportaproblem.apple.com/" forHTTPHeaderField:@"Referer"];

	[self performRequest:request completion:^(NSData* data, NSHTTPURLResponse* response, NSError* error)
	{
		if (error)
		{
			completion([self networkError:error]);
			return;
		}
		[self captureXsrfFromHeaders:response.allHeaderFields];
		[self writeDebugLog:[NSString stringWithFormat:@"RAP search page %ld (batch=%@) -> HTTP %ld (%lu bytes)", (long)(*page + 1), batchId.length ? batchId : @"<first>", (long)response.statusCode, (unsigned long)data.length]];
		if (response.statusCode == 403 || response.statusCode == 401)
		{
			completion([self errorWithCode:WFSAppleIDDownloaderErrorAuthenticationFailed message:@"RAP session expired. Sign in again."]);
			return;
		}
		if (response.statusCode == 429)
		{
			completion([self errorWithCode:WFSAppleIDDownloaderErrorRateLimited message:@"Apple is rate limiting requests. Wait a few minutes and try again."]);
			return;
		}
		if (response.statusCode != 200)
		{
			completion([self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:[NSString stringWithFormat:@"RAP search returned HTTP %ld.", (long)response.statusCode]]);
			return;
		}
		NSDictionary* dict = [self jsonObjectForData:data];
		if (!dict)
		{
			[self writeRawJSON:data label:@"search"];
			completion([self errorWithCode:WFSAppleIDDownloaderErrorInvalidResponse message:@"Apple returned an invalid response to the RAP search request."]);
			return;
		}
		if (*page == 0)
		{
			*firstResponse = dict;
		}
		NSArray* items = [self itemsFromResponse:dict];
		if (*page == 0 && items.count)
		{
			[self writeDebugLog:[NSString stringWithFormat:@"RAP first item keys: %@", ((NSDictionary*)items[0]).allKeys]];
		}
		for (id item in items)
		{
			NSDictionary* purchase = [self purchaseFromItem:item];
			if (purchase)
			{
				[allPurchases addObject:purchase];
			}
		}
		(*page)++;
		if (self.historyProgressHandler)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				self.historyProgressHandler(*page, items.count, allPurchases.count);
			});
		}
		NSString* nextBatch = [self stringForKey:@"batchId" in:dict];
		if (!nextBatch.length)
		{
			nextBatch = [self stringForKey:@"nextBatchId" in:dict];
		}
		if (!nextBatch.length)
		{
			nextBatch = [self stringForKey:@"nextBatch" in:dict];
		}
		if (!items.count || !nextBatch.length || [nextBatch isEqualToString:*previousBatchId] || [nextBatch isEqualToString:batchId])
		{
			completion(nil);
			return;
		}
		*previousBatchId = batchId;
		[self fetchSearchPageWithBatchId:nextBatch
						   allPurchases:allPurchases
						  firstResponse:firstResponse
									page:page
						  previousBatchId:previousBatchId
							  completion:completion];
	}];
}

- (NSArray*)itemsFromResponse:(NSDictionary*)dict
{
	id items = dict[@"items"];
	if (![items isKindOfClass:[NSArray class]])
	{
		items = dict[@"results"];
	}
	if (![items isKindOfClass:[NSArray class]])
	{
		items = dict[@"data"];
	}
	if (![items isKindOfClass:[NSArray class]])
	{
		return @[];
	}
	NSMutableArray* result = [NSMutableArray array];
	for (id item in items)
	{
		if ([item isKindOfClass:[NSDictionary class]])
		{
			[result addObject:item];
		}
	}
	return result;
}

- (NSDictionary*)purchaseFromItem:(NSDictionary*)item
{
	NSMutableDictionary* purchase = [NSMutableDictionary dictionary];
	id adamId = item[@"adamId"];
	if (!adamId)
	{
		adamId = item[@"id"];
	}
	if (!adamId)
	{
		adamId = item[@"itemId"];
	}
	if (adamId)
	{
		purchase[@"adamId"] = [NSString stringWithFormat:@"%@", adamId];
	}
	id bundleId = item[@"bundleId"];
	if (!bundleId)
	{
		bundleId = item[@"bundleID"];
	}
	if (bundleId)
	{
		purchase[@"bundleId"] = [NSString stringWithFormat:@"%@", bundleId];
	}
	NSString* title = [self stringForKey:@"title" in:item];
	if (!title.length)
	{
		title = [self stringForKey:@"name" in:item];
	}
	if (!title.length)
	{
		title = [self stringForKey:@"itemName" in:item];
	}
	if (title.length)
	{
		purchase[@"title"] = title;
	}
	if (item[@"purchaseDate"])
	{
		purchase[@"purchaseDate"] = [self formatPurchaseDate:item[@"purchaseDate"]];
	}
	if (item[@"orderId"])
	{
		purchase[@"orderId"] = item[@"orderId"];
	}
	if (item[@"price"])
	{
		purchase[@"price"] = item[@"price"];
	}
	purchase[@"metadata"] = item;
	if (!purchase[@"adamId"] && !purchase[@"bundleId"] && !purchase[@"title"])
	{
		return nil;
	}
	return purchase;
}

- (NSString*)formatPurchaseDate:(id)dateValue
{
	if ([dateValue isKindOfClass:[NSNumber class]])
	{
		double seconds = [dateValue doubleValue];
		if (seconds > 100000000000.0)
		{
			seconds /= 1000.0;
		}
		NSDate* date = [NSDate dateWithTimeIntervalSince1970:seconds];
		return [self dateStringForDate:date];
	}
	if ([dateValue isKindOfClass:[NSString class]])
	{
		return dateValue;
	}
	return [NSString stringWithFormat:@"%@", dateValue];
}

- (NSString*)dateStringForDate:(NSDate*)date
{
	NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
	formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
	formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
	formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
	return [formatter stringFromDate:date];
}

#pragma mark - Requests

- (NSMutableURLRequest*)jsonRequestForURL:(NSURL*)url body:(NSDictionary*)body sessionAuth:(BOOL)sessionAuth page:(BOOL)page
{
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	request.HTTPMethod = @"POST";
	[request setValue:kWFSRAPUserAgent forHTTPHeaderField:@"User-Agent"];
	[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
	[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
	[request setValue:self.parsedWidgetKey.length ? self.parsedWidgetKey : kWFSRAPWidgetKey forHTTPHeaderField:@"X-Apple-Widget-Key"];
	[request setValue:kWFSRAPFDClientInfo forHTTPHeaderField:@"X-Apple-I-FD-Client-Info"];
	[request setValue:@"UTC" forHTTPHeaderField:@"X-Apple-I-Time-Zone"];
	[request setValue:@"en_US" forHTTPHeaderField:@"X-Apple-I-Locale"];
	[request setValue:[self iso8601ClientTime] forHTTPHeaderField:@"X-Apple-I-Client-Time"];
	if (sessionAuth)
	{
		if (self.sessionId.length)
		{
			[request setValue:self.sessionId forHTTPHeaderField:@"X-Apple-ID-Session-Id"];
		}
		if (self.scnt.length)
		{
			[request setValue:self.scnt forHTTPHeaderField:@"scnt"];
		}
	}
	if (page)
	{
		[request setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
	}
	NSData* jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
	request.HTTPBody = jsonData;
	return request;
}

- (NSString*)iso8601ClientTime
{
	NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
	formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
	formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
	formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
	return [formatter stringFromDate:[NSDate date]];
}

- (void)performRequest:(NSURLRequest*)request completion:(void (^)(NSData* data, NSHTTPURLResponse* response, NSError* error))completion
{
	[[self.session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		completion(data, (NSHTTPURLResponse*)response, error);
	}] resume];
}

#pragma mark - Parsing helpers

- (NSString*)widgetKeyFromHTML:(NSString*)html
{
	if (!html.length)
	{
		return nil;
	}
	NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:@"\"widgetKey\"\\s*:\\s*\"([0-9a-f]+)\"" options:NSRegularExpressionCaseInsensitive error:nil];
	NSTextCheckingResult* match = [regex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
	if (match && match.numberOfRanges > 1)
	{
		return [html substringWithRange:[match rangeAtIndex:1]];
	}
	return nil;
}

- (NSString*)errorMessageFromData:(NSData*)data fallback:(NSString*)fallback
{
	NSDictionary* dict = [self jsonObjectForData:data];
	if (dict)
	{
		NSString* message = [self stringForKey:@"error" in:dict];
		if (message.length)
		{
			return message;
		}
		NSArray* errors = dict[@"serviceErrors"];
		if ([errors isKindOfClass:[NSArray class]] && errors.count)
		{
			NSDictionary* first = errors[0];
			if ([first isKindOfClass:[NSDictionary class]])
			{
				NSString* serviceMessage = [self stringForKey:@"message" in:first];
				if (serviceMessage.length)
				{
					return serviceMessage;
				}
			}
		}
	}
	return fallback;
}

- (NSDictionary*)jsonObjectForData:(NSData*)data
{
	if (!data.length)
	{
		return nil;
	}
	id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	if ([object isKindOfClass:[NSDictionary class]])
	{
		return object;
	}
	return nil;
}

- (NSString*)stringForKey:(NSString*)key in:(NSDictionary*)dict
{
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

#pragma mark - XSRF handling

- (void)captureXsrfFromHeaders:(NSDictionary*)headers
{
	for (NSString* key in headers)
	{
		if ([key.lowercaseString containsString:@"xsrf"] || [key.lowercaseString containsString:@"csrf"])
		{
			NSString* value = headers[key];
			if (value.length)
			{
				self.xsrfToken = value;
				[[NSUserDefaults standardUserDefaults] setObject:value forKey:kWFSRAPDefaultsXsrf];
				[[NSUserDefaults standardUserDefaults] synchronize];
				[self writeDebugLog:[NSString stringWithFormat:@"RAP captured xsrf from %@ header", key]];
			}
		}
	}
}

- (void)captureXsrfFromCookies
{
	NSArray* cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:[NSURL URLWithString:kWFSRAPRootURL]];
	for (NSHTTPCookie* cookie in cookies)
	{
		NSString* name = cookie.name.lowercaseString;
		if ([name containsString:@"xsrf"] || [name containsString:@"csrf"] || [name containsString:@"token"])
		{
			if (cookie.value.length)
			{
				self.xsrfToken = cookie.value;
				[[NSUserDefaults standardUserDefaults] setObject:cookie.value forKey:kWFSRAPDefaultsXsrf];
				[[NSUserDefaults standardUserDefaults] synchronize];
				[self writeDebugLog:[NSString stringWithFormat:@"RAP captured xsrf from cookie %@", cookie.name]];
				return;
			}
		}
	}
}

- (BOOL)hasReportAProblemCookies
{
	NSArray* cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:[NSURL URLWithString:kWFSRAPRootURL]];
	for (NSHTTPCookie* cookie in cookies)
	{
		if ([cookie.name isEqualToString:@"user-context"] || [cookie.name isEqualToString:@"dqsid"])
		{
			return YES;
		}
	}
	return NO;
}

- (void)deleteRAPCookies
{
	NSArray* allCookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
	for (NSHTTPCookie* cookie in allCookies)
	{
		NSString* domain = cookie.domain;
		if ([domain containsString:@"idmsa.apple.com"] || [domain containsString:@"reportaproblem.apple.com"] || [domain containsString:@"daiquiri-ext.itunes.apple.com"])
		{
			[[NSHTTPCookieStorage sharedHTTPCookieStorage] deleteCookie:cookie];
		}
	}
}

#pragma mark - Errors and logging

- (NSError*)errorWithCode:(WFSAppleIDDownloaderErrorCode)code message:(NSString*)message
{
	return [NSError errorWithDomain:WFSAppleIDDownloaderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (NSError*)networkError:(NSError*)error
{
	return [NSError errorWithDomain:WFSAppleIDDownloaderErrorDomain code:WFSAppleIDDownloaderErrorNetwork userInfo:@{NSLocalizedDescriptionKey: error.localizedDescription ?: @"Network error.", NSUnderlyingErrorKey: error}];
}

- (void)finishAuth:(WFSRAPAuthCompletion)completion error:(NSError*)error
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		completion(error);
	});
}

- (void)finishHistory:(WFSRAPHistoryCompletion)completion purchases:(NSArray*)purchases response:(NSDictionary*)response error:(NSError*)error
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		completion(purchases, response, error);
	});
}

- (void)writeDebugLog:(NSString*)message
{
	NSString* directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
	NSString* path = [directory stringByAppendingPathComponent:@"WaffleStore_rap.log"];
	NSString* line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
	NSString* existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
	NSString* contents = existing ? [existing stringByAppendingString:line] : line;
	[contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)writeRawJSON:(NSData*)data label:(NSString*)label
{
	if (!data.length)
	{
		return;
	}
	NSString* directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
	NSString* path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"WaffleStore_rap_%@.json", label]];
	[data writeToFile:path atomically:YES];
}

@end