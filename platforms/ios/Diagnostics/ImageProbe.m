#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
// Bounded diagnostic for test-owned PNGs only. Never prints clipboard bytes, dimensions or hashes.
static BOOL dimensions(NSData *bytes, size_t *width, size_t *height) {
    if (!bytes || bytes.length > 8 * 1048576) return NO;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, NULL);
    if (!source) return NO;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    *width = [properties[(NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    *height = [properties[(NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    return *width > 0 && *height > 0 && *width <= 16384 && *height <= 16384 && *width * *height <= 40000000;
}
static NSData *pixels(UIImage *image, size_t width, size_t height) {
    if (!image.CGImage || CGImageGetWidth(image.CGImage) != width || CGImageGetHeight(image.CGImage) != height) return nil;
    NSMutableData *result = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(result.mutableBytes, width, height, 8, width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);
    CGContextRelease(context);
    return result;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3) return 64;
    NSString *operation = [NSString stringWithUTF8String:argv[1]];
    NSString *path = [NSString stringWithUTF8String:argv[2]];
    if (!([operation isEqualToString:@"write"] || [operation isEqualToString:@"read"]) ||
        ![path hasPrefix:@"/var/mobile/Documents/ClipMesh-ImageTest-"] || ![path hasSuffix:@".png"] ||
        ![path.stringByStandardizingPath isEqualToString:path]) return 64;
    NSData *expected = [NSData dataWithContentsOfFile:path];
    size_t width = 0, height = 0;
    if (expected.length > 1048576 || !dimensions(expected, &width, &height) || width > 256 || height > 256) return 65;
    UIImage *expectedImage = [UIImage imageWithData:expected];
    NSData *expectedPixels = pixels(expectedImage, width, height);
    if (!expectedPixels) return 65;
    UIPasteboard *board = [UIPasteboard generalPasteboard];
    if ([operation isEqualToString:@"write"]) [board setData:expected forPasteboardType:@"public.png"];
    BOOL hasImage = board.hasImages, matchesPixels = NO, matchesPNG = NO;
    if (hasImage) {
        NSData *actual = [board dataForPasteboardType:@"public.png"];
        size_t actualWidth = 0, actualHeight = 0;
        if (dimensions(actual, &actualWidth, &actualHeight) && actualWidth == width && actualHeight == height) {
            matchesPNG = [actual isEqualToData:expected];
            NSData *actualPixels = pixels([UIImage imageWithData:actual], width, height);
            matchesPixels = actualPixels && [actualPixels isEqualToData:expectedPixels];
        }
    }
    NSDictionary *result = @{@"operation":operation, @"has_image":@(hasImage), @"matches_expected_pixels":@(matchesPixels), @"matches_expected_png_bytes":@(matchesPNG)};
    NSData *resultData = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    fwrite(resultData.bytes, 1, resultData.length, stdout); fputc('\n', stdout);
    return 0;
} }
