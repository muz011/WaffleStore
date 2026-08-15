#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>
#import "WFSAppDelegate.h"

typedef void (*WFSMobileInstallationCallback)(CFDictionaryRef information);
typedef int (*WFSMobileInstallationInstallFunction)(CFStringRef path, CFDictionaryRef parameters, WFSMobileInstallationCallback callback, CFStringRef backpath);

static NSString* wfsLogPath = nil;

static void wfsEmit(NSString* line)
{
	NSData* data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
	if (wfsLogPath)
	{
		NSFileHandle* handle = [NSFileHandle fileHandleForWritingAtPath:wfsLogPath];
		if (handle)
		{
			[handle seekToEndOfFile];
			[handle writeData:data];
			[handle closeFile];
		}
	}
	NSFileHandle* stdOut = [NSFileHandle fileHandleWithStandardOutput];
	[stdOut writeData:data];
	[stdOut synchronizeFile];
}

static void wfsMobileInstallationStatusCallback(CFDictionaryRef information)
{
	NSDictionary* info = (__bridge NSDictionary*)information;
	NSString* status = info[@"Status"];
	NSNumber* percent = info[@"PercentComplete"];
	if ([percent isKindOfClass:[NSNumber class]])
	{
		wfsEmit([NSString stringWithFormat:@"WFS_PROGRESS: %ld %@", (long)[percent integerValue], status ?: @"installing"]);
	}
	if ([status isEqualToString:@"Error"] || [info[@"ErrorDescription"] isKindOfClass:[NSString class]])
	{
		wfsEmit([NSString stringWithFormat:@"WFS_ERROR: %@", ((NSString*)info[@"ErrorDescription"]) ?: @"install error"]);
	}
}

static int wfsRunRootInstall(NSString* ipaPath)
{
	wfsEmit([NSString stringWithFormat:@"WFS_DIAG: euid=%d egid=%d", (int)geteuid(), (int)getegid()]);
	void* handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY);
	if (!handle)
	{
		wfsEmit(@"WFS_ERROR: Could not load the system installer framework");
		return 1;
	}
	WFSMobileInstallationInstallFunction installFunction = (WFSMobileInstallationInstallFunction)dlsym(handle, "MobileInstallationInstall");
	if (!installFunction)
	{
		wfsEmit(@"WFS_ERROR: Could not find the system installer function");
		return 1;
	}
	NSDictionary* options = @{
		@"ApplicationType": @"User",
		@"PackageType": @"Customer"
	};
	wfsEmit(@"WFS_PROGRESS: 0 starting install");
	int result = installFunction((__bridge CFStringRef)ipaPath, (__bridge CFDictionaryRef)options, &wfsMobileInstallationStatusCallback, (__bridge CFStringRef)ipaPath);
	wfsEmit([NSString stringWithFormat:@"WFS_RESULT: %d", result]);
	return result == 0 ? 0 : 1;
}

int main(int argc, char *argv[]) {
	@autoreleasepool {
		if (argc >= 3 && strcmp(argv[1], "--wfs-install") == 0)
		{
			NSString* ipaPath = [NSString stringWithUTF8String:argv[2]];
			for (int i = 3; i + 1 < argc; i++)
			{
				if (strcmp(argv[i], "--wfs-log") == 0)
				{
					wfsLogPath = [NSString stringWithUTF8String:argv[i + 1]];
				}
			}
			return wfsRunRootInstall(ipaPath);
		}
		return UIApplicationMain(argc, argv, nil, NSStringFromClass(WFSAppDelegate.class));
	}
}
