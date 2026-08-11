#import "WFSAppDelegate.h"
#import "WFSRootViewController.h"

static void WFSUncaughtExceptionHandler(NSException* exception)
{
	NSString* directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
	NSString* path = [directory stringByAppendingPathComponent:@"WaffleStore_crash.log"];
	NSString* details = [NSString stringWithFormat:@"%@\n%@\n%@\n\n%@", exception.name, exception.reason, exception.userInfo, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
	[details writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@implementation WFSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	NSSetUncaughtExceptionHandler(&WFSUncaughtExceptionHandler);
	_window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	_rootViewController = [[UINavigationController alloc] initWithRootViewController:[[WFSRootViewController alloc] init]];
	_window.rootViewController = _rootViewController;
	[_window makeKeyAndVisible];
	return YES;
}

@end
