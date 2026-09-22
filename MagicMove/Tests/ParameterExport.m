/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
// Dumps the plug-in's own parameter registration as JSON so the Motion template
// generator can publish controls in registration order instead of that order
// being picked by hand in Motion. Kept out of the default suite list because it
// produces a file rather than checking behaviour:
//
//   MM_TEST_SUITES=ParameterExport MagicMove/Tests/run.sh parameters.json
//
// scripts/template-build.py runs that for you.
#import "Constants.h"
#import "MockHost.h"
#import "Plugin_Private.h"
#import <stdio.h>

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 2) {
      fprintf(stderr, "usage: ParameterExport <output.json>\n");
      return 2;
    }
    MockHost *host = [MockHost new];
    MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:host];
    host.plugin = plugin;
    NSError *error = nil;
    if (![plugin addParametersWithError:&error]) {
      fprintf(stderr, "parameter registration failed: %s\n",
              error.localizedDescription.UTF8String ?: "unknown error");
      return 1;
    }
    NSMutableArray<NSDictionary *> *parameters = [NSMutableArray new];
    for (NSNumber *identifier in host.registrationOrder) {
      NSDictionary *definition = host.definitions[identifier];
      FxParameterFlags flags = [host.flags[identifier] unsignedIntValue];
      // The SDK flag bits stay on this side of the boundary: the generator only
      // needs to know which controls the host shows and in what order.
      [parameters addObject:@{
        @"id" : identifier,
        @"name" : definition[@"name"] ?: @"",
        @"kind" : definition[@"kind"] ?: @"unknown",
        @"customUI" : @((flags & kFxParameterFlag_CUSTOM_UI) != 0),
        @"hidden" : @((flags & kFxParameterFlag_HIDDEN) != 0),
      }];
    }
    NSData *json = [NSJSONSerialization
        dataWithJSONObject:@{@"pluginID" : kPluginID, @"parameters" : parameters}
                   options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                     error:&error];
    NSString *path = [NSString stringWithUTF8String:argv[1]];
    if (!json || ![json writeToFile:path options:NSDataWritingAtomic error:&error]) {
      fprintf(stderr, "could not write %s: %s\n", argv[1],
              error.localizedDescription.UTF8String ?: "unknown error");
      return 1;
    }
  }
  return 0;
}
