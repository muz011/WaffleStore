#import "WFSRootViewController.h"
#import "WFSVersionPickerViewController.h"
#import "WFSAppleIDDownloader.h"
#import "WFSPatchIPA.h"
#import "CoreServices.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <zlib.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <sys/types.h>
#import <signal.h>
#import <time.h>
#import <unistd.h>
#import <dlfcn.h>

extern char** environ;

typedef struct __WFSSecTask* WFSSecTaskRef;
extern WFSSecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(WFSSecTaskRef task, CFStringRef entitlement, CFErrorRef* error);

extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict attrs, uid_t persona_id, uint32_t flags);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict attrs, uid_t uid);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict attrs, gid_t gid);

#define WFS_PERSONA_FLAGS_OVERRIDE 1

typedef int (*WFSJBInitFn)(void);
typedef int (*WFSJBClientCloseFn)(void);
typedef int (*WFSJBClientSpawnFn)(uid_t uid, gid_t gid, int argc, char** argv, void (^callback)(pid_t pid));
typedef int (*WFSJBPersonaFixFn)(int childPid, uid_t overwriteUid, gid_t overwriteGid);

static NSNumber* wfsEffectiveEntitlement(NSString* key)
{
	WFSSecTaskRef task = SecTaskCreateFromSelf(NULL);
	if (!task)
	{
		return nil;
	}
	CFTypeRef value = SecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)key, NULL);
	CFRelease(task);
	if (!value)
	{
		return @NO;
	}
	if (CFGetTypeID(value) == CFBooleanGetTypeID())
	{
		BOOL result = CFBooleanGetValue((CFBooleanRef)value);
		CFRelease(value);
		return @(result);
	}
	CFRelease(value);
	return nil;
}

static void* wfsJailbreakdHandle(void)
{
	static void* cachedHandle = NULL;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^
	{
		cachedHandle = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_LAZY);
		if (!cachedHandle)
		{
			cachedHandle = dlopen("/var/jb/usr/lib/libjailbreak.dylib", RTLD_LAZY);
		}
		if (!cachedHandle)
		{
			cachedHandle = dlopen("/jb/libjailbreak.dylib", RTLD_LAZY);
		}
	});
	return cachedHandle;
}

static NSString* wfsReadNewLogData(NSString* path, NSUInteger* byteCursor)
{
	NSData* data = [NSData dataWithContentsOfFile:path];
	if (!data || data.length <= *byteCursor)
	{
		return nil;
	}
	NSRange range = NSMakeRange(*byteCursor, data.length - *byteCursor);
	*byteCursor = data.length;
	NSData* newData = [data subdataWithRange:range];
	NSString* output = [[NSString alloc] initWithData:newData encoding:NSUTF8StringEncoding];
	if (!output)
	{
		output = [[NSString alloc] initWithData:newData encoding:NSASCIIStringEncoding];
	}
	return output;
}

static void wfsDrainLogFile(NSString* path, NSUInteger* cursor, void (^outputHandler)(NSString* chunk), void (^progressHandler)(NSString* message))
{
	if (!path)
	{
		return;
	}
	NSString* newOutput = wfsReadNewLogData(path, cursor);
	if (!newOutput || newOutput.length == 0)
	{
		return;
	}
	if (outputHandler)
	{
		outputHandler(newOutput);
	}
	if (progressHandler)
	{
		for (NSString* line in [newOutput componentsSeparatedByString:@"\n"])
		{
			if ([line hasPrefix:@"WFS_PROGRESS: "])
			{
				NSString* payload = [line substringFromIndex:@"WFS_PROGRESS: ".length];
				NSArray* parts = [payload componentsSeparatedByString:@" "];
				if (parts.count >= 2)
				{
					NSString* prettyStatus = [parts[1] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
					progressHandler([NSString stringWithFormat:@"Installing via system installer… %@%% (%@)", parts[0], prettyStatus]);
				}
			}
		}
	}
}

static BOOL WFSSpawnWithTimeout(NSArray* arguments, NSTimeInterval timeout, BOOL* cancelled)
{
	NSMutableArray* allArguments = [NSMutableArray arrayWithArray:arguments];
	[allArguments insertObject:arguments.firstObject atIndex:0];
	NSMutableArray* cStrings = [NSMutableArray arrayWithCapacity:allArguments.count];
	char** argv = calloc(allArguments.count + 1, sizeof(char*));
	if (!argv)
	{
		return NO;
	}
	for (NSUInteger i = 0; i < allArguments.count; i++)
	{
		NSString* argument = allArguments[i];
		char* copy = strdup(argument.UTF8String);
		[cStrings addObject:[NSData dataWithBytes:copy length:strlen(copy) + 1]];
		argv[i] = copy;
	}
	argv[allArguments.count] = NULL;
	pid_t pid = 0;
	int spawnResult = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
	if (spawnResult != 0)
	{
		free(argv);
		return NO;
	}
	struct timespec sleepTime = { 0, 100 * 1000 * 1000 };
	int status = 0;
	NSTimeInterval start = [NSProcessInfo processInfo].systemUptime;
	while (waitpid(pid, &status, WNOHANG) == 0)
	{
		if (cancelled && *cancelled)
		{
			kill(pid, SIGKILL);
			waitpid(pid, &status, 0);
			free(argv);
			return NO;
		}
		if ([NSProcessInfo processInfo].systemUptime - start > timeout)
		{
			kill(pid, SIGKILL);
			waitpid(pid, &status, 0);
			free(argv);
			return NO;
		}
		nanosleep(&sleepTime, NULL);
	}
	free(argv);
	return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static NSInteger WFSSpawnRootWithTimeout(NSArray* arguments, NSString* logFilePath, NSTimeInterval timeout, BOOL* cancelled, NSString** output, int* spawnErrnoOut, NSString** methodUsedOut, void (^progressHandler)(NSString* message), void (^outputHandler)(NSString* chunk))
{
	if (logFilePath && ![[NSFileManager defaultManager] fileExistsAtPath:logFilePath])
	{
		[NSData.data writeToFile:logFilePath atomically:NO];
	}
	NSMutableArray* allArguments = [NSMutableArray arrayWithArray:arguments];
	[allArguments insertObject:arguments.firstObject atIndex:0];
	[allArguments addObject:@"--wfs-log"];
	[allArguments addObject:logFilePath ?: @""];
	char** argv = calloc(allArguments.count + 1, sizeof(char*));
	if (!argv)
	{
		return -400;
	}
	NSMutableArray* cStrings = [NSMutableArray arrayWithCapacity:allArguments.count];
	for (NSUInteger i = 0; i < allArguments.count; i++)
	{
		NSString* argument = allArguments[i];
		char* copy = strdup(argument.UTF8String);
		[cStrings addObject:[NSData dataWithBytes:copy length:strlen(copy) + 1]];
		argv[i] = copy;
	}
	argv[allArguments.count] = NULL;
	struct timespec sleepTime = { 0, 100 * 1000 * 1000 };
	NSTimeInterval start = [NSProcessInfo processInfo].systemUptime;
	NSUInteger logCursor = 0;

	// Method 1: plain spawn as the current user. MobileInstallationInstall is authorized
	// by the com.apple.private.MobileInstallation.allowed entitlement, not by uid, so the
	// child can install without root. Fall through to root methods on any failure.
	{
		if (outputHandler)
		{
			outputHandler(@"WFS_JB: build 1c857f8+; trying plain spawn\n");
		}
		pid_t pid = 0;
		int spawnResult = posix_spawn(&pid, argv[0], NULL, NULL, argv, NULL);
		if (spawnResult == 0)
		{
			if (methodUsedOut)
			{
				*methodUsedOut = @"plain";
			}
			int status = 0;
			NSInteger resultCode = -300;
			while (waitpid(pid, &status, WNOHANG) == 0)
			{
				if (cancelled && *cancelled)
				{
					kill(pid, SIGKILL);
					waitpid(pid, &status, 0);
					resultCode = -301;
					break;
				}
				if ([NSProcessInfo processInfo].systemUptime - start > timeout)
				{
					kill(pid, SIGKILL);
					waitpid(pid, &status, 0);
					resultCode = -300;
					break;
				}
				wfsDrainLogFile(logFilePath, &logCursor, outputHandler, progressHandler);
				nanosleep(&sleepTime, NULL);
			}
			wfsDrainLogFile(logFilePath, &logCursor, outputHandler, progressHandler);
			if (resultCode != -300 && resultCode != -301)
			{
				resultCode = WIFEXITED(status) ? WEXITSTATUS(status) : -300;
			}
			if (output)
			{
				*output = [[NSString alloc] initWithContentsOfFile:logFilePath encoding:NSUTF8StringEncoding error:nil];
			}
			if (resultCode == 0)
			{
				free(argv);
				return resultCode;
			}
			if (outputHandler)
			{
				outputHandler([NSString stringWithFormat:@"WFS_JB: plain spawn result %ld; falling through to root methods\n", (long)resultCode]);
			}
			[[NSFileManager defaultManager] removeItemAtPath:logFilePath error:nil];
			logCursor = 0;
			start = [NSProcessInfo processInfo].systemUptime;
		}
		else
		{
			if (outputHandler)
			{
				outputHandler([NSString stringWithFormat:@"WFS_JB: plain spawn failed (errno %d); falling through to root methods\n", spawnResult]);
			}
		}
	}

	void* jbHandle = wfsJailbreakdHandle();
	if (jbHandle)
	{
		WFSJBInitFn jbInit = (WFSJBInitFn)dlsym(jbHandle, "jb_init");
		WFSJBClientSpawnFn jbSpawn = (WFSJBClientSpawnFn)dlsym(jbHandle, "jb_client_spawn");
		WFSJBClientCloseFn jbClose = (WFSJBClientCloseFn)dlsym(jbHandle, "jb_client_close");
		if (jbInit && jbSpawn)
		{
			__block int spawnResult = -1;
			__block BOOL jbAttempted = NO;
			dispatch_semaphore_t spawnSemaphore = dispatch_semaphore_create(0);
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^
			{
				int initResult = jbInit();
				if (initResult == 0)
				{
					jbAttempted = YES;
					char** jbArgv = calloc(allArguments.count + 1, sizeof(char*));
					if (jbArgv)
					{
						for (NSUInteger i = 0; i < allArguments.count; i++)
						{
							jbArgv[i] = strdup(argv[i]);
						}
						__block pid_t spawnedPid = -1;
						spawnResult = jbSpawn(0, 0, (int)allArguments.count, jbArgv, ^(pid_t pid)
						{
							spawnedPid = pid;
						});
						(void)spawnedPid;
						for (NSUInteger i = 0; i < allArguments.count; i++)
						{
							free(jbArgv[i]);
						}
						free(jbArgv);
					}
				}
				else
				{
					spawnResult = initResult;
				}
				dispatch_semaphore_signal(spawnSemaphore);
			});
			NSTimeInterval jbStart = [NSProcessInfo processInfo].systemUptime;
			BOOL jbTimedOut = (dispatch_semaphore_wait(spawnSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC))) != 0);
			if (jbTimedOut)
			{
				if (outputHandler)
				{
					outputHandler(@"WFS_JB: jailbreakd call blocked beyond 30s; falling through to persona\n");
				}
				if (jbClose)
				{
					jbClose();
				}
			}
			else
			{
				if (outputHandler)
				{
					outputHandler([NSString stringWithFormat:@"WFS_JB: init+spawn returned %d after %.1fs\n", spawnResult, [NSProcessInfo processInfo].systemUptime - jbStart]);
				}
				if (spawnResult == 0)
				{
					if (methodUsedOut)
					{
						*methodUsedOut = @"jailbreakd";
					}
					NSInteger resultCode = -300;
					while (YES)
					{
						if (cancelled && *cancelled)
						{
							resultCode = -301;
							break;
						}
						if ([NSProcessInfo processInfo].systemUptime - start > timeout)
						{
							resultCode = -300;
							break;
						}
						wfsDrainLogFile(logFilePath, &logCursor, outputHandler, progressHandler);
						NSString* fullLog = [[NSString alloc] initWithContentsOfFile:logFilePath encoding:NSUTF8StringEncoding error:nil];
						if ([fullLog rangeOfString:@"WFS_RESULT: "].location != NSNotFound)
						{
							NSArray* lines = [fullLog componentsSeparatedByString:@"\n"];
							NSString* resultLine = nil;
							for (NSString* line in lines)
							{
								if ([line hasPrefix:@"WFS_RESULT: "])
								{
									resultLine = line;
								}
							}
							resultCode = resultLine ? [[resultLine substringFromIndex:@"WFS_RESULT: ".length] integerValue] : 1;
							break;
						}
						nanosleep(&sleepTime, NULL);
					}
					wfsDrainLogFile(logFilePath, &logCursor, outputHandler, progressHandler);
					if (output)
					{
						*output = [[NSString alloc] initWithContentsOfFile:logFilePath encoding:NSUTF8StringEncoding error:nil];
					}
					free(argv);
					return resultCode;
				}
				if (jbAttempted)
				{
					if (spawnErrnoOut)
					{
						*spawnErrnoOut = spawnResult;
					}
					if (methodUsedOut)
					{
						*methodUsedOut = @"jailbreakd(spawn-failed)";
					}
					free(argv);
					return -200;
				}
			}
		}
	}

	start = [NSProcessInfo processInfo].systemUptime;
	WFSJBPersonaFixFn personaFix = (WFSJBPersonaFixFn)dlsym(RTLD_DEFAULT, "jbclient_persona_fix");
	void* jbHandleForPersonaFix = wfsJailbreakdHandle();
	if (!personaFix && jbHandleForPersonaFix)
	{
		personaFix = (WFSJBPersonaFixFn)dlsym(jbHandleForPersonaFix, "jbclient_persona_fix");
	}
	if (personaFix)
	{
		if (outputHandler)
		{
			outputHandler(@"WFS_JB: jbclient_persona_fix available; trying persona+dopamine-fix\n");
		}
		posix_spawnattr_t attributes;
		posix_spawnattr_init(&attributes);
		posix_spawnattr_set_persona_np(&attributes, 99, WFS_PERSONA_FLAGS_OVERRIDE);
		posix_spawnattr_set_persona_uid_np(&attributes, 501);
		posix_spawnattr_set_persona_gid_np(&attributes, 501);
		posix_spawnattr_setflags(&attributes, POSIX_SPAWN_START_SUSPENDED);
		pid_t pid = 0;
		int spawnResult = posix_spawn(&pid, argv[0], NULL, &attributes, argv, NULL);
		posix_spawnattr_destroy(&attributes);
		if (spawnResult == 0)
		{
			int fixResult = personaFix(pid, 0, 0);
			kill(pid, SIGCONT);
			if (outputHandler)
			{
				outputHandler([NSString stringWithFormat:@"WFS_JB: persona fix returned %d\n", fixResult]);
			}
			if (methodUsedOut)
			{
				*methodUsedOut = @"persona+dopamine-fix";
			}
			int status = 0;
			NSInteger resultCode = -300;
			while (waitpid(pid, &status, WNOHANG) == 0)
			{
				if (cancelled && *cancelled)
				{
					kill(pid, SIGKILL);
					waitpid(pid, &status, 0);
					resultCode = -301;
					break;
				}
				if ([NSProcessInfo processInfo].systemUptime - start > timeout)
				{
					kill(pid, SIGKILL);
					waitpid(pid, &status, 0);
					resultCode = -300;
					break;
				}
				wfsDrainLogFile(logFilePath, &logCursor, outputHandler, progressHandler);
				nanosleep(&sleepTime, NULL);
			}
			wfsDrainLogFile(logFilePath, &logCursor, outputHandler, progressHandler);
			if (resultCode != -300 && resultCode != -301)
			{
				resultCode = WIFEXITED(status) ? WEXITSTATUS(status) : -300;
			}
			if (output)
			{
				*output = [[NSString alloc] initWithContentsOfFile:logFilePath encoding:NSUTF8StringEncoding error:nil];
			}
			free(argv);
			return resultCode;
		}
		if (outputHandler)
		{
			outputHandler([NSString stringWithFormat:@"WFS_JB: persona+dopamine-fix spawn failed (%d); falling through to plain persona\n", spawnResult]);
		}
	}
	else
	{
		if (outputHandler)
		{
			outputHandler(@"WFS_JB: jbclient_persona_fix unavailable; using plain persona\n");
		}
	}

	start = [NSProcessInfo processInfo].systemUptime;
	posix_spawnattr_t attributes;
	posix_spawnattr_init(&attributes);
	posix_spawnattr_set_persona_np(&attributes, 99, WFS_PERSONA_FLAGS_OVERRIDE);
	posix_spawnattr_set_persona_uid_np(&attributes, 0);
	posix_spawnattr_set_persona_gid_np(&attributes, 0);
	pid_t pid = 0;
	int spawnResult = posix_spawn(&pid, argv[0], NULL, &attributes, argv, NULL);
	posix_spawnattr_destroy(&attributes);
	if (spawnResult != 0)
	{
		free(argv);
		if (spawnErrnoOut)
		{
			*spawnErrnoOut = spawnResult;
		}
		if (methodUsedOut)
		{
			*methodUsedOut = @"persona";
		}
		return -200;
	}
	if (methodUsedOut)
	{
		*methodUsedOut = @"persona";
	}
	int status = 0;
	NSInteger resultCode = -300;
	while (waitpid(pid, &status, WNOHANG) == 0)
	{
		if (cancelled && *cancelled)
		{
			kill(pid, SIGKILL);
			waitpid(pid, &status, 0);
			resultCode = -301;
			break;
		}
		if ([NSProcessInfo processInfo].systemUptime - start > timeout)
		{
			kill(pid, SIGKILL);
			waitpid(pid, &status, 0);
			resultCode = -300;
			break;
		}
		wfsDrainLogFile(logFilePath, &logCursor, outputHandler, progressHandler);
		nanosleep(&sleepTime, NULL);
	}
	wfsDrainLogFile(logFilePath, &logCursor, outputHandler, progressHandler);
	if (resultCode != -300 && resultCode != -301)
	{
		resultCode = WIFEXITED(status) ? WEXITSTATUS(status) : -300;
	}
	if (output)
	{
		*output = [[NSString alloc] initWithContentsOfFile:logFilePath encoding:NSUTF8StringEncoding error:nil];
	}
	free(argv);
	return resultCode;
}

@interface LSApplicationWorkspace (WFSManualInstall)
- (void)_LSPrivateRebuildApplicationDatabasesForSystemApps:(_Bool)systemApps;
@end

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

@interface WFSRootViewController () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) UIAlertController* progressAlert;
@property (nonatomic, strong) UIAlertController* authProgressAlert;
@property (nonatomic, strong) UIProgressView* authProgressView;
@property (nonatomic, strong) UIProgressView* downloadProgressView;
@property (nonatomic, strong) NSURLSession* ipaDownloadSession;
@property (nonatomic, copy) NSString* pendingDownloadFilename;
	@property (nonatomic, assign) long long pendingDownloadAppId;
	@property (nonatomic, assign) long long pendingDownloadVersionId;
	@property (nonatomic, copy) NSDictionary* pendingDownloadMetadata;
	@property (nonatomic, copy) NSArray* pendingDownloadSinfs;
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

		PSSpecifier* appleIdGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		appleIdGroupSpecifier.name = @"Apple ID";
		[_specifiers addObject:appleIdGroupSpecifier];

		PSSpecifier* signInSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Sign in to Apple ID" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
		signInSpecifier.identifier = @"signIn";
		[signInSpecifier setProperty:@YES forKey:@"enabled"];
		signInSpecifier.buttonAction = @selector(signInToAppleID);
		[_specifiers addObject:signInSpecifier];

		PSSpecifier* appleIdDownloadSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Download with Apple ID" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
		appleIdDownloadSpecifier.identifier = @"appleIdDownload";
		[appleIdDownloadSpecifier setProperty:@YES forKey:@"enabled"];
		appleIdDownloadSpecifier.buttonAction = @selector(downloadWithAppleID);
		[_specifiers addObject:appleIdDownloadSpecifier];

		NSString* appleIdFooterText = @"Sign in with the Apple ID that owns the app licenses to fetch versions and download removed apps directly from Apple.";
		[appleIdGroupSpecifier setProperty:appleIdFooterText forKey:@"footerText"];

		PSSpecifier* downloadGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		downloadGroupSpecifier.name = @"Download";
		[_specifiers addObject:downloadGroupSpecifier];

		PSSpecifier* downloadSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Download" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
		downloadSpecifier.identifier = @"download";
		[downloadSpecifier setProperty:@YES forKey:@"enabled"];
		downloadSpecifier.buttonAction = @selector(downloadApp);
		[_specifiers addObject:downloadSpecifier];

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
	SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, "itunes.apple.com");
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
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
	NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		if (error)
		{
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] iTunes lookup network error: %@\n", [NSDate date], error.localizedDescription]];
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self showAlert:@"Error" message:error.localizedDescription];
			});
			return;
		}
		NSHTTPURLResponse* httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)response : nil;
		NSInteger statusCode = httpResponse ? httpResponse.statusCode : 0;
		NSError* jsonError = nil;
		NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
		if (jsonError || ![json isKindOfClass:[NSDictionary class]])
		{
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] iTunes lookup bad response for bundle %@: HTTP %ld, %lu bytes: %@\n", [NSDate date], bundleId, (long)statusCode, (unsigned long)data.length, jsonError ? jsonError.localizedDescription : @"not a dictionary"]];
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self showAlert:@"Error" message:[NSString stringWithFormat:@"App Store lookup failed (HTTP %ld, %lu bytes). You can try downloading via Apple ID instead.", (long)statusCode, (unsigned long)data.length]];
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
		indicator.tag = 4242;
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
			self.downloadProgressView = nil;
		}
	});
}

- (void)showInstallProgressWithMessage:(NSString*)message cancelHandler:(void (^)(void))cancelHandler
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.progressAlert)
		{
			self.progressAlert.title = @"Installing";
			self.progressAlert.message = message;
			return;
		}
		self.progressAlert = [UIAlertController alertControllerWithTitle:@"Installing" message:message preferredStyle:UIAlertControllerStyleAlert];
		UIActivityIndicatorView* indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
		indicator.translatesAutoresizingMaskIntoConstraints = NO;
		indicator.tag = 4242;
		[indicator startAnimating];
		[self.progressAlert.view addSubview:indicator];
		[NSLayoutConstraint activateConstraints:@[
			[indicator.centerXAnchor constraintEqualToAnchor:self.progressAlert.view.centerXAnchor],
			[indicator.bottomAnchor constraintEqualToAnchor:self.progressAlert.view.bottomAnchor constant:-20]
		]];
		if (cancelHandler)
		{
			[self.progressAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
			{
				cancelHandler();
			}]];
		}
		[self wfsPresentViewController:self.progressAlert];
	});
}

- (void)updateInstallProgressMessage:(NSString*)message
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.progressAlert)
		{
			self.progressAlert.message = message;
		}
	});
}

- (void)showDownloadProgressBarWithMessage:(NSString*)message
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.progressAlert)
		{
			self.progressAlert.title = @"Downloading";
			self.progressAlert.message = message;
			if (!self.downloadProgressView)
			{
				[self addDownloadProgressBarToAlert:self.progressAlert];
			}
			if (self.progressAlert.actions.count == 0 && self.ipaDownloadSession)
			{
				[self.progressAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
				{
					[self.ipaDownloadSession invalidateAndCancel];
					self.ipaDownloadSession = nil;
					self.pendingDownloadFilename = nil;
					self.progressAlert = nil;
					self.downloadProgressView = nil;
				}]];
			}
			return;
		}
		self.progressAlert = [UIAlertController alertControllerWithTitle:@"Downloading" message:message preferredStyle:UIAlertControllerStyleAlert];
		[self addDownloadProgressBarToAlert:self.progressAlert];
		if (self.ipaDownloadSession)
		{
			[self.progressAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
			{
				[self.ipaDownloadSession invalidateAndCancel];
				self.ipaDownloadSession = nil;
				self.pendingDownloadFilename = nil;
				self.progressAlert = nil;
				self.downloadProgressView = nil;
			}]];
		}
		[self wfsPresentViewController:self.progressAlert];
	});
}

- (void)addDownloadProgressBarToAlert:(UIAlertController*)alert
{
	[[alert.view viewWithTag:4242] removeFromSuperview];
	UIProgressView* progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
	progress.translatesAutoresizingMaskIntoConstraints = NO;
	progress.tintColor = [UIColor systemBlueColor];
	progress.progressTintColor = [UIColor systemBlueColor];
	progress.trackTintColor = [UIColor systemGray5Color];
	progress.progress = 0.0f;
	[alert.view addSubview:progress];
	[NSLayoutConstraint activateConstraints:@[
		[progress.leadingAnchor constraintEqualToAnchor:alert.view.leadingAnchor constant:16],
		[progress.trailingAnchor constraintEqualToAnchor:alert.view.trailingAnchor constant:-16],
		[progress.bottomAnchor constraintEqualToAnchor:alert.view.bottomAnchor constant:-55]
	]];
	self.downloadProgressView = progress;
}

- (void)updateDownloadProgressWithBytesWritten:(int64_t)bytesWritten total:(int64_t)total
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (!self.progressAlert)
		{
			return;
		}
		if (total <= 0)
		{
			self.progressAlert.message = [NSString stringWithFormat:@"Downloading .ipa…\n%@ so far", [self formattedByteCount:bytesWritten]];
			return;
		}
		float fraction = (float)bytesWritten / (float)total;
		self.progressAlert.message = [NSString stringWithFormat:@"Downloading .ipa…\n%@ of %@ (%d%%)", [self formattedByteCount:bytesWritten], [self formattedByteCount:total], (int)(fraction * 100.0f)];
		if (self.downloadProgressView)
		{
			self.downloadProgressView.progress = fraction;
		}
	});
}

- (NSString*)formattedByteCount:(int64_t)bytes
{
	if (bytes >= 1024LL * 1024LL * 1024LL)
	{
		return [NSString stringWithFormat:@"%.2f GB", (double)bytes / 1073741824.0];
	}
	if (bytes >= 1024LL * 1024LL)
	{
		return [NSString stringWithFormat:@"%.1f MB", (double)bytes / 1048576.0];
	}
	if (bytes >= 1024LL)
	{
		return [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
	}
	return [NSString stringWithFormat:@"%lld B", bytes];
}

- (void)showAppleIDAuthProgress
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.authProgressAlert)
		{
			return;
		}
		UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Signing in to Apple" message:@"Attempt 0 of 100…" preferredStyle:UIAlertControllerStyleAlert];
		UIProgressView* progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
		progress.translatesAutoresizingMaskIntoConstraints = NO;
		progress.tintColor = [UIColor systemBlueColor];
		progress.progressTintColor = [UIColor systemBlueColor];
		progress.trackTintColor = [UIColor systemGray5Color];
		[alert.view addSubview:progress];
		[NSLayoutConstraint activateConstraints:@[
			[progress.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
			[progress.bottomAnchor constraintEqualToAnchor:alert.view.bottomAnchor constant:-55],
			[progress.widthAnchor constraintEqualToAnchor:alert.view.widthAnchor multiplier:0.8]
		]];
		[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
		{
			[[WFSAppleIDDownloader sharedDownloader] cancelAuthentication];
		}]];
		self.authProgressAlert = alert;
		self.authProgressView = progress;
		[self wfsPresentViewController:alert];
	});
}

- (void)updateAppleIDAuthProgressAttempt:(NSUInteger)attempt total:(NSUInteger)total
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.authProgressAlert)
		{
			self.authProgressAlert.message = [NSString stringWithFormat:@"Attempt %lu of %lu…", (unsigned long)attempt, (unsigned long)total];
		}
		if (self.authProgressView)
		{
			self.authProgressView.progress = (float)attempt / (float)MAX(total, 1);
		}
	});
}

- (void)dismissAppleIDAuthProgress
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		if (self.authProgressAlert)
		{
			[self.authProgressAlert dismissViewControllerAnimated:YES completion:nil];
			self.authProgressAlert = nil;
			self.authProgressView = nil;
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
		NSHTTPURLResponse* httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)response : nil;
		NSInteger statusCode = httpResponse ? httpResponse.statusCode : 0;
		if (jsonError || ![json isKindOfClass:[NSDictionary class]])
		{
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] version server bad response for appId %lld: HTTP %ld, %lu bytes: %@\n", [NSDate date], appId, (long)statusCode, (unsigned long)data.length, jsonError ? jsonError.localizedDescription : @"not a dictionary"]];
			NSString* bodyPreview = @"";
			if (data.length)
			{
				NSString* bodyString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
				if (bodyString.length > 300)
				{
					bodyString = [bodyString substringToIndex:300];
				}
				bodyPreview = [NSString stringWithFormat:@"\n\nResponse: %@", bodyString];
			}
			dispatch_async(dispatch_get_main_queue(), ^
			{
				UIAlertController* jsonErrorAlert = [UIAlertController alertControllerWithTitle:@"Version Server Error" message:[NSString stringWithFormat:@"The version server returned an invalid response (HTTP %ld, %lu bytes).%@\n\nYou can try fetching the version list directly from Apple with your Apple ID.", (long)statusCode, (unsigned long)data.length, bodyPreview] preferredStyle:UIAlertControllerStyleAlert];
				UIAlertAction* appleIdAction = [UIAlertAction actionWithTitle:@"Try Apple ID" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
				{
					[self startAppleIDDownloadForAppId:appId];
				}];
				[jsonErrorAlert addAction:appleIdAction];
				UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
				[jsonErrorAlert addAction:cancelAction];
				[self wfsPresentViewController:jsonErrorAlert];
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

- (void)signInToAppleID
{
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	if (downloader.isAuthenticated)
	{
		[self showAlert:@"Already Signed In" message:[NSString stringWithFormat:@"You are signed in as %@.\n\nThis session is used to fetch versions and download removed apps directly from Apple.", downloader.authenticatedAppleId.length ? downloader.authenticatedAppleId : @"your Apple ID"]];
		return;
	}
	[self promptAppleIDCredentialsWithCompletion:^(BOOL success)
	{
		if (success)
		{
			[self showAlert:@"Signed In" message:@"You are signed in to Apple.\n\nYou can now use Download with Apple ID for removed apps, and your purchase history is synced into the Purchased tab."];
		}
	}];
}

- (void)downloadWithAppleID
{
	if (![self isNetworkReachable])
	{
		[self showAlert:@"No Internet" message:@"Please check your internet connection and try again."];
		return;
	}
	UIAlertController* linkAlert = [UIAlertController alertControllerWithTitle:@"App Link" message:@"Enter the App Store link or App ID of the app you want to download with your Apple ID." preferredStyle:UIAlertControllerStyleAlert];
	[linkAlert addTextFieldWithConfigurationHandler:^(UITextField* textField)
	{
		textField.placeholder = @"https://apps.apple.com/app/idXXXXXXXXX";
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
	}];
	UIAlertAction* downloadAction = [UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		NSString* input = [linkAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (input.length == 0)
		{
			[self showAlert:@"Error" message:@"Please enter an App Store link or App ID."];
			return;
		}
		NSCharacterSet* digits = [NSCharacterSet decimalDigitCharacterSet];
		long long appId = 0;
		if ([input rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound)
		{
			appId = [input longLongValue];
		}
		else
		{
			appId = [self parseAppIdFromLink:input];
		}
		if (appId <= 0)
		{
			[self showAlert:@"Error" message:@"Invalid link"];
			return;
		}
		[self startAppleIDDownloadForAppId:appId];
	}];
	[linkAlert addAction:downloadAction];
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
	WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
	downloader.authProgressHandler = ^(NSUInteger attempt, NSUInteger totalAttempts)
	{
		[self updateAppleIDAuthProgressAttempt:attempt total:totalAttempts];
	};
	[self showAppleIDAuthProgress];
	[downloader authenticateWithAppleId:email password:password completion:^(NSError* error)
	{
		[downloader setAuthProgressHandler:nil];
		[self dismissAppleIDAuthProgress];
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
		if (error.code == WFSAppleIDDownloaderErrorCancelled)
		{
			completion(NO);
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
		UIAlertController* codeAlert = [UIAlertController alertControllerWithTitle:@"Two-Factor Authentication" message:@"Enter the 6-digit verification code for this Apple ID.\n\nNo code arrived? Generate one from any device signed in to this Apple ID: Settings > [your name] > Sign-in & Security > Two-Factor Authentication > Get Verification Code. Codes expire quickly, so enter it right away." preferredStyle:UIAlertControllerStyleAlert];
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
			WFSAppleIDDownloader* downloader = [WFSAppleIDDownloader sharedDownloader];
			downloader.authProgressHandler = ^(NSUInteger attempt, NSUInteger totalAttempts)
			{
				[self updateAppleIDAuthProgressAttempt:attempt total:totalAttempts];
			};
			[self showAppleIDAuthProgress];
			[downloader retryWithTwoFactorCode:code completion:^(NSError* error)
			{
				[downloader setAuthProgressHandler:nil];
				[self dismissAppleIDAuthProgress];
				if (error)
				{
					if (error.code == WFSAppleIDDownloaderErrorCancelled)
					{
						completion(NO);
						return;
					}
					if (error.code == WFSAppleIDDownloaderError2FARequired)
					{
						[self showAlert:@"Sign In Failed" message:@"The verification code was rejected or expired. Make sure the code is fresh and your Apple ID password is correct, then try signing in again."];
						completion(NO);
						return;
					}
					if (error.code == WFSAppleIDDownloaderErrorPasswordTokenExpired)
					{
						[self showAlert:@"Sign In Failed" message:@"Your Apple ID session has expired. Please sign in again."];
						completion(NO);
						return;
					}
					[self showAlert:@"Sign In Failed" message:error.localizedDescription];
					completion(NO);
					return;
				}
				completion(YES);
			}];
		}];
		[codeAlert addAction:verifyAction];
		UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
		{
			[[WFSAppleIDDownloader sharedDownloader] cancelAuthentication];
			completion(NO);
		}];
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
			[self downloadIPAForAppId:appId versionId:0];
			return;
		}
		[self presentVersionPickerWithVersions:list appId:appId completion:^(NSDictionary* selectedVersion)
		{
			long long versionId = [selectedVersion[@"external_identifier"] longLongValue];
			[self downloadIPAForAppId:appId versionId:versionId];
		}];
	}];
}

- (void)downloadIPAForAppId:(long long)appId versionId:(long long)versionId
{
	if (![self isNetworkReachable])
	{
		[self showAlert:@"No Internet" message:@"Please check your internet connection and try again."];
		return;
	}
	if (self.ipaDownloadSession)
	{
		[self showAlert:@"Already Downloading" message:@"A download is already in progress. Wait for it to finish before starting another."];
		return;
	}
	self.pendingDownloadFilename = [NSString stringWithFormat:@"app-%lld-v%lld.ipa", appId, versionId];
	self.pendingDownloadAppId = appId;
	self.pendingDownloadVersionId = versionId;
	[self showDownloadProgressWithMessage:@"Getting download link from Apple…"];
	[self appendToInstallLog:[NSString stringWithFormat:@"[%@] download start: adamId=%lld versionId=%lld\n", [NSDate date], appId, versionId]];
	[[WFSAppleIDDownloader sharedDownloader] getDownloadInfoForAdamId:appId versionId:versionId autoPurchase:YES completion:^(NSURL* ipaURL, NSDictionary* metadata, NSArray* sinfs, NSError* error)
	{
		if (error)
		{
			[self dismissDownloadProgress];
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] download link failed: %@\n", [NSDate date], error.localizedDescription]];
			if (error.code == WFSAppleIDDownloaderErrorLicenseNotFound)
			{
				[self showAlert:@"Not Purchased" message:[NSString stringWithFormat:@"%@\n\nApple only allows downloading apps that are free or that have been purchased with this Apple ID.", error.localizedDescription]];
				return;
			}
			[self showAlert:@"Apple ID Error" message:error.localizedDescription];
			return;
		}
		self.pendingDownloadMetadata = metadata;
		self.pendingDownloadSinfs = sinfs;
		[self appendToInstallLog:[NSString stringWithFormat:@"[%@] download link obtained (sinfs: %lu)\n", [NSDate date], (unsigned long)sinfs.count]];
		NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:ipaURL];
		[request setValue:@"Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6" forHTTPHeaderField:@"User-Agent"];
		[self appendToInstallLog:[NSString stringWithFormat:@"[%@] download link obtained: %@\n", [NSDate date], ipaURL.absoluteString]];
		[self showDownloadProgressBarWithMessage:@"Downloading .ipa…"];
		NSURLSessionConfiguration* configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
		configuration.timeoutIntervalForResource = 1800;
		self.ipaDownloadSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
		NSURLSessionDownloadTask* task = [self.ipaDownloadSession downloadTaskWithRequest:request];
		[task resume];
	}];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession*)session downloadTask:(NSURLSessionDownloadTask*)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
	[self updateDownloadProgressWithBytesWritten:totalBytesWritten total:totalBytesExpectedToWrite];
}

- (void)URLSession:(NSURLSession*)session downloadTask:(NSURLSessionDownloadTask*)downloadTask didFinishDownloadingToURL:(NSURL*)location
{
	if (!location)
	{
		return;
	}
	NSHTTPURLResponse* http = (NSHTTPURLResponse*)downloadTask.response;
	NSInteger statusCode = [http isKindOfClass:[NSHTTPURLResponse class]] ? http.statusCode : 0;
	NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:nil];
	unsigned long long fileSize = attributes ? [attributes[NSFileSize] unsignedLongLongValue] : 0;
	NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:location.path];
	NSData* prefix = [handle readDataOfLength:4];
	[handle closeFile];
	BOOL validZip = prefix.length == 4 && prefix.bytes && ((const uint8_t*)prefix.bytes)[0] == 0x50 && ((const uint8_t*)prefix.bytes)[1] == 0x4B && ((const uint8_t*)prefix.bytes)[2] == 0x03 && ((const uint8_t*)prefix.bytes)[3] == 0x04;
	if (statusCode < 200 || statusCode >= 300 || fileSize == 0 || !validZip)
	{
		[self appendToInstallLog:[NSString stringWithFormat:@"[%@] download rejected: HTTP %ld, %llu bytes, zip=%d\n", [NSDate date], (long)statusCode, fileSize, validZip]];
		[[NSFileManager defaultManager] removeItemAtURL:location error:nil];
		dispatch_async(dispatch_get_main_queue(), ^
		{
			[self dismissDownloadProgress];
			[self showAlert:@"Download Failed" message:[NSString stringWithFormat:@"Apple did not return a valid .ipa file (HTTP %ld, %llu bytes). This can happen when the download link has expired — try again.", (long)statusCode, fileSize]];
		});
		return;
	}
	NSString* destination = [self destinationPathForDownloadTask:downloadTask];
	[self appendToInstallLog:[NSString stringWithFormat:@"[%@] download complete: %llu bytes, HTTP %ld -> %@\n", [NSDate date], fileSize, (long)statusCode, destination]];
	NSFileManager* fileManager = [NSFileManager defaultManager];
	[fileManager removeItemAtPath:destination error:nil];
	NSError* moveError = nil;
	[fileManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:destination] error:&moveError];
	dispatch_async(dispatch_get_main_queue(), ^
	{
		[self dismissDownloadProgress];
		if (moveError)
		{
			[self showAlert:@"Save Failed" message:moveError.localizedDescription];
			return;
		}
		NSError* patchError = nil;
		BOOL patched = WFSPatchIPAWithSinfData(destination, self.pendingDownloadMetadata, self.pendingDownloadSinfs, [[WFSAppleIDDownloader sharedDownloader] authenticatedAppleId], &patchError);
		if (patched)
		{
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] ipa patched with SINF + iTunesMetadata\n", [NSDate date]]];
		}
		else
		{
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] ipa patch skipped: %@\n", [NSDate date], patchError.localizedDescription]];
		}
		[self verifyAndInstallIPAAtPath:destination];
	});
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error
{
	if (error)
	{
		if (error.code != NSURLErrorCancelled)
		{
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] download task error: %@\n", [NSDate date], error.localizedDescription]];
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self dismissDownloadProgress];
				[self showAlert:@"Download Failed" message:error.localizedDescription ?: @"Unknown error."];
			});
		}
	}
	[session finishTasksAndInvalidate];
	if (self.ipaDownloadSession == session)
	{
		self.ipaDownloadSession = nil;
		self.pendingDownloadFilename = nil;
		self.pendingDownloadMetadata = nil;
		self.pendingDownloadSinfs = nil;
	}
}

- (NSString*)destinationPathForDownloadTask:(NSURLSessionDownloadTask*)downloadTask
{
	NSString* filename = self.pendingDownloadFilename;
	if (!filename.length)
	{
		NSURL* ipaURL = downloadTask.response.URL ?: downloadTask.originalRequest.URL;
		filename = [ipaURL.lastPathComponent length] > 0 ? ipaURL.lastPathComponent : @"app.ipa";
	}
	if (![filename hasSuffix:@".ipa"])
	{
		filename = [filename stringByAppendingString:@".ipa"];
	}
	NSString* directory = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"Downgrades"];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
	return [directory stringByAppendingPathComponent:filename];
}

- (NSDictionary*)verifyIPAAtPath:(NSString*)path
{
	NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
	if (!attributes)
	{
		return @{@"error": @"file not found"};
	}
	unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
	if (fileSize < 22)
	{
		return @{@"error": @"file is too small to be an .ipa"};
	}
	NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:path];
	if (!handle)
	{
		return @{@"error": @"cannot open the file"};
	}
	unsigned long long searchFrom = fileSize > 70000 ? fileSize - 70000 : 0;
	[handle seekToFileOffset:searchFrom];
	NSData* tail = [handle readDataToEndOfFile];
	const uint8_t* tailBytes = tail.bytes;
	NSInteger eocd = -1;
	for (NSInteger i = (NSInteger)tail.length - 22; i >= 0; i--)
	{
		if (tailBytes[i] == 0x50 && tailBytes[i + 1] == 0x4B && tailBytes[i + 2] == 0x05 && tailBytes[i + 3] == 0x06)
		{
			NSInteger candidate = i;
			if (candidate + 22 > tail.length)
			{
				continue;
			}
			uint16_t entryCount = tailBytes[candidate + 10] | (tailBytes[candidate + 11] << 8);
			uint32_t cdSize = (uint32_t)(tailBytes[candidate + 12] | (tailBytes[candidate + 13] << 8) | (tailBytes[candidate + 14] << 16) | (tailBytes[candidate + 15] << 24));
			uint32_t cdOffset = (uint32_t)(tailBytes[candidate + 16] | (tailBytes[candidate + 17] << 8) | (tailBytes[candidate + 18] << 16) | (tailBytes[candidate + 19] << 24));
			if (cdSize > 0 && (uint64_t)cdOffset + cdSize <= fileSize && entryCount > 0 && entryCount <= cdSize / 46 + 1)
			{
				eocd = candidate;
				break;
			}
		}
	}
	if (eocd < 0)
	{
		[handle closeFile];
		return @{@"error": @"not a valid zip archive"};
	}
	uint16_t entryCount = tailBytes[eocd + 10] | (tailBytes[eocd + 11] << 8);
	uint32_t cdSize = (uint32_t)(tailBytes[eocd + 12] | (tailBytes[eocd + 13] << 8) | (tailBytes[eocd + 14] << 16) | (tailBytes[eocd + 15] << 24));
	uint32_t cdOffset = (uint32_t)(tailBytes[eocd + 16] | (tailBytes[eocd + 17] << 8) | (tailBytes[eocd + 18] << 16) | (tailBytes[eocd + 19] << 24));
	[handle seekToFileOffset:cdOffset];
	NSMutableData* centralData = [NSMutableData data];
	while (centralData.length < cdSize)
	{
		NSData* chunk = [handle readDataOfLength:(NSUInteger)(cdSize - (uint32_t)centralData.length)];
		if (chunk.length == 0)
		{
			break;
		}
		[centralData appendData:chunk];
	}
	const uint8_t* cd = centralData.bytes;
	NSInteger centralLength = centralData.length;
	NSMutableDictionary* entries = [NSMutableDictionary dictionary];
	NSString* appDirectoryName = nil;
	NSInteger pos = 0;
	for (uint16_t i = 0; i < entryCount && pos + 46 <= centralLength; i++)
	{
		if (cd[pos] != 0x50 || cd[pos + 1] != 0x4B || cd[pos + 2] != 0x01 || cd[pos + 3] != 0x02)
		{
			break;
		}
		uint16_t method = cd[pos + 10] | (cd[pos + 11] << 8);
		uint32_t compSize = (uint32_t)(cd[pos + 20] | (cd[pos + 21] << 8) | (cd[pos + 22] << 16) | (cd[pos + 23] << 24));
		uint16_t nameLength = cd[pos + 28] | (cd[pos + 29] << 8);
		uint16_t extraLength = cd[pos + 30] | (cd[pos + 31] << 8);
		uint16_t commentLength = cd[pos + 32] | (cd[pos + 33] << 8);
		uint32_t localOffset = (uint32_t)(cd[pos + 42] | (cd[pos + 43] << 8) | (cd[pos + 44] << 16) | (cd[pos + 45] << 24));
		NSString* name = [[NSString alloc] initWithBytes:(cd + pos + 46) length:nameLength encoding:NSUTF8StringEncoding];
		pos += 46 + nameLength + extraLength + commentLength;
		if (name.length == 0 || [name hasPrefix:@"__MACOSX"])
		{
			continue;
		}
		if (!appDirectoryName && [name hasPrefix:@"Payload/"] && [name hasSuffix:@"/"] && [name rangeOfString:@"/" options:0 range:NSMakeRange(0, name.length - 1)].location == 7)
		{
			appDirectoryName = name;
		}
		entries[name] = @{ @"method": @(method), @"compSize": @(compSize), @"localOffset": @(localOffset) };
	}
	if (!appDirectoryName)
	{
		[handle closeFile];
		return @{@"error": @"no Payload/*.app found inside the .ipa"};
	}
	NSString* infoPlistName = [appDirectoryName stringByAppendingString:@"Info.plist"];
	NSDictionary* infoEntry = entries[infoPlistName];
	if (!infoEntry)
	{
		[handle closeFile];
		return @{@"error": @"missing Info.plist in the app bundle"};
	}
	NSData* infoData = [self zipEntryDataFromHandle:handle entry:infoEntry];
	if (!infoData)
	{
		[handle closeFile];
		return @{@"error": @"could not read Info.plist"};
	}
	NSError* plistError = nil;
	NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
	NSDictionary* info = [NSPropertyListSerialization propertyListWithData:infoData options:0 format:&format error:&plistError];
	if (![info isKindOfClass:[NSDictionary class]])
	{
		[handle closeFile];
		return @{@"error": @"Info.plist is not a valid property list"};
	}
	NSString* executableName = info[@"CFBundleExecutable"];
	if (![executableName isKindOfClass:[NSString class]] || executableName.length == 0)
	{
		[handle closeFile];
		return @{@"error": @"Info.plist has no CFBundleExecutable"};
	}
	NSDictionary* execEntry = entries[[appDirectoryName stringByAppendingString:executableName]];
	if (!execEntry)
	{
		[handle closeFile];
		return @{@"error": [NSString stringWithFormat:@"main executable (%@) is missing from the .ipa", executableName]};
	}
	NSData* execHeader = [self zipEntryPrefixDataFromHandle:handle entry:execEntry length:4096];
	[handle closeFile];
	if (!execHeader || execHeader.length < 4)
	{
		return @{@"error": @"could not read the main executable header"};
	}
	NSUInteger readLength = 4096;
	NSNumber* cryptid = nil;
	for (int attempt = 0; attempt < 4 && !cryptid; attempt++)
	{
		cryptid = [self cryptidFromMachOHeader:execHeader];
		WFSMachOType machOType = [self machOTypeFromHeader:execHeader];
		if (!cryptid && (machOType == WFSMachOTypeFat || machOType == WFSMachOTypeFat64))
		{
			readLength *= 16;
			NSFileHandle* reopenHandle = [NSFileHandle fileHandleForReadingAtPath:path];
			if (!reopenHandle)
			{
				break;
			}
			execHeader = [self zipEntryPrefixDataFromHandle:reopenHandle entry:execEntry length:readLength];
			[reopenHandle closeFile];
			if (!execHeader || execHeader.length < 4)
			{
				break;
			}
		}
	}
	if (!cryptid)
	{
		[self appendToInstallLog:[NSString stringWithFormat:@"[%@] unrecognized main executable format in %@; proceeding with the install anyway.\n---\n", [NSDate date], path]];
		return nil;
	}
	return cryptid.boolValue ? @{@"encrypted": @YES} : nil;
}

typedef NS_ENUM(NSInteger, WFSMachOType)
{
	WFSMachOTypeUnknown = 0,
	WFSMachOTypeMachO32,
	WFSMachOTypeMachO64,
	WFSMachOTypeFat,
	WFSMachOTypeFat64
};

static uint32_t wfsReadU32(const uint8_t* bytes, BOOL bigEndian)
{
	if (bigEndian)
	{
		return (uint32_t)(((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3]);
	}
	return (uint32_t)((uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24));
}

static uint64_t wfsReadU64(const uint8_t* bytes, BOOL bigEndian)
{
	if (bigEndian)
	{
		return ((uint64_t)wfsReadU32(bytes, YES) << 32) | (uint64_t)wfsReadU32(bytes + 4, YES);
	}
	return (uint64_t)wfsReadU32(bytes, NO) | ((uint64_t)wfsReadU32(bytes + 4, NO) << 32);
}

- (WFSMachOType)machOTypeFromHeader:(NSData*)header
{
	if (header.length < 4)
	{
		return WFSMachOTypeUnknown;
	}
	const uint8_t* b = header.bytes;
	if ((b[0] == 0xCF && b[1] == 0xFA && b[2] == 0xED && b[3] == 0xFE) || (b[0] == 0xFE && b[1] == 0xED && b[2] == 0xFA && b[3] == 0xCF))
	{
		return WFSMachOTypeMachO64;
	}
	if ((b[0] == 0xCE && b[1] == 0xFA && b[2] == 0xED && b[3] == 0xFE) || (b[0] == 0xFE && b[1] == 0xED && b[2] == 0xFA && b[3] == 0xCE))
	{
		return WFSMachOTypeMachO32;
	}
	if (b[0] == 0xCA && b[1] == 0xFE && b[2] == 0xBA && b[3] == 0xBE)
	{
		return WFSMachOTypeFat;
	}
	if (b[0] == 0xCA && b[1] == 0xFE && b[2] == 0xBA && b[3] == 0xBF)
	{
		return WFSMachOTypeFat64;
	}
	if (b[0] == 0xBE && b[1] == 0xBA && b[2] == 0xFE && b[3] == 0xCA)
	{
		return WFSMachOTypeFat;
	}
	return WFSMachOTypeUnknown;
}

- (NSNumber*)cryptidFromMachOHeader:(NSData*)header
{
	if (header.length < 4)
	{
		return nil;
	}
	WFSMachOType type = [self machOTypeFromHeader:header];
	const uint8_t* mh = header.bytes;
	if (type == WFSMachOTypeMachO64)
	{
		BOOL bigEndian = mh[0] == 0xFE;
		if (header.length < 32)
		{
			return nil;
		}
		uint32_t ncmds = wfsReadU32(mh + 16, bigEndian);
		NSUInteger off = 32;
		for (uint32_t i = 0; i < ncmds && off + 8 <= header.length; i++)
		{
			uint32_t cmd = wfsReadU32(mh + off, bigEndian);
			uint32_t cmdSize = wfsReadU32(mh + off + 4, bigEndian);
			if (cmd == 0x2C && off + 20 <= header.length)
			{
				return @(wfsReadU32(mh + off + 16, bigEndian) != 0);
			}
			if (cmdSize == 0)
			{
				break;
			}
			off += cmdSize;
		}
		return @NO;
	}
	if (type == WFSMachOTypeMachO32)
	{
		BOOL bigEndian = mh[0] == 0xFE;
		if (header.length < 28)
		{
			return nil;
		}
		uint32_t ncmds = wfsReadU32(mh + 16, bigEndian);
		NSUInteger off = 28;
		for (uint32_t i = 0; i < ncmds && off + 8 <= header.length; i++)
		{
			uint32_t cmd = wfsReadU32(mh + off, bigEndian);
			uint32_t cmdSize = wfsReadU32(mh + off + 4, bigEndian);
			if (cmd == 0x21 && off + 12 <= header.length)
			{
				return @(wfsReadU32(mh + off + 8, bigEndian) != 0);
			}
			if (cmdSize == 0)
			{
				break;
			}
			off += cmdSize;
		}
		return @NO;
	}
	if (type == WFSMachOTypeFat || type == WFSMachOTypeFat64)
	{
		BOOL bigEndian = mh[0] != 0xBE;
		if (header.length < 8)
		{
			return nil;
		}
		uint32_t nfat = wfsReadU32(mh + 4, bigEndian);
		if (nfat == 0 || nfat > 64)
		{
			return nil;
		}
		NSUInteger entrySize = type == WFSMachOTypeFat64 ? 32 : 20;
		NSUInteger off = 8;
		for (uint32_t i = 0; i < nfat; i++)
		{
			if (off + entrySize > header.length)
			{
				return nil;
			}
			uint32_t cpuType = wfsReadU32(mh + off, bigEndian);
			uint64_t fileOff = type == WFSMachOTypeFat64 ? wfsReadU64(mh + off + 8, bigEndian) : wfsReadU32(mh + off + 8, bigEndian);
			if ((cpuType & 0x00FFFFFF) == 12)
			{
				if (fileOff == 0 || fileOff >= header.length)
				{
					return nil;
				}
				return [self cryptidFromMachOHeader:[header subdataWithRange:NSMakeRange((NSUInteger)fileOff, header.length - (NSUInteger)fileOff)]];
			}
			off += entrySize;
		}
		return nil;
	}
	return nil;
}

- (NSData*)zipEntryDataFromHandle:(NSFileHandle*)handle entry:(NSDictionary*)entry
{
	uint32_t localOffset = [entry[@"localOffset"] unsignedIntValue];
	[handle seekToFileOffset:localOffset];
	NSData* localHeader = [handle readDataOfLength:30];
	if (localHeader.length < 30)
	{
		return nil;
	}
	const uint8_t* lh = localHeader.bytes;
	uint16_t localNameLength = lh[26] | (lh[27] << 8);
	uint16_t localExtraLength = lh[28] | (lh[29] << 8);
	[handle seekToFileOffset:localOffset + 30 + localNameLength + localExtraLength];
	uint32_t compSize = [entry[@"compSize"] unsignedIntValue];
	NSData* compressed = [handle readDataOfLength:compSize];
	if (compressed.length != compSize)
	{
		return nil;
	}
	if ([entry[@"method"] unsignedShortValue] == 0)
	{
		return compressed;
	}
	return [self zipInflateData:compressed];
}

- (NSData*)zipEntryPrefixDataFromHandle:(NSFileHandle*)handle entry:(NSDictionary*)entry length:(NSUInteger)length
{
	uint32_t localOffset = [entry[@"localOffset"] unsignedIntValue];
	[handle seekToFileOffset:localOffset];
	NSData* localHeader = [handle readDataOfLength:30];
	if (localHeader.length < 30)
	{
		return nil;
	}
	const uint8_t* lh = localHeader.bytes;
	uint16_t localNameLength = lh[26] | (lh[27] << 8);
	uint16_t localExtraLength = lh[28] | (lh[29] << 8);
	[handle seekToFileOffset:localOffset + 30 + localNameLength + localExtraLength];
	uint32_t compSize = [entry[@"compSize"] unsignedIntValue];
	if ([entry[@"method"] unsignedShortValue] == 0)
	{
		return [handle readDataOfLength:(NSUInteger)MIN(compSize, (uint32_t)length)];
	}
	NSMutableData* inflated = [NSMutableData data];
	z_stream stream;
	memset(&stream, 0, sizeof(stream));
	if (inflateInit2(&stream, -MAX_WBITS) != Z_OK)
	{
		return nil;
	}
	uint8_t inBuffer[65536];
	uint8_t outBuffer[65536];
	uint32_t remaining = compSize;
	int ret = Z_OK;
	BOOL done = NO;
	while (remaining > 0 && !done)
	{
		NSData* chunk = [handle readDataOfLength:(NSUInteger)MIN(remaining, (uint32_t)sizeof(inBuffer))];
		if (chunk.length == 0)
		{
			break;
		}
		remaining -= (uint32_t)chunk.length;
		stream.next_in = (Bytef*)chunk.bytes;
		stream.avail_in = (uInt)chunk.length;
		do
		{
			stream.next_out = outBuffer;
			stream.avail_out = sizeof(outBuffer);
			ret = inflate(&stream, Z_NO_FLUSH);
			if (ret != Z_OK && ret != Z_STREAM_END)
			{
				done = YES;
				break;
			}
			[inflated appendBytes:outBuffer length:sizeof(outBuffer) - stream.avail_out];
			if (inflated.length >= length)
			{
				done = YES;
				break;
			}
		} while (stream.avail_out == 0);
	}
	inflateEnd(&stream);
	return inflated.length > 0 ? [inflated subdataWithRange:NSMakeRange(0, MIN(inflated.length, length))] : nil;
}

- (NSData*)zipInflateData:(NSData*)compressed
{
	NSMutableData* result = [NSMutableData data];
	z_stream stream;
	memset(&stream, 0, sizeof(stream));
	if (inflateInit2(&stream, -MAX_WBITS) != Z_OK)
	{
		return nil;
	}
	stream.next_in = (Bytef*)compressed.bytes;
	stream.avail_in = (uInt)compressed.length;
	uint8_t outBuffer[65536];
	int ret = Z_OK;
	do
	{
		stream.next_out = outBuffer;
		stream.avail_out = sizeof(outBuffer);
		ret = inflate(&stream, Z_NO_FLUSH);
		if (ret != Z_OK && ret != Z_STREAM_END)
		{
			break;
		}
		[result appendBytes:outBuffer length:sizeof(outBuffer) - stream.avail_out];
	} while (stream.avail_out == 0);
	inflateEnd(&stream);
	return ret == Z_STREAM_END ? result : nil;
}

- (void)verifyAndInstallIPAAtPath:(NSString*)path
{
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^
	{
		NSDictionary* verification = [self verifyIPAAtPath:path];
		if (verification[@"error"])
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self showAlert:@"Invalid .ipa" message:[NSString stringWithFormat:@"The downloaded file is not a valid .ipa:\n%@\n\nThe file was saved to:\n%@\n\nInstall it with TrollStore or Filza to see the original error.", verification[@"error"], path]];
			});
			return;
		}
		if (verification[@"encrypted"])
		{
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] %@ is FairPlay-encrypted; install requires on-device App Store account to match the download account.\n---\n", [NSDate date], path]];
			[self promptInstallMethodForPath:path];
			return;
		}
		[self installIPAAutomaticallyAtPath:path encrypted:verification[@"encrypted"] != nil];
	});
}

- (void)promptInstallMethodForPath:(NSString*)path
{
	long long appId = self.pendingDownloadAppId;
	long long versionId = self.pendingDownloadVersionId;
	dispatch_async(dispatch_get_main_queue(), ^
	{
		UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Install" message:@"Choose how to install this encrypted app.\n\nInstall via Apple: Apple's own installer downloads and installs the app for the on-device App Store account — no root needed. Works only while Apple still serves this app.\n\nInstall via system installer: installs this exact .ipa file through the system installer (requires root/jailbreak). Works even for delisted apps." preferredStyle:UIAlertControllerStyleAlert];
		UIAlertAction* appleAction = [UIAlertAction actionWithTitle:@"Install via Apple (no root)" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			if (appId > 0)
			{
				[self downloadAppWithAppId:appId versionId:versionId];
			}
			else
			{
				[self installIPAAutomaticallyAtPath:path encrypted:YES];
			}
		}];
		[alert addAction:appleAction];
		UIAlertAction* systemAction = [UIAlertAction actionWithTitle:@"Install via system installer (root)" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			[self installIPAAutomaticallyAtPath:path encrypted:YES];
		}];
		[alert addAction:systemAction];
		UIAlertAction* saveAction = [UIAlertAction actionWithTitle:@"Just Save" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
		{
			[self showAlert:@"Saved" message:[NSString stringWithFormat:@"The .ipa is saved to:\n%@\n\nInstall it with TrollStore or Filza.", path]];
		}];
		[alert addAction:saveAction];
		[self wfsPresentViewController:alert];
	});
}

- (void)installIPAAutomaticallyAtPath:(NSString*)path encrypted:(BOOL)encrypted
{
	__block BOOL cancelled = NO;
	__block BOOL finished = NO;
	[self showInstallProgressWithMessage:@"Installing via system installer…" cancelHandler:^
	{
		cancelled = YES;
	}];
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^
	{
		__strong typeof(self) self = weakSelf;
		if (!self)
		{
			return;
		}
		NSString* executablePath = [NSBundle mainBundle].executablePath;
		NSString* childOutput = nil;
		int spawnErrno = 0;
		NSString* methodUsed = nil;
		NSString* logFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wfs-install-child.log"];
		[[NSFileManager defaultManager] removeItemAtPath:logFilePath error:nil];
		NSNumber* personaEntitlement = wfsEffectiveEntitlement(@"com.apple.private.persona-mgmt");
		NSNumber* noSandboxEntitlement = wfsEffectiveEntitlement(@"com.apple.private.security.no-sandbox");
		NSNumber* platformEntitlement = wfsEffectiveEntitlement(@"platform-application");
		[self appendToInstallLog:[NSString stringWithFormat:@"[%@] effective entitlements: persona-mgmt=%@ no-sandbox=%@ platform-application=%@ libjailbreak=%d\n", [NSDate date], personaEntitlement ?: @"(unavailable)", noSandboxEntitlement ?: @"(unavailable)", platformEntitlement ?: @"(unavailable)", wfsJailbreakdHandle() != NULL]];
		NSInteger exitCode = WFSSpawnRootWithTimeout(@[ executablePath, @"--wfs-install", path ], logFilePath, 240.0, &cancelled, &childOutput, &spawnErrno, &methodUsed, ^(NSString* message)
		{
			[self updateInstallProgressMessage:message];
		}, ^(NSString* chunk)
		{
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] child: %@", [NSDate date], chunk]];
		});
		[self appendToInstallLog:[NSString stringWithFormat:@"[%@] install of %@ -> exit %ld (spawn errno %d, encrypted %d, method %@)\n%@\n---\n", [NSDate date], path, (long)exitCode, spawnErrno, encrypted, methodUsed ?: @"?", childOutput ?: @"(no output)"]];
		if (cancelled)
		{
			[self finishInstallWithMessage:[NSString stringWithFormat:@"Install cancelled. The .ipa is saved to:\n%@", path] title:@"Cancelled" path:path finished:&finished];
			return;
		}
		if (exitCode == -300)
		{
			NSString* trimmedOutput = childOutput.length > 600 ? [childOutput substringFromIndex:childOutput.length - 600] : childOutput;
			[self finishInstallWithMessage:[NSString stringWithFormat:@"The system installer did not finish in time.\n\nThis usually means the device is not signed into the App Store with the same Apple ID that downloaded the app, so the DRM check stalls.\n\nOpen Settings, tap your name at the top, then Media & Purchases, and sign in with the download account. Then try again.\n\nChild output:\n%@\n\nThe .ipa is saved to:\n%@", trimmedOutput ?: @"(no output)", path] title:@"Install Taking Too Long" path:path finished:&finished];
			return;
		}
		if (exitCode == -200 || exitCode == -400)
		{
			NSString* errnoText = [NSString stringWithFormat:@"error %d (%s)", spawnErrno, strerror(spawnErrno)];
			NSString* methodText = methodUsed ?: @"?";
			NSString* entitlementsText = [NSString stringWithFormat:@"persona-mgmt=%@ no-sandbox=%@ platform-application=%@", personaEntitlement ?: @"(unavailable)", noSandboxEntitlement ?: @"(unavailable)", platformEntitlement ?: @"(unavailable)"];
			NSString* reinstallHint = [personaEntitlement boolValue] ? @"WaffleStore has the root entitlement, so this iOS build likely blocks root-spawn helpers. Check Settings > Privacy & Security and confirm the jailbreak is bootstrapped (Sileo opens)." : @"WaffleStore was signed without the root entitlement (stale install). Reinstall WaffleStore via TrollStore, then try again.";
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] root installer unavailable: method %@, %@, entitlements %@\n", [NSDate date], methodText, errnoText, entitlementsText]];
			if (spawnErrno == 1)
			{
				[self finishInstallWithMessage:[NSString stringWithFormat:@"The system installer could not run as root (%@).\n\n%@\n\nDiagnostics: method %@, %@\n\nReinstall WaffleStore via TrollStore if prompted.\n\nThe .ipa is saved to:\n%@", errnoText, reinstallHint, methodText, entitlementsText, path] title:@"Root Installer Blocked" path:path finished:&finished];
				return;
			}
			if (!encrypted)
			{
				[self appendToInstallLog:[NSString stringWithFormat:@"[%@] root installer unavailable (%@); falling back to manual install for unencrypted app\n", [NSDate date], errnoText]];
				[self installIPAAutomaticallyManuallyAtPath:path cancelled:&cancelled finished:&finished];
				return;
			}
			[self finishInstallWithMessage:[NSString stringWithFormat:@"The system installer could not run as root (%@). DRM-encrypted apps can only be installed by the system installer, so a manual install would not work.\n\nSign into the App Store on this device with the Apple ID that downloaded the app, then try again. Or install the .ipa with TrollStore or Filza.\n\nSaved .ipa:\n%@", errnoText, path] title:@"Install Failed" path:path finished:&finished];
			return;
		}
		if (exitCode == 0)
		{
			[self finishInstallWithMessage:[NSString stringWithFormat:@"The app was installed successfully.\n\nSaved .ipa:\n%@", path] title:@"Installed" path:path finished:&finished];
			return;
		}
		NSString* errorText = @"The installer returned an unknown error.";
		for (NSString* line in [childOutput componentsSeparatedByString:@"\n"])
		{
			if ([line hasPrefix:@"WFS_ERROR: "])
			{
				errorText = [line substringFromIndex:@"WFS_ERROR: ".length];
				break;
			}
		}
		[self finishInstallWithMessage:[NSString stringWithFormat:@"The system installer failed: %@\n\nThe .ipa is saved to:\n%@\n\nPaid apps require the device to be signed into the App Store with the same Apple ID. You can also install it with TrollStore or Filza.", errorText, path] title:@"Install Failed" path:path finished:&finished];
	});
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(420 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^
	{
		if (!finished)
		{
			[self dismissDownloadProgress];
			[self showAlert:@"Install Taking Too Long" message:[NSString stringWithFormat:@"The install did not finish in time. The .ipa is saved to:\n%@\n\nYou can install it with TrollStore or Filza, or try again.", path]];
		}
	});
}

- (void)installIPAAutomaticallyManuallyAtPath:(NSString*)path cancelled:(BOOL*)cancelled finished:(BOOL*)finished
{
	[self updateInstallProgressMessage:@"Extracting app bundle…"];
	NSError* error = nil;
	NSString* extractedAppPath = [self extractAppBundleFromIPAAtPath:path progress:^(NSUInteger completed, NSUInteger total)
	{
		if (completed == 0 || completed == total || completed % 10 == 0)
		{
			[self updateInstallProgressMessage:[NSString stringWithFormat:@"Extracting app bundle… (%lu of %lu files)", (unsigned long)completed, (unsigned long)total]];
		}
	} cancelFlag:cancelled error:&error];
	if (*cancelled)
	{
		[self finishInstallWithMessage:[NSString stringWithFormat:@"Install cancelled. The .ipa is saved to:\n%@", path] title:@"Cancelled" path:path finished:finished];
		return;
	}
	if (!extractedAppPath)
	{
		[self finishInstallWithMessage:[NSString stringWithFormat:@"Could not extract the .ipa (%@). The .ipa is saved to:\n%@\n\nInstall it with TrollStore or Filza.", error.localizedDescription, path] title:@"Install Failed" path:path finished:finished];
		return;
	}
	if (*cancelled)
	{
		[self finishInstallWithMessage:[NSString stringWithFormat:@"Install cancelled. The .ipa is saved to:\n%@", path] title:@"Cancelled" path:path finished:finished];
		return;
	}
	[self updateInstallProgressMessage:@"Copying app bundle…"];
	NSString* installedPath = [self copyAppBundleToSystemAtPath:extractedAppPath error:&error];
	[[NSFileManager defaultManager] removeItemAtPath:[extractedAppPath stringByDeletingLastPathComponent] error:nil];
	if (*cancelled)
	{
		[self finishInstallWithMessage:[NSString stringWithFormat:@"Install cancelled. The .ipa is saved to:\n%@", path] title:@"Cancelled" path:path finished:finished];
		return;
	}
	if (!installedPath)
	{
		[self finishInstallWithMessage:[NSString stringWithFormat:@"Could not install the app (%@). The .ipa is saved to:\n%@\n\nInstall it with TrollStore or Filza.", error.localizedDescription, path] title:@"Install Failed" path:path finished:finished];
		return;
	}
	[self updateInstallProgressMessage:@"Registering app with the system…"];
	[self registerAppBundleAtPath:installedPath cancelFlag:cancelled];
	if (*cancelled)
	{
		[self finishInstallWithMessage:[NSString stringWithFormat:@"Install cancelled. The .ipa is saved to:\n%@", path] title:@"Cancelled" path:path finished:finished];
		return;
	}
	[self finishInstallWithMessage:[NSString stringWithFormat:@"The app was installed successfully.\n\nSaved .ipa:\n%@", path] title:@"Installed" path:path finished:finished];
}

- (void)appendToInstallLog:(NSString*)line
{
	static dispatch_queue_t installLogQueue = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^
	{
		installLogQueue = dispatch_queue_create("org.muz011.wafflestore.installlog", DISPATCH_QUEUE_SERIAL);
	});
	NSString* logPath = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"WaffleStore_install.log"];
	dispatch_async(installLogQueue, ^
	{
		NSFileHandle* handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
		if (!handle)
		{
			[line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
			return;
		}
		@try
		{
			[handle seekToEndOfFile];
			[handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
			[handle closeFile];
		}
		@catch (NSException* exception)
		{
		}
	});
}

- (void)finishInstallWithMessage:(NSString*)message title:(NSString*)title path:(NSString*)path finished:(BOOL*)finished
{
	*finished = YES;
	dispatch_async(dispatch_get_main_queue(), ^
	{
		[self dismissDownloadProgress];
		[self showAlert:title message:message];
	});
}

- (BOOL)registerAppBundleAtPath:(NSString*)appPath cancelFlag:(BOOL*)cancelled
{
	NSArray* uicacheCandidates = @[ @"/var/jb/usr/bin/uicache", @"/usr/bin/uicache", @"/usr/local/bin/uicache" ];
	for (NSString* uicache in uicacheCandidates)
	{
		if (![[NSFileManager defaultManager] isExecutableFileAtPath:uicache])
		{
			continue;
		}
		BOOL succeeded = WFSSpawnWithTimeout(@[ uicache, @"-p", appPath ], 30.0, cancelled);
		if (succeeded)
		{
			return YES;
		}
		if (cancelled && *cancelled)
		{
			return NO;
		}
	}
	[[LSApplicationWorkspace defaultWorkspace] _LSPrivateRebuildApplicationDatabasesForSystemApps:NO];
	return YES;
}

- (NSString*)extractAppBundleFromIPAAtPath:(NSString*)ipaPath progress:(void (^)(NSUInteger completed, NSUInteger total))progressHandler cancelFlag:(BOOL*)cancelled error:(NSError**)error
{
	NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:ipaPath error:nil];
	unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
	NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:ipaPath];
	if (!handle)
	{
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError userInfo:@{NSLocalizedDescriptionKey: @"cannot open the .ipa file"}];
		}
		return nil;
	}
	unsigned long long searchFrom = fileSize > 70000 ? fileSize - 70000 : 0;
	[handle seekToFileOffset:searchFrom];
	NSData* tail = [handle readDataToEndOfFile];
	const uint8_t* tailBytes = tail.bytes;
	NSMutableArray* eocdCandidates = [NSMutableArray array];
	for (NSInteger i = (NSInteger)tail.length - 22; i >= 0; i--)
	{
		if (tailBytes[i] == 0x50 && tailBytes[i + 1] == 0x4B && tailBytes[i + 2] == 0x05 && tailBytes[i + 3] == 0x06)
		{
			[eocdCandidates addObject:@(i)];
		}
	}
	NSInteger eocd = -1;
	for (NSNumber* candidate in eocdCandidates)
	{
		NSInteger i = candidate.integerValue;
		if (i + 22 > tail.length)
		{
			continue;
		}
		uint16_t entryCount = tailBytes[i + 10] | (tailBytes[i + 11] << 8);
		uint32_t cdSize = (uint32_t)(tailBytes[i + 12] | (tailBytes[i + 13] << 8) | (tailBytes[i + 14] << 16) | (tailBytes[i + 15] << 24));
		uint32_t cdOffset = (uint32_t)(tailBytes[i + 16] | (tailBytes[i + 17] << 8) | (tailBytes[i + 18] << 16) | (tailBytes[i + 19] << 24));
		if (cdSize > 0 && (uint64_t)cdOffset + cdSize <= fileSize && entryCount > 0 && entryCount <= cdSize / 46 + 1)
		{
			eocd = i;
			break;
		}
	}
	if (eocd < 0)
	{
		[handle closeFile];
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSLocalizedDescriptionKey: @"not a valid zip archive"}];
		}
		return nil;
	}
	uint16_t entryCount = tailBytes[eocd + 10] | (tailBytes[eocd + 11] << 8);
	uint32_t cdSize = (uint32_t)(tailBytes[eocd + 12] | (tailBytes[eocd + 13] << 8) | (tailBytes[eocd + 14] << 16) | (tailBytes[eocd + 15] << 24));
	uint32_t cdOffset = (uint32_t)(tailBytes[eocd + 16] | (tailBytes[eocd + 17] << 8) | (tailBytes[eocd + 18] << 16) | (tailBytes[eocd + 19] << 24));
	[handle seekToFileOffset:cdOffset];
	NSMutableData* centralData = [NSMutableData data];
	while (centralData.length < cdSize)
	{
		NSData* chunk = [handle readDataOfLength:(NSUInteger)(cdSize - (uint32_t)centralData.length)];
		if (chunk.length == 0)
		{
			break;
		}
		[centralData appendData:chunk];
	}
	[handle closeFile];
	const uint8_t* cd = centralData.bytes;
	NSInteger centralLength = centralData.length;
	NSString* appDirectoryName = nil;
	NSMutableArray* fileEntries = [NSMutableArray array];
	NSInteger pos = 0;
	for (uint16_t i = 0; i < entryCount && pos + 46 <= centralLength; i++)
	{
		if (cd[pos] != 0x50 || cd[pos + 1] != 0x4B || cd[pos + 2] != 0x01 || cd[pos + 3] != 0x02)
		{
			break;
		}
		uint16_t method = cd[pos + 10] | (cd[pos + 11] << 8);
		uint32_t compSize = (uint32_t)(cd[pos + 20] | (cd[pos + 21] << 8) | (cd[pos + 22] << 16) | (cd[pos + 23] << 24));
		uint16_t nameLength = cd[pos + 28] | (cd[pos + 29] << 8);
		uint16_t extraLength = cd[pos + 30] | (cd[pos + 31] << 8);
		uint16_t commentLength = cd[pos + 32] | (cd[pos + 33] << 8);
		uint32_t localOffset = (uint32_t)(cd[pos + 42] | (cd[pos + 43] << 8) | (cd[pos + 44] << 16) | (cd[pos + 45] << 24));
		NSString* name = [[NSString alloc] initWithBytes:(cd + pos + 46) length:nameLength encoding:NSUTF8StringEncoding];
		pos += 46 + nameLength + extraLength + commentLength;
		if (name.length == 0 || [name hasPrefix:@"__MACOSX"])
		{
			continue;
		}
		if (!appDirectoryName && [name hasPrefix:@"Payload/"] && [name hasSuffix:@"/"] && [name rangeOfString:@"/" options:0 range:NSMakeRange(0, name.length - 1)].location == 7)
		{
			appDirectoryName = name;
		}
		if (!appDirectoryName || ![name hasPrefix:appDirectoryName])
		{
			continue;
		}
		[fileEntries addObject:@{ @"name": name, @"method": @(method), @"compSize": @(compSize), @"localOffset": @(localOffset) }];
	}
	if (!appDirectoryName)
	{
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSLocalizedDescriptionKey: @"no .app found in the .ipa"}];
		}
		return nil;
	}
	NSString* outputRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	NSString* appDirectoryPath = [outputRoot stringByAppendingPathComponent:appDirectoryName];
	[[NSFileManager defaultManager] createDirectoryAtPath:appDirectoryPath withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
	NSFileHandle* readHandle = [NSFileHandle fileHandleForReadingAtPath:ipaPath];
	if (!readHandle)
	{
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError userInfo:@{NSLocalizedDescriptionKey: @"cannot open the .ipa file"}];
		}
		return nil;
	}
	BOOL extractedAll = YES;
	NSUInteger entryIndex = 0;
	NSUInteger totalEntries = fileEntries.count;
	uint64_t totalCompressed = 0;
	for (NSDictionary* entry in fileEntries)
	{
		totalCompressed += [entry[@"compSize"] unsignedLongLongValue];
	}
	[self appendToInstallLog:[NSString stringWithFormat:@"[%@] manual extraction started: %lu entries, ~%.1f MB compressed, %llu bytes total\n", [NSDate date], (unsigned long)totalEntries, (double)totalCompressed / 1048576.0, fileSize]];
	for (NSDictionary* entry in fileEntries)
	{
		if (cancelled && *cancelled)
		{
			extractedAll = NO;
			break;
		}
		entryIndex++;
		NSString* entryName = entry[@"name"];
		NSString* relativePath = [entryName substringFromIndex:appDirectoryName.length];
		if (relativePath.length == 0)
		{
			continue;
		}
		NSString* outputPath = [outputRoot stringByAppendingPathComponent:entryName];
		if ([entryName hasSuffix:@"/"])
		{
			[[NSFileManager defaultManager] createDirectoryAtPath:outputPath withIntermediateDirectories:YES attributes:nil error:nil];
			continue;
		}
		uint32_t localOffset = [entry[@"localOffset"] unsignedIntValue];
		[readHandle seekToFileOffset:localOffset];
		NSData* localHeader = [readHandle readDataOfLength:30];
		if (localHeader.length < 30)
		{
			extractedAll = NO;
			break;
		}
		const uint8_t* lh = localHeader.bytes;
		uint16_t localNameLength = lh[26] | (lh[27] << 8);
		uint16_t localExtraLength = lh[28] | (lh[29] << 8);
		[readHandle seekToFileOffset:localOffset + 30 + localNameLength + localExtraLength];
		[[NSFileManager defaultManager] createDirectoryAtPath:[outputPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
		BOOL success = NO;
		uint32_t compSize = [entry[@"compSize"] unsignedIntValue];
		uint16_t method = [entry[@"method"] unsignedShortValue];
		if (method == 0)
		{
			NSFileHandle* outHandle = [NSFileHandle fileHandleForWritingAtPath:outputPath];
			if (outHandle)
			{
				long long remaining = compSize;
				while (remaining > 0)
				{
					NSData* chunk = [readHandle readDataOfLength:(NSUInteger)MIN(remaining, 4194304LL)];
					if (chunk.length == 0)
					{
						break;
					}
					[outHandle writeData:chunk];
					remaining -= chunk.length;
				}
				[outHandle closeFile];
				success = remaining == 0;
			}
		}
		else if (method == 8)
		{
			success = [self inflateZipEntryFromHandle:readHandle compressedSize:compSize toPath:outputPath];
		}
		if (success)
		{
			[[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:outputPath error:nil];
		}
		else
		{
			extractedAll = NO;
			break;
		}
		if (progressHandler)
		{
			progressHandler(entryIndex, totalEntries);
		}
		if (entryIndex % 50 == 0 || entryIndex == totalEntries)
		{
			[self appendToInstallLog:[NSString stringWithFormat:@"[%@] extracting %lu of %lu entries (%@)\n", [NSDate date], (unsigned long)entryIndex, (unsigned long)totalEntries, entryName]];
		}
	}
	[readHandle closeFile];
	if (!extractedAll)
	{
		[[NSFileManager defaultManager] removeItemAtPath:outputRoot error:nil];
		if (error && !(cancelled && *cancelled))
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSLocalizedDescriptionKey: @"could not extract the app bundle"}];
		}
		return nil;
	}
	return appDirectoryPath;
}

- (BOOL)inflateZipEntryFromHandle:(NSFileHandle*)handle compressedSize:(uint32_t)compressedSize toPath:(NSString*)outputPath
{
	NSFileHandle* outHandle = [NSFileHandle fileHandleForWritingAtPath:outputPath];
	if (!outHandle)
	{
		return NO;
	}
	z_stream stream;
	memset(&stream, 0, sizeof(stream));
	if (inflateInit2(&stream, -MAX_WBITS) != Z_OK)
	{
		[outHandle closeFile];
		return NO;
	}
	uint8_t inBuffer[262144];
	uint8_t outBuffer[262144];
	uint32_t remaining = compressedSize;
	int ret = Z_OK;
	while (remaining > 0 && ret != Z_STREAM_END)
	{
		NSData* chunk = [handle readDataOfLength:(NSUInteger)MIN(remaining, (uint32_t)sizeof(inBuffer))];
		if (chunk.length == 0)
		{
			break;
		}
		remaining -= (uint32_t)chunk.length;
		stream.next_in = (Bytef*)chunk.bytes;
		stream.avail_in = (uInt)chunk.length;
		do
		{
			stream.next_out = outBuffer;
			stream.avail_out = sizeof(outBuffer);
			ret = inflate(&stream, Z_NO_FLUSH);
			if (ret != Z_OK && ret != Z_STREAM_END)
			{
				break;
			}
			[outHandle writeData:[NSData dataWithBytes:outBuffer length:sizeof(outBuffer) - stream.avail_out]];
		} while (stream.avail_out == 0);
		if (ret != Z_OK && ret != Z_STREAM_END)
		{
			break;
		}
	}
	inflateEnd(&stream);
	[outHandle closeFile];
	return ret == Z_STREAM_END;
}

- (NSString*)copyAppBundleToSystemAtPath:(NSString*)appPath error:(NSError**)error
{
	NSString* bundleRoot = @"/var/containers/Bundle/Application";
	NSFileManager* fileManager = [NSFileManager defaultManager];
	if (![fileManager fileExistsAtPath:bundleRoot])
	{
		if (error)
		{
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:@{NSLocalizedDescriptionKey: @"app bundle container is not available on this device"}];
		}
		return nil;
	}
	NSString* containerPath = [bundleRoot stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	if (![fileManager createDirectoryAtPath:containerPath withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:error])
	{
		return nil;
	}
	NSString* targetPath = [containerPath stringByAppendingPathComponent:appPath.lastPathComponent];
	if (![fileManager copyItemAtPath:appPath toPath:targetPath error:error])
	{
		[fileManager removeItemAtPath:containerPath error:nil];
		return nil;
	}
	return targetPath;
}

@end
