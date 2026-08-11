#import "WFSPurchasedAppsViewController.h"
#import "WFSAppleStore.h"
#import "WFSDevicePurchaseScanner.h"
#import "CoreServices.h"

static dispatch_queue_t WFSMergeQueue(void)
{
	static dispatch_queue_t queue;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^
	{
		queue = dispatch_queue_create("dev.muz011.wafflestore.merge", NULL);
	});
	return queue;
}

@interface WFSPurchasedAppsViewController ()
@property (nonatomic, copy) void (^selectionHandler)(long long appId, NSDictionary* metadataPlist);
@property (nonatomic, strong) NSMutableArray* allApps;
@property (nonatomic, strong) NSMutableArray* visibleApps;
@property (nonatomic, strong) NSMutableDictionary* storeInfo;
@property (nonatomic, strong) NSMutableSet* removedStoreIDs;
@property (nonatomic, strong) NSMutableSet* installedBundleIDs;
@property (nonatomic, strong) NSMutableSet* localScannedKeys;
@property (nonatomic, strong) NSCache* imageCache;
@property (nonatomic, strong) UISegmentedControl* filterControl;
@property (nonatomic, strong) UILabel* accountLabel;
@property (nonatomic, strong) UILabel* statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView* spinner;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL didAppear;
@property (nonatomic, assign) BOOL didLoadHistory;
@end

static NSString* const WFSPurchasedCellIdentifier = @"WFSPurchasedCellIdentifier";

@implementation WFSPurchasedAppsViewController

- (instancetype)initWithSelectionHandler:(void (^)(long long appId, NSDictionary* metadataPlist))selectionHandler
{
	self = [super initWithStyle:UITableViewStylePlain];
	if (self)
	{
		self.selectionHandler = selectionHandler;
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Purchased Apps";
	self.allApps = [NSMutableArray new];
	self.visibleApps = [NSMutableArray new];
	self.storeInfo = [NSMutableDictionary new];
	self.removedStoreIDs = [NSMutableSet new];
	self.localScannedKeys = [NSMutableSet new];
	self.imageCache = [NSCache new];
	self.tableView.rowHeight = 60;
	self.tableView.tableFooterView = [UIView new];

	[self setupHeaderView];

	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(loadPurchases)];

	UIRefreshControl* refreshControl = [UIRefreshControl new];
	[refreshControl addTarget:self action:@selector(loadPurchases) forControlEvents:UIControlEventValueChanged];
	self.refreshControl = refreshControl;
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	if (!self.didAppear)
	{
		self.didAppear = YES;
		[self loadPurchases];
	}
}

- (void)setupHeaderView
{
	CGFloat width = self.tableView.bounds.size.width;
	if (width <= 0)
	{
		width = [UIScreen mainScreen].bounds.size.width;
	}
	UIView* header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 124)];

	self.accountLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, width - 32, 20)];
	self.accountLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	self.accountLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
	self.accountLabel.textColor = [UIColor secondaryLabelColor];
	self.accountLabel.text = @"Checking signed-in Apple ID…";
	[header addSubview:self.accountLabel];

	self.filterControl = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Not Installed", @"Removed"]];
	self.filterControl.frame = CGRectMake(16, 36, width - 32, 32);
	self.filterControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	self.filterControl.selectedSegmentIndex = 0;
	NSDictionary* segmentFont = @{NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]};
	[self.filterControl setTitleTextAttributes:segmentFont forState:UIControlStateNormal];
	[self.filterControl setTitleTextAttributes:segmentFont forState:UIControlStateSelected];
	[self.filterControl addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
	[header addSubview:self.filterControl];

	UIView* statusView = [[UIView alloc] initWithFrame:CGRectMake(16, 74, width - 32, 26)];
	statusView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
	self.spinner.frame = CGRectMake(0, 0, 24, 24);
	[statusView addSubview:self.spinner];

	self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(28, 2, statusView.bounds.size.width - 28, 22)];
	self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	self.statusLabel.font = [UIFont systemFontOfSize:13];
	self.statusLabel.textColor = [UIColor secondaryLabelColor];
	self.statusLabel.numberOfLines = 2;
	[statusView addSubview:self.statusLabel];

	[header addSubview:statusView];
	self.tableView.tableHeaderView = header;
}

- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];
	UIView* header = self.tableView.tableHeaderView;
	if (!header)
	{
		return;
	}
	CGFloat width = self.tableView.bounds.size.width;
	if (width <= 0)
	{
		width = [UIScreen mainScreen].bounds.size.width;
	}
	if (fabs(header.bounds.size.width - width) > 0.5)
	{
		header.frame = CGRectMake(0, 0, width, header.bounds.size.height);
	}
	self.accountLabel.frame = CGRectMake(16, 10, width - 32, 20);
	self.filterControl.frame = CGRectMake(16, 36, width - 32, 32);
	UIView* statusView = self.statusLabel.superview;
	statusView.frame = CGRectMake(16, 74, width - 32, 26);
	self.statusLabel.frame = CGRectMake(28, 2, statusView.bounds.size.width - 28, 22);
}

- (void)setLoading:(BOOL)loading
{
	_loading = loading;
	[self.spinner setHidden:!loading];
	if (loading)
	{
		[self.spinner startAnimating];
	}
	else
	{
		[self.spinner stopAnimating];
		[self.refreshControl endRefreshing];
	}
}

- (void)handleStoreUnavailable:(NSString*)message
{
	[self setLoading:NO];
	self.accountLabel.text = @"Not signed in";
	self.statusLabel.hidden = NO;
	self.statusLabel.text = message;
	[self showError:@"Apple ID Unavailable" message:message];
}

- (void)loadPurchases
{
	NSLog(@"[WaffleStore] Purchases: loadPurchases begin");
	if (self.loading)
	{
		[self.refreshControl endRefreshing];
		return;
	}
	self.didLoadHistory = NO;
	@try
	{
		Class accountStoreClass = NSClassFromString(@"SSAccountStore");
		if (!accountStoreClass || ![accountStoreClass respondsToSelector:@selector(defaultStore)])
		{
			NSLog(@"[WaffleStore] Purchases: SSAccountStore unavailable");
			[self handleStoreUnavailable:@"The App Store account service is unavailable on this iOS version."];
			return;
		}
		id accountStore = [accountStoreClass defaultStore];
		id account = nil;
		if (accountStore && [accountStore respondsToSelector:@selector(activeAccount)])
		{
			account = [accountStore activeAccount];
		}
		NSLog(@"[WaffleStore] Purchases: activeAccount = %@", account);
		if (!account)
		{
			[self.refreshControl endRefreshing];
			[self promptSignIn];
			return;
		}

		NSString* accountName = nil;
		if ([account respondsToSelector:@selector(accountName)])
		{
			accountName = [account accountName];
		}
		self.accountLabel.text = [NSString stringWithFormat:@"Signed in as: %@", accountName.length ? accountName : @"Apple ID"];
		self.statusLabel.hidden = NO;
		self.statusLabel.text = @"Loading purchases…";
		self.statusLabel.textColor = [UIColor secondaryLabelColor];
		[self setLoading:YES];

		long long dsid = 0;
		if ([account respondsToSelector:@selector(uniqueIdentifier)])
		{
			NSNumber* uniqueIdentifier = [account uniqueIdentifier];
			dsid = [uniqueIdentifier longLongValue];
		}
		if (dsid == 0 && [account respondsToSelector:NSSelectorFromString(@"dsid")])
		{
			dsid = [[account valueForKey:@"dsid"] longLongValue];
		}
		NSLog(@"[WaffleStore] Purchases: dsid = %lld", dsid);
		if (dsid == 0)
		{
			[self setLoading:NO];
			[self showError:@"Account Error" message:@"Could not read the Apple ID for the signed-in account."];
			return;
		}

		Class historyClass = NSClassFromString(@"ASDPurchaseHistory");
		if (!historyClass || ![historyClass respondsToSelector:@selector(sharedInstance)])
		{
			[self setLoading:NO];
			[self showError:@"Purchase History Unavailable" message:@"The App Store purchase library service is unavailable on this iOS version."];
			return;
		}
		id history = [historyClass sharedInstance];
		if (![history respondsToSelector:@selector(updateForAccountID:withCompletionHandler:)])
		{
			[self setLoading:NO];
			[self showError:@"Purchase History Unavailable" message:@"The App Store purchase library service is unavailable on this iOS version."];
			return;
		}
		__weak typeof(self) weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^
		{
			__strong typeof(weakSelf) self = weakSelf;
			if (self.loading && !self.didLoadHistory)
			{
				[self setLoading:NO];
				[self showError:@"Purchase History Unavailable" message:@"The App Store did not respond in time. Check your connection and try again."];
			}
		});
		[history updateForAccountID:dsid withCompletionHandler:^(NSError* error)
		{
			@try
			{
				__strong typeof(weakSelf) self = weakSelf;
				NSLog(@"[WaffleStore] Purchases: updateForAccountID error = %@", error);
				if (error)
				{
					dispatch_async(dispatch_get_main_queue(), ^
					{
						[self setLoading:NO];
						[self showError:@"Purchase History Unavailable" message:error.localizedDescription];
					});
					return;
				}
				dispatch_async(dispatch_get_main_queue(), ^
				{
					[self runHistoryQueriesWithDSID:dsid];
				});
			}
			@catch (NSException* exception)
			{
				NSLog(@"[WaffleStore] Purchases: update exception %@ %@", exception.name, exception.reason);
			}
		}];
	}
	@catch (NSException* exception)
	{
		NSLog(@"[WaffleStore] Purchases: exception %@ %@", exception.name, exception.reason);
		[self handleStoreUnavailable:[NSString stringWithFormat:@"The App Store account service failed (%@).", exception.reason ?: exception.name]];
	}
}

- (void)runHistoryQueriesWithDSID:(long long)dsid
{
	Class historyClass = NSClassFromString(@"ASDPurchaseHistory");
	Class queryClass = NSClassFromString(@"ASDPurchaseHistoryQuery");
	if (!historyClass || !queryClass)
	{
		dispatch_async(dispatch_get_main_queue(), ^
		{
			[self setLoading:NO];
			[self showError:@"Purchase History Unavailable" message:@"The App Store purchase library service is unavailable on this iOS version."];
		});
		return;
	}
		id history = [historyClass sharedInstance];
		if (![history respondsToSelector:@selector(executeQuery:withResultHandler:)])
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self setLoading:NO];
				[self showError:@"Purchase History Unavailable" message:@"The App Store purchase library service is unavailable on this iOS version."];
			});
			return;
		}
		__block NSMutableDictionary* merged = [NSMutableDictionary new];
	__block NSInteger pending = 2;
	__weak typeof(self) weakSelf = self;
	for (long long hiddenValue = 0; hiddenValue <= 1; hiddenValue++)
	{
		id query = [[queryClass alloc] init];
		if ([query respondsToSelector:@selector(setAccountID:)])
		{
			[query setAccountID:dsid];
		}
		if ([query respondsToSelector:@selector(setIsHidden:)])
		{
			[query setIsHidden:hiddenValue];
		}
		[history executeQuery:query withResultHandler:^(NSArray* apps, NSError* error)
		{
			@try
			{
				__strong typeof(weakSelf) self = weakSelf;
				NSLog(@"[WaffleStore] Purchases: executeQuery(hidden=%lld) apps=%lu error=%@", hiddenValue, (unsigned long)apps.count, error);
				dispatch_async(WFSMergeQueue(), ^
				{
					@try
					{
						if (!error)
						{
							for (ASDPurchaseHistoryApp* app in apps)
							{
								if (app.storeItemID > 0 && app.bundleID.length > 0)
								{
									merged[@(app.storeItemID)] = app;
								}
							}
						}
					}
					@catch (NSException* exception)
					{
						NSLog(@"[WaffleStore] Purchases: merge exception %@ %@", exception.name, exception.reason);
					}
					pending--;
					if (pending == 0)
					{
						NSArray* allApps = [merged allValues];
						[self allHistoryLoaded:allApps dsid:dsid];
					}
				});
			}
			@catch (NSException* exception)
			{
				NSLog(@"[WaffleStore] Purchases: execute exception %@ %@", exception.name, exception.reason);
			}
		}];
	}
}

- (void)allHistoryLoaded:(NSArray*)apps dsid:(long long)dsid
{
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^
	{
		__strong typeof(weakSelf) self = weakSelf;
		[self refreshInstalledBundleIDs];
		[self mergeDevicePurchasesWithApps:apps dsid:dsid];
	});
}

- (void)mergeDevicePurchasesWithApps:(NSArray*)apps dsid:(long long)dsid
{
	__weak typeof(self) weakSelf = self;
	dispatch_async(WFSMergeQueue(), ^
	{
		__strong typeof(weakSelf) self = weakSelf;
		NSMutableArray* all = [NSMutableArray arrayWithArray:apps];
		NSMutableSet* seenStoreIDs = [NSMutableSet new];
		NSMutableSet* seenBundleIDs = [NSMutableSet new];
		for (ASDPurchaseHistoryApp* app in apps)
		{
			if (app.storeItemID > 0)
			{
				[seenStoreIDs addObject:@(app.storeItemID)];
			}
			if (app.bundleID.length > 0)
			{
				[seenBundleIDs addObject:app.bundleID];
			}
		}
		NSMutableSet* localScanned = [NSMutableSet new];
		NSArray* scanned = [WFSDevicePurchaseScanner scanPurchasesForDSID:dsid];
		for (__strong NSDictionary* entry in scanned)
		{
			NSNumber* storeID = entry[WFSDevicePurchaseStoreIDKey];
			NSString* bundleID = entry[WFSDevicePurchaseBundleIDKey];
			if (storeID && [seenStoreIDs containsObject:storeID])
			{
				continue;
			}
			if (bundleID.length && [seenBundleIDs containsObject:bundleID])
			{
				continue;
			}
			if (bundleID.length && [self.installedBundleIDs containsObject:bundleID])
			{
				continue;
			}
			if (!storeID && bundleID.length)
			{
				NSNumber* resolved = [self resolveStoreIDForBundleID:bundleID];
				if (resolved)
				{
					storeID = resolved;
					if ([seenStoreIDs containsObject:storeID])
					{
						continue;
					}
					NSMutableDictionary* enriched = [entry mutableCopy];
					enriched[WFSDevicePurchaseStoreIDKey] = storeID;
					entry = enriched;
				}
			}
			ASDPurchaseHistoryApp* app = [self historyAppFromScannedEntry:entry];
			if (!app)
			{
				continue;
			}
			[all addObject:app];
			NSString* key = bundleID.length ? bundleID : [NSString stringWithFormat:@"id:%@", storeID];
			[localScanned addObject:key];
			if (storeID)
			{
				[seenStoreIDs addObject:storeID];
			}
			if (bundleID.length)
			{
				[seenBundleIDs addObject:bundleID];
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^
		{
			__strong typeof(weakSelf) self = weakSelf;
			self.didLoadHistory = YES;
			self.localScannedKeys = localScanned;
			NSArray* sortedApps = all;
			@try
			{
				sortedApps = [all sortedArrayUsingComparator:^NSComparisonResult(ASDPurchaseHistoryApp* a, ASDPurchaseHistoryApp* b)
				{
					NSDate* dateA = a.datePurchased ?: [NSDate distantPast];
					NSDate* dateB = b.datePurchased ?: [NSDate distantPast];
					return [dateB compare:dateA];
				}];
			}
			@catch (NSException* exception)
			{
				NSLog(@"[WaffleStore] Purchases: sort exception %@ %@", exception.name, exception.reason);
			}
			self.allApps = [sortedApps mutableCopy];
			if (self.allApps.count == 0)
			{
				[self setLoading:NO];
				self.statusLabel.hidden = NO;
				self.statusLabel.text = @"No purchases found for this account.";
				[self applyFilter];
				return;
			}
			[self fetchStoreMetadataForApps:self.allApps];
		});
	});
}

- (ASDPurchaseHistoryApp*)historyAppFromScannedEntry:(NSDictionary*)entry
{
	@try
	{
		Class appClass = NSClassFromString(@"ASDPurchaseHistoryApp");
		if (!appClass)
		{
			return nil;
		}
		ASDPurchaseHistoryApp* app = [appClass new];
		NSNumber* storeID = entry[WFSDevicePurchaseStoreIDKey];
		NSString* bundleID = entry[WFSDevicePurchaseBundleIDKey];
		NSString* title = entry[WFSDevicePurchaseTitleKey];
		NSDate* date = entry[WFSDevicePurchaseDateKey];
		if (storeID)
		{
			[app setValue:storeID forKey:@"storeItemID"];
		}
		if (bundleID.length)
		{
			[app setValue:bundleID forKey:@"bundleID"];
		}
		if (title.length)
		{
			[app setValue:title forKey:@"title"];
		}
		if (date)
		{
			[app setValue:date forKey:@"datePurchased"];
		}
		return app;
	}
	@catch (NSException* exception)
	{
		NSLog(@"[WaffleStore] Purchases: historyAppFromScannedEntry exception %@ %@", exception.name, exception.reason);
		return nil;
	}
}

- (NSNumber*)resolveStoreIDForBundleID:(NSString*)bundleID
{
	NSString* encoded = [bundleID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
	NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software", encoded]];
	if (!url)
	{
		return nil;
	}
	__block NSNumber* result = nil;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		if (!error && data.length)
		{
			NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
			for (NSDictionary* item in json[@"results"])
			{
				if ([item isKindOfClass:[NSDictionary class]])
				{
					NSNumber* trackId = item[@"trackId"];
					if (trackId && [trackId longLongValue] > 0)
					{
						result = trackId;
						break;
					}
				}
			}
		}
		dispatch_semaphore_signal(semaphore);
	}];
	[task resume];
	dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));
	return result;
}

- (NSString*)keyForApp:(ASDPurchaseHistoryApp*)app
{
	if (app.bundleID.length > 0)
	{
		return app.bundleID;
	}
	if (app.storeItemID > 0)
	{
		return [NSString stringWithFormat:@"id:%lld", app.storeItemID];
	}
	return nil;
}

- (void)refreshInstalledBundleIDs
{
	NSMutableSet* installed = [NSMutableSet new];
	[[LSApplicationWorkspace defaultWorkspace] enumerateApplicationsOfType:0 block:^(LSApplicationProxy* proxy)
	{
		if (proxy.isInstalled && proxy.bundleIdentifier.length > 0)
		{
			[installed addObject:proxy.bundleIdentifier];
		}
	}];
	self.installedBundleIDs = installed;
}

- (void)fetchStoreMetadataForApps:(NSArray*)apps
{
	NSMutableArray* ids = [NSMutableArray new];
	for (ASDPurchaseHistoryApp* app in apps)
	{
		[ids addObject:@(app.storeItemID)];
	}
	NSMutableArray* batches = [NSMutableArray new];
	for (NSUInteger i = 0; i < ids.count; i += 20)
	{
		NSUInteger length = MIN(20, ids.count - i);
		[batches addObject:[ids subarrayWithRange:NSMakeRange(i, length)]];
	}
	__block NSInteger remaining = batches.count;
	__weak typeof(self) weakSelf = self;
	for (NSArray* batch in batches)
	{
		NSString* idList = [batch componentsJoinedByString:@","];
		NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?id=%@", idList]];
		NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
		{
			NSMutableSet* found = [NSMutableSet new];
			NSMutableDictionary* foundInfo = [NSMutableDictionary new];
			if (!error && data)
			{
				NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
				for (NSDictionary* result in json[@"results"])
				{
					NSNumber* trackId = result[@"trackId"];
					if (trackId)
					{
						[found addObject:trackId];
						foundInfo[trackId] = result;
					}
				}
			}
			dispatch_async(dispatch_get_main_queue(), ^
			{
				__strong typeof(weakSelf) self = weakSelf;
				if (foundInfo.count > 0)
				{
					for (NSNumber* trackId in foundInfo)
					{
						self.storeInfo[trackId] = foundInfo[trackId];
					}
					for (NSNumber* appId in batch)
					{
						if (![found containsObject:appId])
						{
							[self.removedStoreIDs addObject:appId];
						}
					}
				}
				remaining--;
				if (remaining == 0)
				{
					[self setLoading:NO];
					if (self.removedStoreIDs.count == 0 && self.storeInfo.count == 0)
					{
						self.statusLabel.hidden = NO;
						self.statusLabel.text = @"Store info unavailable. Apps without a store listing are marked as removed.";
					}
					else
					{
						self.statusLabel.hidden = YES;
					}
					[self applyFilter];
				}
			});
		}];
		[task resume];
	}
}

- (void)filterChanged
{
	[self applyFilter];
}

- (void)applyFilter
{
	NSInteger segment = self.filterControl.selectedSegmentIndex;
	NSMutableArray* filtered = [NSMutableArray new];
	@try
	{
		for (ASDPurchaseHistoryApp* app in self.allApps)
		{
			BOOL installed = [self.installedBundleIDs containsObject:app.bundleID];
			BOOL removed = [self.removedStoreIDs containsObject:@(app.storeItemID)];
			NSString* key = [self keyForApp:app];
			BOOL localOnly = key.length > 0 && [self.localScannedKeys containsObject:key];
			if (segment == 1 && installed)
			{
				continue;
			}
			if (segment == 2 && !(removed || localOnly))
			{
				continue;
			}
			[filtered addObject:app];
		}
	}
	@catch (NSException* exception)
	{
		NSLog(@"[WaffleStore] Purchases: filter exception %@ %@", exception.name, exception.reason);
	}
	self.visibleApps = filtered;
	[self.tableView reloadData];
}

- (NSString*)statusForApp:(ASDPurchaseHistoryApp*)app
{
	BOOL installed = [self.installedBundleIDs containsObject:app.bundleID];
	BOOL removed = [self.removedStoreIDs containsObject:@(app.storeItemID)];
	NSString* key = [self keyForApp:app];
	BOOL localOnly = key.length > 0 && [self.localScannedKeys containsObject:key];
	if (removed)
	{
		return @"Removed from App Store";
	}
	if (installed)
	{
		return @"Installed";
	}
	if (localOnly)
	{
		return @"Not in Purchases — found on this device";
	}
	return @"Not Installed";
}

- (NSDictionary*)iTunesMetadataPlistForBundleID:(NSString*)bundleID
{
	if (bundleID.length == 0)
	{
		return nil;
	}
	LSApplicationProxy* proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
	if (!proxy || !proxy.isInstalled)
	{
		return nil;
	}
	NSFileManager* fileManager = [NSFileManager defaultManager];
	NSMutableArray* candidatePaths = [NSMutableArray new];
	if (proxy.bundleContainerURL)
	{
		[candidatePaths addObject:[[proxy.bundleContainerURL URLByAppendingPathComponent:@"iTunesMetadata.plist"] path]];
	}
	if (proxy.bundleURL)
	{
		[candidatePaths addObject:[[proxy.bundleURL URLByAppendingPathComponent:@"iTunesMetadata.plist"] path]];
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

- (void)loadIconForApp:(ASDPurchaseHistoryApp*)app intoCell:(UITableViewCell*)cell atRow:(NSInteger)row
{
	NSString* urlString = nil;
	NSDictionary* metadata = self.storeInfo[@(app.storeItemID)];
	if ([metadata[@"artworkUrl512"] isKindOfClass:[NSString class]] && ((NSString*)metadata[@"artworkUrl512"]).length)
	{
		urlString = metadata[@"artworkUrl512"];
	}
	else if (app.iconURLString.length)
	{
		urlString = app.iconURLString;
	}
	else if (app.circularIconURLString.length)
	{
		urlString = app.circularIconURLString;
	}
	UIImage* placeholder = [UIImage systemImageNamed:@"app"];
	cell.imageView.image = placeholder;
	cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
	cell.imageView.layer.cornerRadius = 9;
	cell.imageView.layer.masksToBounds = YES;
	cell.imageView.layer.borderWidth = 0.5;
	cell.imageView.layer.borderColor = [UIColor separatorColor].CGColor;
	if (urlString.length == 0)
	{
		return;
	}
	UIImage* cached = [self.imageCache objectForKey:urlString];
	if (cached)
	{
		cell.imageView.image = cached;
		return;
	}
	NSURL* url = [NSURL URLWithString:urlString];
	if (!url)
	{
		return;
	}
	cell.tag = row;
	__weak typeof(self) weakSelf = self;
	NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		if (error || data.length == 0)
		{
			return;
		}
		UIImage* image = [UIImage imageWithData:data];
		if (!image)
		{
			return;
		}
		[weakSelf.imageCache setObject:image forKey:urlString];
		dispatch_async(dispatch_get_main_queue(), ^
		{
			if (cell.tag == row)
			{
				cell.imageView.image = image;
			}
		});
	}];
	[task resume];
}

- (void)promptSignIn
{
	self.accountLabel.text = @"Not signed in";
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Not Signed In" message:@"WaffleStore uses the Apple ID you are signed into in the App Store to list your purchases. Sign in to your Apple ID on this device and try again." preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Sign In" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		[self performSystemSignIn];
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	if (self.isViewLoaded && self.view.window && self.presentedViewController == nil)
	{
		[self presentViewController:alert animated:YES completion:nil];
	}
}

- (void)performSystemSignIn
{
	@try
	{
		Class contextClass = NSClassFromString(@"SSAuthenticationContext");
		Class requestClass = NSClassFromString(@"SSAuthenticateRequest");
		if (!contextClass || !requestClass || ![contextClass respondsToSelector:@selector(contextForSignIn)])
		{
			[self handleStoreUnavailable:@"The App Store sign-in service is unavailable on this iOS version."];
			return;
		}
		self.accountLabel.text = @"Signing in…";
		id context = [contextClass contextForSignIn];
		id request = nil;
		if ([requestClass instancesRespondToSelector:@selector(initWithAuthenticationContext:)])
		{
			request = [[requestClass alloc] initWithAuthenticationContext:context];
		}
		if (!request || ![request respondsToSelector:@selector(startWithAuthenticateResponseBlock:)])
		{
			[self handleStoreUnavailable:@"The App Store sign-in service is unavailable on this iOS version."];
			return;
		}
		__weak typeof(self) weakSelf = self;
		[request startWithAuthenticateResponseBlock:^(id response, NSError* error)
		{
			__strong typeof(weakSelf) self = weakSelf;
			dispatch_async(dispatch_get_main_queue(), ^
			{
				if (error)
				{
					self.accountLabel.text = @"Not signed in";
					[self showError:@"Sign-In Failed" message:error.localizedDescription];
					return;
				}
				[self loadPurchases];
			});
		}];
	}
	@catch (NSException* exception)
	{
		NSLog(@"[WaffleStore] Purchases: sign-in exception %@ %@", exception.name, exception.reason);
		[self handleStoreUnavailable:@"The App Store sign-in service failed."];
	}
}

- (void)showError:(NSString*)title message:(NSString*)message
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		UIAlertController* alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		if (self.isViewLoaded && self.view.window && self.presentedViewController == nil)
		{
			[self presentViewController:alert animated:YES completion:nil];
		}
	});
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView
{
	return 1;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
	return self.visibleApps.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath
{
	if (indexPath.row < 0 || indexPath.row >= self.visibleApps.count)
	{
		return [UITableViewCell new];
	}
	UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:WFSPurchasedCellIdentifier];
	if (!cell)
	{
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:WFSPurchasedCellIdentifier];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	}
	ASDPurchaseHistoryApp* app = self.visibleApps[indexPath.row];
	cell.textLabel.text = app.title.length ? app.title : app.bundleID;
	NSString* bundleIdText = app.bundleID ?: @"";
	if (app.hidden)
	{
		bundleIdText = [NSString stringWithFormat:@"Hidden · %@", bundleIdText];
	}
	cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", [self statusForApp:app], bundleIdText];
	[self loadIconForApp:app intoCell:cell atRow:indexPath.row];
	return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.row < 0 || indexPath.row >= self.visibleApps.count || self.presentedViewController)
	{
		return;
	}
	ASDPurchaseHistoryApp* app = self.visibleApps[indexPath.row];
	NSString* title = app.title.length ? app.title : app.bundleID;
	if (app.storeItemID <= 0)
	{
		UIAlertController* infoAlert = [UIAlertController alertControllerWithTitle:title message:@"This app was removed from the App Store and its App ID is not recorded on this device. To download it, use the Download tab with its App Store link, or enter the App ID manually." preferredStyle:UIAlertControllerStyleAlert];
		[infoAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:infoAlert animated:YES completion:nil];
		return;
	}
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:title message:[NSString stringWithFormat:@"%@\nChoose a version to download or downgrade.", [self statusForApp:app]] preferredStyle:UIAlertControllerStyleAlert];
	__weak typeof(self) weakSelf = self;
	[alert addAction:[UIAlertAction actionWithTitle:@"Choose Version" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		__strong typeof(weakSelf) self = weakSelf;
		if (self.selectionHandler)
		{
			self.selectionHandler(app.storeItemID, [self iTunesMetadataPlistForBundleID:app.bundleID]);
		}
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end
