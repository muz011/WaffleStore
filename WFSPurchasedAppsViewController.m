#import "WFSPurchasedAppsViewController.h"
#import "WFSAppleStore.h"
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
@property (nonatomic, strong) NSCache* imageCache;
@property (nonatomic, strong) UISegmentedControl* filterControl;
@property (nonatomic, strong) UILabel* accountLabel;
@property (nonatomic, strong) UILabel* statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView* spinner;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL didAppear;
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
	UIView* header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 104)];

	self.accountLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, header.bounds.size.width - 32, 20)];
	self.accountLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
	self.accountLabel.textColor = [UIColor secondaryLabelColor];
	self.accountLabel.text = @"Checking signed-in Apple ID…";
	[header addSubview:self.accountLabel];

	self.filterControl = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Not Installed", @"Removed"]];
	self.filterControl.frame = CGRectMake(16, 36, header.bounds.size.width - 32, 30);
	self.filterControl.selectedSegmentIndex = 0;
	[self.filterControl addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
	[header addSubview:self.filterControl];

	UIView* statusView = [[UIView alloc] initWithFrame:CGRectMake(16, 72, header.bounds.size.width - 32, 24)];
	self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
	self.spinner.frame = CGRectMake(0, 0, 24, 24);
	[statusView addSubview:self.spinner];

	self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(28, 2, statusView.bounds.size.width - 28, 20)];
	self.statusLabel.font = [UIFont systemFontOfSize:13];
	self.statusLabel.textColor = [UIColor secondaryLabelColor];
	self.statusLabel.numberOfLines = 2;
	[statusView addSubview:self.statusLabel];

	[header addSubview:statusView];
	self.tableView.tableHeaderView = header;
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
				[self runHistoryQueriesWithDSID:dsid];
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
				if (!error)
				{
					dispatch_sync(WFSMergeQueue(), ^
					{
						for (ASDPurchaseHistoryApp* app in apps)
						{
							if (app.storeItemID > 0 && app.bundleID.length > 0)
							{
								merged[@(app.storeItemID)] = app;
							}
						}
					});
				}
				pending--;
				if (pending == 0)
				{
					NSArray* allApps = nil;
					dispatch_sync(WFSMergeQueue(), ^
					{
						allApps = [merged allValues];
					});
					[self allHistoryLoaded:allApps];
				}
			}
			@catch (NSException* exception)
			{
				NSLog(@"[WaffleStore] Purchases: execute exception %@ %@", exception.name, exception.reason);
			}
		}];
	}
}

- (void)allHistoryLoaded:(NSArray*)apps
{
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^
	{
		__strong typeof(weakSelf) self = weakSelf;
		self.allApps = [[apps sortedArrayUsingComparator:^NSComparisonResult(ASDPurchaseHistoryApp* a, ASDPurchaseHistoryApp* b)
		{
			NSDate* dateA = a.datePurchased ?: [NSDate distantPast];
			NSDate* dateB = b.datePurchased ?: [NSDate distantPast];
			return [dateB compare:dateA];
		}] mutableCopy];
		[self refreshInstalledBundleIDs];
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
			if (!error && data)
			{
				NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
				for (NSDictionary* result in json[@"results"])
				{
					NSNumber* trackId = result[@"trackId"];
					if (trackId)
					{
						[found addObject:trackId];
						weakSelf.storeInfo[trackId] = result;
					}
				}
			}
			dispatch_async(dispatch_get_main_queue(), ^
			{
				__strong typeof(weakSelf) self = weakSelf;
				if (found.count > 0)
				{
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
	for (ASDPurchaseHistoryApp* app in self.allApps)
	{
		BOOL installed = [self.installedBundleIDs containsObject:app.bundleID];
		BOOL removed = [self.removedStoreIDs containsObject:@(app.storeItemID)];
		if (segment == 1 && installed)
		{
			continue;
		}
		if (segment == 2 && !removed)
		{
			continue;
		}
		[filtered addObject:app];
	}
	self.visibleApps = filtered;
	[self.tableView reloadData];
}

- (NSString*)statusForApp:(ASDPurchaseHistoryApp*)app
{
	BOOL installed = [self.installedBundleIDs containsObject:app.bundleID];
	BOOL removed = [self.removedStoreIDs containsObject:@(app.storeItemID)];
	if (removed)
	{
		return @"Removed from App Store";
	}
	return installed ? @"Installed" : @"Not Installed";
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
	NSString* urlString = app.iconURLString.length ? app.iconURLString : app.circularIconURLString;
	UIImage* placeholder = [UIImage systemImageNamed:@"app"];
	cell.imageView.image = placeholder;
	cell.imageView.layer.cornerRadius = 10;
	cell.imageView.layer.masksToBounds = YES;
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
			__strong typeof(weakSelf) self = weakSelf;
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
	if (self.isViewLoaded && self.view.window)
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
		if (self.isViewLoaded && self.view.window)
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
	ASDPurchaseHistoryApp* app = self.visibleApps[indexPath.row];
	NSString* title = app.title.length ? app.title : app.bundleID;
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
