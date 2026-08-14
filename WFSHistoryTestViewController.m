#import "WFSHistoryTestViewController.h"
#import "WFSAppleIDDownloader.h"

@implementation WFSHistoryTestViewController
{
	UIButton* _fetchButton;
	UIButton* _probeButton;
	UIButton* _clearButton;
	UISegmentedControl* _rangeControl;
	UILabel* _statusLabel;
	UITextView* _logView;
	BOOL _running;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"historyTest";
	self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

	_fetchButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_fetchButton setTitle:@"Fetch Commerce History" forState:UIControlStateNormal];
	[_fetchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	_fetchButton.backgroundColor = [UIColor systemBlueColor];
	_fetchButton.layer.cornerRadius = 10;
	[_fetchButton addTarget:self action:@selector(startTest) forControlEvents:UIControlEventTouchUpInside];

	_rangeControl = [[UISegmentedControl alloc] initWithItems:@[@"90d", @"2026", @"2025", @"2024", @"All"]];
	_rangeControl.selectedSegmentIndex = 0;

	_probeButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_probeButton setTitle:@"Probe Range Values" forState:UIControlStateNormal];
	[_probeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	_probeButton.backgroundColor = [UIColor systemOrangeColor];
	_probeButton.layer.cornerRadius = 10;
	[_probeButton addTarget:self action:@selector(startProbe) forControlEvents:UIControlEventTouchUpInside];

	_clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_clearButton setTitle:@"Clear Log" forState:UIControlStateNormal];
	[_clearButton addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];

	_statusLabel = [[UILabel alloc] init];
	_statusLabel.font = [UIFont systemFontOfSize:13];
	_statusLabel.textColor = [UIColor secondaryLabelColor];
	_statusLabel.text = @"Ready.";

	_logView = [[UITextView alloc] init];
	_logView.editable = NO;
	_logView.selectable = YES;
	_logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	_logView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
	_logView.layer.cornerRadius = 10;
	_logView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
	_logView.text = @"Purchase history test.\n";

	[self.view addSubview:_fetchButton];
	[self.view addSubview:_rangeControl];
	[self.view addSubview:_probeButton];
	[self.view addSubview:_clearButton];
	[self.view addSubview:_statusLabel];
	[self.view addSubview:_logView];

	[self setupConstraints];
}

- (void)setupConstraints
{
	_fetchButton.translatesAutoresizingMaskIntoConstraints = NO;
	_rangeControl.translatesAutoresizingMaskIntoConstraints = NO;
	_probeButton.translatesAutoresizingMaskIntoConstraints = NO;
	_clearButton.translatesAutoresizingMaskIntoConstraints = NO;
	_statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_logView.translatesAutoresizingMaskIntoConstraints = NO;

	[NSLayoutConstraint activateConstraints:@[
		[_fetchButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
		[_fetchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
		[_fetchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
		[_fetchButton.heightAnchor constraintEqualToConstant:44],

		[_rangeControl.topAnchor constraintEqualToAnchor:_fetchButton.bottomAnchor constant:10],
		[_rangeControl.leadingAnchor constraintEqualToAnchor:_fetchButton.leadingAnchor],
		[_rangeControl.trailingAnchor constraintEqualToAnchor:_fetchButton.trailingAnchor],

		[_probeButton.topAnchor constraintEqualToAnchor:_rangeControl.bottomAnchor constant:10],
		[_probeButton.leadingAnchor constraintEqualToAnchor:_fetchButton.leadingAnchor],
		[_probeButton.trailingAnchor constraintEqualToAnchor:_fetchButton.trailingAnchor],
		[_probeButton.heightAnchor constraintEqualToConstant:40],

		[_statusLabel.topAnchor constraintEqualToAnchor:_probeButton.bottomAnchor constant:10],
		[_statusLabel.leadingAnchor constraintEqualToAnchor:_fetchButton.leadingAnchor constant:4],
		[_statusLabel.trailingAnchor constraintEqualToAnchor:_fetchButton.trailingAnchor constant:-4],

		[_clearButton.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:4],
		[_clearButton.trailingAnchor constraintEqualToAnchor:_fetchButton.trailingAnchor],
		[_clearButton.heightAnchor constraintEqualToConstant:28],

		[_logView.topAnchor constraintEqualToAnchor:_clearButton.bottomAnchor constant:8],
		[_logView.leadingAnchor constraintEqualToAnchor:_fetchButton.leadingAnchor],
		[_logView.trailingAnchor constraintEqualToAnchor:_fetchButton.trailingAnchor],
		[_logView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
	]];
}

- (void)appendLog:(NSString*)line
{
	_logView.text = [_logView.text stringByAppendingFormat:@"%@\n", line];
	[_logView scrollRangeToVisible:NSMakeRange(_logView.text.length, 0)];
}

- (void)setStatus:(NSString*)status
{
	_statusLabel.text = status;
}

- (void)setRunning:(BOOL)running
{
	_running = running;
	_fetchButton.enabled = !running;
	_probeButton.enabled = !running;
}

- (void)clearLog
{
	_logView.text = @"Purchase history test.\n";
	[self setStatus:@"Ready."];
}

- (void)startTest
{
	if (_running)
	{
		return;
	}
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	if (!downloader.isAuthenticated)
	{
		[self appendLog:@"ERROR: not signed in. Use the authTest tab to sign in first."];
		return;
	}
	[self setRunning:YES];
	[_fetchButton setTitle:@"Fetching…" forState:UIControlStateNormal];
	[self appendLog:@"---"];
	[self appendLog:[NSString stringWithFormat:@"guid: %@", downloader.guid ?: @"?"]];
	__weak typeof(self) weakSelf = self;
	if (_rangeControl.selectedSegmentIndex == 4)
	{
		NSInteger currentYear = [self currentYear];
		[self setStatus:[NSString stringWithFormat:@"Fetching all-time history (2008-%ld)…", (long)currentYear]];
		[self appendLog:[NSString stringWithFormat:@"all-time: probing %ld-all … %ld-all", (long)2008, (long)currentYear]];
		[self fetchAllYearsWithYear:2008 currentYear:currentYear purchases:[NSMutableArray array] completion:^(NSArray* purchases, NSDictionary* firstResponse, NSError* error)
		{
			__strong typeof(self) self = weakSelf;
			if (!self)
			{
				return;
			}
			[self finishFetchWithPurchases:purchases firstResponse:firstResponse error:error];
		}];
		return;
	}
	NSString* range = [self selectedRangeString];
	[self setStatus:[NSString stringWithFormat:@"Fetching commerce history (range=%@)…", range]];
	[self fetchCommercePagesWithRange:range token:nil purchases:[NSMutableArray array] completion:^(NSArray* purchases, NSDictionary* firstResponse, NSError* error)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		[self finishFetchWithPurchases:purchases firstResponse:firstResponse error:error];
	}];
}

- (void)fetchAllYearsWithYear:(NSInteger)year currentYear:(NSInteger)currentYear purchases:(NSMutableArray*)purchases completion:(WFSAppleIDHistoryCompletion)completion
{
	if (year > currentYear)
	{
		completion(purchases, nil, nil);
		return;
	}
	NSString* range = [NSString stringWithFormat:@"%ld-all", (long)year];
	[self setStatus:[NSString stringWithFormat:@"All-time: probing %@…", range]];
	__weak typeof(self) weakSelf = self;
	[self fetchCommercePagesWithRange:range token:nil purchases:[NSMutableArray array] completion:^(NSArray* yearPurchases, NSDictionary* response, NSError* error)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		if (error)
		{
			completion(purchases, nil, error);
			return;
		}
		[purchases addObjectsFromArray:yearPurchases];
		[self appendLog:[NSString stringWithFormat:@"  %@ -> %lu purchase(s)", range, (unsigned long)yearPurchases.count]];
		[self fetchAllYearsWithYear:year + 1 currentYear:currentYear purchases:purchases completion:completion];
	}];
}

- (void)finishFetchWithPurchases:(NSArray*)purchases firstResponse:(NSDictionary*)firstResponse error:(NSError*)error
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	[self setRunning:NO];
	[_fetchButton setTitle:@"Fetch Commerce History" forState:UIControlStateNormal];
	if (error)
	{
		[self setStatus:@"Failed."];
		[self appendLog:[NSString stringWithFormat:@"FAILED [%ld]: %@", (long)error.code, error.localizedDescription]];
		if (downloader.lastDownloadEndpoint.length)
		{
			[self appendLog:[NSString stringWithFormat:@"  endpoint: %@", downloader.lastDownloadEndpoint]];
		}
		return;
	}
	[self setStatus:@"Done."];
	[self appendLog:[NSString stringWithFormat:@"endpoint: %@", downloader.lastDownloadEndpoint]];
	if ([firstResponse isKindOfClass:[NSDictionary class]])
	{
		NSArray* keys = [firstResponse.allKeys sortedArrayUsingSelector:@selector(compare:)];
		[self appendLog:[NSString stringWithFormat:@"response keys (%lu): %@", (unsigned long)keys.count, [keys componentsJoinedByString:@", "]]];
		NSDictionary* rangeInfo = firstResponse[@"range"];
		if ([rangeInfo isKindOfClass:[NSDictionary class]])
		{
			[self appendLog:[NSString stringWithFormat:@"range: start=%@ displayable=%@", [self stringFrom:rangeInfo[@"start"]], [self stringFrom:rangeInfo[@"displayable-range"]]]];
		}
	}
	[self appendLog:[NSString stringWithFormat:@"total purchases: %lu", (unsigned long)purchases.count]];
	for (NSUInteger i = 0; i < purchases.count; i++)
	{
		NSDictionary* purchase = purchases[i];
		NSString* title = purchase[@"title"];
		NSString* adamId = purchase[@"adamId"];
		NSString* bundleId = purchase[@"bundleId"];
		NSString* purchaseDate = purchase[@"purchaseDate"];
		[self appendLog:[NSString stringWithFormat:@"%lu. %@ #%@ %@ %@", (unsigned long)(i + 1), title ?: @"(untitled)", adamId ?: @"?", bundleId ?: @"?", purchaseDate ?: @"?"]];
	}
}

- (void)fetchCommercePagesWithRange:(NSString*)range token:(NSString*)token purchases:(NSMutableArray*)purchases completion:(WFSAppleIDHistoryCompletion)completion
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	NSInteger page = token.length ? 2 : 1;
	[self appendLog:[NSString stringWithFormat:@"page %ld (range=%@%@)", (long)page, range, token.length ? [NSString stringWithFormat:@", token=%@", token] : @""]];
	__weak typeof(self) weakSelf = self;
	[downloader fetchCommercePurchaseHistoryWithRange:range page:page paginationToken:token completion:^(NSArray* pagePurchases, NSDictionary* response, NSError* error)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		if (error)
		{
			completion(purchases, nil, error);
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
				[self fetchCommercePagesWithRange:range token:nextToken purchases:purchases completion:completion];
			});
			return;
		}
		completion(purchases, response, nil);
	}];
}

- (void)startProbe
{
	if (_running)
	{
		return;
	}
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	if (!downloader.isAuthenticated)
	{
		[self appendLog:@"ERROR: not signed in. Use the authTest tab to sign in first."];
		return;
	}
	[self setRunning:YES];
	[self appendLog:@"--- probing range values ---"];
	[self setStatus:@"Probing range values…"];
	NSArray* candidates = @[
		@"last90Days",
		@"2026-all",
		@"2025-all",
		@"2024-all",
		@"2023-all",
		@"2022-all",
		@"2021-all",
		@"2020-all",
		@"1970-all",
		@"9999-all",
		@"all-all",
	];
	__weak typeof(self) weakSelf = self;
	[self probeRanges:candidates index:0 completion:^
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		[self setRunning:NO];
		[self setStatus:@"Probe done."];
	}];
}

- (void)probeRanges:(NSArray*)ranges index:(NSUInteger)index completion:(void (^)(void))completion
{
	if (index >= ranges.count)
	{
		completion();
		return;
	}
	NSString* range = ranges[index];
	[self appendLog:[NSString stringWithFormat:@"range=%@", range]];
	__weak typeof(self) weakSelf = self;
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	[downloader fetchCommercePurchaseHistoryWithRange:range page:1 paginationToken:nil completion:^(NSArray* pagePurchases, NSDictionary* response, NSError* error)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		if (error)
		{
			[self appendLog:[NSString stringWithFormat:@"  -> %@", error.localizedDescription]];
		}
		else
		{
			NSString* echo = @"?";
			NSDictionary* rangeInfo = response[@"range"];
			if ([rangeInfo isKindOfClass:[NSDictionary class]])
			{
				echo = [NSString stringWithFormat:@"start=%@ disp=%@", [self stringFrom:rangeInfo[@"start"]], [self stringFrom:rangeInfo[@"displayable-range"]]];
			}
			[self appendLog:[NSString stringWithFormat:@"  -> HTTP 200 | %lu purchase(s) | %@", (unsigned long)pagePurchases.count, echo]];
		}
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^
		{
			[self probeRanges:ranges index:index + 1 completion:completion];
		});
	}];
}

- (NSString*)selectedRangeString
{
	switch (_rangeControl.selectedSegmentIndex)
	{
		case 1:
			return @"2026-all";
		case 2:
			return @"2025-all";
		case 3:
			return @"2024-all";
		default:
			return @"last90Days";
	}
}

- (NSInteger)currentYear
{
	return [[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:[NSDate date]];
}

- (NSString*)stringFrom:(id)value
{
	if ([value isKindOfClass:[NSString class]])
	{
		return (NSString*)value;
	}
	if ([value respondsToSelector:@selector(stringValue)])
	{
		return [value stringValue];
	}
	return @"?";
}

@end