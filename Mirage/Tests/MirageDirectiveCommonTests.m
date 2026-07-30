/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

#import "MirageDirectiveCommon.h"
#import "MirageScalarParse.h"
#import "MirageTemplateType.h"

static void KKRequire(BOOL condition, NSString *message) {
  if (condition)
    return;
  NSLog(@"FAIL: %@", message);
  exit(1);
}

int main(void) {
  @autoreleasepool {
    KKRequire(MirageAttrHasBareFlag(@" dropdown multiple", @"dropdown"),
              @"recognises a bare dropdown flag");
    KKRequire(MirageAttrHasBareFlag(@" dropdown multiple", @"multiple"),
              @"recognises a bare multiple flag");
    KKRequire(!MirageAttrHasBareFlag(@" label=\"multiple\"", @"multiple"),
              @"ignores flags in quoted labels");
    KKRequire(!MirageAttrHasBareFlag(@" options=\"Flow,No flow\" flowgate=-30",
                                     @"flow"),
              @"ignores quoted and prefixed flow words");
    KKRequire(MirageAttrHasBareFlag(@" flow flowgate=-30", @"flow"),
              @"recognises flow alongside prefixed attributes");

    MirageTemplateDirectiveError templateError =
        MirageTemplateDirectiveErrorNone;
    KKRequire(MirageTemplateTypeForSource(
                  @"// #template color-transform\nvoid mainImage() {}",
                  &templateError) == MirageTemplateTypeColorTransform &&
                  templateError == MirageTemplateDirectiveErrorNone,
              @"recognises the color-transform template");

    NSMutableArray<NSString *> *longLabels = [NSMutableArray array];
    for (NSInteger i = 0; i < 40; i++)
      [longLabels addObject:[NSString stringWithFormat:@"Camera Profile %02ld",
                                                       (long)i]];
    NSString *longChoice = [NSString
        stringWithFormat:@"// #choice dropdown options=\"%@\" default=39\n"
                         @"uniform int uInput;\n",
                         [longLabels componentsJoinedByString:@","]];
    MirageScalarProp prop = {0};
    int used = 0, truncated = 0;
    KKRequire(
        MirageParseScalarProps(longChoice, &prop, 1, 0, &used, &truncated) == 1,
        @"parses a long searchable choice");
    KKRequire(prop.choiceCount == 40 && prop.cdefault == 39,
              @"preserves every long-choice label and its default");

    // A directive name ends at a hyphen. These patterns used to end in `\b`,
    // which IS a boundary between a letter and a hyphen, so a future
    // `#color-surface` parsed as `#color` and handed `-surface ...` over as its
    // attribute body. Silently, which is the bad part.
    MirageScalarProp hyphenated = {0};
    used = 0;
    truncated = 0;
    KKRequire(
        MirageParseScalarProps(@"// #choice-surface options=\"A,B\" default=1\n"
                               @"uniform int uThing;\n",
                               &hyphenated, 1, 0, &used, &truncated) == 0,
        @"does not read #choice-surface as #choice");
    KKRequire(MirageParseScalarProps(@"// #choice options=\"A,B\" default=1\n"
                                     @"uniform int uThing;\n",
                                     &hyphenated, 1, 0, &used, &truncated) == 1,
              @"still reads a plain #choice");

    templateError = MirageTemplateDirectiveErrorNone;
    KKRequire(MirageTemplateTypeForSource(
                  @"// #template-of-mine filter\nvoid mainImage() {}",
                  &templateError) == MirageTemplateTypeInvalid,
              @"does not read #template-of-mine as #template");
  }
  return 0;
}
