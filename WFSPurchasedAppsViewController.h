#import <UIKit/UIKit.h>

@interface WFSPurchasedAppsViewController : UITableViewController

- (instancetype)initWithSelectionHandler:(void (^)(long long appId, NSDictionary* metadataPlist))selectionHandler;

@end
