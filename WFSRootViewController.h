#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface WFSRootViewController : PSListController

@property (nonatomic, weak) UIViewController* wfsPresentingViewController;

- (void)getAllAppVersionIdsAndPrompt:(long long)appId metadataPlist:(NSDictionary*)metadataPlist;
- (void)promptAppleIDCredentialsWithCompletion:(void (^)(BOOL success))completion;
- (void)startAppleIDDownloadForAppId:(long long)appId;
- (void)signInToAppleID;
- (void)downloadWithAppleID;

@end
