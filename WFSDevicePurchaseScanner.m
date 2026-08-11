#import "WFSDevicePurchaseScanner.h"
#import <sqlite3.h>

NSString* const WFSDevicePurchaseStoreIDKey = @"storeItemID";
NSString* const WFSDevicePurchaseBundleIDKey = @"bundleID";
NSString* const WFSDevicePurchaseTitleKey = @"title";
NSString* const WFSDevicePurchaseDateKey = @"datePurchased";
NSString* const WFSDevicePurchaseSourceKey = @"source";
NSString* const WFSDevicePurchaseSourceApplicationState = @"applicationState";
NSString* const WFSDevicePurchaseSourceMediaLibrary = @"mediaLibrary";

static NSString* const WFSApplicationStateDBPath = @"/var/mobile/Library/FrontBoard/applicationState.db";
static NSString* const WFSMediaLibraryDBPath = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";

@implementation WFSDevicePurchaseScanner

+ (NSArray<NSDictionary*>*)scanPurchasesForDSID:(long long)dsid
{
	NSMutableDictionary* merged = [NSMutableDictionary dictionary];
	[self scanApplicationStateInto:merged];
	[self scanMediaLibraryForDSID:dsid into:merged];
	return [merged allValues];
}

+ (void)scanApplicationStateInto:(NSMutableDictionary*)merged
{
	sqlite3* db = NULL;
	if (sqlite3_open_v2(WFSApplicationStateDBPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK)
	{
		NSLog(@"[WaffleStore] Scanner: cannot open applicationState.db: %s", sqlite3_errmsg(db));
		if (db)
		{
			sqlite3_close(db);
		}
		return;
	}
	sqlite3_stmt* stmt = NULL;
	if (sqlite3_prepare_v2(db, "SELECT application_identifier FROM application_identifier_tab", -1, &stmt, NULL) == SQLITE_OK)
	{
		while (sqlite3_step(stmt) == SQLITE_ROW)
		{
			const unsigned char* text = sqlite3_column_text(stmt, 0);
			if (!text)
			{
				continue;
			}
			NSString* bundleID = [NSString stringWithUTF8String:(const char*)text];
			if (!bundleID.length)
			{
				continue;
			}
			merged[bundleID] = @{
				WFSDevicePurchaseBundleIDKey: bundleID,
				WFSDevicePurchaseSourceKey: WFSDevicePurchaseSourceApplicationState,
			};
		}
	}
	else
	{
		NSLog(@"[WaffleStore] Scanner: applicationState query failed: %s", sqlite3_errmsg(db));
	}
	sqlite3_finalize(stmt);
	sqlite3_close(db);
}

+ (void)scanMediaLibraryForDSID:(long long)dsid into:(NSMutableDictionary*)merged
{
	NSString* accountFilter = [NSString stringWithFormat:@" AND sto.account_id = %lld", dsid];
	NSArray* rows = [self mediaLibraryRowsWithAccountFilter:accountFilter];
	if (rows.count == 0)
	{
		rows = [self mediaLibraryRowsWithAccountFilter:@""];
	}
	for (NSDictionary* row in rows)
	{
		NSInteger mediaKind = [row[@"kind"] integerValue];
		if (mediaKind >= 1 && mediaKind <= 8)
		{
			continue;
		}
		NSNumber* storeID = row[@"id"];
		NSString* key = [NSString stringWithFormat:@"id:%@", storeID];
		NSMutableDictionary* entry = [merged[key] mutableCopy];
		if (!entry)
		{
			entry = [NSMutableDictionary dictionary];
		}
		entry[WFSDevicePurchaseStoreIDKey] = storeID;
		NSString* title = row[@"title"];
		if (title.length)
		{
			entry[WFSDevicePurchaseTitleKey] = title;
		}
		double dateInterval = [row[@"date"] doubleValue];
		if (dateInterval > 0)
		{
			entry[WFSDevicePurchaseDateKey] = [NSDate dateWithTimeIntervalSince1970:dateInterval + 978307200.0];
		}
		entry[WFSDevicePurchaseSourceKey] = WFSDevicePurchaseSourceMediaLibrary;
		merged[key] = entry;
	}
}

+ (NSArray*)mediaLibraryRowsWithAccountFilter:(NSString*)accountFilter
{
	sqlite3* db = NULL;
	if (sqlite3_open_v2(WFSMediaLibraryDBPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK)
	{
		NSLog(@"[WaffleStore] Scanner: cannot open MediaLibrary.sqlitedb: %s", sqlite3_errmsg(db));
		if (db)
		{
			sqlite3_close(db);
		}
		return @[];
	}
	NSString* query = [NSString stringWithFormat:
		@"SELECT sto.store_item_id, ext.title, sto.date_purchased, ext.media_kind "
		@"FROM item_store sto JOIN item_extra ext ON ext.item_pid = sto.item_pid "
		@"WHERE sto.store_item_id > 0%@",
		accountFilter];
	sqlite3_stmt* stmt = NULL;
	if (sqlite3_prepare_v2(db, query.UTF8String, -1, &stmt, NULL) != SQLITE_OK)
	{
		NSLog(@"[WaffleStore] Scanner: MediaLibrary query failed: %s", sqlite3_errmsg(db));
		sqlite3_close(db);
		return @[];
	}
	NSMutableArray* rows = [NSMutableArray array];
	while (sqlite3_step(stmt) == SQLITE_ROW)
	{
		long long storeID = sqlite3_column_int64(stmt, 0);
		if (storeID <= 0)
		{
			continue;
		}
		NSString* title = nil;
		const unsigned char* titleText = sqlite3_column_text(stmt, 1);
		if (titleText)
		{
			title = [NSString stringWithUTF8String:(const char*)titleText];
		}
		double dateInterval = sqlite3_column_double(stmt, 2);
		NSInteger mediaKind = sqlite3_column_int(stmt, 3);
		[rows addObject:@{
			@"id": @(storeID),
			@"title": title ?: @"",
			@"date": @(dateInterval),
			@"kind": @(mediaKind),
		}];
	}
	sqlite3_finalize(stmt);
	sqlite3_close(db);
	return rows;
}

@end
