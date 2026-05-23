/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCanvasStore.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <os/lock.h>

@implementation KKCanvasStoreSnapshot
@end

@interface KKStoreObserverEntry : NSObject
@property(nonatomic) KKStoreChange mask;
@property(nonatomic, copy) KKStoreObserverBlock block;
@end

@implementation KKStoreObserverEntry
@end

@implementation KKCanvasStore {
  os_unfair_lock _lock;

  // Mutable state - only access under _lock.
  NSArray<KKBezierPath *> *_paths;
  NSIndexSet *_selectedIndices;
  BOOL _soloActive;
  BOOL _isEditing;
  BOOL _isDragging;
  NSSet<NSString *> *_collapsedGroupIDs;
  BOOL _strokeExpanded;
  BOOL _fillExpanded;
  BOOL _sketchExpanded;
  BOOL _transformExpanded;
  BOOL _forceShow;

  // Derived from selected path.
  BOOL _hasSelectedPath;
  BOOL _selectedPathOpen;
  BOOL _selectedPathHasJoins;
  BOOL _strokeEnabled;
  BOOL _fillEnabled;
  BOOL _sketchEnabled;
  BOOL _transformEnabled;
  uint8_t _lineCap;
  uint8_t _lineJoin;
  uint8_t _strokeStyle;
  uint8_t _startMarker;
  uint8_t _endMarker;
  uint8_t _fillStyle;
  NSInteger _selectedLineCap;
  NSInteger _selectedLineJoin;
  NSInteger _selectedStrokeStyle;
  NSInteger _selectedStartMarker;
  NSInteger _selectedEndMarker;
  NSInteger _selectedFillStyle;
  uint8_t _strokeColorMode;
  uint8_t _fillColorMode;
  uint8_t _strokeGradientType;
  uint8_t _fillGradientType;

  // Observers.
  NSMutableArray<KKStoreObserverEntry *> *_observers;

  // Coalescing.
  KKStoreChange _pendingChanges;
  BOOL _notificationScheduled;

  // Snapshot before batch (for diffing).
  KKCanvasStoreSnapshot *_beforeBatch;
}

- (instancetype)initWithUUID:(NSString *)uuid {
  self = [super init];
  if (self) {
    _uuid = [uuid copy];
    _lock = OS_UNFAIR_LOCK_INIT;
    _paths = @[];
    _selectedIndices = [NSIndexSet indexSet];
    _collapsedGroupIDs = [NSSet set];
    _observers = [NSMutableArray array];
    _strokeEnabled =
        YES; // Match FxPlug default (addToggleButton defaultValue:YES).
    _transformEnabled = YES;
    _selectedLineCap = -1;
    _selectedLineJoin = -1;
    _selectedStrokeStyle = -1;
    _selectedStartMarker = -1;
    _selectedEndMarker = -1;
    _selectedFillStyle = 0;
    _strokeGradientType = 1;
    _fillGradientType = 1;
  }
  return self;
}

- (KKCanvasStoreSnapshot *)_createSnapshotLocked {
  KKCanvasStoreSnapshot *s = [[KKCanvasStoreSnapshot alloc] init];
  // Use KVC to set readonly properties on the snapshot.
  [s setValue:[_paths copy] forKey:@"paths"];
  [s setValue:[_selectedIndices copy] forKey:@"selectedIndices"];
  [s setValue:@(_soloActive) forKey:@"soloActive"];
  [s setValue:@(_isEditing) forKey:@"isEditing"];
  [s setValue:@(_isDragging) forKey:@"isDragging"];
  [s setValue:[_collapsedGroupIDs copy] forKey:@"collapsedGroupIDs"];
  [s setValue:@(_hasSelectedPath) forKey:@"hasSelectedPath"];
  [s setValue:@(_selectedPathOpen) forKey:@"selectedPathOpen"];
  [s setValue:@(_selectedPathHasJoins) forKey:@"selectedPathHasJoins"];
  [s setValue:@(_strokeEnabled) forKey:@"strokeEnabled"];
  [s setValue:@(_fillEnabled) forKey:@"fillEnabled"];
  [s setValue:@(_sketchEnabled) forKey:@"sketchEnabled"];
  [s setValue:@(_transformEnabled) forKey:@"transformEnabled"];
  [s setValue:@(_strokeExpanded) forKey:@"strokeExpanded"];
  [s setValue:@(_fillExpanded) forKey:@"fillExpanded"];
  [s setValue:@(_sketchExpanded) forKey:@"sketchExpanded"];
  [s setValue:@(_transformExpanded) forKey:@"transformExpanded"];
  [s setValue:@(_lineCap) forKey:@"lineCap"];
  [s setValue:@(_lineJoin) forKey:@"lineJoin"];
  [s setValue:@(_strokeStyle) forKey:@"strokeStyle"];
  [s setValue:@(_startMarker) forKey:@"startMarker"];
  [s setValue:@(_endMarker) forKey:@"endMarker"];
  [s setValue:@(_fillStyle) forKey:@"fillStyle"];
  [s setValue:@(_selectedLineCap) forKey:@"selectedLineCap"];
  [s setValue:@(_selectedLineJoin) forKey:@"selectedLineJoin"];
  [s setValue:@(_selectedStrokeStyle) forKey:@"selectedStrokeStyle"];
  [s setValue:@(_selectedStartMarker) forKey:@"selectedStartMarker"];
  [s setValue:@(_selectedEndMarker) forKey:@"selectedEndMarker"];
  [s setValue:@(_selectedFillStyle) forKey:@"selectedFillStyle"];
  [s setValue:@(_forceShow) forKey:@"forceShow"];
  [s setValue:@(_strokeColorMode) forKey:@"strokeColorMode"];
  [s setValue:@(_fillColorMode) forKey:@"fillColorMode"];
  [s setValue:@(_strokeGradientType) forKey:@"strokeGradientType"];
  [s setValue:@(_fillGradientType) forKey:@"fillGradientType"];
  return s;
}

- (KKCanvasStoreSnapshot *)snapshot {
  os_unfair_lock_lock(&_lock);
  KKCanvasStoreSnapshot *s = [self _createSnapshotLocked];
  os_unfair_lock_unlock(&_lock);
  return s;
}

- (void)performBatch:(void (^)(void))block {
  os_unfair_lock_lock(&_lock);
  _beforeBatch = [self _createSnapshotLocked];
  os_unfair_lock_unlock(&_lock);

  block();

  os_unfair_lock_lock(&_lock);
  KKCanvasStoreSnapshot *after = [self _createSnapshotLocked];
  KKStoreChange changes = [self _diffBefore:_beforeBatch after:after];
  _beforeBatch = nil;

  if (changes != KKStoreChangeNone) {
    _pendingChanges |= changes;
    if (!_notificationScheduled) {
      _notificationScheduled = YES;
      NSArray<KKStoreObserverEntry *> *observers = [_observers copy];
      os_unfair_lock_unlock(&_lock);

      dispatch_async(dispatch_get_main_queue(), ^{
        os_unfair_lock_lock(&self->_lock);
        KKStoreChange pending = self->_pendingChanges;
        self->_pendingChanges = KKStoreChangeNone;
        self->_notificationScheduled = NO;
        KKCanvasStoreSnapshot *snap = [self _createSnapshotLocked];
        os_unfair_lock_unlock(&self->_lock);

        for (KKStoreObserverEntry *entry in observers) {
          if (entry.mask & pending)
            entry.block(snap, pending & entry.mask);
        }
      });
    } else {
      os_unfair_lock_unlock(&_lock);
    }
  } else {
    os_unfair_lock_unlock(&_lock);
  }
}

- (KKStoreChange)_diffBefore:(KKCanvasStoreSnapshot *)b
                       after:(KKCanvasStoreSnapshot *)a {
  KKStoreChange ch = KKStoreChangeNone;

  if (b.paths.count != a.paths.count)
    ch |= KKStoreChangePaths;
  else {
    for (NSUInteger i = 0; i < a.paths.count; i++) {
      if (b.paths[i] != a.paths[i]) {
        ch |= KKStoreChangePaths;
        break;
      }
    }
  }

  if (![b.selectedIndices isEqualToIndexSet:a.selectedIndices])
    ch |= KKStoreChangeSelection;

  if (b.soloActive != a.soloActive)
    ch |= KKStoreChangeSolo;

  if (b.isEditing != a.isEditing || b.isDragging != a.isDragging)
    ch |= KKStoreChangeEditing;

  if (![b.collapsedGroupIDs isEqualToSet:a.collapsedGroupIDs])
    ch |= KKStoreChangeCollapse;

  if (b.strokeExpanded != a.strokeExpanded ||
      b.fillExpanded != a.fillExpanded ||
      b.sketchExpanded != a.sketchExpanded ||
      b.transformExpanded != a.transformExpanded)
    ch |= KKStoreChangeExpanded;

  // Check visibility (hidden/locked on paths).
  if (!(ch & KKStoreChangePaths) && a.paths.count > 0) {
    for (NSUInteger i = 0; i < a.paths.count; i++) {
      if (a.paths[i].hidden != b.paths[i].hidden ||
          a.paths[i].locked != b.paths[i].locked) {
        ch |= KKStoreChangeVisibility;
        break;
      }
    }
  } else if (ch & KKStoreChangePaths) {
    ch |= KKStoreChangeVisibility;
  }

  if (b.hasSelectedPath != a.hasSelectedPath ||
      b.strokeEnabled != a.strokeEnabled || b.fillEnabled != a.fillEnabled ||
      b.sketchEnabled != a.sketchEnabled ||
      b.transformEnabled != a.transformEnabled ||
      b.selectedPathOpen != a.selectedPathOpen ||
      b.selectedPathHasJoins != a.selectedPathHasJoins ||
      b.lineCap != a.lineCap || b.lineJoin != a.lineJoin ||
      b.strokeStyle != a.strokeStyle || b.startMarker != a.startMarker ||
      b.endMarker != a.endMarker || b.fillStyle != a.fillStyle ||
      b.forceShow != a.forceShow || b.selectedLineCap != a.selectedLineCap ||
      b.selectedLineJoin != a.selectedLineJoin ||
      b.selectedStrokeStyle != a.selectedStrokeStyle ||
      b.selectedStartMarker != a.selectedStartMarker ||
      b.selectedEndMarker != a.selectedEndMarker ||
      b.selectedFillStyle != a.selectedFillStyle ||
      b.strokeColorMode != a.strokeColorMode ||
      b.fillColorMode != a.fillColorMode ||
      b.strokeGradientType != a.strokeGradientType ||
      b.fillGradientType != a.fillGradientType)
    ch |= KKStoreChangePathProps;

  return ch;
}

// --- Mutators ---

- (void)setPaths:(NSArray<KKBezierPath *> *)paths {
  os_unfair_lock_lock(&_lock);
  _paths = [paths copy];
  os_unfair_lock_unlock(&_lock);
}

- (void)setSelectedIndices:(NSIndexSet *)indices {
  os_unfair_lock_lock(&_lock);
  _selectedIndices = [indices copy];
  os_unfair_lock_unlock(&_lock);
}

- (void)setSoloActive:(BOOL)active {
  os_unfair_lock_lock(&_lock);
  _soloActive = active;
  os_unfair_lock_unlock(&_lock);
}

- (void)setEditing:(BOOL)editing {
  os_unfair_lock_lock(&_lock);
  _isEditing = editing;
  os_unfair_lock_unlock(&_lock);
}

- (void)setDragging:(BOOL)dragging {
  os_unfair_lock_lock(&_lock);
  _isDragging = dragging;
  os_unfair_lock_unlock(&_lock);
}

- (void)setCollapsedGroupIDs:(NSSet<NSString *> *)ids {
  os_unfair_lock_lock(&_lock);
  _collapsedGroupIDs = [ids copy];
  os_unfair_lock_unlock(&_lock);
}

- (void)setStrokeExpanded:(BOOL)expanded {
  os_unfair_lock_lock(&_lock);
  _strokeExpanded = expanded;
  os_unfair_lock_unlock(&_lock);
}

- (void)setFillExpanded:(BOOL)expanded {
  os_unfair_lock_lock(&_lock);
  _fillExpanded = expanded;
  os_unfair_lock_unlock(&_lock);
}

- (void)setSketchExpanded:(BOOL)expanded {
  os_unfair_lock_lock(&_lock);
  _sketchExpanded = expanded;
  os_unfair_lock_unlock(&_lock);
}

- (void)setTransformExpanded:(BOOL)expanded {
  os_unfair_lock_lock(&_lock);
  _transformExpanded = expanded;
  os_unfair_lock_unlock(&_lock);
}

- (void)setForceShow:(BOOL)forceShow {
  os_unfair_lock_lock(&_lock);
  _forceShow = forceShow;
  os_unfair_lock_unlock(&_lock);
}

- (void)setStrokeEnabled:(BOOL)enabled {
  os_unfair_lock_lock(&_lock);
  _strokeEnabled = enabled;
  os_unfair_lock_unlock(&_lock);
}

- (void)setFillEnabled:(BOOL)enabled {
  os_unfair_lock_lock(&_lock);
  _fillEnabled = enabled;
  os_unfair_lock_unlock(&_lock);
}

- (void)setSketchEnabled:(BOOL)enabled {
  os_unfair_lock_lock(&_lock);
  _sketchEnabled = enabled;
  os_unfair_lock_unlock(&_lock);
}

- (void)setTransformEnabled:(BOOL)enabled {
  os_unfair_lock_lock(&_lock);
  _transformEnabled = enabled;
  os_unfair_lock_unlock(&_lock);
}

- (void)setStrokeColorMode:(uint8_t)mode {
  os_unfair_lock_lock(&_lock);
  _strokeColorMode = mode;
  os_unfair_lock_unlock(&_lock);
}

- (void)setFillColorMode:(uint8_t)mode {
  os_unfair_lock_lock(&_lock);
  _fillColorMode = mode;
  os_unfair_lock_unlock(&_lock);
}

- (void)setStrokeGradientType:(uint8_t)t {
  os_unfair_lock_lock(&_lock);
  _strokeGradientType = t;
  os_unfair_lock_unlock(&_lock);
}

- (void)setFillGradientType:(uint8_t)t {
  os_unfair_lock_lock(&_lock);
  _fillGradientType = t;
  os_unfair_lock_unlock(&_lock);
}

- (void)syncSelectedPathProperties {
  os_unfair_lock_lock(&_lock);

  _hasSelectedPath = NO;
  _selectedPathOpen = NO;
  _selectedPathHasJoins = NO;
  // NOTE: do NOT reset strokeEnabled/fillEnabled/sketchEnabled here.
  // When no path is selected these are set by the producer (drawOSC)
  // from FxPlug params, so the inspector acts as "defaults for next shape".
  _selectedLineCap = -1;
  _selectedLineJoin = -1;
  _selectedStrokeStyle = -1;
  _selectedStartMarker = -1;
  _selectedEndMarker = -1;
  _selectedFillStyle = 0;

  for (NSUInteger i = 0; i < _paths.count; i++) {
    if ([_selectedIndices containsIndex:i] && !_paths[i].isGroup) {
      KKBezierPath *p = _paths[i];
      _hasSelectedPath = YES;
      // NOTE: strokeEnabled/fillEnabled/sketchEnabled are NOT set here.
      // They come from FxPlug params (set by drawOSC or header callbacks)
      // which are authoritative. The path blob may be stale for one frame.
      _lineCap = p.lineCap;
      _lineJoin = p.lineJoin;
      _strokeStyle = p.strokeStyle;
      _startMarker = p.startMarker;
      _endMarker = p.endMarker;
      _fillStyle = (uint8_t)p.sketchFillStyle;
      _selectedPathOpen = !p.closed;
      _selectedPathHasJoins = (p.count > 2);

      if (!p.closed) {
        _selectedLineCap = p.lineCap;
        _selectedStartMarker = p.startMarker;
        _selectedEndMarker = p.endMarker;
      }
      if (p.count > 2)
        _selectedLineJoin = p.lineJoin;
      _selectedStrokeStyle = p.strokeStyle;
      _selectedFillStyle = p.sketchFillStyle;
      _strokeColorMode = p.strokeColorMode;
      _fillColorMode = p.fillColorMode;
      _strokeGradientType = p.strokeGradientType;
      _fillGradientType = p.fillGradientType;
      break;
    }
  }

  os_unfair_lock_unlock(&_lock);
}

// --- Observation ---

- (id)addObserverForChanges:(KKStoreChange)mask
                      block:(KKStoreObserverBlock)block {
  KKStoreObserverEntry *entry = [[KKStoreObserverEntry alloc] init];
  entry.mask = mask;
  entry.block = block;
  os_unfair_lock_lock(&_lock);
  [_observers addObject:entry];
  os_unfair_lock_unlock(&_lock);
  return entry;
}

- (void)removeObserver:(id)token {
  os_unfair_lock_lock(&_lock);
  [_observers removeObjectIdenticalTo:token];
  os_unfair_lock_unlock(&_lock);
}

@end
