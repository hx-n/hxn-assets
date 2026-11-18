#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

char *hxn_file_apple_path(int assets) {
    @autoreleasepool {
        NSString *path = assets
            ? [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"assets"]
            : [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                  inDomains:NSUserDomainMask].firstObject.path;
        return path ? strdup(path.UTF8String) : NULL;
    }
}
void hxn_file_string_free(char *value) { free(value); }
