#import <Foundation/Foundation.h>

@interface SSAccount : NSObject
@property (copy, nonatomic) NSString* accountName;
@property (retain, nonatomic) NSNumber* uniqueIdentifier;
@property (copy, nonatomic) NSString* storeFrontIdentifier;
@end

@interface SSAccountStore : NSObject
+ (instancetype)defaultStore;
@property (readonly) SSAccount* activeAccount;
@end

@interface SSAuthenticationContext : NSObject
+ (instancetype)contextForSignIn;
@end

@interface SSAuthenticateRequest : NSObject
- (instancetype)initWithAuthenticationContext:(SSAuthenticationContext*)context;
- (void)startWithAuthenticateResponseBlock:(void (^)(id response, NSError* error))block;
@end

@interface ASDPurchaseHistory : NSObject
+ (instancetype)sharedInstance;
- (void)updateForAccountID:(long long)accountID withCompletionHandler:(void (^)(NSError* error))completionHandler;
- (void)executeQuery:(id)query withResultHandler:(void (^)(NSArray* apps, NSError* error))resultHandler;
@end

@interface ASDPurchaseHistoryQuery : NSObject
@property long long accountID;
@property long long isHidden;
@property long long isPreorder;
@property long long isFirstParty;
@property (copy) NSArray* bundleIDs;
@property (copy) NSArray* storeIDs;
@property (copy) NSString* searchTerm;
@property (copy) NSArray* sortOptions;
@end

@interface ASDPurchaseHistoryApp : NSObject
@property (copy) NSString* bundleID;
@property (copy) NSString* circularIconURLString;
@property (copy) NSDate* datePurchased;
@property (copy) NSString* developerName;
@property (getter=isFamilyShared) BOOL familyShared;
@property (getter=isHidden) BOOL hidden;
@property (getter=isPreorder) BOOL preorder;
@property (copy) NSString* iconURLString;
@property (copy) NSString* longTitle;
@property unsigned int mediaKind;
@property (copy) NSURL* productURL;
@property (copy) NSString* redownloadParams;
@property long long storeItemID;
@property (copy) NSString* title;
@end
