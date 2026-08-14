#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>
#import "WFSAppDelegate.h"

typedef void (*WFSMobileInstallationCallback)(CFDictionaryRef information);
typedef int (*WFSMobileInstallationInstallFunction)(CFStringRef path, CFDictionaryRef parameters, WFSMobileInstallationCallback callback, CFStringRef backpath);

static void wfsMobileInstallationStatusCallback(CFDictionaryRef information)
{
	NSDictionary* info = (__bridge NSDictionary*)information;
	NSString* status = info[@"Status"];
	NSNumber* percent = info[@"PercentComplete"];
	if ([percent isKindOfClass:[NSNumber class]])
	{
		printf("WFS_PROGRESS: %ld %s\n", (long)[percent integerValue], status ? status.UTF8String : "installing");
		fflush(stdout);
	}
	if ([status isEqualToString:@"Error"] || [info[@"ErrorDescription"] isKindOfClass:[NSString class]])
	{
		printf("WFS_ERROR: %s\n", ((NSString*)info[@"ErrorDescription"]).UTF8String ?: "install error");
		fflush(stdout);
	}
}

static int wfsRunRootInstall(NSString* ipaPath)
{
	printf("WFS_DIAG: euid=%d egid=%d sandboxed=1\n", (int)geteuid(), (int)getegid());
	fflush(stdout);
	void* handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY);
	if (!handle)
	{
		printf("WFS_ERROR: Could not load the system installer framework\n");
		fflush(stdout);
		return 1;
	}
	WFSMobileInstallationInstallFunction installFunction = (WFSMobileInstallationInstallFunction)dlsym(handle, "MobileInstallationInstall");
	if (!installFunction)
	{
		printf("WFS_ERROR: Could not find the system installer function\n");
		fflush(stdout);
		return 1;
	}
	NSDictionary* options = @{
		@"ApplicationType": @"User",
		@"PackageType": @"Customer"
	};
	printf("WFS_PROGRESS: 0 starting install\n");
	fflush(stdout);
	int result = installFunction((__bridge CFStringRef)ipaPath, (__bridge CFDictionaryRef)options, &wfsMobileInstallationStatusCallback, (__bridge CFStringRef)ipaPath);
	printf("WFS_RESULT: %d\n", result);
	fflush(stdout);
	return result == 0 ? 0 : 1;
}

int main(int argc, char *argv[]) {
	@autoreleasepool {
		if (geteuid() == 0 && argc >= 3 && strcmp(argv[1], "--wfs-install") == 0)
		{
			NSString* ipaPath = [NSString stringWithUTF8String:argv[2]];
			return wfsRunRootInstall(ipaPath);
		}
		return UIApplicationMain(argc, argv, nil, NSStringFromClass(WFSAppDelegate.class));
	}
}
