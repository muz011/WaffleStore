#import "WFSDownloadTestViewController.h"
#import "WFSAppleIDDownloader.h"

static NSString* const kWFSDownloadTestUA = @"Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6";

@implementation WFSDownloadTestViewController
{
	UITextField* _adamIdField;
	UITextField* _versionField;
	UISwitch* _autoPurchaseSwitch;
	UIButton* _testButton;
	UIButton* _clearButton;
	UILabel* _statusLabel;
	UITextView* _logView;
	BOOL _running;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"downloadTest";
	self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

	_adamIdField = [self makeNumberFieldWithPlaceholder:@"Adam ID (App ID)"];
	_versionField = [self makeNumberFieldWithPlaceholder:@"External version ID (optional)"];

	_autoPurchaseSwitch = [UISwitch new];
	UILabel* autoPurchaseLabel = [[UILabel alloc] init];
	autoPurchaseLabel.text = @"Auto-purchase license if needed";
	autoPurchaseLabel.font = [UIFont systemFontOfSize:15];
	autoPurchaseLabel.textColor = [UIColor labelColor];
	UIStackView* autoPurchaseRow = [[UIStackView alloc] initWithArrangedSubviews:@[autoPurchaseLabel, _autoPurchaseSwitch]];
	autoPurchaseRow.axis = UILayoutConstraintAxisHorizontal;
	autoPurchaseRow.spacing = 8;
	autoPurchaseRow.distribution = UIStackViewDistributionEqualSpacing;

	_testButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_testButton setTitle:@"Test Download" forState:UIControlStateNormal];
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
	_logView.text = @"volumeStoreDownloadProduct download test.\n";

	[self.view addSubview:_adamIdField];
	[self.view addSubview:_versionField];
	[self.view addSubview:autoPurchaseRow];
	[self.view addSubview:_testButton];
	[self.view addSubview:_clearButton];
	[self.view addSubview:_statusLabel];
	[self.view addSubview:_logView];

	[self setupConstraintsForRow:autoPurchaseRow];
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

- (void)setupConstraintsForRow:(UIStackView*)autoPurchaseRow
{
	_adamIdField.translatesAutoresizingMaskIntoConstraints = NO;
	_versionField.translatesAutoresizingMaskIntoConstraints = NO;
	autoPurchaseRow.translatesAutoresizingMaskIntoConstraints = NO;
	_testButton.translatesAutoresizingMaskIntoConstraints = NO;
	_clearButton.translatesAutoresizingMaskIntoConstraints = NO;
	_statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_logView.translatesAutoresizingMaskIntoConstraints = NO;

	[NSLayoutConstraint activateConstraints:@[
		[_adamIdField.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
		[_adamIdField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
		[_adamIdField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
		[_adamIdField.heightAnchor constraintEqualToConstant:44],

		[_versionField.topAnchor constraintEqualToAnchor:_adamIdField.bottomAnchor constant:10],
		[_versionField.leadingAnchor constraintEqualToAnchor:_adamIdField.leadingAnchor],
		[_versionField.trailingAnchor constraintEqualToAnchor:_adamIdField.trailingAnchor],
		[_versionField.heightAnchor constraintEqualToConstant:44],

		[autoPurchaseRow.topAnchor constraintEqualToAnchor:_versionField.bottomAnchor constant:12],
		[autoPurchaseRow.leadingAnchor constraintEqualToAnchor:_adamIdField.leadingAnchor],
		[autoPurchaseRow.trailingAnchor constraintEqualToAnchor:_adamIdField.trailingAnchor],

		[_testButton.topAnchor constraintEqualToAnchor:autoPurchaseRow.bottomAnchor constant:12],
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
	_logView.text = @"volumeStoreDownloadProduct download test.\n";
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
	long long versionId = _versionField.text.longLongValue;
	_running = YES;
	_testButton.enabled = NO;
	[_testButton setTitle:@"Testing…" forState:UIControlStateNormal];
	[self.view endEditing:YES];
	[self appendLog:@"---"];
	[self appendLog:[NSString stringWithFormat:@"adamId=%lld versionId=%lld autoPurchase=%@", adamId, versionId, _autoPurchaseSwitch.isOn ? @"YES" : @"NO"]];
	[self appendLog:[NSString stringWithFormat:@"  account: %@ (dsid=%@)", downloader.authenticatedAppleId, downloader.dsid]];
	[self setStatus:@"Requesting download info…"];

	[downloader getDownloadInfoForAdamId:adamId versionId:versionId autoPurchase:_autoPurchaseSwitch.isOn completion:^(NSURL* ipaURL, NSDictionary* metadata, NSError* error)
	{
		dispatch_async(dispatch_get_main_queue(), ^
		{
			if (error)
			{
				[self handleDownloadError:error];
				return;
			}
			[self setStatus:@"Downloading .ipa…"];
			[self appendLog:[NSString stringWithFormat:@"endpoint: %@", downloader.lastDownloadEndpoint]];
			[self appendLog:[NSString stringWithFormat:@"URL: %@", ipaURL.absoluteString]];
			[self appendLog:@"downloading .ipa…"];
			[self downloadIPAAtURL:ipaURL adamId:adamId versionId:versionId metadata:metadata];
		});
	}];
}

- (void)handleDownloadError:(NSError*)error
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	_running = NO;
	_testButton.enabled = YES;
	[_testButton setTitle:@"Test Download" forState:UIControlStateNormal];
	[self setStatus:@"Failed."];
	[self appendLog:[NSString stringWithFormat:@"FAILED [%ld]: %@", (long)error.code, error.localizedDescription]];
	if (downloader.lastDownloadEndpoint.length)
	{
		[self appendLog:[NSString stringWithFormat:@"  endpoint: %@", downloader.lastDownloadEndpoint]];
	}
}

- (void)downloadIPAAtURL:(NSURL*)url adamId:(long long)adamId versionId:(long long)versionId metadata:(NSDictionary*)metadata
{
	NSString* directory = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"WaffleStore Downloads"];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
	NSString* bundleId = [metadata isKindOfClass:[NSDictionary class]] ? metadata[@"softwareVersionBundleId"] : nil;
	if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0)
	{
		bundleId = [NSString stringWithFormat:@"app%lld", adamId];
	}
	NSString* version = [metadata isKindOfClass:[NSDictionary class]] ? metadata[@"bundleShortVersionString"] : nil;
	if (![version isKindOfClass:[NSString class]] || version.length == 0)
	{
		version = versionId > 0 ? [NSString stringWithFormat:@"%lld", versionId] : @"latest";
	}
	NSString* filename = [NSString stringWithFormat:@"%@_%lld_%@.ipa", bundleId, adamId, version];
	NSString* destination = [directory stringByAppendingPathComponent:filename];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	[request setValue:kWFSDownloadTestUA forHTTPHeaderField:@"User-Agent"];
	NSURLSessionDownloadTask* task = [[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL* location, NSURLResponse* response, NSError* downloadError)
	{
		dispatch_async(dispatch_get_main_queue(), ^
		{
			_running = NO;
			_testButton.enabled = YES;
			[_testButton setTitle:@"Test Download" forState:UIControlStateNormal];
			if (downloadError || !location)
			{
				[self setStatus:@"Failed."];
				[self appendLog:[NSString stringWithFormat:@"DOWNLOAD FAILED: %@", downloadError.localizedDescription ?: @"Unknown error."]];
				return;
			}
			[[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
			NSError* moveError = nil;
			[[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destination] error:&moveError];
			if (moveError)
			{
				[self setStatus:@"Failed."];
				[self appendLog:[NSString stringWithFormat:@"SAVE FAILED: %@", moveError.localizedDescription]];
				return;
			}
			unsigned long long size = 0;
			NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:destination error:nil];
			if (attributes)
			{
				size = [attributes[NSFileSize] unsignedLongLongValue];
			}
			[self setStatus:@"Done."];
			[self appendLog:[NSString stringWithFormat:@"DOWNLOADED: %@", destination]];
			[self appendLog:[NSString stringWithFormat:@"  size: %llu bytes", size]];
		});
	}];
	[task resume];
}

@end