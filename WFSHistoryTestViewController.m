#import "WFSHistoryTestViewController.h"
#import "WFSAppleIDDownloader.h"
#import "WFSRAPClient.h"

@implementation WFSHistoryTestViewController
{
	UIButton* _fetchButton;
	UIButton* _clearButton;
	UIButton* _rapButton;
	UILabel* _statusLabel;
	UITextView* _logView;
	BOOL _running;
	BOOL _rapRunning;
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

	_rapButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_rapButton setTitle:@"Fetch All History (RAP)" forState:UIControlStateNormal];
	[_rapButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	_rapButton.backgroundColor = [UIColor systemTealColor];
	_rapButton.layer.cornerRadius = 10;
	[_rapButton addTarget:self action:@selector(startRAPTest) forControlEvents:UIControlEventTouchUpInside];

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
	[self.view addSubview:_rapButton];
	[self.view addSubview:_statusLabel];
	[self.view addSubview:_logView];

	[self setupConstraints];
}

- (void)setupConstraints
{
	_fetchButton.translatesAutoresizingMaskIntoConstraints = NO;
	_clearButton.translatesAutoresizingMaskIntoConstraints = NO;
	_rapButton.translatesAutoresizingMaskIntoConstraints = NO;
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

		[_rapButton.topAnchor constraintEqualToAnchor:_clearButton.bottomAnchor constant:8],
		[_rapButton.leadingAnchor constraintEqualToAnchor:_fetchButton.leadingAnchor],
		[_rapButton.trailingAnchor constraintEqualToAnchor:_fetchButton.trailingAnchor],
		[_rapButton.heightAnchor constraintEqualToConstant:44],

		[_logView.topAnchor constraintEqualToAnchor:_rapButton.bottomAnchor constant:8],
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

- (void)startRAPTest
{
	if (_running || _rapRunning)
	{
		return;
	}
	WFSRAPClient* rap = [WFSRAPClient sharedClient];
	if (rap.isAuthenticated)
	{
		[self runRAPFetch];
		return;
	}
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	NSString* email = downloader.authenticatedAppleId;
	if (!email.length)
	{
		email = [[NSUserDefaults standardUserDefaults] stringForKey:@"wfsAppleIDEmail"];
	}
	if (!email.length)
	{
		[self appendLog:@"ERROR: no Apple ID known. Sign in on the authTest tab first."];
		return;
	}
	UIAlertController* signInAlert = [UIAlertController alertControllerWithTitle:@"Apple ID (RAP)"
																		message:@"Sign in to the reportaproblem.apple.com portal to fetch your full purchase history.\n\nYour password is only used for this request and is never stored."
																 preferredStyle:UIAlertControllerStyleAlert];
	[signInAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
	{
		textField.placeholder = email;
		textField.text = email;
		textField.keyboardType = UIKeyboardTypeEmailAddress;
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
	}];
	[signInAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
	{
		textField.placeholder = @"Password";
		textField.secureTextEntry = YES;
	}];
	[signInAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[signInAlert addAction:[UIAlertAction actionWithTitle:@"Sign In" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		NSString* account = [signInAlert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSString* password = signInAlert.textFields[1].text;
		if (!account.length || !password.length)
		{
			[self appendLog:@"ERROR: Apple ID and password are required."];
			return;
		}
		[self authenticateRAPWithAppleId:account password:password];
	}]];
	[self presentViewController:signInAlert animated:YES completion:nil];
}

- (void)authenticateRAPWithAppleId:(NSString*)appleId password:(NSString*)password
{
	if (_rapRunning)
	{
		return;
	}
	_rapRunning = YES;
	_rapButton.enabled = NO;
	[_rapButton setTitle:@"Signing in…" forState:UIControlStateNormal];
	[self appendLog:@"---"];
	[self setStatus:@"Signing in to RAP portal…"];
	__weak typeof(self) weakSelf = self;
	[[WFSRAPClient sharedClient] authenticateWithAppleId:appleId password:password completion:^(NSError* error)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		if (error && error.code == WFSAppleIDDownloaderError2FARequired)
		{
			[self promptRAPTwoFactorCode];
			return;
		}
		if (error)
		{
			[self appendLog:[NSString stringWithFormat:@"RAP sign-in FAILED [%ld]: %@", (long)error.code, error.localizedDescription]];
			[self appendLog:@"Full details: Documents/WaffleStore_rap.log on this device."];
			[self setRAPStopped];
			return;
		}
		[self appendLog:@"RAP sign-in OK"];
		[self runRAPFetch];
	}];
}

- (void)promptRAPTwoFactorCode
{
	UIAlertController* codeAlert = [UIAlertController alertControllerWithTitle:@"Two-Factor Authentication"
																	 message:@"Enter the 6-digit verification code for this Apple ID.\n\nNo code arrived? Generate one from any device signed in to this Apple ID: Settings > [your name] > Sign-in & Security > Two-Factor Authentication > Get Verification Code. Codes expire quickly, so enter it right away."
															  preferredStyle:UIAlertControllerStyleAlert];
	[codeAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
	{
		textField.placeholder = @"Code";
		textField.keyboardType = UIKeyboardTypeNumberPad;
	}];
	[codeAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
	{
		[[WFSRAPClient sharedClient] cancelAuthentication];
		[self appendLog:@"RAP sign-in cancelled."];
		[self setRAPStopped];
	}]];
	[codeAlert addAction:[UIAlertAction actionWithTitle:@"Verify" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		NSString* code = [codeAlert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if (!code.length)
		{
			[self promptRAPTwoFactorCode];
			return;
		}
		[self appendLog:@"Submitting two-factor code…"];
		__weak typeof(self) weakSelf = self;
		[[WFSRAPClient sharedClient] retryWithTwoFactorCode:code completion:^(NSError* error)
		{
			__strong typeof(self) self = weakSelf;
			if (!self)
			{
				return;
			}
			if (error)
			{
				[self appendLog:[NSString stringWithFormat:@"RAP two-factor FAILED [%ld]: %@", (long)error.code, error.localizedDescription]];
				[self appendLog:@"Full details: Documents/WaffleStore_rap.log on this device."];
				[self setRAPStopped];
				return;
			}
			[self appendLog:@"RAP two-factor OK"];
			[self runRAPFetch];
		}];
	}]];
	[self presentViewController:codeAlert animated:YES completion:nil];
}

- (void)runRAPFetch
{
	_rapRunning = YES;
	_rapButton.enabled = NO;
	[_rapButton setTitle:@"Fetching RAP history…" forState:UIControlStateNormal];
	[self appendLog:@"---"];
	[self setStatus:@"Fetching RAP purchase history…"];
	WFSRAPClient* rap = [WFSRAPClient sharedClient];
	__weak typeof(self) weakSelf = self;
	rap.historyProgressHandler = ^(NSInteger pageNumber, NSInteger pagePurchaseCount, NSInteger totalPurchases)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		[self appendLog:[NSString stringWithFormat:@"page %ld -> %ld item(s), total %ld", (long)pageNumber, (long)pagePurchaseCount, (long)totalPurchases]];
	};
	[rap fetchFullPurchaseHistoryWithCompletion:^(NSArray* purchases, NSDictionary* firstResponse, NSError* error)
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		rap.historyProgressHandler = nil;
		[self setRAPStopped];
		if (error)
		{
			[self setStatus:@"Failed."];
			[self appendLog:[NSString stringWithFormat:@"RAP FAILED [%ld]: %@", (long)error.code, error.localizedDescription]];
			[self appendLog:@"Full details: Documents/WaffleStore_rap.log on this device."];
			return;
		}
		[self setStatus:@"Done."];
		[self appendLog:@"endpoint: POST https://reportaproblem.apple.com/api/purchase/search"];
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
			[self appendLog:[NSString stringWithFormat:@"RAP item keys seen (%lu): %@", (unsigned long)sortedKeys.count, [sortedKeys componentsJoinedByString:@", "]]];
		}
		for (NSUInteger i = 0; i < purchases.count; i++)
		{
			NSDictionary* purchase = purchases[i];
			NSString* title = purchase[@"title"];
			NSString* adamId = purchase[@"adamId"];
			NSString* bundleId = purchase[@"bundleId"];
			NSString* purchaseDate = purchase[@"purchaseDate"];
			NSString* orderId = purchase[@"orderId"];
			[self appendLog:[NSString stringWithFormat:@"%lu. %@ #%@ %@ %@ (order %@)", (unsigned long)(i + 1), title ?: @"(untitled)", adamId ?: @"?", bundleId ?: @"?", purchaseDate ?: @"?", orderId ?: @"?"]];
		}
	}];
}

- (void)setRAPStopped
{
	_rapRunning = NO;
	_rapButton.enabled = YES;
	[_rapButton setTitle:@"Fetch All History (RAP)" forState:UIControlStateNormal];
}

@end
