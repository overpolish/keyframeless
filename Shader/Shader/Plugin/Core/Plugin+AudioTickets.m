/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderDirectives.h"

// Where Shader keeps its Sonar tickets.
//
// The kit owns what a ticket IS and how a source is named (KKSonarTicket.h).
// All that is left for a consumer is where to put the bytes, which is the one
// question each plugin has to answer for itself.
//
// WHY A STRING PARAM, NOT A BLOB
//
// A ticket describes something Sonar published. It is not a decision the user
// made, so it has no business on the undo stack. String writes are the one
// param write FCP keeps off it (KKDataBlob.h explains that blobs exist
// *because* string writes aren't undoable - here that liability is the
// feature). Store tickets in the undoable kParamUIState instead and picking a
// source registers a second undo entry beside the lane change: the first cmd-Z
// would quietly drop a ticket and look like it did nothing at all.
//
// WHY KEYED BY SOURCE KEY, NOT BY UNIFORM
//
// The lane is the only authority on what is bound. This map only says what a
// key meant when we last saw it. Keying by uniform would let the two disagree -
// bind Music, bind Dialogue, undo, and the lane says Music while the uniform's
// ticket says Dialogue, so the badge would name the wrong source. A key cannot
// be misread, so a stale entry an undo left behind is inert rather than wrong.
// That is what makes a store this far outside the undo stack safe.

static NSString *ShaderTicketMapKey(double key) {
  return [NSString stringWithFormat:@"%ld", lround(key)];
}

static NSDictionary<NSString *, id> *
ShaderReadTicketMap(id<FxParameterRetrievalAPI_v6> getAPI) {
  if (!getAPI) {
    return @{};
  }
  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kParamAudioTickets];
  if (!json.length) {
    return @{};
  }
  NSDictionary *map = [NSJSONSerialization
      JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                 options:0
                   error:nil];
  return [map isKindOfClass:NSDictionary.class] ? map : @{};
}

/// Every non-zero key the shader's `#audio` lanes are currently bound to.
///
/// Read at fraction 0 because a source selection is structural - it has the
/// same value everywhere on the timeline, so there is no "when" to ask about.
static NSArray<NSNumber *> *ShaderBoundAudioKeys(NSString *source,
                                                 KKTimeline *timeline) {
  ShaderAudioProp props[KK_SHADER_MAX_AUDIO_PROPS];
  int used = 0;
  int nProps =
      ShaderParseAudioProps(source, props, KK_SHADER_MAX_AUDIO_PROPS, 0, &used);
  NSMutableArray<NSNumber *> *keys = [NSMutableArray array];
  for (int i = 0; i < nProps; i++) {
    NSString *uniform = @(props[i].name);
    for (KKLane *lane in timeline.lanes) {
      if (![lane.label isEqualToString:uniform]) {
        continue;
      }
      NSArray<NSNumber *> *values =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, 0.0);
      if (values.count && lround(values[0].doubleValue) != 0) {
        [keys addObject:values[0]];
      }
      break;
    }
  }
  return keys;
}

@implementation ShaderPlugin (AudioTickets)

- (void)syncAudioTicketsForTimeline:(KKTimeline *)timeline {
  if (!timeline) {
    return;
  }
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI) {
    return;
  }
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  NSString *source = [ShaderPlugin shaderSourceFromTimeline:timeline];
  NSArray<NSNumber *> *bound = ShaderBoundAudioKeys(source, timeline);
  NSDictionary<NSString *, id> *existing = ShaderReadTicketMap(getAPI);
  // Cached even when there's nothing to sync: the lane builder reads this from
  // callbacks where the param APIs don't resolve, and it needs the tickets a
  // saved project arrived with, not just ones minted this session.
  self.audioTickets = existing;
  if (bound.count == 0) {
    [actionAPI endAction:self];
    return;
  }

  NSArray<NSDictionary<NSString *, id> *> *published =
      KKSpectrogramPublishedSources();
  NSMutableDictionary<NSString *, id> *merged = [existing mutableCopy];

  for (NSNumber *key in bound) {
    NSDictionary<NSString *, id> *entry =
        KKSonarSourceForKey(key.doubleValue, published);
    if (!entry) {
      // Bound to something not published here. This is the case the whole
      // feature exists for, and the ticket we already hold is the only record
      // of what it was - so leave it exactly where it is, and ask Sonar for it.
      // Nothing is awaited: the note simply waits in the container until the
      // project is next dropped on Sonar, which may be never.
      NSDictionary<NSString *, id> *ticket =
          merged[ShaderTicketMapKey(key.doubleValue)];
      if (ticket) {
        KKSonarWriteRepublishRequest(ticket);
      }
      continue;
    }
    NSDictionary<NSString *, id> *ticket = KKSonarTicketForSource(entry);
    if (ticket) {
      // Refreshed rather than only added: a rename in Sonar keeps the content
      // hash, so the key survives while the name it should show changes.
      merged[ShaderTicketMapKey(key.doubleValue)] = ticket;
      // It's here now, so nothing is owed. Clears a request this instance (or
      // another clip bound to the same source) raised before the republish.
      KKSonarClearRepublishRequest(key.doubleValue);
    }
  }

  // Never pruned. An entry costs a few dozen bytes and is only ever read by
  // exact key, whereas dropping one loses the only description of a source
  // that may not exist on this Mac to look up again.
  if (![merged isEqualToDictionary:existing]) {
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSData *data = [NSJSONSerialization dataWithJSONObject:merged
                                                   options:0
                                                     error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data
                                                  encoding:NSUTF8StringEncoding]
                          : nil;
    if (json.length) {
      [setAPI setStringParameterValue:json toParameter:kParamAudioTickets];
      self.audioTickets = merged;
    }
  }
  [actionAPI endAction:self];
}

@end
