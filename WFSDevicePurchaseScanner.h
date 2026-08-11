#import <Foundation/Foundation.h>

extern NSString* const WFSDevicePurchaseStoreIDKey;
extern NSString* const WFSDevicePurchaseBundleIDKey;
extern NSString* const WFSDevicePurchaseTitleKey;
extern NSString* const WFSDevicePurchaseDateKey;
extern NSString* const WFSDevicePurchaseSourceKey;
extern NSString* const WFSDevicePurchaseSourceMediaLibrary;

@interface WFSDevicePurchaseScanner : NSObject

+ (NSArray<NSDictionary*>*)scanPurchasesForDSID:(long long)dsid;

@end
