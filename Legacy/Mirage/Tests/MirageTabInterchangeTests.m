/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The `// #tab` multi-tab interchange, both directions: the kit's paste split
// (KKCodeTabInterchange, compiled straight from the kit source - it is
// Foundation-only on purpose) and Mirage's Option-click export, checked to
// round-trip through it byte for byte.

#import <Foundation/Foundation.h>

#import "KKCodeTabInterchange.h"
#import "MirageSchemaDoc.h"
#import "MirageShaderTabs.h"

static int gFailures = 0;

static void KKRequire(BOOL condition, NSString *message) {
  if (condition)
    return;
  printf("FAIL: %s\n", message.UTF8String);
  gFailures++;
}

static void KKRequireEqual(NSString *_Nullable got, NSString *_Nullable want,
                           NSString *message) {
  if ((!got && !want) || [got isEqualToString:want])
    return;
  printf("FAIL: %s\n  got:  %s\n  want: %s\n", message.UTF8String,
         got ? got.UTF8String : "(nil)", want ? want.UTF8String : "(nil)");
  gFailures++;
}

static NSArray<NSString *> *KnownTabs(void) {
  return @[
    @"Image", @"Common", @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D"
  ];
}

int main(void) {
  @autoreleasepool {
    // A three-tab blob: every marker line is stripped, every body lands whole.
    NSString *blob =
        @"// #tab image\n"
        @"void mainImage(out vec4 O, in vec2 I) {\n"
        @"  O = vec4(1.0);\n"
        @"}\n"
        @"// #tab common\n"
        @"#define TAU 6.283185\n"
        @"// #tab buffer-a\n"
        @"void mainImage(out vec4 O, in vec2 I) { O = vec4(0.0); }\n";
    NSDictionary<NSString *, NSString *> *split =
        KKCodeSplitTabbedText(blob, KnownTabs());
    KKRequire(split.count == 3, @"three markers give three tabs");
    KKRequireEqual(split[@"Image"],
                   @"void mainImage(out vec4 O, in vec2 I) {\n  O = "
                   @"vec4(1.0);\n}",
                   @"the Image body arrives whole");
    KKRequireEqual(split[@"Common"], @"#define TAU 6.283185",
                   @"the Common body arrives whole");
    KKRequireEqual(split[@"Buffer A"],
                   @"void mainImage(out vec4 O, in vec2 I) { O = vec4(0.0); }",
                   @"a hyphenated marker resolves to the spaced tab name");
    for (NSString *code in split.allValues)
      KKRequire([code rangeOfString:@"#tab"].location == NSNotFound,
                @"no marker line survives into a tab");

    // A model that forgets the opening marker: the leading block is Image.
    NSDictionary<NSString *, NSString *> *lead = KKCodeSplitTabbedText(
        @"void mainImage(out vec4 O, in vec2 I) { O = vec4(0.5); }\n"
        @"// #tab common\n"
        @"#define K 2.0\n",
        KnownTabs());
    KKRequireEqual(lead[@"Image"],
                   @"void mainImage(out vec4 O, in vec2 I) { O = vec4(0.5); }",
                   @"content before the first marker is the Image tab");
    KKRequireEqual(lead[@"Common"], @"#define K 2.0",
                   @"and the marked tab still lands");

    // Name spelling is identity-only: letters and digits, case-insensitive.
    NSArray<NSString *> *variants =
        @[ @"buffer-a", @"buffer a", @"Buffer A", @"BUFFER_A", @"bufferA" ];
    for (NSString *v in variants) {
      NSDictionary<NSString *, NSString *> *d = KKCodeSplitTabbedText(
          [NSString stringWithFormat:@"// #tab %@\nX\n", v], KnownTabs());
      KKRequireEqual(d[@"Buffer A"], @"X",
                     [NSString stringWithFormat:@"`%@` names Buffer A", v]);
    }
    KKRequire(KKCodeTabMarkerName(@"   // #tab   Buffer B  ") != nil,
              @"a marker tolerates surrounding whitespace");
    KKRequire(KKCodeTabMarkerName(@"// #table lookup") == nil,
              @"`#table` is an ordinary comment, not a marker");
    KKRequire(KKCodeTabMarkerName(@"// #tab") == nil,
              @"a marker with no name is not a marker");
    KKRequire(KKCodeTabMarkerName(@"float x; // #tab image") == nil,
              @"a marker must be the whole line");

    // An unknown tab makes the WHOLE paste plain text - nothing is dropped.
    KKRequire(KKCodeSplitTabbedText(@"// #tab image\nA\n// #tab buffer-e\nB\n",
                                    KnownTabs()) == nil,
              @"an unknown tab name refuses the split");
    KKRequire(KKCodeSplitTabbedText(@"void mainImage() {}\n", KnownTabs()) ==
                  nil,
              @"no markers at all = an ordinary paste");

    // Two adjacent markers, and markers with only blank space between them,
    // both mean an EMPTY tab (not a stray newline).
    NSDictionary<NSString *, NSString *> *empty = KKCodeSplitTabbedText(
        @"// #tab image\n// #tab common\n\n  \n// #tab buffer-a\nZ\n",
        KnownTabs());
    KKRequireEqual(empty[@"Image"], @"", @"an adjacent marker empties the tab");
    KKRequireEqual(empty[@"Common"], @"",
                   @"blank lines between markers empty the tab too");
    KKRequireEqual(empty[@"Buffer A"], @"Z", @"and the last tab still lands");

    // A tab named twice keeps the last block.
    NSDictionary<NSString *, NSString *> *dupe = KKCodeSplitTabbedText(
        @"// #tab image\nfirst\n// #tab image\nsecond\n", KnownTabs());
    KKRequireEqual(dupe[@"Image"], @"second", @"a repeated tab keeps the last");

    // CRLF, as pasted from a Windows-flavoured chat client.
    NSDictionary<NSString *, NSString *> *crlf = KKCodeSplitTabbedText(
        @"// #tab image\r\nA\r\nB\r\n// #tab common\r\nC\r\n", KnownTabs());
    KKRequireEqual(crlf[@"Image"], @"A\nB", @"CRLF normalises to LF");
    KKRequireEqual(crlf[@"Common"], @"C", @"and the second tab still lands");

    // The Option-click export round-trips: what Copy Schema puts on the
    // clipboard, fed back through the split, is the editor's own tabs.
    NSArray<NSDictionary<NSString *, NSString *> *> *sections = @[
      @{
        @"name" : @"Image",
        @"code" : @"// #template filter\n"
                  @"uniform float uAmount;\n"
                  @"void mainImage(out vec4 O, in vec2 I) {\n"
                  @"  O = texture(iChannel0, I / iResolution.xy) * uAmount;\n"
                  @"}"
      },
      @{
        @"name" : @"Common",
        @"code" : @"#define TAU 6.283185\nfloat sq(float "
                  @"x) { return x * x; }"
      },
      @{
        @"name" : @"Buffer A",
        @"code" : @"void mainImage(out vec4 O, in vec2 I) {\n"
                  @"  O = vec4(sq(I.x / iResolution.x), 0.0, 0.0, 1.0);\n"
                  @"}"
      },
    ];
    NSString *refPath = [NSString
        stringWithFormat:@"%s/../Mirage/Resources/AIKnowledge/directives.md",
                         getenv("MIRAGE_TESTS_DIR") ?: "."];
    NSURL *refURL = [NSURL fileURLWithPath:refPath];
    NSString *doc = MirageSchemaDocument(refURL, sections);
    KKRequire(doc.length > 0, @"the schema document composes");
    if (doc.length) {
      KKRequire([doc rangeOfString:@"## Current template"].location !=
                    NSNotFound,
                @"the export keeps the Current template heading");
      // The template blob is everything from its first marker to the end.
      NSRange head = [doc rangeOfString:@"## Current template"];
      KKRequire([doc rangeOfString:@"```glsl"
                           options:0
                             range:NSMakeRange(NSMaxRange(head),
                                               doc.length - NSMaxRange(head))]
                        .location == NSNotFound,
                @"the export is a flat blob, not fenced sections");
      NSRange first =
          [doc rangeOfString:@"\n// #tab "
                     options:0
                       range:NSMakeRange(NSMaxRange(head),
                                         doc.length - NSMaxRange(head))];
      KKRequire(first.location != NSNotFound,
                @"the export carries `// #tab` markers");
      if (first.location != NSNotFound) {
        NSString *exported = [doc substringFromIndex:first.location + 1];
        NSDictionary<NSString *, NSString *> *back =
            KKCodeSplitTabbedText(exported, KnownTabs());
        KKRequire(back.count == sections.count,
                  @"the export splits back into the same tab count");
        for (NSDictionary<NSString *, NSString *> *s in sections)
          KKRequireEqual(
              back[s[@"name"]], s[@"code"],
              [NSString stringWithFormat:@"%@ round-trips byte for byte",
                                         s[@"name"]]);
      }
    }

    // The AI code route's own round trip: lane sections out as a blob, the
    // blob back through the split, the split merged onto the lane's tabs.
    NSString *laneImage = sections[0][@"code"];
    NSArray<NSDictionary<NSString *, NSString *> *> *laneTabs =
        [sections subarrayWithRange:NSMakeRange(1, sections.count - 1)];
    NSString *aiBlob = MirageShaderTabsBlob(laneImage, laneTabs);
    NSDictionary<NSString *, NSString *> *aiSplit =
        KKCodeSplitTabbedText(aiBlob, KnownTabs());
    KKRequire(aiSplit.count == sections.count,
              @"the lane exports every section as its own tab");
    KKRequireEqual(aiSplit[@"Image"], laneImage,
                   @"the Image section round-trips byte for byte");
    for (NSDictionary<NSString *, NSString *> *t in laneTabs)
      KKRequireEqual(aiSplit[t[@"name"]], t[@"code"],
                     [NSString stringWithFormat:@"%@ round-trips byte for byte",
                                                t[@"name"]]);
    NSArray<NSDictionary<NSString *, NSString *> *> *merged =
        MirageShaderTabsMerged(laneTabs, aiSplit, KnownTabs());
    KKRequire([merged isEqualToArray:laneTabs],
              @"merging a shader back onto itself changes nothing");

    // A single-pass lane exports no marker at all, so nothing splits and the
    // whole answer is the Image source.
    KKRequireEqual(MirageShaderTabsBlob(laneImage, @[]), laneImage,
                   @"a single-section lane exports the bare Image source");
    KKRequire(KKCodeSplitTabbedText(MirageShaderTabsBlob(laneImage, nil),
                                    KnownTabs()) == nil,
              @"and that export is an ordinary paste, not a tab blob");

    // An answer that adds Buffer B: it lands in CATALOG order (after Buffer A),
    // rewrites the tab it names, and leaves the tab it didn't mention alone.
    NSDictionary<NSString *, NSString *> *addSplit = @{
      @"Image" : @"new image",
      @"Buffer B" : @"new buffer b",
      @"Buffer A" : @"rewritten buffer a"
    };
    NSArray<NSDictionary<NSString *, NSString *> *> *grown =
        MirageShaderTabsMerged(laneTabs, addSplit, KnownTabs());
    KKRequire(grown.count == 3, @"the new tab is added, not swapped in");
    KKRequireEqual(grown[0][@"name"], @"Common",
                   @"the untouched tab keeps its place");
    KKRequireEqual(grown[0][@"code"], laneTabs[0][@"code"],
                   @"and a tab the answer omitted keeps its code");
    KKRequireEqual(grown[1][@"name"], @"Buffer A", @"Buffer A stays second");
    KKRequireEqual(grown[1][@"code"], @"rewritten buffer a",
                   @"a named tab is replaced");
    KKRequireEqual(grown[2][@"name"], @"Buffer B",
                   @"a new tab lands in catalog order");

    // An answer with no extra sections at all leaves the multi-pass lane's
    // tabs intact - only the Image source it did send changes.
    KKRequire([MirageShaderTabsMerged(laneTabs, @{@"Image" : @"only image"},
                                      KnownTabs()) isEqualToArray:laneTabs],
              @"an Image-only answer never drops the other passes");

    if (gFailures) {
      printf("%d failure(s)\n", gFailures);
      return 1;
    }
    printf("all tab-interchange tests passed\n");
    return 0;
  }
}
