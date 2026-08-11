#import <UIKit/UIKit.h>

typedef void (^WFSVersionPickerCompletion)(NSDictionary* selectedVersion);

@interface WFSVersionPickerViewController : UITableViewController

@property (nonatomic, copy) WFSVersionPickerCompletion completionHandler;

- (instancetype)initWithVersions:(NSArray*)versions completion:(WFSVersionPickerCompletion)completion;

@end
