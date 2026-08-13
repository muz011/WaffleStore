#import "WFSAppDelegate.h"
#import "WFSRootViewController.h"
#import "WFSPurchasedAppsViewController.h"
#import "WFSAuthTestViewController.h"
#import "WFSDownloadTestViewController.h"
#import "WFSVersionTestViewController.h"

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
	purchasesViewController.appleIDSignInHandler = ^(void (^completion)(BOOL success))
	{
		[weakDowngradeViewController promptAppleIDCredentialsWithCompletion:completion];
	};
	UINavigationController* purchasesNavigationController = [[UINavigationController alloc] initWithRootViewController:purchasesViewController];
	purchasesNavigationController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Purchased" image:[UIImage systemImageNamed:@"bag"] selectedImage:[UIImage systemImageNamed:@"bag.fill"]];

	WFSAuthTestViewController* authTestViewController = [WFSAuthTestViewController new];
	UINavigationController* authTestNavigationController = [[UINavigationController alloc] initWithRootViewController:authTestViewController];
	authTestNavigationController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"authTest" image:[UIImage systemImageNamed:@"key"] selectedImage:[UIImage systemImageNamed:@"key.fill"]];

	WFSDownloadTestViewController* downloadTestViewController = [WFSDownloadTestViewController new];
	UINavigationController* downloadTestNavigationController = [[UINavigationController alloc] initWithRootViewController:downloadTestViewController];
	downloadTestNavigationController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"downloadTest" image:[UIImage systemImageNamed:@"icloud.and.arrow.down"] selectedImage:[UIImage systemImageNamed:@"icloud.and.arrow.down.fill"]];

	WFSVersionTestViewController* versionTestViewController = [WFSVersionTestViewController new];
	UINavigationController* versionTestNavigationController = [[UINavigationController alloc] initWithRootViewController:versionTestViewController];
	versionTestNavigationController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"verTest" image:[UIImage systemImageNamed:@"list.number"] selectedImage:[UIImage systemImageNamed:@"list.number"]];

	UITabBarController* tabBarController = [UITabBarController new];
	tabBarController.viewControllers = @[downgradeNavigationController, purchasesNavigationController, authTestNavigationController, downloadTestNavigationController, versionTestNavigationController];
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
