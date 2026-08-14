#import "WFSRootViewController.h"
#import "WFSVersionPickerViewController.h"
#import "WFSAppleIDDownloader.h"
#import "CoreServices.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <zlib.h>

@interface LSApplicationWorkspace (WFSManualInstall)
- (void)_LSPrivateRebuildApplicationDatabasesForSystemApps:(_Bool)systemApps;
@end

@interface SKUIItemStateCenter : NSObject

+ (id)defaultCenter;
- (id)_newPurchasesWithItems:(id)items;
- (void)_performPurchases:(id)purchases hasBundlePurchase:(_Bool)purchase withClientContext:(id)context completionBlock:(id /* block */)block;
- (void)_performSoftwarePurchases:(id)purchases withClientContext:(id)context completionBlock:(id /* block */)block;

@end

@interface SKUIItem : NSObject
- (id)initWithLookupDictionary:(id)dictionary;
@end

@interface SKUIItemOffer : NSObject
- (id)initWithLookupDictionary:(id)dictionary;
@end

@interface SKUIClientContext : NSObject
+ (id)defaultContext;
@end

@interface WFSRootViewController () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) UIAlertController* progressAlert;
@property (nonatomic, strong) UIAlertController* authProgressAlert;
@property (nonatomic, strong) UIProgressView* authProgressView;
@property (nonatomic, strong) UIProgressView* downloadProgressView;
@property (nonatomic, strong) NSURLSession* ipaDownloadSession;
@end

@implementation WFSRootViewController

- (void)loadView
{
	[super loadView];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSpecifiers) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (NSMutableArray*)specifiers
{
	if (!_specifiers)
	{
		_specifiers = [NSMutableArray new];

		PSSpecifier* appleIdGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		appleIdGroupSpecifier.name = @"Apple ID";
		[_specifiers addObject:appleIdGroupSpecifier];

		PSSpecifier* signInSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Sign in to Apple ID" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
		signInSpecifier.identifier = @"signIn";
		[signInSpecifier setProperty:@YES forKey:@"enabled"];
		signInSpecifier.buttonAction = @selector(signInToAppleID);
		[_specifiers addObject:signInSpecifier];

		PSSpecifier* appleIdDownloadSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Download with Apple ID" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
		appleIdDownloadSpecifier.identifier = @"appleIdDownload";
		[appleIdDownloadSpecifier setProperty:@YES forKey:@"enabled"];
		appleIdDownloadSpecifier.buttonAction = @selector(downloadWithAppleID);
		[_specifiers addObject:appleIdDownloadSpecifier];

		NSString* appleIdFooterText = @"Sign in with the Apple ID that owns the app licenses to fetch versions and download removed apps directly from Apple.";
		[appleIdGroupSpecifier setProperty:appleIdFooterText forKey:@"footerText"];

		PSSpecifier* downloadGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		downloadGroupSpecifier.name = @"Download";
		[_specifiers addObject:downloadGroupSpecifier];

		PSSpecifier* downloadSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Download" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
		downloadSpecifier.identifier = @"download";
		[downloadSpecifier setProperty:@YES forKey:@"enabled"];
		downloadSpecifier.buttonAction = @selector(downloadApp);
		[_specifiers addObject:downloadSpecifier];

		NSString* aboutText = [self getAboutText];
		[downloadGroupSpecifier setProperty:aboutText forKey:@"footerText"];

		PSSpecifier* installedGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		installedGroupSpecifier.name = @"Installed Apps";
		[_specifiers addObject:installedGroupSpecifier];

		NSMutableArray* appSpecifiers = [NSMutableArray new];
		[[LSApplicationWorkspace defaultWorkspace] enumerateApplicationsOfType:0 block:^(LSApplicationProxy* appProxy)
		{
			PSSpecifier* appSpecifier = [PSSpecifier preferenceSpecifierNamed:appProxy.localizedName target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
			[appSpecifier setProperty:appProxy.bundleURL forKey:@"bundleURL"];
			if (appProxy.bundleContainerURL)
			{
				[appSpecifier setProperty:appProxy.bundleContainerURL forKey:@"bundleContainerURL"];
			}
			[appSpecifier setProperty:@YES forKey:@"enabled"];
			appSpecifier.buttonAction = @selector(downloadAppShortcut:);
			[appSpecifiers addObject:appSpecifier];
		}];
		[appSpecifiers sortUsingComparator:^NSComparisonResult(PSSpecifier* a, PSSpecifier* b)
		{
			return [a.name compare:b.name];
		}];
		[_specifiers addObjectsFromArray:appSpecifiers];
	}
	[(UINavigationItem*)self.navigationItem setTitle:@"WaffleStore"];
	return _specifiers;
}

- (BOOL)isNetworkReachable
{
	SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, "apis.bilin.eu.org");
	SCNetworkReachabilityFlags flags;
	BOOL reachable = NO;
	if (SCNetworkReachabilityGetFlags(reachability, &flags))
	{
		BOOL isReachable = (flags & kSCNetworkFlagsReachable) != 0;
		BOOL needsConnection = (flags & kSCNetworkFlagsConnectionRequired) != 0;
		reachable = isReachable && !needsConnection;
	}
	CFRelease(reachability);
	return reachable;
}

- (void)wfsPresentViewController:(UIViewController*)viewController
{
	UIViewController* presenter = self.wfsPresentingViewController ?: self;
	[presenter presentViewController:viewController animated:YES completion:nil];
}

- (void)downloadAppShortcut:(PSSpecifier*)specifier
{
	NSURL* bundleURL = [specifier propertyForKey:@"bundleURL"];
	NSDictionary* metadataPlist = [self readITunesMetadataPlistForApp:bundleURL bundleContainerURL:[specifier propertyForKey:@"bundleContainerURL"]];
	long long plistAppId = 0;
	if (metadataPlist)
	{
		plistAppId = [metadataPlist[@"itemId"] longLongValue];
	}
	if (metadataPlist && plistAppId > 0)
	{
		[self getAllAppVersionIdsAndPrompt:plistAppId metadataPlist:metadataPlist];
		return;
	}
	if (![self isNetworkReachable])
	{
		[self showAlert:@"No Internet" message:@"Please check your internet connection and try again."];
		return;
	}
	NSDictionary* infoPlist = [NSDictionary dictionaryWithContentsOfFile:[bundleURL.path stringByAppendingPathComponent:@"Info.plist"]];
	NSString* bundleId = infoPlist[@"CFBundleIdentifier"];
	NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software", bundleId]];
	NSURLRequest* request = [NSURLRequest requestWithURL:url];
	NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		if (error)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self showAlert:@"Error" message:error.localizedDescription];
			});
			return;
		}
		NSError* jsonError = nil;
		NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
		if (jsonError)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self showAlert:@"JSON Error" message:jsonError.localizedDescription];
			});
			return;
		}
		NSArray* results = json[@"results"];
		if (results.count == 0)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self showAlert:@"Error" message:@"No results found for this app."];
			});
			return;
		}
		NSDictionary* app = results[0];
		[self getAllAppVersionIdsAndPrompt:[app[@"trackId"] longLongValue] metadataPlist:nil];
	}];
	[task resume];
}

- (NSDictionary*)readITunesMetadataPlistForApp:(NSURL*)bundleURL bundleContainerURL:(NSURL*)bundleContainerURL
{
	NSFileManager* fileManager = [NSFileManager defaultManager];
	NSMutableArray* candidatePaths = [NSMutableArray new];
	if (bundleContainerURL)
	{
		[candidatePaths addObject:[bundleContainerURL URLByAppendingPathComponent:@"iTunesMetadata.plist"].path];
	}
	if (bundleURL)
	{
		[candidatePaths addObject:[bundleURL URLByAppendingPathComponent:@"iTunesMetadata.plist"].path];
	}
	for (NSString* path in candidatePaths)
	{
		if ([fileManager fileExistsAtPath:path])
		{
			NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:path];
			if (plist)
			{
				return plist;
			}
		}
	}
	return nil;
}

- (NSArray*)versionIdsFromMetadataPlist:(NSDictionary*)metadataPlist
{
	NSArray* versionIds = metadataPlist[@"softwareVersionExternalIdentifiers"];
	if (versionIds.count == 0)
	{
		NSNumber* singleId = metadataPlist[@"softwareVersionExternalIdentifier"];
		if (singleId)
		{
			versionIds = @[singleId];
		}
	}
	return versionIds;
}

- (void)showVersionsFromMetadataPlist:(NSDictionary*)metadataPlist appId:(long long)appId
{
	NSArray* versionIds = [self versionIdsFromMetadataPlist:metadataPlist];
	if (versionIds.count == 0)
	{
		[self showAlert:@"Error" message:@"No version identifiers found in iTunesMetadata.plist."];
		return;
	}
	NSMutableArray* plistVersions = [NSMutableArray new];
	for (NSNumber* versionId in versionIds)
	{
		[plistVersions addObject:@{ @"external_identifier": versionId, @"bundle_version": @"" }];
	}
	if (![self isNetworkReachable])
	{
		NSArray* newestFirst = [[plistVersions reverseObjectEnumerator] allObjects];
		[self presentVersionPickerWithVersions:newestFirst appId:appId];
		return;
	}
	NSString* serverURL = @"https://apis.bilin.eu.org/history/";
	NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%lld", serverURL, appId]];
	NSURLRequest* request = [NSURLRequest requestWithURL:url];
	NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		NSMutableArray* mergedVersions = [NSMutableArray new];
		NSMutableSet* seenIds = [NSMutableSet new];
		if (!error)
		{
			NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
			NSArray* serverVersions = json[@"data"];
			for (NSDictionary* serverVersion in serverVersions)
			{
				NSNumber* externalId = serverVersion[@"external_identifier"];
				if (!externalId || [seenIds containsObject:externalId])
				{
					continue;
				}
				[seenIds addObject:externalId];
				[mergedVersions addObject:serverVersion];
			}
		}
		for (NSDictionary* plistVersion in plistVersions)
		{
			if (![seenIds containsObject:plistVersion[@"external_identifier"]])
			{
				[seenIds addObject:plistVersion[@"external_identifier"]];
				[mergedVersions addObject:plistVersion];
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^
		{
			if (mergedVersions.count == 0)
			{
				[self showAlert:@"Error" message:@"No versions found."];
				return;
			}
			[self presentVersionPickerWithVersions:mergedVersions appId:appId];
		});
	}];
	[task resume];
}

- (void)presentVersionPickerWithVersions:(NSArray*)versions appId:(long long)appId
{
	[self presentVersionPickerWithVersions:versions appId:appId completion:^(NSDictionary* selectedVersion)
	{
		[self downloadAppWithAppId:appId versionId:[selectedVersion[@"external_identifier"] longLongValue]];
	}];
}

- (void)presentVersionPickerWithVersions:(NSArray*)versions appId:(long long)appId completion:(void (^)(NSDictionary* selectedVersion))completion
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		WFSVersionPickerViewController* picker = [[WFSVersionPickerViewController alloc] initWithVersions:versions completion:completion];
		UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:picker];
		nav.modalPresentationStyle = UIModalPresentationFormSheet;
		if (@available(iOS 15.0, *))
		{
			id sheet = [nav performSelector:@selector(sheetPresentationController)];
			Class detentClass = NSClassFromString(@"UISheetPresentationControllerDetent");
			if (sheet && detentClass)
			{
				id medium = [detentClass performSelector:@selector(mediumDetent)];
				id large = [detentClass performSelector:@selector(largeDetent)];
				if (medium && large)
				{
					[sheet setValue:@[medium, large] forKey:@"detents"];
					[sheet setValue:@YES forKey:@"prefersGrabberVisible"];
				}
			}
		}
		[self wfsPresentViewController:nav];
	});
}

- (NSString*)getAboutText
{
	return @"WaffleStore v1.1.0\nMade by muz011, based on MuffinStore by Mineek\nApp Icon designed by Kate\nhttps://github.com/mineek/MuffinStore";
}

- (void)showAlert:(NSString*)title message:(NSString*)message
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		UIAlertController* alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
		UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
		[alert addAction:okAction];
		[self wfsPresentViewController:alert];
	});
}

- (void)showDownloadProgressWithMessage:(NSString*)message
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.progressAlert)
		{
			self.progressAlert.message = message;
			return;
		}
		self.progressAlert = [UIAlertController alertControllerWithTitle:@"Downloading" message:message preferredStyle:UIAlertControllerStyleAlert];
		UIActivityIndicatorView* indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
		indicator.translatesAutoresizingMaskIntoConstraints = NO;
		indicator.tag = 4242;
		[indicator startAnimating];
		[self.progressAlert.view addSubview:indicator];
		[NSLayoutConstraint activateConstraints:@[
			[indicator.centerXAnchor constraintEqualToAnchor:self.progressAlert.view.centerXAnchor],
			[indicator.bottomAnchor constraintEqualToAnchor:self.progressAlert.view.bottomAnchor constant:-20]
		]];
		[self wfsPresentViewController:self.progressAlert];
	});
}

- (void)dismissDownloadProgress
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.progressAlert)
		{
			[self.progressAlert dismissViewControllerAnimated:YES completion:nil];
			self.progressAlert = nil;
			self.downloadProgressView = nil;
		}
	});
}

- (void)showDownloadProgressBarWithMessage:(NSString*)message
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.progressAlert)
		{
			self.progressAlert.title = @"Downloading";
			self.progressAlert.message = message;
			if (!self.downloadProgressView)
			{
				[self addDownloadProgressBarToAlert:self.progressAlert];
			}
			return;
		}
		self.progressAlert = [UIAlertController alertControllerWithTitle:@"Downloading" message:message preferredStyle:UIAlertControllerStyleAlert];
		[self addDownloadProgressBarToAlert:self.progressAlert];
		[self wfsPresentViewController:self.progressAlert];
	});
}

- (void)addDownloadProgressBarToAlert:(UIAlertController*)alert
{
	[[alert.view viewWithTag:4242] removeFromSuperview];
	UIProgressView* progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
	progress.translatesAutoresizingMaskIntoConstraints = NO;
	progress.tintColor = [UIColor systemBlueColor];
	progress.progressTintColor = [UIColor systemBlueColor];
	progress.trackTintColor = [UIColor systemGray5Color];
	progress.progress = 0.0f;
	[alert.view addSubview:progress];
	[NSLayoutConstraint activateConstraints:@[
		[progress.leadingAnchor constraintEqualToAnchor:alert.view.leadingAnchor constant:16],
		[progress.trailingAnchor constraintEqualToAnchor:alert.view.trailingAnchor constant:-16],
		[progress.bottomAnchor constraintEqualToAnchor:alert.view.bottomAnchor constant:-55]
	]];
	self.downloadProgressView = progress;
}

- (void)updateDownloadProgressWithBytesWritten:(int64_t)bytesWritten total:(int64_t)total
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (!self.progressAlert)
		{
			return;
		}
		if (total <= 0)
		{
			self.progressAlert.message = [NSString stringWithFormat:@"Downloading .ipa…\n%@ so far", [self formattedByteCount:bytesWritten]];
			return;
		}
		float fraction = (float)bytesWritten / (float)total;
		self.progressAlert.message = [NSString stringWithFormat:@"Downloading .ipa…\n%@ of %@ (%d%%)", [self formattedByteCount:bytesWritten], [self formattedByteCount:total], (int)(fraction * 100.0f)];
		if (self.downloadProgressView)
		{
			self.downloadProgressView.progress = fraction;
		}
	});
}

- (NSString*)formattedByteCount:(int64_t)bytes
{
	if (bytes >= 1024LL * 1024LL * 1024LL)
	{
		return [NSString stringWithFormat:@"%.2f GB", (double)bytes / 1073741824.0];
	}
	if (bytes >= 1024LL * 1024LL)
	{
		return [NSString stringWithFormat:@"%.1f MB", (double)bytes / 1048576.0];
	}
	if (bytes >= 1024LL)
	{
		return [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
	}
	return [NSString stringWithFormat:@"%lld B", bytes];
}

- (void)showAppleIDAuthProgress
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.authProgressAlert)
		{
			return;
		}
		UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Signing in to Apple" message:@"Attempt 0 of 100…" preferredStyle:UIAlertControllerStyleAlert];
		UIProgressView* progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
		progress.translatesAutoresizingMaskIntoConstraints = NO;
		progress.tintColor = [UIColor systemBlueColor];
		progress.progressTintColor = [UIColor systemBlueColor];
		progress.trackTintColor = [UIColor systemGray5Color];
		[alert.view addSubview:progress];
		[NSLayoutConstraint activateConstraints:@[
			[progress.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
			[progress.bottomAnchor constraintEqualToAnchor:alert.view.bottomAnchor constant:-55],
			[progress.widthAnchor constraintEqualToAnchor:alert.view.widthAnchor multiplier:0.8]
		]];
		[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
		{
			[[WFSAppleIDDownloader sharedDownloader] cancelAuthentication];
		}]];
		self.authProgressAlert = alert;
		self.authProgressView = progress;
		[self wfsPresentViewController:alert];
	});
}

- (void)updateAppleIDAuthProgressAttempt:(NSUInteger)attempt total:(NSUInteger)total
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.authProgressAlert)
		{
			self.authProgressAlert.message = [NSString stringWithFormat:@"Attempt %lu of %lu…", (unsigned long)attempt, (unsigned long)total];
		}
		if (self.authProgressView)
		{
			self.authProgressView.progress = (float)attempt / (float)MAX(total, 1);
		}
	});
}

- (void)dismissAppleIDAuthProgress
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.authProgressAlert)
		{
			[self.authProgressAlert dismissViewControllerAnimated:YES completion:nil];
			self.authProgressAlert = nil;
			self.authProgressView = nil;
		}
	});
}

- (void)getAllAppVersionIdsFromServer:(long long)appId
{
	if (![self isNetworkReachable])
	{
		[self showAlert:@"No Internet" message:@"Please check your internet connection and try again."];
		return;
	}
	NSString* serverURL = @"https://apis.bilin.eu.org/history/";
	NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%lld", serverURL, appId]];
	NSURLRequest* request = [NSURLRequest requestWithURL:url];
	NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		if (error)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self showAlert:@"Error" message:error.localizedDescription];
			});
			return;
		}
		NSError* jsonError = nil;
		NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
		if (jsonError)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self showAlert:@"JSON Error" message:jsonError.debugDescription];
			});
			return;
		}
		NSArray* versionIds = json[@"data"];
		if (versionIds.count == 0)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				UIAlertController* noVersionsAlert = [UIAlertController alertControllerWithTitle:@"No Versions Found" message:@"No version IDs were found on the version server. You can try fetching the version list directly from Apple with your Apple ID." preferredStyle:UIAlertControllerStyleAlert];
				UIAlertAction* appleIdAction = [UIAlertAction actionWithTitle:@"Try Apple ID" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
				{
					[self startAppleIDDownloadForAppId:appId];
				}];
				[noVersionsAlert addAction:appleIdAction];
				UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
				[noVersionsAlert addAction:cancelAction];
				[self wfsPresentViewController:noVersionsAlert];
			});
			return;
		}
		dispatch_async(dispatch_get_main_queue(), ^
		{
			[self presentVersionPickerWithVersions:versionIds appId:appId];
		});
	}];
	[task resume];
}

- (void)promptForVersionId:(long long)appId
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		UIAlertController* versionAlert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Enter the version ID of the app you want to download" preferredStyle:UIAlertControllerStyleAlert];
		[versionAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
		{
			textField.placeholder = @"Version ID";
			textField.keyboardType = UIKeyboardTypeNumberPad;
		}];
		UIAlertAction* downloadAction = [UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			long long versionId = [versionAlert.textFields.firstObject.text longLongValue];
			[self downloadAppWithAppId:appId versionId:versionId];
		}];
		[versionAlert addAction:downloadAction];
		UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
		[versionAlert addAction:cancelAction];
		[self wfsPresentViewController:versionAlert];
	});
}

- (void)downloadLatestForAppId:(long long)appId
{
	if (![self isNetworkReachable])
	{
		[self showAlert:@"No Internet" message:@"Please check your internet connection and try again."];
		return;
	}
	[self downloadAppWithAppId:appId versionId:0];
}

- (void)getAllAppVersionIdsAndPrompt:(long long)appId metadataPlist:(NSDictionary*)metadataPlist
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		UIAlertController* promptAlert = [UIAlertController alertControllerWithTitle:@"Version Selection" message:@"Choose how to select the app version to download." preferredStyle:UIAlertControllerStyleAlert];
		UIAlertAction* latestAction = [UIAlertAction actionWithTitle:@"Download Latest" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			[self downloadLatestForAppId:appId];
		}];
		[promptAlert addAction:latestAction];
		if (metadataPlist && [self versionIdsFromMetadataPlist:metadataPlist].count > 0)
		{
			UIAlertAction* localAction = [UIAlertAction actionWithTitle:@"Use iTunesMetadata.plist" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
			{
				[self showVersionsFromMetadataPlist:metadataPlist appId:appId];
			}];
			[promptAlert addAction:localAction];
		}
		UIAlertAction* serverAction = [UIAlertAction actionWithTitle:@"Browse Version List" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			[self getAllAppVersionIdsFromServer:appId];
		}];
		[promptAlert addAction:serverAction];
		UIAlertAction* appleIdAction = [UIAlertAction actionWithTitle:@"Use Apple ID Version List" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			[self startAppleIDDownloadForAppId:appId];
		}];
		[promptAlert addAction:appleIdAction];
		UIAlertAction* manualAction = [UIAlertAction actionWithTitle:@"Enter Version ID Manually" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			[self promptForVersionId:appId];
		}];
		[promptAlert addAction:manualAction];
		UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
		[promptAlert addAction:cancelAction];
		[self wfsPresentViewController:promptAlert];
	});
}

- (void)downloadAppWithAppId:(long long)appId versionId:(long long)versionId
{
	if (![self isNetworkReachable])
	{
		[self showAlert:@"No Internet" message:@"Please check your internet connection and try again."];
		return;
	}
	[self showDownloadProgressWithMessage:@"Initiating download…"];
	NSString* adamId = [NSString stringWithFormat:@"%lld", appId];
	NSString* pricingParameters = @"pricingParameter";
	NSString* appExtVrsId = [NSString stringWithFormat:@"%lld", versionId];
	NSString* installed = @"0";
	NSString* offerString = nil;
	if (versionId == 0)
	{
		offerString = [NSString stringWithFormat:@"productType=C&price=0&salableAdamId=%@&pricingParameters=%@&clientBuyId=1&installed=%@&trolled=1", adamId, pricingParameters, installed];
	}
	else
	{
		offerString = [NSString stringWithFormat:@"productType=C&price=0&salableAdamId=%@&pricingParameters=%@&appExtVrsId=%@&clientBuyId=1&installed=%@&trolled=1", adamId, pricingParameters, appExtVrsId, installed];
	}
	NSDictionary* offerDict = @{@"buyParams": offerString};
	NSDictionary* itemDict = @{@"_itemOffer": adamId};
	SKUIItemOffer* offer = [[SKUIItemOffer alloc] initWithLookupDictionary:offerDict];
	SKUIItem* item = [[SKUIItem alloc] initWithLookupDictionary:itemDict];
	[item setValue:offer forKey:@"_itemOffer"];
	[item setValue:@"iosSoftware" forKey:@"_itemKindString"];
	if (versionId != 0)
	{
		[item setValue:@(versionId) forKey:@"_versionIdentifier"];
	}
	SKUIItemStateCenter* center = [SKUIItemStateCenter defaultCenter];
	NSArray* items = @[item];
	dispatch_async(dispatch_get_main_queue(), ^
	{
		[self showDownloadProgressWithMessage:@"Purchase request sent. The download will begin in the background."];
		[center _performPurchases:[center _newPurchasesWithItems:items] hasBundlePurchase:0 withClientContext:[SKUIClientContext defaultContext] completionBlock:^(id arg1)
		{
			[self dismissDownloadProgress];
		}];
	});
}

- (long long)parseAppIdFromLink:(NSString*)link
{
	if (![link containsString:@"id"])
	{
		return 0;
	}
	NSArray* components = [link componentsSeparatedByString:@"id"];
	if (components.count < 2)
	{
		return 0;
	}
	NSArray* idComponents = [components[1] componentsSeparatedByString:@"?"];
	NSString* raw = idComponents[0];
	NSMutableString* digits = [NSMutableString string];
	for (NSUInteger i = 0; i < raw.length; i++)
	{
		unichar c = [raw characterAtIndex:i];
		if (c >= '0' && c <= '9')
		{
			[digits appendFormat:@"%C", c];
		}
		else
		{
			break;
		}
	}
	return [digits longLongValue];
}

- (void)downloadAppWithLink:(NSString*)link
{
	if (![self isNetworkReachable])
	{
		[self showAlert:@"No Internet" message:@"Please check your internet connection and try again."];
		return;
	}
	long long targetAppIdParsed = [self parseAppIdFromLink:link];
	if (targetAppIdParsed <= 0)
	{
		[self showAlert:@"Error" message:@"Invalid link"];
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^
	{
		[self getAllAppVersionIdsAndPrompt:targetAppIdParsed metadataPlist:nil];
	});
}

- (void)downloadApp
{
	UIAlertController* linkAlert = [UIAlertController alertControllerWithTitle:@"App Link" message:@"Enter the App Store link to the app you want to download" preferredStyle:UIAlertControllerStyleAlert];
	[linkAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
	{
		textField.placeholder = @"https://apps.apple.com/app/idXXXXXXXXX";
	}];
	UIAlertAction* downloadAction = [UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		[self downloadAppWithLink:linkAlert.textFields.firstObject.text];
	}];
	[linkAlert addAction:downloadAction];
	UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
	[linkAlert addAction:cancelAction];
	[self wfsPresentViewController:linkAlert];
}

#pragma mark - Apple ID download

- (void)signInToAppleID
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	if (downloader.isAuthenticated)
	{
		[self showAlert:@"Already Signed In" message:[NSString stringWithFormat:@"You are signed in as %@.\n\nThis session is used to fetch versions and download removed apps directly from Apple.", downloader.authenticatedAppleId.length ? downloader.authenticatedAppleId : @"your Apple ID"]];
		return;
	}
	[self promptAppleIDCredentialsWithCompletion:^(BOOL success)
	{
		if (success)
		{
			[self showAlert:@"Signed In" message:@"You are signed in to Apple.\n\nYou can now use Download with Apple ID for removed apps, and your purchase history is synced into the Purchased tab."];
		}
	}];
}

- (void)downloadWithAppleID
{
	if (![self isNetworkReachable])
	{
		[self showAlert:@"No Internet" message:@"Please check your internet connection and try again."];
		return;
	}
	UIAlertController* linkAlert = [UIAlertController alertControllerWithTitle:@"App Link" message:@"Enter the App Store link or App ID of the app you want to download with your Apple ID." preferredStyle:UIAlertControllerStyleAlert];
	[linkAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
	{
		textField.placeholder = @"https://apps.apple.com/app/idXXXXXXXXX";
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
	}];
	UIAlertAction* downloadAction = [UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		NSString* input = [linkAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (input.length == 0)
		{
			[self showAlert:@"Error" message:@"Please enter an App Store link or App ID."];
			return;
		}
		NSCharacterSet* digits = [NSCharacterSet decimalDigitCharacterSet];
		long long appId = 0;
		if ([input rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound)
		{
			appId = [input longLongValue];
		}
		else
		{
			appId = [self parseAppIdFromLink:input];
		}
		if (appId <= 0)
		{
			[self showAlert:@"Error" message:@"Invalid link"];
			return;
		}
		[self startAppleIDDownloadForAppId:appId];
	}];
	[linkAlert addAction:downloadAction];
	UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
	[linkAlert addAction:cancelAction];
	[self wfsPresentViewController:linkAlert];
}

- (void)startAppleIDDownloadForAppId:(long long)appId
{
	if (![self isNetworkReachable])
	{
		[self showAlert:@"No Internet" message:@"Please check your internet connection and try again."];
		return;
	}
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	if (!downloader.isAuthenticated)
	{
		[self promptAppleIDCredentialsWithCompletion:^(BOOL success)
		{
			if (success)
			{
				[self fetchAppleIDVersionsForAppId:appId];
			}
		}];
		return;
	}
	[self fetchAppleIDVersionsForAppId:appId];
}

- (void)promptAppleIDCredentialsWithCompletion:(void (^)(BOOL success))completion
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		UIAlertController* signInAlert = [UIAlertController alertControllerWithTitle:@"Apple ID" message:@"Sign in to Apple to fetch the app's version list directly from the App Store.\n\nYour password is only used for this request and is never stored." preferredStyle:UIAlertControllerStyleAlert];
		[signInAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
		{
			textField.placeholder = @"Apple ID email";
			textField.keyboardType = UIKeyboardTypeEmailAddress;
			textField.autocorrectionType = UITextAutocorrectionTypeNo;
			textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
			textField.text = [[NSUserDefaults standardUserDefaults] objectForKey:@"wfsAppleIDEmail"];
		}];
		[signInAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
		{
			textField.placeholder = @"Password";
			textField.secureTextEntry = YES;
		}];
		UIAlertAction* signInAction = [UIAlertAction actionWithTitle:@"Sign In" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			NSString* email = signInAlert.textFields.firstObject.text;
			NSString* password = signInAlert.textFields[1].text;
			if (email.length == 0 || password.length == 0)
			{
				[self showAlert:@"Error" message:@"Please enter your Apple ID and password."];
				completion(NO);
				return;
			}
			[self authenticateAppleIDWithEmail:email password:password completion:completion];
		}];
		[signInAlert addAction:signInAction];
		UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
		[signInAlert addAction:cancelAction];
		[self wfsPresentViewController:signInAlert];
	});
}

- (void)authenticateAppleIDWithEmail:(NSString*)email password:(NSString*)password completion:(void (^)(BOOL success))completion
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	downloader.authProgressHandler = ^(NSUInteger attempt, NSUInteger totalAttempts)
	{
		[self updateAppleIDAuthProgressAttempt:attempt total:totalAttempts];
	};
	[self showAppleIDAuthProgress];
	[downloader authenticateWithAppleId:email password:password completion:^(NSError* error)
	{
		[downloader setAuthProgressHandler:nil];
		[self dismissAppleIDAuthProgress];
		if (!error)
		{
			completion(YES);
			return;
		}
		if (error.code == WFSAppleIDDownloaderError2FARequired)
		{
			[self promptTwoFactorCodeWithCompletion:completion];
			return;
		}
		if (error.code == WFSAppleIDDownloaderErrorCancelled)
		{
			completion(NO);
			return;
		}
		[self showAlert:@"Sign In Failed" message:error.localizedDescription];
		completion(NO);
	}];
}

- (void)promptTwoFactorCodeWithCompletion:(void (^)(BOOL success))completion
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		UIAlertController* codeAlert = [UIAlertController alertControllerWithTitle:@"Two-Factor Authentication" message:@"Enter the 6-digit verification code for this Apple ID.\n\nNo code arrived? Generate one from any device signed in to this Apple ID: Settings > [your name] > Sign-in & Security > Two-Factor Authentication > Get Verification Code. Codes expire quickly, so enter it right away." preferredStyle:UIAlertControllerStyleAlert];
		[codeAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
		{
			textField.placeholder = @"6-digit code";
			textField.keyboardType = UIKeyboardTypeNumberPad;
		}];
		UIAlertAction* verifyAction = [UIAlertAction actionWithTitle:@"Verify" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			NSString* code = codeAlert.textFields.firstObject.text;
			if (code.length == 0)
			{
				completion(NO);
				return;
			}
			WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
			downloader.authProgressHandler = ^(NSUInteger attempt, NSUInteger totalAttempts)
			{
				[self updateAppleIDAuthProgressAttempt:attempt total:totalAttempts];
			};
			[self showAppleIDAuthProgress];
			[downloader retryWithTwoFactorCode:code completion:^(NSError* error)
			{
				[downloader setAuthProgressHandler:nil];
				[self dismissAppleIDAuthProgress];
				if (error)
				{
					if (error.code == WFSAppleIDDownloaderErrorCancelled)
					{
						completion(NO);
						return;
					}
					if (error.code == WFSAppleIDDownloaderError2FARequired)
					{
						[self showAlert:@"Sign In Failed" message:@"The verification code was rejected or expired. Make sure the code is fresh and your Apple ID password is correct, then try signing in again."];
						completion(NO);
						return;
					}
					if (error.code == WFSAppleIDDownloaderErrorPasswordTokenExpired)
					{
						[self showAlert:@"Sign In Failed" message:@"Your Apple ID session has expired. Please sign in again."];
						completion(NO);
						return;
					}
					[self showAlert:@"Sign In Failed" message:error.localizedDescription];
					completion(NO);
					return;
				}
				completion(YES);
			}];
		}];
		[codeAlert addAction:verifyAction];
		UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
		{
			[[WFSAppleIDDownloader sharedDownloader] cancelAuthentication];
			completion(NO);
		}];
		[codeAlert addAction:cancelAction];
		[self wfsPresentViewController:codeAlert];
	});
}

- (void)fetchAppleIDVersionsForAppId:(long long)appId
{
	[self showDownloadProgressWithMessage:@"Fetching version list from Apple…"];
	[[WFSAppleIDDownloader sharedDownloader] getVersionsForAppId:appId completion:^(NSArray* versions, NSDictionary* metadata, NSError* error)
	{
		[self dismissDownloadProgress];
		if (error)
		{
			if (error.code == WFSAppleIDDownloaderErrorLicenseNotFound)
			{
				[self showAlert:@"Not Purchased" message:[NSString stringWithFormat:@"%@\n\nApple only allows downloading apps that are free or that have been purchased with this Apple ID.", error.localizedDescription]];
				return;
			}
			[self showAlert:@"Apple ID Error" message:error.localizedDescription];
			return;
		}
		NSMutableArray* list = [NSMutableArray arrayWithArray:versions];
		NSString* currentVersion = [metadata isKindOfClass:[NSDictionary class]] ? metadata[@"bundleShortVersionString"] : nil;
		if (![currentVersion isKindOfClass:[NSString class]] || currentVersion.length == 0)
		{
			currentVersion = @"Latest";
		}
		[list insertObject:@{@"external_identifier": @0, @"bundle_version": currentVersion} atIndex:0];
		if (list.count == 1)
		{
			[self downloadIPAForAppId:appId versionId:0];
			return;
		}
		[self presentVersionPickerWithVersions:list appId:appId completion:^(NSDictionary* selectedVersion)
		{
			long long versionId = [selectedVersion[@"external_identifier"] longLongValue];
			[self downloadIPAForAppId:appId versionId:versionId];
		}];
	}];
}

- (void)downloadIPAForAppId:(long long)appId versionId:(long long)versionId
{
	if (![self isNetworkReachable])
	{
		[self showAlert:@"No Internet" message:@"Please check your internet connection and try again."];
		return;
	}
	[self showDownloadProgressWithMessage:@"Getting download link from Apple…"];
	[[WFSAppleIDDownloader sharedDownloader] getDownloadInfoForAppId:appId versionId:versionId completion:^(NSURL* ipaURL, NSDictionary* metadata, NSError* error)
	{
		if (error)
		{
			[self dismissDownloadProgress];
			if (error.code == WFSAppleIDDownloaderErrorLicenseNotFound)
			{
				[self showAlert:@"Not Purchased" message:[NSString stringWithFormat:@"%@\n\nApple only allows downloading apps that are free or that have been purchased with this Apple ID.", error.localizedDescription]];
				return;
			}
			[self showAlert:@"Apple ID Error" message:error.localizedDescription];
			return;
		}
		NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:ipaURL];
		[request setValue:@"Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6" forHTTPHeaderField:@"User-Agent"];
		[self showDownloadProgressBarWithMessage:@"Downloading .ipa…"];
		NSURLSessionConfiguration* configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
		self.ipaDownloadSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
		NSURLSessionDownloadTask* task = [self.ipaDownloadSession downloadTaskWithRequest:request];
		[task resume];
	}];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession*)session downloadTask:(NSURLSessionDownloadTask*)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
	[self updateDownloadProgressWithBytesWritten:totalBytesWritten total:totalBytesExpectedToWrite];
}

- (void)URLSession:(NSURLSession*)session downloadTask:(NSURLSessionDownloadTask*)downloadTask didFinishDownloadingToURL:(NSURL*)location
{
	if (!location)
	{
		return;
	}
	NSString* destination = [self destinationPathForDownloadTask:downloadTask];
	NSFileManager* fileManager = [NSFileManager defaultManager];
	[fileManager removeItemAtPath:destination error:nil];
	NSError* moveError = nil;
	[fileManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:destination] error:&moveError];
	dispatch_async(dispatch_get_main_queue(), ^
	{
		[self dismissDownloadProgress];
		if (moveError)
		{
			[self showAlert:@"Save Failed" message:moveError.localizedDescription];
			return;
		}
		[self installIPAAutomaticallyAtPath:destination];
	});
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error
{
	if (error)
	{
		dispatch_async(dispatch_get_main_queue(), ^
		{
			[self dismissDownloadProgress];
			[self showAlert:@"Download Failed" message:error.localizedDescription ?: @"Unknown error."];
		});
	}
	[session finishTasksAndInvalidate];
	if (self.ipaDownloadSession == session)
	{
		self.ipaDownloadSession = nil;
	}
}

- (NSString*)destinationPathForDownloadTask:(NSURLSessionDownloadTask*)downloadTask
{
	NSURL* ipaURL = downloadTask.response.URL ?: downloadTask.originalRequest.URL;
	NSString* filename = [ipaURL.lastPathComponent length] > 0 ? ipaURL.lastPathComponent : @"app.ipa";
	if (![filename hasSuffix:@".ipa"])
	{
		filename = [filename stringByAppendingString:@".ipa"];
	}
	NSString* directory = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"Downgrades"];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
	return [directory stringByAppendingPathComponent:filename];
}

- (void)installIPAAutomaticallyAtPath:(NSString*)path
{
	[self showDownloadProgressWithMessage:@"Preparing app for install…"];
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^
	{
		NSError* error = nil;
		NSString* extractedAppPath = [self extractAppBundleFromIPAAtPath:path error:&error];
		if (!extractedAppPath)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self dismissDownloadProgress];
				[self showAlert:@"Install Failed" message:[NSString stringWithFormat:@"Could not extract the .ipa (%@). The .ipa is saved to:\n%@\n\nInstall it with TrollStore or Filza.", error.localizedDescription, path]];
			});
			return;
		}
		NSString* installedPath = [self copyAppBundleToSystemAtPath:extractedAppPath error:&error];
		[[NSFileManager defaultManager] removeItemAtPath:[extractedAppPath stringByDeletingLastPathComponent] error:nil];
		if (!installedPath)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self dismissDownloadProgress];
				[self showAlert:@"Install Failed" message:[NSString stringWithFormat:@"Could not install the app (%@). The .ipa is saved to:\n%@\n\nInstall it with TrollStore or Filza.", error.localizedDescription, path]];
			});
			return;
		}
		[[LSApplicationWorkspace defaultWorkspace] _LSPrivateRebuildApplicationDatabasesForSystemApps:NO];
		dispatch_async(dispatch_get_main_queue(), ^
		{
			[self dismissDownloadProgress];
			[self showAlert:@"Installed" message:[NSString stringWithFormat:@"The app was installed successfully.\n\nSaved .ipa:\n%@", path]];
		});
	});
}

- (NSString*)extractAppBundleFromIPAAtPath:(NSString*)ipaPath error:(NSError**)error
{
	NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:ipaPath error:nil];
	unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
	NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:ipaPath];
	if (!handle)
	{
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError userInfo:@{NSLocalizedDescriptionKey: @"cannot open the .ipa file"}];
		}
		return nil;
	}
	unsigned long long searchFrom = fileSize > 70000 ? fileSize - 70000 : 0;
	[handle seekToFileOffset:searchFrom];
	NSData* tail = [handle readDataToEndOfFile];
	const uint8_t* tailBytes = tail.bytes;
	NSInteger eocd = -1;
	for (NSInteger i = (NSInteger)tail.length - 22; i >= 0; i--)
	{
		if (tailBytes[i] == 0x50 && tailBytes[i + 1] == 0x4B && tailBytes[i + 2] == 0x05 && tailBytes[i + 3] == 0x06)
		{
			eocd = i;
			break;
		}
	}
	if (eocd < 0)
	{
		[handle closeFile];
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSLocalizedDescriptionKey: @"not a valid zip archive"}];
		}
		return nil;
	}
	uint16_t entryCount = tailBytes[eocd + 10] | (tailBytes[eocd + 11] << 8);
	uint32_t cdSize = (uint32_t)(tailBytes[eocd + 12] | (tailBytes[eocd + 13] << 8) | (tailBytes[eocd + 14] << 16) | (tailBytes[eocd + 15] << 24));
	uint32_t cdOffset = (uint32_t)(tailBytes[eocd + 16] | (tailBytes[eocd + 17] << 8) | (tailBytes[eocd + 18] << 16) | (tailBytes[eocd + 19] << 24));
	[handle seekToFileOffset:cdOffset];
	NSMutableData* centralData = [NSMutableData data];
	while (centralData.length < cdSize)
	{
		NSData* chunk = [handle readDataOfLength:(NSUInteger)(cdSize - (uint32_t)centralData.length)];
		if (chunk.length == 0)
		{
			break;
		}
		[centralData appendData:chunk];
	}
	[handle closeFile];
	const uint8_t* cd = centralData.bytes;
	NSInteger centralLength = centralData.length;
	NSString* appDirectoryName = nil;
	NSMutableArray* fileEntries = [NSMutableArray array];
	NSInteger pos = 0;
	for (uint16_t i = 0; i < entryCount && pos + 46 <= centralLength; i++)
	{
		if (cd[pos] != 0x50 || cd[pos + 1] != 0x4B || cd[pos + 2] != 0x01 || cd[pos + 3] != 0x02)
		{
			break;
		}
		uint16_t method = cd[pos + 10] | (cd[pos + 11] << 8);
		uint32_t compSize = (uint32_t)(cd[pos + 20] | (cd[pos + 21] << 8) | (cd[pos + 22] << 16) | (cd[pos + 23] << 24));
		uint16_t nameLength = cd[pos + 28] | (cd[pos + 29] << 8);
		uint16_t extraLength = cd[pos + 30] | (cd[pos + 31] << 8);
		uint16_t commentLength = cd[pos + 32] | (cd[pos + 33] << 8);
		uint32_t localOffset = (uint32_t)(cd[pos + 42] | (cd[pos + 43] << 8) | (cd[pos + 44] << 16) | (cd[pos + 45] << 24));
		NSString* name = [[NSString alloc] initWithBytes:(cd + pos + 46) length:nameLength encoding:NSUTF8StringEncoding];
		pos += 46 + nameLength + extraLength + commentLength;
		if (name.length == 0 || [name hasPrefix:@"__MACOSX"])
		{
			continue;
		}
		if (!appDirectoryName && [name hasPrefix:@"Payload/"] && [name hasSuffix:@"/"] && [name rangeOfString:@"/" options:0 range:NSMakeRange(0, name.length - 1)].location == 7)
		{
			appDirectoryName = name;
		}
		if (!appDirectoryName || ![name hasPrefix:appDirectoryName])
		{
			continue;
		}
		[fileEntries addObject:@{ @"name": name, @"method": @(method), @"compSize": @(compSize), @"localOffset": @(localOffset) }];
	}
	if (!appDirectoryName)
	{
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSLocalizedDescriptionKey: @"no .app found in the .ipa"}];
		}
		return nil;
	}
	NSString* outputRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	NSString* appDirectoryPath = [outputRoot stringByAppendingPathComponent:appDirectoryName];
	[[NSFileManager defaultManager] createDirectoryAtPath:appDirectoryPath withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
	NSFileHandle* readHandle = [NSFileHandle fileHandleForReadingAtPath:ipaPath];
	if (!readHandle)
	{
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError userInfo:@{NSLocalizedDescriptionKey: @"cannot open the .ipa file"}];
		}
		return nil;
	}
	BOOL extractedAll = YES;
	for (NSDictionary* entry in fileEntries)
	{
		NSString* entryName = entry[@"name"];
		NSString* relativePath = [entryName substringFromIndex:appDirectoryName.length];
		if (relativePath.length == 0)
		{
			continue;
		}
		NSString* outputPath = [outputRoot stringByAppendingPathComponent:entryName];
		if ([entryName hasSuffix:@"/"])
		{
			[[NSFileManager defaultManager] createDirectoryAtPath:outputPath withIntermediateDirectories:YES attributes:nil error:nil];
			continue;
		}
		uint32_t localOffset = [entry[@"localOffset"] unsignedIntValue];
		[readHandle seekToFileOffset:localOffset];
		NSData* localHeader = [readHandle readDataOfLength:30];
		if (localHeader.length < 30)
		{
			extractedAll = NO;
			break;
		}
		const uint8_t* lh = localHeader.bytes;
		uint16_t localNameLength = lh[26] | (lh[27] << 8);
		uint16_t localExtraLength = lh[28] | (lh[29] << 8);
		[readHandle seekToFileOffset:localOffset + 30 + localNameLength + localExtraLength];
		[[NSFileManager defaultManager] createDirectoryAtPath:[outputPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
		BOOL success = NO;
		uint32_t compSize = [entry[@"compSize"] unsignedIntValue];
		uint16_t method = [entry[@"method"] unsignedShortValue];
		if (method == 0)
		{
			NSFileHandle* outHandle = [NSFileHandle fileHandleForWritingAtPath:outputPath];
			if (outHandle)
			{
				long long remaining = compSize;
				while (remaining > 0)
				{
					NSData* chunk = [readHandle readDataOfLength:(NSUInteger)MIN(remaining, 1048576LL)];
					if (chunk.length == 0)
					{
						break;
					}
					[outHandle writeData:chunk];
					remaining -= chunk.length;
				}
				[outHandle closeFile];
				success = remaining == 0;
			}
		}
		else if (method == 8)
		{
			success = [self inflateZipEntryFromHandle:readHandle compressedSize:compSize toPath:outputPath];
		}
		if (success)
		{
			[[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:outputPath error:nil];
		}
		else
		{
			extractedAll = NO;
			break;
		}
	}
	[readHandle closeFile];
	if (!extractedAll)
	{
		[[NSFileManager defaultManager] removeItemAtPath:outputRoot error:nil];
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSLocalizedDescriptionKey: @"could not extract the app bundle"}];
		}
		return nil;
	}
	return appDirectoryPath;
}

- (BOOL)inflateZipEntryFromHandle:(NSFileHandle*)handle compressedSize:(uint32_t)compressedSize toPath:(NSString*)outputPath
{
	NSFileHandle* outHandle = [NSFileHandle fileHandleForWritingAtPath:outputPath];
	if (!outHandle)
	{
		return NO;
	}
	z_stream stream;
	memset(&stream, 0, sizeof(stream));
	if (inflateInit2(&stream, -MAX_WBITS) != Z_OK)
	{
		[outHandle closeFile];
		return NO;
	}
	uint8_t inBuffer[65536];
	uint8_t outBuffer[65536];
	uint32_t remaining = compressedSize;
	int ret = Z_OK;
	while (remaining > 0 && ret != Z_STREAM_END)
	{
		NSData* chunk = [handle readDataOfLength:(NSUInteger)MIN(remaining, (uint32_t)sizeof(inBuffer))];
		if (chunk.length == 0)
		{
			break;
		}
		remaining -= (uint32_t)chunk.length;
		stream.next_in = (Bytef*)chunk.bytes;
		stream.avail_in = (uInt)chunk.length;
		do
		{
			stream.next_out = outBuffer;
			stream.avail_out = sizeof(outBuffer);
			ret = inflate(&stream, Z_NO_FLUSH);
			if (ret != Z_OK && ret != Z_STREAM_END)
			{
				break;
			}
			[outHandle writeData:[NSData dataWithBytes:outBuffer length:sizeof(outBuffer) - stream.avail_out]];
		} while (stream.avail_out == 0);
		if (ret != Z_OK && ret != Z_STREAM_END)
		{
			break;
		}
	}
	inflateEnd(&stream);
	[outHandle closeFile];
	return ret == Z_STREAM_END;
}

- (NSString*)copyAppBundleToSystemAtPath:(NSString*)appPath error:(NSError**)error
{
	NSString* bundleRoot = @"/var/containers/Bundle/Application";
	NSFileManager* fileManager = [NSFileManager defaultManager];
	if (![fileManager fileExistsAtPath:bundleRoot])
	{
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:@{NSLocalizedDescriptionKey: @"app bundle container is not available on this device"}];
		}
		return nil;
	}
	NSString* containerPath = [bundleRoot stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	if (![fileManager createDirectoryAtPath:containerPath withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:error])
	{
		return nil;
	}
	NSString* targetPath = [containerPath stringByAppendingPathComponent:appPath.lastPathComponent];
	if (![fileManager copyItemAtPath:appPath toPath:targetPath error:error])
	{
		[fileManager removeItemAtPath:containerPath error:nil];
		return nil;
	}
	return targetPath;
}

@end
