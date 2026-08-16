#import "WFSAppDelegate.h"
#import "WFSRootViewController.h"
#import "WFSPurchasedAppsViewController.h"

static void WFSUncaughtExceptionHandler(NSException* exception)
{
	NSString* directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
	NSString* path = [directory stringByAppendingPathComponent:@"WaffleStore_crash.log"];
	NSString* details = [NSString stringWithFormat:@"%@\n%@\n%@\n\n%@", exception.name, exception.reason, exception.userInfo, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
	[details writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static UIImage* WFSImageNamed(NSString* name)
{
	SEL selector = NSSelectorFromString(@"systemImageNamed:");
	if ([UIImage respondsToSelector:selector])
	{
		return [UIImage performSelector:selector withObject:name];
	}
	return nil;
}

@implementation WFSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	NSSetUncaughtExceptionHandler(&WFSUncaughtExceptionHandler);
	_window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

	WFSRootViewController* downgradeViewController = [WFSRootViewController new];
	UINavigationController* downgradeNavigationController = [[UINavigationController alloc] initWithRootViewController:downgradeViewController];
	downgradeNavigationController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Downgrade" image:WFSImageNamed(@"arrow.down.circle") selectedImage:WFSImageNamed(@"arrow.down.circle.fill")];

	__weak WFSRootViewController* weakDowngradeViewController = downgradeViewController;
	WFSPurchasedAppsViewController* purchasesViewController = [[WFSPurchasedAppsViewController alloc] initWithSelectionHandler:^(long long appId, NSDictionary* metadataPlist)
	{
		[weakDowngradeViewController getAllAppVersionIdsAndPrompt:appId metadataPlist:metadataPlist];
	}];
	purchasesViewController.appleIDSignInHandler = ^(void (^completion)(BOOL success))
	{
		[weakDowngradeViewController promptAppleIDCredentialsWithCompletion:completion];
	};
	purchasesViewController.appleIDDownloadHandler = ^(long long appId)
	{
		[weakDowngradeViewController startAppleIDDownloadForAppId:appId];
	};
	UINavigationController* purchasesNavigationController = [[UINavigationController alloc] initWithRootViewController:purchasesViewController];
	purchasesNavigationController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Purchased" image:WFSImageNamed(@"bag") selectedImage:WFSImageNamed(@"bag.fill")];

	UITabBarController* tabBarController = [UITabBarController new];
	tabBarController.viewControllers = @[downgradeNavigationController, purchasesNavigationController];
	Class appearanceClass = NSClassFromString(@"UITabBarAppearance");
	if (appearanceClass)
	{
		id appearance = [appearanceClass new];
		[appearance performSelector:NSSelectorFromString(@"configureWithDefaultBackground")];
		[tabBarController.tabBar setValue:appearance forKey:@"standardAppearance"];
		[tabBarController.tabBar setValue:appearance forKey:@"scrollEdgeAppearance"];
	}
	downgradeViewController.wfsPresentingViewController = tabBarController;
	_tabBarController = tabBarController;
	_window.rootViewController = tabBarController;
	[_window makeKeyAndVisible];
	return YES;
}

@end
