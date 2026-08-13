#import "WFSHistoryTestViewController.h"
#import "WFSAppleIDDownloader.h"

@implementation WFSHistoryTestViewController
{
	UIButton* _fetchButton;
	UIButton* _clearButton;
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
	[_fetchButton setTitle:@"Fetch All History" forState:UIControlStateNormal];
	[_fetchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	_fetchButton.backgroundColor = [UIColor systemBlueColor];
	_fetchButton.layer.cornerRadius = 10;
	[_fetchButton addTarget:self action:@selector(startTest) forControlEvents:UIControlEventTouchUpInside];

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
	[self.view addSubview:_clearButton];
	[self.view addSubview:_statusLabel];
	[self.view addSubview:_logView];

	[self setupConstraints];
}

- (void)setupConstraints
{
	_fetchButton.translatesAutoresizingMaskIntoConstraints = NO;
	_clearButton.translatesAutoresizingMaskIntoConstraints = NO;
	_statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_logView.translatesAutoresizingMaskIntoConstraints = NO;

	[NSLayoutConstraint activateConstraints:@[
		[_fetchButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
		[_fetchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
		[_fetchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
		[_fetchButton.heightAnchor constraintEqualToConstant:44],

		[_statusLabel.topAnchor constraintEqualToAnchor:_fetchButton.bottomAnchor constant:10],
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
	_running = YES;
	_fetchButton.enabled = NO;
	[_fetchButton setTitle:@"Fetching…" forState:UIControlStateNormal];
	[self appendLog:@"---"];
	[self setStatus:@"Fetching purchase history…"];
	__weak typeof(self) weakSelf = self;
	downloader.historyProgressHandler = ^(NSInteger chunkNumber, NSInteger chunkCount, NSInteger totalPurchases)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		[self appendLog:[NSString stringWithFormat:@"chunk %ld -> %ld metadata app(s), total %ld", (long)chunkNumber, (long)chunkCount, (long)totalPurchases]];
	};
	[downloader getAllPurchaseHistoryWithCompletion:^(NSArray* purchases, NSDictionary* firstResponse, NSError* error)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		downloader.historyProgressHandler = nil;
		_running = NO;
		_fetchButton.enabled = YES;
		[_fetchButton setTitle:@"Fetch All History" forState:UIControlStateNormal];
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
		}
		[self appendLog:[NSString stringWithFormat:@"total purchases: %lu", (unsigned long)purchases.count]];
		NSMutableSet* metadataKeys = [NSMutableSet set];
		for (NSDictionary* purchase in purchases)
		{
			NSDictionary* metadata = purchase[@"metadata"];
			if ([metadata isKindOfClass:[NSDictionary class]])
			{
				[metadataKeys addObjectsFromArray:metadata.allKeys];
			}
		}
		if (metadataKeys.count)
		{
			NSArray* sortedKeys = [metadataKeys.allObjects sortedArrayUsingSelector:@selector(compare:)];
			[self appendLog:[NSString stringWithFormat:@"metadata keys seen (%lu): %@", (unsigned long)sortedKeys.count, [sortedKeys componentsJoinedByString:@", "]]];
		}
		for (NSUInteger i = 0; i < purchases.count; i++)
		{
			NSDictionary* purchase = purchases[i];
			NSString* title = purchase[@"title"];
			NSString* adamId = purchase[@"adamId"];
			NSString* bundleId = purchase[@"bundleId"];
			NSString* purchaseDate = purchase[@"purchaseDate"];
			NSString* marker = @"";
			NSDictionary* metadata = purchase[@"metadata"];
			if (![metadata isKindOfClass:[NSDictionary class]])
			{
				marker = @" [no metadata - possibly deleted/removed]";
			}
			[self appendLog:[NSString stringWithFormat:@"%lu. %@ #%@ %@ %@%@", (unsigned long)(i + 1), title ?: @"(untitled)", adamId ?: @"?", bundleId ?: @"?", purchaseDate ?: @"?", marker]];
		}
	}];
}

@end
