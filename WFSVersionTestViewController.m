#import "WFSVersionTestViewController.h"
#import "WFSAppleIDDownloader.h"

@implementation WFSVersionTestViewController
{
	UITextField* _adamIdField;
	UIButton* _testButton;
	UIButton* _clearButton;
	UILabel* _statusLabel;
	UITextView* _logView;
	BOOL _running;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"verTest";
	self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

	_adamIdField = [self makeNumberFieldWithPlaceholder:@"Adam ID (App ID)"];
	_adamIdField.text = [[NSUserDefaults standardUserDefaults] objectForKey:@"wfsVerTestAdamId"];

	_testButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_testButton setTitle:@"Fetch Versions" forState:UIControlStateNormal];
	[_testButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	_testButton.backgroundColor = [UIColor systemBlueColor];
	_testButton.layer.cornerRadius = 10;
	[_testButton addTarget:self action:@selector(startTest) forControlEvents:UIControlEventTouchUpInside];

	_clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_clearButton setTitle:@"Clear Log" forState:UIControlStateNormal];
	[_clearButton addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];

	_statusLabel = [[UILabel alloc] init];
	_statusLabel.font = [UIFont systemFontOfSize:13];
	_statusLabel.textColor = [UIColor secondaryLabelColor];
	_statusLabel.text = @"Ready.";

	UITapGestureRecognizer* tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
	tapGesture.cancelsTouchesInView = NO;
	[self.view addGestureRecognizer:tapGesture];

	_logView = [[UITextView alloc] init];
	_logView.editable = NO;
	_logView.selectable = YES;
	_logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	_logView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
	_logView.layer.cornerRadius = 10;
	_logView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
	_logView.text = @"External version identifiers test.\n";

	[self.view addSubview:_adamIdField];
	[self.view addSubview:_testButton];
	[self.view addSubview:_clearButton];
	[self.view addSubview:_statusLabel];
	[self.view addSubview:_logView];

	[self setupConstraints];
}

- (UITextField*)makeNumberFieldWithPlaceholder:(NSString*)placeholder
{
	UITextField* field = [[UITextField alloc] init];
	field.placeholder = placeholder;
	field.borderStyle = UITextBorderStyleRoundedRect;
	field.keyboardType = UIKeyboardTypeNumberPad;
	field.autocorrectionType = UITextAutocorrectionTypeNo;
	field.clearButtonMode = UITextFieldViewModeWhileEditing;
	field.inputAccessoryView = [self keyboardDoneToolbar];
	return field;
}

- (UIToolbar*)keyboardDoneToolbar
{
	UIToolbar* toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
	UIBarButtonItem* flexible = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
	UIBarButtonItem* done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissKeyboard)];
	toolbar.items = @[flexible, done];
	return toolbar;
}

- (void)dismissKeyboard
{
	[self.view endEditing:YES];
}

- (void)setupConstraints
{
	_adamIdField.translatesAutoresizingMaskIntoConstraints = NO;
	_testButton.translatesAutoresizingMaskIntoConstraints = NO;
	_clearButton.translatesAutoresizingMaskIntoConstraints = NO;
	_statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_logView.translatesAutoresizingMaskIntoConstraints = NO;

	[NSLayoutConstraint activateConstraints:@[
		[_adamIdField.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
		[_adamIdField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
		[_adamIdField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
		[_adamIdField.heightAnchor constraintEqualToConstant:44],

		[_testButton.topAnchor constraintEqualToAnchor:_adamIdField.bottomAnchor constant:12],
		[_testButton.leadingAnchor constraintEqualToAnchor:_adamIdField.leadingAnchor],
		[_testButton.trailingAnchor constraintEqualToAnchor:_adamIdField.trailingAnchor],
		[_testButton.heightAnchor constraintEqualToConstant:44],

		[_statusLabel.topAnchor constraintEqualToAnchor:_testButton.bottomAnchor constant:10],
		[_statusLabel.leadingAnchor constraintEqualToAnchor:_adamIdField.leadingAnchor constant:4],
		[_statusLabel.trailingAnchor constraintEqualToAnchor:_adamIdField.trailingAnchor constant:-4],

		[_clearButton.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:4],
		[_clearButton.trailingAnchor constraintEqualToAnchor:_adamIdField.trailingAnchor],
		[_clearButton.heightAnchor constraintEqualToConstant:28],

		[_logView.topAnchor constraintEqualToAnchor:_clearButton.bottomAnchor constant:8],
		[_logView.leadingAnchor constraintEqualToAnchor:_adamIdField.leadingAnchor],
		[_logView.trailingAnchor constraintEqualToAnchor:_adamIdField.trailingAnchor],
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
	_logView.text = @"External version identifiers test.\n";
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
	long long adamId = _adamIdField.text.longLongValue;
	if (adamId <= 0)
	{
		[self appendLog:@"ERROR: enter a valid Adam ID (app ID)."];
		return;
	}
	_running = YES;
	_testButton.enabled = NO;
	[_testButton setTitle:@"Fetching…" forState:UIControlStateNormal];
	[self.view endEditing:YES];
	[[NSUserDefaults standardUserDefaults] setObject:_adamIdField.text forKey:@"wfsVerTestAdamId"];
	[self appendLog:@"---"];
	[self appendLog:[NSString stringWithFormat:@"adamId=%lld", adamId]];
	[self setStatus:@"Fetching versions…"];

	[downloader getExternalVersionIdsForAdamId:adamId completion:^(NSArray* externalVersionIds, NSDictionary* metadata, NSError* error)
	{
		_running = NO;
		_testButton.enabled = YES;
		[_testButton setTitle:@"Fetch Versions" forState:UIControlStateNormal];
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
		if ([metadata isKindOfClass:[NSDictionary class]])
		{
			NSString* bundleId = metadata[@"softwareVersionBundleId"];
			if ([bundleId isKindOfClass:[NSString class]] && bundleId.length)
			{
				[self appendLog:[NSString stringWithFormat:@"bundleId: %@", bundleId]];
			}
			NSString* currentVersion = metadata[@"bundleShortVersionString"];
			if ([currentVersion isKindOfClass:[NSString class]] && currentVersion.length)
			{
				[self appendLog:[NSString stringWithFormat:@"current version: %@", currentVersion]];
			}
			id latest = metadata[@"softwareVersionExternalIdentifier"];
			if (latest)
			{
				[self appendLog:[NSString stringWithFormat:@"latest external version ID: %@", latest]];
			}
		}
		[self appendLog:[NSString stringWithFormat:@"external version IDs (%lu):", (unsigned long)externalVersionIds.count]];
		for (NSString* identifier in externalVersionIds)
		{
			[self appendLog:[NSString stringWithFormat:@"  %@", identifier]];
		}
	}];
}

@end