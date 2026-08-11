#import <UIKit/UIKit.h>

@interface WFSPurchasedAppsViewController : UITableViewController

- (instancetype)initWithSelectionHandler:(void (^)(long long appId, NSDictionary* metadataPlist))selectionHandler;

@property (nonatomic, copy, nullable) void (^appleIDSignInHandler)(void (^completion)(BOOL success));

@end
