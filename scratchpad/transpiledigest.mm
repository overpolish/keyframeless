// Transpile a GLSL file on disk and print a digest of the resulting MSL, so an
// attribute-only edit to a template can be shown to leave the shader untouched.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "KKGLSLTranspiler.h"

int main(int argc, const char **argv) {
  @autoreleasepool {
    for (int i = 1; i < argc; i++) {
      NSString *path = [NSString stringWithUTF8String:argv[i]];
      NSString *src = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
      if (!src) { printf("%s: UNREADABLE\n", argv[i]); return 1; }
      KKGLSLTranspileResult *r = KKTranspileGLSL(src);
      NSString *msl = r.msl ?: @"";
      if (r.errorLog.length)
        printf("%s: ERROR %s\n", argv[i], r.errorLog.UTF8String);
      NSData *d = [msl dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
      printf("%s  %lu bytes  %s\n", (r.mslDigest ?: @"-").UTF8String,
             (unsigned long)d.length, path.lastPathComponent.UTF8String);
    }
  }
  return 0;
}
