#import "WFSAuthTestViewController.h"
#import "WFSAppleIDDownloader.h"

@implementation WFSAuthTestViewController
{
	UITextField* _emailField;
	UITextField* _passwordField;
	UIButton* _testButton;
	UIButton* _clearButton;
	UILabel* _statusLabel;
	UITextView* _logView;
	BOOL _running;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"authTest";
	self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

	_emailField = [self makeTextFieldWithPlaceholder:@"Apple ID email" secure:NO];
	_emailField.text = [[NSUserDefaults standardUserDefaults] objectForKey:@"wfsAppleIDEmail"];
	_passwordField = [self makeTextFieldWithPlaceholder:@"Password" secure:YES];

	_testButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_testButton setTitle:@"Test Auth" forState:UIControlStateNormal];
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
	_logView.text = @"Anisette + buy/MZFinance.woa/wa/authenticate test.\n";

	[self.view addSubview:_emailField];
	[self.view addSubview:_passwordField];
	[self.view addSubview:_testButton];
	[self.view addSubview:_clearButton];
	[self.view addSubview:_statusLabel];
	[self.view addSubview:_logView];

	[self setupConstraints];
}

- (UITextField*)makeTextFieldWithPlaceholder:(NSString*)placeholder secure:(BOOL)secure
{
	UITextField* field = [[UITextField alloc] init];
	field.placeholder = placeholder;
	field.secureTextEntry = secure;
	field.borderStyle = UITextBorderStyleRoundedRect;
	field.autocorrectionType = UITextAutocorrectionTypeNo;
	field.autocapitalizationType = UITextAutocapitalizationTypeNone;
	field.keyboardType = secure ? UIKeyboardTypeDefault : UIKeyboardTypeEmailAddress;
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
	_emailField.translatesAutoresizingMaskIntoConstraints = NO;
	_passwordField.translatesAutoresizingMaskIntoConstraints = NO;
	_testButton.translatesAutoresizingMaskIntoConstraints = NO;
	_clearButton.translatesAutoresizingMaskIntoConstraints = NO;
	_statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_logView.translatesAutoresizingMaskIntoConstraints = NO;

	[NSLayoutConstraint activateConstraints:@[
		[_emailField.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
		[_emailField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
		[_emailField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
		[_emailField.heightAnchor constraintEqualToConstant:44],

		[_passwordField.topAnchor constraintEqualToAnchor:_emailField.bottomAnchor constant:10],
		[_passwordField.leadingAnchor constraintEqualToAnchor:_emailField.leadingAnchor],
		[_passwordField.trailingAnchor constraintEqualToAnchor:_emailField.trailingAnchor],
		[_passwordField.heightAnchor constraintEqualToConstant:44],

		[_testButton.topAnchor constraintEqualToAnchor:_passwordField.bottomAnchor constant:12],
		[_testButton.leadingAnchor constraintEqualToAnchor:_emailField.leadingAnchor],
		[_testButton.trailingAnchor constraintEqualToAnchor:_emailField.trailingAnchor],
		[_testButton.heightAnchor constraintEqualToConstant:44],

		[_statusLabel.topAnchor constraintEqualToAnchor:_testButton.bottomAnchor constant:10],
		[_statusLabel.leadingAnchor constraintEqualToAnchor:_emailField.leadingAnchor constant:4],
		[_statusLabel.trailingAnchor constraintEqualToAnchor:_emailField.trailingAnchor constant:-4],

		[_clearButton.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:4],
		[_clearButton.trailingAnchor constraintEqualToAnchor:_emailField.trailingAnchor],
		[_clearButton.heightAnchor constraintEqualToConstant:28],

		[_logView.topAnchor constraintEqualToAnchor:_clearButton.bottomAnchor constant:8],
		[_logView.leadingAnchor constraintEqualToAnchor:_emailField.leadingAnchor],
		[_logView.trailingAnchor constraintEqualToAnchor:_emailField.trailingAnchor],
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
	_logView.text = @"Anisette + buy/MZFinance.woa/wa/authenticate test.\n";
	[self setStatus:@"Ready."];
}

- (void)startTest
{
	if (_running)
	{
		return;
	}
	NSString* email = _emailField.text;
	NSString* password = _passwordField.text;
	if (!email.length || !password.length)
	{
		[self appendLog:@"ERROR: enter both Apple ID and password."];
		return;
	}
	_running = YES;
	_testButton.enabled = NO;
	[_testButton setTitle:@"Testing…" forState:UIControlStateNormal];
	[self.view endEditing:YES];
	[self appendLog:@"---"];
	[self appendLog:[NSString stringWithFormat:@"Testing auth for %@", email]];

	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	downloader.authProgressHandler = ^(NSUInteger attempt, NSUInteger totalAttempts)
	{
		[self setStatus:[NSString stringWithFormat:@"Attempt %lu/%lu…", (unsigned long)attempt, (unsigned long)totalAttempts]];
	};
	[downloader authenticateWithAppleId:email password:password completion:^(NSError* error)
	{
		[self handleAuthCompletionWithError:error];
	}];
}

- (void)handleAuthCompletionWithError:(NSError*)error
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	[downloader setAuthProgressHandler:nil];
	dispatch_async(dispatch_get_main_queue(), ^
	{
		_running = NO;
		_testButton.enabled = YES;
		[_testButton setTitle:@"Test Auth" forState:UIControlStateNormal];
		if (error)
		{
			[self handleAuthError:error];
			return;
		}
		[self setStatus:@"Signed in."];
		[self appendLog:@"SUCCESS: authenticated."];
		if (downloader.lastAuthEndpoint.length)
		{
			[self appendLog:[NSString stringWithFormat:@"  endpoint: %@", downloader.lastAuthEndpoint]];
		}
		if (downloader.dsid.length)
		{
			[self appendLog:[NSString stringWithFormat:@"  dsid: %@", downloader.dsid]];
		}
		if (downloader.storeFront.length)
		{
			[self appendLog:[NSString stringWithFormat:@"  storeFront: %@", downloader.storeFront]];
		}
		[self appendLog:downloader.anisetteAvailable ? @"  anisette: headers were applied" : @"  anisette: NOT available (ani.sidestore.io unreachable)"];
	});
}

- (void)handleAuthError:(NSError*)error
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	[self setStatus:@"Failed."];
	[self appendLog:[NSString stringWithFormat:@"FAILED [%ld]: %@", (long)error.code, error.localizedDescription]];
	if (error.code == WFSAppleIDDownloaderErrorCancelled)
	{
		[self appendLog:@"  cancelled."];
		return;
	}
	if (error.code == WFSAppleIDDownloaderError2FARequired)
	{
		[self appendLog:@"  2FA code required, prompting…"];
		[self promptTwoFactorCode];
		return;
	}
	if (downloader.lastAuthEndpoint.length)
	{
		[self appendLog:[NSString stringWithFormat:@"  last endpoint: %@", downloader.lastAuthEndpoint]];
	}
	[self appendLog:downloader.anisetteAvailable ? @"  anisette: headers were applied" : @"  anisette: NOT available (ani.sidestore.io unreachable)"];
	[self appendLog:@"  log file: Documents/WaffleStore_appleid.log"];
	[self appendLogFileContents];
}

- (void)promptTwoFactorCode
{
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Two-Factor Authentication" message:@"Enter the 6-digit verification code for this Apple ID." preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField* textField)
	{
		textField.placeholder = @"6-digit code";
		textField.keyboardType = UIKeyboardTypeNumberPad;
	}];
	UIAlertAction* verifyAction = [UIAlertAction actionWithTitle:@"Verify" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		NSString* code = alert.textFields.firstObject.text;
		if (!code.length)
		{
			[self handleAuthCompletionWithError:[self cancelledError]];
			return;
		}
		[self retryAuthWithCode:code];
	}];
	[alert addAction:verifyAction];
	UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
	{
		[[WFSAppleIDDownloader sharedDownloader] cancelAuthentication];
		[self handleAuthCompletionWithError:[self cancelledError]];
	}];
	[alert addAction:cancelAction];
	[self presentViewController:alert animated:YES completion:nil];
}

- (NSError*)cancelledError
{
	return [NSError errorWithDomain:WFSAppleIDDownloaderErrorDomain code:WFSAppleIDDownloaderErrorCancelled userInfo:nil];
}

- (void)retryAuthWithCode:(NSString*)code
{
	_running = YES;
	_testButton.enabled = NO;
	[_testButton setTitle:@"Testing…" forState:UIControlStateNormal];
	[self appendLog:@"Submitting 2FA code…"];
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	downloader.authProgressHandler = ^(NSUInteger attempt, NSUInteger totalAttempts)
	{
		[self setStatus:[NSString stringWithFormat:@"Attempt %lu/%lu…", (unsigned long)attempt, (unsigned long)totalAttempts]];
	};
	[downloader retryWithTwoFactorCode:code completion:^(NSError* error)
	{
		[self handleAuthCompletionWithError:error];
	}];
}

- (void)appendLogFileContents
{
	NSString* path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"WaffleStore_appleid.log"];
	NSString* contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
	if (!contents.length)
	{
		[self appendLog:@"  (log file not written yet)"];
		return;
	}
	NSArray* lines = [contents componentsSeparatedByString:@"\n"];
	NSUInteger start = lines.count > 30 ? lines.count - 30 : 0;
	for (NSUInteger i = start; i < lines.count; i++)
	{
		NSString* line = lines[i];
		if (line.length)
		{
			[self appendLog:line];
		}
	}
}

@end