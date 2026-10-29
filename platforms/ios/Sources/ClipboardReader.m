#import <UIKit/UIKit.h>
#import <dlfcn.h>
#include <unistd.h>
#include <string.h>
// A narrowly entitled reader. No network, persistent clipboard text, or diagnostic output.
// Refuse direct use by other apps/shells: the caller must be the system SpringBoard.
int main(void) { @autoreleasepool {
    int (*pidpath)(int, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath");
    char parentPath[4096] = {0};
    if (!pidpath || pidpath(getppid(), parentPath, sizeof(parentPath)) <= 0 ||
        strcmp(parentPath, "/System/Library/CoreServices/SpringBoard.app/SpringBoard") != 0) return 77;
    NSData *configData = [NSData dataWithContentsOfFile:@"/var/mobile/Library/Preferences/dev.clipmesh.ios.json"];
    NSDictionary *config = configData ? [NSJSONSerialization JSONObjectWithData:configData options:0 error:NULL] : nil;
    if (![config isKindOfClass:NSDictionary.class] || [config[@"v"] integerValue] != 1 ||
        [config[@"paused"] boolValue] || ![config[@"active_group"] isKindOfClass:NSString.class] ||
        [config[@"active_group"] length] != 64) return 78;
    UIPasteboard *board = [UIPasteboard generalPasteboard];
    NSInteger before = board.changeCount;
    NSString *text = nil;
    NSString *mime = @"text/plain";
    // Prefer the image representation when an app supplies both an image and a caption.
    if (board.hasImages) {
        UIImage *image = board.image;
        if (image) {
            CGFloat width = image.size.width * image.scale, height = image.size.height * image.scale;
            if (width > 0 && height > 0 && width <= 16384 && height <= 16384 && width * height <= 40000000) {
                if (image.imageOrientation != UIImageOrientationUp) {
                    UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
                    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
                    image = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                }
                NSData *png = image ? UIImagePNGRepresentation(image) : nil;
                if (png && png.length <= 8 * 1048576) { text = [png base64EncodedStringWithOptions:0]; mime = @"image/png"; }
            }
        }
    } else { text = board.string; }
    NSInteger after = board.changeCount;
    if (before != after) return 75; // Retry this clipboard revision rather than send a raced snapshot.
    if ([mime isEqualToString:@"text/plain"] && text && [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1048576) text = nil;
    // Unsupported/oversized content consumes this revision, preventing expensive repeated encodes.
    NSDictionary *result = @{@"change_count":@(after), @"mime":mime, @"text":text ?: NSNull.null};
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingWithoutEscapingSlashes error:NULL];
    if (!data || data.length > 12 * 1048576) return 65;
    if (fwrite(data.bytes, 1, data.length, stdout) != data.length) return 74;
    return fflush(stdout) == 0 ? 0 : 74;
} }
