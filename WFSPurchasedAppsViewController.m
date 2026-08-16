#import "WFSPurchasedAppsViewController.h"
#import "WFSAppleStore.h"
#import "WFSDevicePurchaseScanner.h"
#import "WFSAppleIDDownloader.h"
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

static const CGFloat WFSAppIconSize = 44;
static const CGFloat WFSAppIconCornerRadius = 10;

@interface WFSPurchasedAppCell : UITableViewCell
@property (nonatomic, strong) UIImageView* appIconView;
+ (UIImage*)applePlaceholderImage;
@end

@implementation WFSPurchasedAppCell

+ (UIImage*)applePlaceholderImage
{
	static UIImage* placeholder;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^
	{
		UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(WFSAppIconSize, WFSAppIconSize)];
		placeholder = [renderer imageWithActions:^(UIGraphicsImageRendererContext* rendererContext)
		{
			UIBezierPath* path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, WFSAppIconSize, WFSAppIconSize) cornerRadius:WFSAppIconCornerRadius];
			[[UIColor systemGray5Color] setFill];
			[path fill];
			UIImage* glyph = [UIImage systemImageNamed:@"app"];
			if (glyph)
			{
				glyph = [glyph imageWithTintColor:[UIColor systemGrayColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
				CGFloat glyphSize = WFSAppIconSize * 0.52;
				[glyph drawInRect:CGRectMake((WFSAppIconSize - glyphSize) / 2.0, (WFSAppIconSize - glyphSize) / 2.0, glyphSize, glyphSize)];
			}
		}];
	});
	return placeholder;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString*)reuseIdentifier
{
	self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
	if (self)
	{
		self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		_appIconView = [[UIImageView alloc] init];
		_appIconView.contentMode = UIViewContentModeScaleAspectFill;
		_appIconView.layer.cornerRadius = WFSAppIconCornerRadius;
		_appIconView.layer.masksToBounds = YES;
		_appIconView.layer.borderWidth = 0.5;
		_appIconView.layer.borderColor = [UIColor separatorColor].CGColor;
		[self.contentView addSubview:_appIconView];
	}
	return self;
}

- (void)layoutSubviews
{
	[super layoutSubviews];
	CGFloat height = self.contentView.bounds.size.height;
	CGFloat side = MIN(WFSAppIconSize, height - 12);
	_appIconView.frame = CGRectMake(16, (height - side) / 2.0, side, side);
	CGFloat labelX = 16 + side + 12;
	CGFloat labelWidth = self.contentView.bounds.size.width - labelX - 12;
	if (self.accessoryType != UITableViewCellAccessoryNone)
	{
		labelWidth -= 30;
	}
	CGRect titleFrame = self.textLabel.frame;
	titleFrame.origin.x = labelX;
	titleFrame.size.width = labelWidth;
	self.textLabel.frame = titleFrame;
	CGRect detailFrame = self.detailTextLabel.frame;
	detailFrame.origin.x = labelX;
	detailFrame.size.width = labelWidth;
	self.detailTextLabel.frame = detailFrame;
}

@end

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
@property (nonatomic, strong) UIAlertController* resolvingAlert;
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
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addAppManually)];

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
		self.didLoadHistory = YES;
		[self refreshInstalledBundleIDs];
		[self fetchCommerceHistoryAndMergeWithApps:apps dsid:dsid];
	});
}

- (void)fetchCommerceHistoryAndMergeWithApps:(NSArray*)apps dsid:(long long)dsid
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	if (!downloader.isAuthenticated)
	{
		[self mergeDevicePurchasesWithApps:apps dsid:dsid];
		return;
	}
	self.statusLabel.hidden = NO;
	self.statusLabel.text = @"Loading Apple ID purchase history…";
	self.statusLabel.textColor = [UIColor secondaryLabelColor];
	__weak typeof(self) weakSelf = self;
	[self fetchCommerceYearsFromYear:2008 toYear:[self currentYear] purchases:[NSMutableArray array] completion:^(NSArray* purchases, NSError* error)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		if (error)
		{
			NSLog(@"[WaffleStore] Purchases: commerce history error %ld %@", (long)error.code, error.localizedDescription);
		}
		NSMutableArray* merged = [NSMutableArray arrayWithArray:apps];
		NSMutableSet* seenStoreIDs = [NSMutableSet new];
		for (ASDPurchaseHistoryApp* app in apps)
		{
			if (app.storeItemID > 0)
			{
				[seenStoreIDs addObject:@(app.storeItemID)];
			}
		}
		for (NSDictionary* purchase in purchases)
		{
			if (![purchase isKindOfClass:[NSDictionary class]])
			{
				continue;
			}
			long long adamId = [purchase[@"adamId"] longLongValue];
			if (adamId <= 0 || [seenStoreIDs containsObject:@(adamId)])
			{
				continue;
			}
			ASDPurchaseHistoryApp* app = [self historyAppFromCommerceEntry:purchase];
			if (!app)
			{
				continue;
			}
			[seenStoreIDs addObject:@(adamId)];
			[merged addObject:app];
		}
		if (purchases.count)
		{
			NSLog(@"[WaffleStore] Purchases: merged %lu Apple ID purchase(s), total %lu", (unsigned long)purchases.count, (unsigned long)merged.count);
		}
		[self mergeDevicePurchasesWithApps:merged dsid:dsid];
	}];
}

- (void)fetchCommerceYearsFromYear:(NSInteger)year toYear:(NSInteger)toYear purchases:(NSMutableArray*)purchases completion:(void (^)(NSArray* purchases, NSError* error))completion
{
	if (year > toYear)
	{
		completion(purchases, nil);
		return;
	}
	__weak typeof(self) weakSelf = self;
	[self fetchCommercePagesForRange:[NSString stringWithFormat:@"%ld-all", (long)year] token:nil purchases:[NSMutableArray array] completion:^(NSArray* yearPurchases, NSError* error)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			completion(purchases, error);
			return;
		}
		if (error)
		{
			completion(purchases, error);
			return;
		}
		[purchases addObjectsFromArray:yearPurchases];
		[self fetchCommerceYearsFromYear:year + 1 toYear:toYear purchases:purchases completion:completion];
	}];
}

- (void)fetchCommercePagesForRange:(NSString*)range token:(NSString*)token purchases:(NSMutableArray*)purchases completion:(void (^)(NSArray* purchases, NSError* error))completion
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	NSInteger page = token.length ? 2 : 1;
	__weak typeof(self) weakSelf = self;
	[downloader fetchCommercePurchaseHistoryWithRange:range page:page paginationToken:token completion:^(NSArray* pagePurchases, NSDictionary* response, NSError* error)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			completion(purchases, error);
			return;
		}
		if (error)
		{
			completion(purchases, error);
			return;
		}
		[purchases addObjectsFromArray:pagePurchases];
		BOOL complete = [response[@"is-complete"] respondsToSelector:@selector(boolValue)] && [response[@"is-complete"] boolValue];
		NSString* nextToken = nil;
		if (!complete)
		{
			id tokenValue = response[@"pagination-token"];
			if ([tokenValue isKindOfClass:[NSString class]] && ((NSString*)tokenValue).length)
			{
				nextToken = (NSString*)tokenValue;
			}
		}
		if (nextToken && purchases.count < 1000)
		{
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^
			{
				[self fetchCommercePagesForRange:range token:nextToken purchases:purchases completion:completion];
			});
			return;
		}
		completion(purchases, nil);
	}];
}

- (ASDPurchaseHistoryApp*)historyAppFromCommerceEntry:(NSDictionary*)entry
{
	@try
	{
		Class appClass = NSClassFromString(@"ASDPurchaseHistoryApp");
		if (!appClass)
		{
			return nil;
		}
		ASDPurchaseHistoryApp* app = [appClass new];
		long long adamId = [entry[@"adamId"] longLongValue];
		NSString* bundleId = entry[@"bundleId"];
		NSString* title = entry[@"title"];
		NSString* purchaseDate = entry[@"purchaseDate"];
		NSDate* date = nil;
		if ([purchaseDate isKindOfClass:[NSString class]] && purchaseDate.length)
		{
			NSDateFormatter* formatter = [NSDateFormatter new];
			formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
			formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
			date = [formatter dateFromString:purchaseDate];
		}
		if (adamId > 0)
		{
			[app setValue:@(adamId) forKey:@"storeItemID"];
		}
		if (bundleId.length)
		{
			[app setValue:bundleId forKey:@"bundleID"];
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
		NSLog(@"[WaffleStore] Purchases: historyAppFromCommerceEntry exception %@ %@", exception.name, exception.reason);
		return nil;
	}
}

- (NSInteger)currentYear
{
	return [[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:[NSDate date]];
}

- (void)mergeDevicePurchasesWithApps:(NSArray*)apps dsid:(long long)dsid
{
	__weak typeof(self) weakSelf = self;
	dispatch_async(WFSMergeQueue(), ^
	{
		__strong typeof(weakSelf) self = weakSelf;
		NSMutableArray* all = [NSMutableArray arrayWithArray:apps];
		NSMutableSet* seenStoreIDs = [NSMutableSet new];
		for (ASDPurchaseHistoryApp* app in apps)
		{
			if (app.storeItemID > 0)
			{
				[seenStoreIDs addObject:@(app.storeItemID)];
			}
		}
		NSMutableSet* localScanned = [NSMutableSet new];
		NSArray* scanned = [WFSDevicePurchaseScanner scanPurchasesForDSID:dsid];
		for (NSDictionary* entry in scanned)
		{
			NSNumber* storeID = entry[WFSDevicePurchaseStoreIDKey];
			if (storeID && [seenStoreIDs containsObject:storeID])
			{
				continue;
			}
			ASDPurchaseHistoryApp* app = [self historyAppFromScannedEntry:entry];
			if (!app)
			{
				continue;
			}
			[all addObject:app];
			[localScanned addObject:[NSString stringWithFormat:@"id:%@", storeID]];
			if (storeID)
			{
				[seenStoreIDs addObject:storeID];
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^
		{
			__strong typeof(weakSelf) self = weakSelf;
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

- (void)addAppManually
{
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Add App" message:@"Enter an App ID, an App Store link, or a Bundle ID. WaffleStore will ask the App Store to purchase or download it for your signed-in Apple ID." preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField* textField)
	{
		textField.placeholder = @"e.g. 1053533457 or com.example.app";
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
		textField.keyboardType = UIKeyboardTypeDefault;
	}];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		NSString* input = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (input.length == 0)
		{
			return;
		}
		[self resolveInputAndStartDownload:input];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)resolveInputAndStartDownload:(NSString*)input
{
	long long appId = [self parseAppIdFromInput:input];
	if (appId > 0)
	{
		[self startDownloadFlowForAppId:appId];
		return;
	}
	NSString* bundleID = input;
	if (bundleID.length == 0)
	{
		[self showAddError:@"Enter an App ID, an App Store link, or a Bundle ID."];
		return;
	}
	[self showResolvingIndicatorForInput:input];
	[self lookupStoreIDForBundleID:bundleID completion:^(long long resolvedAppId)
	{
		if (resolvedAppId > 0)
		{
			[self dismissResolvingIndicator];
			[self startDownloadFlowForAppId:resolvedAppId];
			return;
		}
		[self resolveBundleIDInAppleIDHistory:bundleID];
	}];
}

- (void)resolveBundleIDInAppleIDHistory:(NSString*)bundleID
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	if (downloader.isAuthenticated)
	{
		[self searchAppleIDHistoryForBundleID:bundleID];
		return;
	}
	[self dismissResolvingIndicator];
	if (!self.appleIDSignInHandler)
	{
		[self showAddError:@"No App Store app found for that Bundle ID, and sign-in is not available in this build. Check the spelling and try again."];
		return;
	}
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Not Found in App Store" message:[NSString stringWithFormat:@"\"%@\" is not listed in the App Store. If you purchased it, WaffleStore can look it up in your Apple ID purchase history — sign in to check.", bundleID] preferredStyle:UIAlertControllerStyleAlert];
	UIAlertAction* signInAction = [UIAlertAction actionWithTitle:@"Sign In" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		[self dismissViewControllerAnimated:NO completion:^
		{
			self.appleIDSignInHandler(^(BOOL success)
			{
				if (success)
				{
					[self searchAppleIDHistoryForBundleID:bundleID];
					return;
				}
				[self showAddError:[NSString stringWithFormat:@"Sign-in failed. \"%@\" could not be resolved.", bundleID]];
			});
		}];
	}];
	[alert addAction:signInAction];
	UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
	[alert addAction:cancelAction];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)searchAppleIDHistoryForBundleID:(NSString*)bundleID
{
	[self showResolvingIndicatorForInput:bundleID];
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	[downloader searchPurchaseHistoryForBundleID:bundleID completion:^(NSDictionary* purchase, NSError* error)
	{
		[self dismissResolvingIndicator];
		if (error)
		{
			if (error.code == WFSAppleIDDownloaderErrorLicenseNotFound)
			{
				[self showAddError:[NSString stringWithFormat:@"\"%@\" is not listed in the App Store and was not found in your Apple ID purchase history.", bundleID]];
				return;
			}
			[self showAddError:error.localizedDescription];
			return;
		}
		long long adamId = [purchase[@"adamId"] longLongValue];
		if (adamId <= 0)
		{
			[self showAddError:@"The app was found in your purchase history but its App ID could not be determined."];
			return;
		}
		NSMutableDictionary* metadata = [NSMutableDictionary dictionary];
		NSString* title = purchase[@"title"];
		if (title.length)
		{
			metadata[@"title"] = title;
		}
		if ([purchase[@"metadata"] isKindOfClass:[NSDictionary class]])
		{
			[metadata addEntriesFromDictionary:purchase[@"metadata"]];
		}
		[self startDownloadFlowForAppId:adamId metadata:metadata];
	}];
}

- (long long)parseAppIdFromInput:(NSString*)input
{
	NSCharacterSet* digits = [NSCharacterSet decimalDigitCharacterSet];
	if ([input rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound && input.length > 0)
	{
		return [input longLongValue];
	}
	NSRange idRange = [input rangeOfString:@"id" options:NSCaseInsensitiveSearch];
	if (idRange.location == NSNotFound)
	{
		return 0;
	}
	NSUInteger start = idRange.location + idRange.length;
	NSMutableString* number = [NSMutableString new];
	for (NSUInteger i = start; i < input.length; i++)
	{
		unichar c = [input characterAtIndex:i];
		if (c >= '0' && c <= '9')
		{
			[number appendFormat:@"%C", c];
		}
		else
		{
			break;
		}
	}
	return number.length ? [number longLongValue] : 0;
}

- (void)lookupStoreIDForBundleID:(NSString*)bundleID completion:(void (^)(long long appId))completion
{
	NSString* encoded = [bundleID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
	NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software", encoded]];
	if (!url)
	{
		completion(0);
		return;
	}
	NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
	config.timeoutIntervalForRequest = 15;
	config.timeoutIntervalForResource = 20;
	NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
	NSURLSessionDataTask* task = [session dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		[session finishTasksAndInvalidate];
		long long trackId = 0;
		if (!error && data.length)
		{
			NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
			for (NSDictionary* item in json[@"results"])
			{
				if ([item isKindOfClass:[NSDictionary class]])
				{
					NSNumber* candidate = item[@"trackId"];
					if (candidate && [candidate longLongValue] > 0)
					{
						trackId = [candidate longLongValue];
						break;
					}
				}
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^
		{
			completion(trackId);
		});
	}];
	[task resume];
}

- (void)showResolvingIndicatorForInput:(NSString*)input
{
	if (self.presentedViewController)
	{
		[self dismissViewControllerAnimated:NO completion:nil];
	}
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Resolving" message:[NSString stringWithFormat:@"Looking up \"%@\"…", input] preferredStyle:UIAlertControllerStyleAlert];
	[self presentViewController:alert animated:YES completion:nil];
	self.resolvingAlert = alert;
}

- (void)dismissResolvingIndicator
{
	if (self.resolvingAlert)
	{
		UIAlertController* alert = self.resolvingAlert;
		self.resolvingAlert = nil;
		[alert dismissViewControllerAnimated:NO completion:nil];
	}
}

- (void)startDownloadFlowForAppId:(long long)appId
{
	[self startDownloadFlowForAppId:appId metadata:nil];
}

- (void)startDownloadFlowForAppId:(long long)appId metadata:(NSDictionary*)metadata
{
	if (self.selectionHandler)
	{
		self.selectionHandler(appId, metadata);
	}
}

- (void)showAddError:(NSString*)message
{
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Add App" message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
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
	NSMutableDictionary* bundleIdsByStoreID = [NSMutableDictionary new];
	NSMutableArray* ids = [NSMutableArray new];
	for (ASDPurchaseHistoryApp* app in apps)
	{
		if (app.storeItemID > 0)
		{
			[ids addObject:@(app.storeItemID)];
			if (app.bundleID.length)
			{
				bundleIdsByStoreID[@(app.storeItemID)] = app.bundleID;
			}
		}
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
			NSMutableDictionary* foundInfo = [NSMutableDictionary new];
			if (!error && data)
			{
				NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
				for (NSDictionary* result in json[@"results"])
				{
					NSNumber* trackId = result[@"trackId"];
					if (trackId)
					{
						foundInfo[trackId] = result;
					}
				}
			}
			dispatch_async(dispatch_get_main_queue(), ^
			{
				__strong typeof(weakSelf) self = weakSelf;
				for (NSNumber* appId in batch)
				{
					NSDictionary* result = foundInfo[appId];
					if (!result)
					{
						[self.removedStoreIDs addObject:appId];
						continue;
					}
					NSString* expectedBundleId = bundleIdsByStoreID[appId];
					NSString* resultBundleId = result[@"bundleId"];
					if ([expectedBundleId isKindOfClass:[NSString class]] && expectedBundleId.length &&
						[resultBundleId isKindOfClass:[NSString class]] && resultBundleId.length &&
						![resultBundleId isEqualToString:expectedBundleId])
					{
						[self.removedStoreIDs addObject:appId];
						continue;
					}
					self.storeInfo[appId] = result;
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
		return @"Bought on this device (hidden from Purchases)";
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
	UIImageView* iconView = nil;
	if ([cell isKindOfClass:[WFSPurchasedAppCell class]])
	{
		iconView = ((WFSPurchasedAppCell*)cell).appIconView;
	}
	else
	{
		iconView = cell.imageView;
	}
	iconView.image = [WFSPurchasedAppCell applePlaceholderImage];
	iconView.contentMode = UIViewContentModeScaleAspectFill;
	if ([self.removedStoreIDs containsObject:@(app.storeItemID)])
	{
		return;
	}
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
	if (urlString.length == 0)
	{
		return;
	}
	UIImage* cached = [self.imageCache objectForKey:urlString];
	if (cached)
	{
		iconView.image = cached;
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
				iconView.image = image;
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
		cell = [[WFSPurchasedAppCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:WFSPurchasedCellIdentifier];
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
		UIAlertController* infoAlert = [UIAlertController alertControllerWithTitle:title message:@"This app was removed from the App Store and its App ID is not recorded on this device. Tap + to add it by App ID, Bundle ID, or App Store link." preferredStyle:UIAlertControllerStyleAlert];
		[infoAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:infoAlert animated:YES completion:nil];
		return;
	}
	if ([self.removedStoreIDs containsObject:@(app.storeItemID)] && self.appleIDDownloadHandler)
	{
		UIAlertController* removedAlert = [UIAlertController alertControllerWithTitle:title message:@"This app was removed from the App Store.\n\nDownload it directly with your Apple ID instead — the .ipa is saved so you can install it with Filza or TrollStore." preferredStyle:UIAlertControllerStyleAlert];
		__weak typeof(self) weakSelf = self;
		[removedAlert addAction:[UIAlertAction actionWithTitle:@"Download with Apple ID" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			__strong typeof(weakSelf) self = weakSelf;
			if (self.appleIDDownloadHandler)
			{
				self.appleIDDownloadHandler(app.storeItemID);
			}
		}]];
		[removedAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
		[self presentViewController:removedAlert animated:YES completion:nil];
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
