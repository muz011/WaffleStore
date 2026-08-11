#import "WFSRootViewController.h"
#import "WFSVersionPickerViewController.h"
#import "WFSAppleIDDownloader.h"
#import "CoreServices.h"
#import <SystemConfiguration/SystemConfiguration.h>

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

@interface WFSRootViewController ()
@property (nonatomic, strong) UIAlertController* progressAlert;
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

		PSSpecifier* downloadGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		downloadGroupSpecifier.name = @"Download";
		[_specifiers addObject:downloadGroupSpecifier];

		PSSpecifier* downloadSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Download" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
		downloadSpecifier.identifier = @"download";
		[downloadSpecifier setProperty:@YES forKey:@"enabled"];
		downloadSpecifier.buttonAction = @selector(downloadApp);
		[_specifiers addObject:downloadSpecifier];

		PSSpecifier* appleIdDownloadSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Download with Apple ID" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
		appleIdDownloadSpecifier.identifier = @"appleIdDownload";
		[appleIdDownloadSpecifier setProperty:@YES forKey:@"enabled"];
		appleIdDownloadSpecifier.buttonAction = @selector(downloadAppWithAppleID);
		[_specifiers addObject:appleIdDownloadSpecifier];

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

- (void)downloadAppWithAppleID
{
	UIAlertController* linkAlert = [UIAlertController alertControllerWithTitle:@"App Link" message:@"Enter the App Store link to the app you want to download with your Apple ID." preferredStyle:UIAlertControllerStyleAlert];
	[linkAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
	{
		textField.placeholder = @"https://apps.apple.com/app/idXXXXXXXXX";
	}];
	UIAlertAction* continueAction = [UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		long long appId = [self parseAppIdFromLink:linkAlert.textFields.firstObject.text];
		if (appId <= 0)
		{
			[self showAlert:@"Error" message:@"Invalid link"];
			return;
		}
		[self startAppleIDDownloadForAppId:appId];
	}];
	[linkAlert addAction:continueAction];
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
	[self showDownloadProgressWithMessage:@"Signing in to Apple…"];
	[[WFSAppleIDDownloader sharedDownloader] authenticateWithAppleId:email password:password completion:^(NSError* error)
	{
		[self dismissDownloadProgress];
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
		[self showAlert:@"Sign In Failed" message:error.localizedDescription];
		completion(NO);
	}];
}

- (void)promptTwoFactorCodeWithCompletion:(void (^)(BOOL success))completion
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		UIAlertController* codeAlert = [UIAlertController alertControllerWithTitle:@"Two-Factor Authentication" message:@"Enter the verification code sent to your trusted devices." preferredStyle:UIAlertControllerStyleAlert];
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
			[self showDownloadProgressWithMessage:@"Verifying code…"];
			[[WFSAppleIDDownloader sharedDownloader] retryWithTwoFactorCode:code completion:^(NSError* error)
			{
				[self dismissDownloadProgress];
				if (error)
				{
					[self showAlert:@"Sign In Failed" message:error.localizedDescription];
					completion(NO);
					return;
				}
				completion(YES);
			}];
		}];
		[codeAlert addAction:verifyAction];
		UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
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
			[self promptDownloadMethodForAppId:appId versionId:0 metadata:metadata];
			return;
		}
		[self presentVersionPickerWithVersions:list appId:appId completion:^(NSDictionary* selectedVersion)
		{
			long long versionId = [selectedVersion[@"external_identifier"] longLongValue];
			[self promptDownloadMethodForAppId:appId versionId:versionId metadata:metadata];
		}];
	}];
}

- (void)promptDownloadMethodForAppId:(long long)appId versionId:(long long)versionId metadata:(NSDictionary*)metadata
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		UIAlertController* methodAlert = [UIAlertController alertControllerWithTitle:@"Download" message:@"Choose how to get the app." preferredStyle:UIAlertControllerStyleAlert];
		UIAlertAction* appStoreAction = [UIAlertAction actionWithTitle:@"Install via App Store" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			[self downloadAppWithAppId:appId versionId:versionId];
		}];
		[methodAlert addAction:appStoreAction];
		UIAlertAction* saveAction = [UIAlertAction actionWithTitle:@"Save .ipa to Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			[self downloadIPAForAppId:appId versionId:versionId];
		}];
		[methodAlert addAction:saveAction];
		UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
		[methodAlert addAction:cancelAction];
		[self wfsPresentViewController:methodAlert];
	});
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
		NSString* directory = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"Downgrades"];
		[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
		NSString* bundleId = [metadata isKindOfClass:[NSDictionary class]] ? metadata[@"softwareVersionBundleId"] : nil;
		if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0)
		{
			bundleId = [NSString stringWithFormat:@"app%lld", appId];
		}
		NSString* filename = [NSString stringWithFormat:@"%@-%lld-%lld.ipa", bundleId, appId, versionId];
		NSString* destination = [directory stringByAppendingPathComponent:filename];
		NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:ipaURL];
		[request setValue:@"Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6" forHTTPHeaderField:@"User-Agent"];
		[self showDownloadProgressWithMessage:@"Downloading .ipa…"];
		NSURLSessionDownloadTask* task = [[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL* location, NSURLResponse* response, NSError* downloadError)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self dismissDownloadProgress];
				if (downloadError || !location)
				{
					[self showAlert:@"Download Failed" message:downloadError.localizedDescription ?: @"Unknown error."];
					return;
				}
				[[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
				NSError* moveError = nil;
				[[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destination] error:&moveError];
				if (moveError)
				{
					[self showAlert:@"Save Failed" message:moveError.localizedDescription];
					return;
				}
				[self showAlert:@"Downloaded" message:[NSString stringWithFormat:@"Saved to:\n%@\n\nYou can find it in the Files app under WaffleStore.", destination]];
			});
		}];
		[task resume];
	}];
}

@end
