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

@implementation WFSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	NSSetUncaughtExceptionHandler(&WFSUncaughtExceptionHandler);
	_window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

	WFSRootViewController* downgradeViewController = [WFSRootViewController new];
	UINavigationController* downgradeNavigationController = [[UINavigationController alloc] initWithRootViewController:downgradeViewController];
	downgradeNavigationController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Downgrade" image:[UIImage systemImageNamed:@"arrow.down.circle"] selectedImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"]];

	__weak WFSRootViewController* weakDowngradeViewController = downgradeViewController;
	WFSPurchasedAppsViewController* purchasesViewController = [[WFSPurchasedAppsViewController alloc] initWithSelectionHandler:^(long long appId, NSDictionary* metadataPlist)
	{
		[weakDowngradeViewController getAllAppVersionIdsAndPrompt:appId metadataPlist:metadataPlist];
	}];
	UINavigationController* purchasesNavigationController = [[UINavigationController alloc] initWithRootViewController:purchasesViewController];
	purchasesNavigationController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Purchased" image:[UIImage systemImageNamed:@"bag"] selectedImage:[UIImage systemImageNamed:@"bag.fill"]];

	UITabBarController* tabBarController = [UITabBarController new];
	tabBarController.viewControllers = @[downgradeNavigationController, purchasesNavigationController];
	if (@available(iOS 15.0, *))
	{
		UITabBarAppearance* appearance = [UITabBarAppearance new];
		[appearance configureWithDefaultBackground];
		tabBarController.tabBar.standardAppearance = appearance;
		tabBarController.tabBar.scrollEdgeAppearance = appearance;
	}
	downgradeViewController.wfsPresentingViewController = tabBarController;
	_tabBarController = tabBarController;
	_window.rootViewController = tabBarController;
	[_window makeKeyAndVisible];
	return YES;
}

@end
