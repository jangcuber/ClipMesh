#import <UIKit/UIKit.h>
// Explicitly approved on-device diagnostic only. Never prints clipboard contents.
int main(void) { @autoreleasepool {
 UIPasteboard *board=[UIPasteboard generalPasteboard];
 NSString *text=board.string;
 NSDictionary *result=@{@"has_text":@(text!=nil),@"is_test_marker":@([text hasPrefix:@"CLIPMESH-"]),@"change_count":@(board.changeCount)};
 NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
 fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);
} return 0; }
