#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface WFSRootViewController : PSListController

@property (nonatomic, weak) UIViewController* wfsPresentingViewController;

- (void)getAllAppVersionIdsAndPrompt:(long long)appId metadataPlist:(NSDictionary*)metadataPlist;

@end
