/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKBezierPath.h"

static const NSUInteger kArcLengthSamples = 64;

static simd_float2 evalCubicBezier(simd_float2 p0, simd_float2 c0,
                                   simd_float2 c1, simd_float2 p1, float t) {
  float u = 1.0f - t;
  return u * u * u * p0 + 3.0f * u * u * t * c0 + 3.0f * u * t * t * c1 +
         t * t * t * p1;
}

@implementation KKBezierPath {
  KKBezierPoint *_points;
  NSUInteger _count;
  NSUInteger _capacity;
  NSUInteger *_contourStarts;
  NSUInteger _contourCount;
  NSUInteger _contourCapacity;
}

+ (instancetype)pathWithData:(NSData *)data {
  KKBezierPath *path = [[KKBezierPath alloc] init];
  if (data.length >= 4) {
    const uint8_t *bytes = data.bytes;
    uint32_t count;
    memcpy(&count, bytes, 4);
    size_t pointSize = sizeof(KKBezierPoint);

    // New format: 4 bytes count + 1 byte flags + points
    size_t newExpected = 5 + count * pointSize;
    // Old format: 4 bytes count + points (no flags)

    BOOL maybeGroup = (data.length >= 5 && (bytes[4] & 128) != 0);
    if (data.length >= newExpected && (count > 0 || maybeGroup)) {
      uint8_t flags = bytes[4];
      path->_closed = (flags & 1) != 0;
      path->_isLine = (flags & 2) != 0;
      path->_isRect = (flags & 8) != 0;
      path->_hidden = (flags & 16) != 0;
      path->_locked = (flags & 32) != 0;
      path->_isGroup = (flags & 128) != 0;
      size_t headerSize = 5;
      if (path->_isGroup && data.length >= 7) {
        uint16_t gidLen;
        memcpy(&gidLen, bytes + 5, 2);
        headerSize = 7;
        if (gidLen > 0 && data.length >= headerSize + gidLen) {
          path->_groupID =
              [[NSString alloc] initWithBytes:bytes + headerSize
                                       length:gidLen
                                     encoding:NSUTF8StringEncoding];
          headerSize += gidLen;
        }
      }
      path->_count = count;
      path->_capacity = count;
      if (count > 0) {
        path->_points = malloc(count * pointSize);
        memcpy(path->_points, bytes + headerSize, count * pointSize);
      }
      // Extended: corner radii after points
      size_t extOffset = headerSize + count * pointSize;
      if ((flags & 4) && data.length >= extOffset + 4 * sizeof(float)) {
        float cr[4];
        memcpy(cr, bytes + extOffset, 4 * sizeof(float));
        path->_cornerRadiusTL = cr[0];
        path->_cornerRadiusTR = cr[1];
        path->_cornerRadiusBR = cr[2];
        path->_cornerRadiusBL = cr[3];
        extOffset += 4 * sizeof(float);
      }
      if ((flags & 64) && data.length >= extOffset + 2) {
        uint16_t nameLen;
        memcpy(&nameLen, bytes + extOffset, 2);
        extOffset += 2;
        if (nameLen > 0 && data.length >= extOffset + nameLen) {
          path->_name = [[NSString alloc] initWithBytes:bytes + extOffset
                                                 length:nameLen
                                               encoding:NSUTF8StringEncoding];
          extOffset += nameLen;
        }
      }
      if (data.length >= extOffset + 2) {
        uint16_t pgidLen;
        memcpy(&pgidLen, bytes + extOffset, 2);
        extOffset += 2;
        if (pgidLen > 0 && data.length >= extOffset + pgidLen) {
          path->_parentGroupID =
              [[NSString alloc] initWithBytes:bytes + extOffset
                                       length:pgidLen
                                     encoding:NSUTF8StringEncoding];
          extOffset += pgidLen;
        }
      }
      // Per-object properties: marker 0xAA + version + data.
      if (data.length >= extOffset + 2 && bytes[extOffset] == 0xAA) {
        uint8_t ver = bytes[extOffset + 1];
        size_t hdr = extOffset + 2;
        if (ver >= 1 && data.length >= hdr + 4 * sizeof(float)) {
          float sd[4];
          memcpy(sd, bytes + hdr, 4 * sizeof(float));
          path->_strokeWidth = sd[0];
          path->_strokeR = sd[1];
          path->_strokeG = sd[2];
          path->_strokeB = sd[3];
          hdr += 4 * sizeof(float);
        }
        if (ver >= 1 && data.length >= hdr + 1 + 3 * sizeof(float)) {
          path->_fillEnabled = bytes[hdr] != 0;
          hdr += 1;
          float fd[3];
          memcpy(fd, bytes + hdr, 3 * sizeof(float));
          path->_fillR = fd[0];
          path->_fillG = fd[1];
          path->_fillB = fd[2];
          hdr += 3 * sizeof(float);
        }
        if (ver >= 2 && data.length >= hdr + sizeof(float)) {
          memcpy(&path->_opacity, bytes + hdr, sizeof(float));
          hdr += sizeof(float);
        }
        if (ver >= 3 && data.length >= hdr + 1) {
          path->_lineCap = bytes[hdr];
          hdr += 1;
        }
        if (ver >= 4 && data.length >= hdr + 1) {
          path->_strokeEnabled = bytes[hdr] != 0;
          hdr += 1;
        }
        if (ver >= 5 && data.length >= hdr + 1) {
          path->_lineJoin = bytes[hdr];
          hdr += 1;
        }
        if (ver >= 6 && data.length >= hdr + 1) {
          path->_strokeStyle = bytes[hdr];
          hdr += 1;
        }
        if (ver >= 7 && data.length >= hdr + 3 * sizeof(float)) {
          float dd[3];
          memcpy(dd, bytes + hdr, 3 * sizeof(float));
          path->_dashLength = dd[0];
          path->_dashGap = dd[1];
          path->_dotGap = dd[2];
          hdr += 3 * sizeof(float);
        }
        if (ver >= 8 &&
            data.length >= hdr + 1 + 2 * sizeof(float) + sizeof(uint32_t) + 2) {
          path->_sketchEnabled = bytes[hdr] != 0;
          hdr += 1;
          float sk[2];
          memcpy(sk, bytes + hdr, 2 * sizeof(float));
          path->_sketchRoughness = sk[0];
          path->_sketchBowing = sk[1];
          hdr += 2 * sizeof(float);
          memcpy(&path->_sketchSeed, bytes + hdr, sizeof(uint32_t));
          hdr += sizeof(uint32_t);
          path->_sketchStrokes = bytes[hdr];
          if (path->_sketchStrokes < 1)
            path->_sketchStrokes = 2;
          hdr += 1;
          path->_sketchFillStyle = bytes[hdr];
          hdr += 1;
          if (data.length >= hdr + 3 * sizeof(float)) {
            float fp[3];
            memcpy(fp, bytes + hdr, 3 * sizeof(float));
            path->_sketchFillGap = fp[0];
            path->_sketchFillAngle = fp[1];
            path->_sketchFillWeight = fp[2];
            hdr += 3 * sizeof(float);
          }
        }
        if (ver >= 9 && data.length >= hdr + 2) {
          path->_startMarker = bytes[hdr];
          hdr += 1;
          path->_endMarker = bytes[hdr];
          hdr += 1;
        }
        if (ver >= 10 && data.length >= hdr + 2 * sizeof(float)) {
          float ms[2];
          memcpy(ms, bytes + hdr, 2 * sizeof(float));
          path->_startMarkerSize = ms[0];
          path->_endMarkerSize = ms[1];
          hdr += 2 * sizeof(float);
        }
        if (ver >= 11 && data.length >= hdr + sizeof(float)) {
          memcpy(&path->_endWidth, bytes + hdr, sizeof(float));
          hdr += sizeof(float);
        }
        if (ver >= 12 && data.length >= hdr + 2) {
          uint16_t nc;
          memcpy(&nc, bytes + hdr, 2);
          hdr += 2;
          if (nc > 1 && data.length >= hdr + nc * sizeof(uint32_t)) {
            path->_contourCount = nc;
            path->_contourCapacity = nc;
            path->_contourStarts = malloc(nc * sizeof(NSUInteger));
            for (uint16_t ci = 0; ci < nc; ci++) {
              uint32_t idx;
              memcpy(&idx, bytes + hdr, sizeof(uint32_t));
              path->_contourStarts[ci] = idx;
              hdr += sizeof(uint32_t);
            }
          }
        }
        if (ver >= 13 && data.length >= hdr + 1) {
          path->_isImage = bytes[hdr] != 0;
          hdr += 1;
          if (path->_isImage && data.length >= hdr + 2) {
            uint16_t ipLen;
            memcpy(&ipLen, bytes + hdr, 2);
            hdr += 2;
            if (ipLen > 0 && data.length >= hdr + ipLen) {
              path->_imagePath =
                  [[NSString alloc] initWithBytes:bytes + hdr
                                           length:ipLen
                                         encoding:NSUTF8StringEncoding];
              hdr += ipLen;
            }
          }
        }
        if (ver >= 14 && data.length >= hdr + sizeof(float)) {
          memcpy(&path->_imageAspect, bytes + hdr, sizeof(float));
          hdr += sizeof(float);
        }
        if (ver >= 15 && data.length >= hdr + sizeof(float)) {
          memcpy(&path->_fillTint, bytes + hdr, sizeof(float));
          hdr += sizeof(float);
        }
        if (ver >= 16 && data.length >= hdr + 1 + 1 + sizeof(float) + 2) {
          path->_strokeColorMode = bytes[hdr];
          hdr += 1;
          path->_strokeGradientType = bytes[hdr];
          hdr += 1;
          memcpy(&path->_strokeGradientAngle, bytes + hdr, sizeof(float));
          hdr += sizeof(float);
          uint16_t sgLen;
          memcpy(&sgLen, bytes + hdr, 2);
          hdr += 2;
          if (sgLen > 0 && data.length >= hdr + sgLen) {
            path->_strokeGradientJSON =
                [[NSString alloc] initWithBytes:bytes + hdr
                                         length:sgLen
                                       encoding:NSUTF8StringEncoding];
            hdr += sgLen;
          }
          if (data.length >= hdr + 1 + 1 + sizeof(float) + 2) {
            path->_fillColorMode = bytes[hdr];
            hdr += 1;
            path->_fillGradientType = bytes[hdr];
            hdr += 1;
            memcpy(&path->_fillGradientAngle, bytes + hdr, sizeof(float));
            hdr += sizeof(float);
            uint16_t fgLen;
            memcpy(&fgLen, bytes + hdr, 2);
            hdr += 2;
            if (fgLen > 0 && data.length >= hdr + fgLen) {
              path->_fillGradientJSON =
                  [[NSString alloc] initWithBytes:bytes + hdr
                                           length:fgLen
                                         encoding:NSUTF8StringEncoding];
              hdr += fgLen;
            }
          }
        }
        if (ver >= 17 && data.length >= hdr + 2) {
          uint16_t lidLen;
          memcpy(&lidLen, bytes + hdr, 2);
          hdr += 2;
          if (lidLen > 0 && data.length >= hdr + lidLen) {
            path->_layerID =
                [[NSString alloc] initWithBytes:bytes + hdr
                                         length:lidLen
                                       encoding:NSUTF8StringEncoding];
            hdr += lidLen;
          }
        }
        if (ver >= 18 && data.length >= hdr + 2 * sizeof(float) + 1) {
          float tr[2];
          memcpy(tr, bytes + hdr, 2 * sizeof(float));
          path->_translateX = tr[0];
          path->_translateY = tr[1];
          hdr += 2 * sizeof(float);
          // Reserved byte (was transformOSCVisible — now a per-lane setting).
          hdr += 1;
        }
        if (ver >= 19 && data.length >= hdr + 1) {
          path->_transformEnabled = bytes[hdr] != 0;
          hdr += 1;
        }
        if (ver >= 20 && data.length >= hdr + 4 * sizeof(float)) {
          float sa[4];
          memcpy(sa, bytes + hdr, 4 * sizeof(float));
          path->_scaleX = sa[0];
          path->_scaleY = sa[1];
          path->_anchorX = sa[2];
          path->_anchorY = sa[3];
          hdr += 4 * sizeof(float);
        }
        if (ver >= 21 && data.length >= hdr + sizeof(float)) {
          memcpy(&path->_rotationZ, bytes + hdr, sizeof(float));
          hdr += sizeof(float);
        }
        if (ver >= 22 && data.length >= hdr + 2 * sizeof(float)) {
          float rxy[2];
          memcpy(rxy, bytes + hdr, 2 * sizeof(float));
          path->_rotationX = rxy[0];
          path->_rotationY = rxy[1];
          hdr += 2 * sizeof(float);
        }
        if (ver >= 23 && data.length >= hdr + 1) {
          path->_rotateWithMotion = bytes[hdr] != 0;
          hdr += 1;
        }
        if (ver >= 24 && data.length >= hdr + 2 * sizeof(float)) {
          float dro[2];
          memcpy(dro, bytes + hdr, 2 * sizeof(float));
          path->_drawOnStart = dro[0];
          path->_drawOnEnd = dro[1];
          hdr += 2 * sizeof(float);
        }
        if (ver >= 25 && data.length >= hdr + 2 * sizeof(float)) {
          float ants[2];
          memcpy(ants, bytes + hdr, 2 * sizeof(float));
          path->_marchingAntsOffset = ants[0];
          path->_marchingAntsSpeed = ants[1];
          hdr += 2 * sizeof(float);
        }
        if (ver >= 26 && data.length >= hdr + sizeof(float)) {
          memcpy(&path->_drawOnOrigin, bytes + hdr, sizeof(float));
          hdr += sizeof(float);
        }
        if (ver >= 27 && data.length >= hdr + 2) {
          uint16_t nTargets;
          memcpy(&nTargets, bytes + hdr, 2);
          hdr += 2;
          if (nTargets > 0) {
            NSMutableArray<NSData *> *targets =
                [NSMutableArray arrayWithCapacity:nTargets];
            for (uint16_t ti = 0; ti < nTargets; ti++) {
              if (data.length < hdr + 4)
                break;
              uint32_t blobLen;
              memcpy(&blobLen, bytes + hdr, 4);
              hdr += 4;
              if (blobLen == 0 || data.length < hdr + blobLen)
                break;
              [targets addObject:[NSData dataWithBytes:bytes + hdr
                                                length:blobLen]];
              hdr += blobLen;
            }
            path->_morphTargets = targets;
          }
        }
      }
    }
  }
  return path;
}

- (NSData *)dataRepresentation {
  uint32_t count = (uint32_t)_count;
  uint8_t flags = _closed ? 1 : 0;
  if (_isLine)
    flags |= 2;
  if (_isRect)
    flags |= 8;
  if (_hidden)
    flags |= 16;
  if (_locked)
    flags |= 32;
  if (_isGroup)
    flags |= 128;
  BOOL hasRadius = (_cornerRadiusTL > 0 || _cornerRadiusTR > 0 ||
                    _cornerRadiusBR > 0 || _cornerRadiusBL > 0);
  if (hasRadius)
    flags |= 4;
  NSData *nameData = [_name dataUsingEncoding:NSUTF8StringEncoding];
  if (nameData.length > 0)
    flags |= 64;
  NSData *groupIDData = [_groupID dataUsingEncoding:NSUTF8StringEncoding];
  NSData *parentGroupIDData =
      [_parentGroupID dataUsingEncoding:NSUTF8StringEncoding];
  size_t pointSize = sizeof(KKBezierPoint);
  NSMutableData *data = [NSMutableData dataWithCapacity:128];
  [data appendBytes:&count length:4];
  [data appendBytes:&flags length:1];
  if (_isGroup) {
    // Write groupID length-prefixed (replaces old childCount)
    uint16_t gidLen = (uint16_t)groupIDData.length;
    [data appendBytes:&gidLen length:2];
    if (gidLen > 0)
      [data appendData:groupIDData];
  }
  if (count > 0)
    [data appendBytes:_points length:count * pointSize];
  if (hasRadius) {
    float cr[4] = {_cornerRadiusTL, _cornerRadiusTR, _cornerRadiusBR,
                   _cornerRadiusBL};
    [data appendBytes:cr length:4 * sizeof(float)];
  }
  if (nameData.length > 0) {
    uint16_t nameLen = (uint16_t)nameData.length;
    [data appendBytes:&nameLen length:2];
    [data appendData:nameData];
  }
  // Always write parentGroupID (0 length = no parent)
  uint16_t pgidLen = (uint16_t)parentGroupIDData.length;
  [data appendBytes:&pgidLen length:2];
  if (pgidLen > 0)
    [data appendData:parentGroupIDData];
  // Per-object properties block: marker 0xAA + version + data.
  // v1: stroke (4 floats) + fill enabled (1 byte) + fill color (3 floats).
  // v2: + opacity (1 float).
  // v3: + lineCap (1 byte).
  // v4: + strokeEnabled (1 byte).
  // v5: + lineJoin (1 byte).
  // v6: + strokeStyle (1 byte).
  // v7: + dashLength, dashGap, dotGap (3 floats).
  // v8: + sketchEnabled (1 byte) + sketchRoughness, sketchBowing (2 floats).
  // v9: + startMarker (1 byte) + endMarker (1 byte).
  // v10: + startMarkerSize, endMarkerSize (2 floats).
  // v11: + endWidth (1 float).
  // v12: + contour starts (2-byte count + N × uint32 indices).
  uint8_t propMarker = 0xAA;
  uint8_t propVersion = 27;
  [data appendBytes:&propMarker length:1];
  [data appendBytes:&propVersion length:1];
  float strokeData[4] = {_strokeWidth, _strokeR, _strokeG, _strokeB};
  [data appendBytes:strokeData length:4 * sizeof(float)];
  uint8_t fillFlag = _fillEnabled ? 1 : 0;
  [data appendBytes:&fillFlag length:1];
  float fillData[3] = {_fillR, _fillG, _fillB};
  [data appendBytes:fillData length:3 * sizeof(float)];
  [data appendBytes:&_opacity length:sizeof(float)];
  [data appendBytes:&_lineCap length:1];
  uint8_t strokeFlag = _strokeEnabled ? 1 : 0;
  [data appendBytes:&strokeFlag length:1];
  [data appendBytes:&_lineJoin length:1];
  [data appendBytes:&_strokeStyle length:1];
  float dashData[3] = {_dashLength, _dashGap, _dotGap};
  [data appendBytes:dashData length:3 * sizeof(float)];
  uint8_t sketchFlag = _sketchEnabled ? 1 : 0;
  [data appendBytes:&sketchFlag length:1];
  float sketchData[2] = {_sketchRoughness, _sketchBowing};
  [data appendBytes:sketchData length:2 * sizeof(float)];
  [data appendBytes:&_sketchSeed length:sizeof(uint32_t)];
  [data appendBytes:&_sketchStrokes length:1];
  [data appendBytes:&_sketchFillStyle length:1];
  float fillParams[3] = {_sketchFillGap, _sketchFillAngle, _sketchFillWeight};
  [data appendBytes:fillParams length:3 * sizeof(float)];
  [data appendBytes:&_startMarker length:1];
  [data appendBytes:&_endMarker length:1];
  float markerSizes[2] = {_startMarkerSize, _endMarkerSize};
  [data appendBytes:markerSizes length:2 * sizeof(float)];
  [data appendBytes:&_endWidth length:sizeof(float)];
  uint16_t nc = (uint16_t)_contourCount;
  [data appendBytes:&nc length:2];
  if (nc > 1) {
    for (NSUInteger ci = 0; ci < nc; ci++) {
      uint32_t idx = (uint32_t)_contourStarts[ci];
      [data appendBytes:&idx length:sizeof(uint32_t)];
    }
  }
  // v13: isImage + imagePath
  uint8_t imageFlag = _isImage ? 1 : 0;
  [data appendBytes:&imageFlag length:1];
  if (_isImage) {
    NSData *ipData = [_imagePath dataUsingEncoding:NSUTF8StringEncoding];
    uint16_t ipLen = (uint16_t)ipData.length;
    [data appendBytes:&ipLen length:2];
    if (ipLen > 0)
      [data appendData:ipData];
  }
  // v14: imageAspect
  float aspect = _imageAspect;
  [data appendBytes:&aspect length:sizeof(float)];
  // v15: fillTint
  [data appendBytes:&_fillTint length:sizeof(float)];
  // v16: per-path stroke + fill gradient (mode, type, angle, JSON).
  [data appendBytes:&_strokeColorMode length:1];
  [data appendBytes:&_strokeGradientType length:1];
  [data appendBytes:&_strokeGradientAngle length:sizeof(float)];
  NSData *sgData = [_strokeGradientJSON dataUsingEncoding:NSUTF8StringEncoding];
  uint16_t sgLen = (uint16_t)sgData.length;
  [data appendBytes:&sgLen length:2];
  if (sgLen > 0)
    [data appendData:sgData];
  [data appendBytes:&_fillColorMode length:1];
  [data appendBytes:&_fillGradientType length:1];
  [data appendBytes:&_fillGradientAngle length:sizeof(float)];
  NSData *fgData = [_fillGradientJSON dataUsingEncoding:NSUTF8StringEncoding];
  uint16_t fgLen = (uint16_t)fgData.length;
  [data appendBytes:&fgLen length:2];
  if (fgLen > 0)
    [data appendData:fgData];
  // v17: layerID (length-prefixed UTF-8 UUID).
  NSData *lidData = [_layerID dataUsingEncoding:NSUTF8StringEncoding];
  uint16_t lidLen = (uint16_t)lidData.length;
  [data appendBytes:&lidLen length:2];
  if (lidLen > 0)
    [data appendData:lidData];
  // v18: translateX, translateY (2 floats) + 1 reserved byte
  // (was transformOSCVisible — now driven by per-lane sequencer toggle).
  float tr[2] = {_translateX, _translateY};
  [data appendBytes:tr length:2 * sizeof(float)];
  uint8_t reserved = 0;
  [data appendBytes:&reserved length:1];
  // v19: transformEnabled (1 byte).
  uint8_t txEnFlag = _transformEnabled ? 1 : 0;
  [data appendBytes:&txEnFlag length:1];
  // v20: scaleX, scaleY, anchorX, anchorY (4 floats).
  float sa[4] = {_scaleX, _scaleY, _anchorX, _anchorY};
  [data appendBytes:sa length:4 * sizeof(float)];
  // v21: rotationZ (1 float, radians).
  [data appendBytes:&_rotationZ length:sizeof(float)];
  // v22: rotationX, rotationY (2 floats, radians).
  float rxy[2] = {_rotationX, _rotationY};
  [data appendBytes:rxy length:2 * sizeof(float)];
  // v23: rotateWithMotion (1 byte).
  uint8_t rwmFlag = _rotateWithMotion ? 1 : 0;
  [data appendBytes:&rwmFlag length:1];
  // v24: drawOnStart, drawOnEnd (2 floats).
  float dro[2] = {_drawOnStart, _drawOnEnd};
  [data appendBytes:dro length:2 * sizeof(float)];
  // v25: marchingAntsOffset, marchingAntsSpeed (2 floats).
  float ants[2] = {_marchingAntsOffset, _marchingAntsSpeed};
  [data appendBytes:ants length:2 * sizeof(float)];
  // v26: drawOnOrigin (1 float).
  [data appendBytes:&_drawOnOrigin length:sizeof(float)];
  // v27: morph targets (uint16 count, then for each: uint32 blob length +
  // blob).
  uint16_t nTargets =
      (uint16_t)MIN((NSUInteger)UINT16_MAX, _morphTargets.count);
  [data appendBytes:&nTargets length:2];
  for (uint16_t ti = 0; ti < nTargets; ti++) {
    NSData *blob = _morphTargets[ti];
    uint32_t blobLen = (uint32_t)blob.length;
    [data appendBytes:&blobLen length:4];
    if (blobLen > 0)
      [data appendData:blob];
  }
  return data;
}

+ (NSMutableArray<KKBezierPath *> *)pathsFromBlob:(NSData *)blob {
  if (!blob || blob.length < 4)
    return [NSMutableArray array];

  const uint8_t *bytes = blob.bytes;
  NSUInteger offset = 0;
  uint32_t pathCount;
  memcpy(&pathCount, bytes + offset, 4);
  offset += 4;

  if (pathCount > 10000 || offset + pathCount * 4 > blob.length) {
    KKBezierPath *single = [KKBezierPath pathWithData:blob];
    if (single && single.count > 0)
      return [NSMutableArray arrayWithObject:single];
    return [NSMutableArray array];
  }

  NSMutableArray *result = [NSMutableArray arrayWithCapacity:pathCount];
  for (uint32_t i = 0; i < pathCount; i++) {
    if (offset + 4 > blob.length)
      break;
    uint32_t len;
    memcpy(&len, bytes + offset, 4);
    offset += 4;
    if (offset + len > blob.length)
      break;
    NSData *pathData = [blob subdataWithRange:NSMakeRange(offset, len)];
    KKBezierPath *path = [KKBezierPath pathWithData:pathData];
    if (path)
      [result addObject:path];
    offset += len;
  }
  return result;
}

+ (NSData *)blobFromPaths:(NSArray<KKBezierPath *> *)paths {
  NSMutableData *blob = [NSMutableData data];
  uint32_t pathCount = (uint32_t)paths.count;
  [blob appendBytes:&pathCount length:4];
  for (KKBezierPath *path in paths) {
    NSData *pathData = [path dataRepresentation];
    uint32_t len = (uint32_t)pathData.length;
    [blob appendBytes:&len length:4];
    [blob appendData:pathData];
  }
  return blob;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _layerID = [[NSUUID UUID] UUIDString];
    _points = NULL;
    _count = 0;
    _capacity = 0;
    _strokeEnabled = YES;
    _transformEnabled = YES;
    _scaleX = 1.0f;
    _scaleY = 1.0f;
    // Anchor is an offset from the path's bbox center in object-space units;
    // (0, 0) means "pivot at bbox center" (the natural default).
    _anchorX = 0.0f;
    _anchorY = 0.0f;
    _strokeWidth = 8.0f;
    _strokeR = 1.0f;
    _strokeG = 0.0f;
    _strokeB = 0.0f;
    _opacity = 1.0f;
    _fillEnabled = NO;
    _fillR = 1.0f;
    _fillG = 1.0f;
    _fillB = 1.0f;
    _fillTint = 1.0f;
    _dashLength = 20.0f;
    _dashGap = 10.0f;
    _dotGap = 10.0f;
    _drawOnStart = 0.0f;
    _drawOnEnd = 1.0f;
    _drawOnOrigin = 0.0f;
    _marchingAntsOffset = 0.0f;
    _marchingAntsSpeed = 0.0f;
    _sketchEnabled = NO;
    _sketchRoughness = kSketchRoughnessDefault;
    _sketchBowing = kSketchBowingDefault;
    _sketchSeed = 0;
    _sketchStrokes = kSketchStrokesDefault;
    _sketchFillStyle = 0;
    _sketchFillGap = kSketchFillGapDefault;
    _sketchFillAngle = kSketchFillAngleDefault * (float)(M_PI / 180.0);
    _sketchFillWeight = kSketchFillWeightDefault;
    _startMarkerSize = 3.0f;
    _endMarkerSize = 3.0f;
    _endWidth = 0.0f;
    _strokeColorMode = 0;
    _strokeGradientType = 1;
    _strokeGradientAngle = 0.0f;
    _strokeGradientJSON = nil;
    _fillColorMode = 0;
    _fillGradientType = 1;
    _fillGradientAngle = 0.0f;
    _fillGradientJSON = nil;
  }
  return self;
}

- (void)dealloc {
  free(_points);
  free(_contourStarts);
}

- (NSUInteger)segmentCount {
  return _count + 1;
}

- (KKBezierPoint)pointAtIndex:(NSUInteger)index {
  return _points[index];
}

- (void)ensureCapacity:(NSUInteger)needed {
  if (_capacity >= needed)
    return;
  NSUInteger newCap = MAX(needed, _capacity * 2);
  if (newCap < 4)
    newCap = 4;
  _points = realloc(_points, newCap * sizeof(KKBezierPoint));
  _capacity = newCap;
}

- (void)insertAtIndex:(NSUInteger)index position:(simd_float2)pos {
  [self ensureCapacity:_count + 1];
  if (index < _count)
    memmove(&_points[index + 1], &_points[index],
            (_count - index) * sizeof(KKBezierPoint));
  _points[index] = (KKBezierPoint){
      .x = pos.x,
      .y = pos.y,
      .type = KKBezierPointLinear,
  };
  _count++;
}

- (void)removeAtIndex:(NSUInteger)index {
  if (index < _count - 1)
    memmove(&_points[index], &_points[index + 1],
            (_count - index - 1) * sizeof(KKBezierPoint));
  _count--;
}

- (void)setLinearPositions:(const simd_float2 *)positions
                     count:(NSUInteger)count
                    closed:(BOOL)closed {
  [self ensureCapacity:count];
  for (NSUInteger i = 0; i < count; i++) {
    _points[i] = (KKBezierPoint){
        .x = positions[i].x, .y = positions[i].y, .type = KKBezierPointLinear};
  }
  _count = count;
  _closed = closed;
  // Bulk geometry replacement invalidates the rect-style affordance — the
  // new shape isn't an axis-aligned rectangle anymore. Matches the
  // OSC point-edit codepath which clears isRect on per-point drag.
  _isRect = NO;
}

- (void)setBezierPoints:(const KKBezierPoint *)points
                  count:(NSUInteger)count
                 closed:(BOOL)closed {
  [self ensureCapacity:count];
  if (count > 0)
    memcpy(_points, points, count * sizeof(KKBezierPoint));
  _count = count;
  _closed = closed;
  _isRect = NO;
}

- (void)setContourStarts:(NSArray<NSNumber *> *)starts {
  // Strip a leading 0 if the caller included it — first contour always
  // starts at index 0 implicitly.
  NSUInteger leading =
      (starts.count > 0 && starts[0].unsignedIntegerValue == 0) ? 1 : 0;
  NSUInteger explicitCount =
      starts.count > leading ? starts.count - leading : 0;
  if (explicitCount == 0) {
    _contourCount = 0;
    return;
  }
  // _contourCount is the total contour count including the implicit first.
  NSUInteger total = explicitCount + 1;
  if (total > _contourCapacity) {
    _contourStarts = realloc(_contourStarts, total * sizeof(NSUInteger));
    _contourCapacity = total;
  }
  _contourStarts[0] = 0;
  for (NSUInteger i = 0; i < explicitCount; i++)
    _contourStarts[i + 1] = starts[leading + i].unsignedIntegerValue;
  _contourCount = total;
}

- (void)moveAtIndex:(NSUInteger)index to:(simd_float2)pos {
  _points[index].x = pos.x;
  _points[index].y = pos.y;
}

- (void)setInHandle:(simd_float2)offset atIndex:(NSUInteger)index {
  _points[index].inX = offset.x;
  _points[index].inY = offset.y;
}

- (void)setOutHandle:(simd_float2)offset atIndex:(NSUInteger)index {
  _points[index].outX = offset.x;
  _points[index].outY = offset.y;
}

- (void)setType:(KKBezierPointType)type atIndex:(NSUInteger)index {
  if (index < _count)
    _points[index].type = type;
}

- (void)translateBy:(simd_float2)delta {
  for (NSUInteger i = 0; i < _count; i++) {
    _points[i].x += delta.x;
    _points[i].y += delta.y;
  }
}

static void cornerRadii(float fraction, float maxRX, float maxRY, float objW,
                        float objH, float canvasW, float canvasH, float *outRX,
                        float *outRY) {
  float f = fmaxf(0.0f, fminf(fraction, 1.0f));
  if (f < 0.0001f) {
    *outRX = 0;
    *outRY = 0;
    return;
  }
  float maxPxX = (objW > 0.0001f) ? (maxRX / objW) * canvasW : 0;
  float maxPxY = (objH > 0.0001f) ? (maxRY / objH) * canvasH : 0;
  float maxPx = fmaxf(maxPxX, maxPxY);
  float pixelR = f * maxPx;
  *outRX = (canvasW > 0.0001f)
               ? fminf((fminf(pixelR, maxPxX) / canvasW) * objW, maxRX)
               : 0;
  *outRY = (canvasH > 0.0001f)
               ? fminf((fminf(pixelR, maxPxY) / canvasH) * objH, maxRY)
               : 0;
}

- (void)setRoundedRectWithMin:(simd_float2)min
                          max:(simd_float2)max
                   fractionTL:(float)ftl
                   fractionTR:(float)ftr
                   fractionBR:(float)fbr
                   fractionBL:(float)fbl
                  canvasWidth:(float)canvasW
                 canvasHeight:(float)canvasH {
  _cornerRadiusTL = fmaxf(0.0f, fminf(ftl, 1.0f));
  _cornerRadiusTR = fmaxf(0.0f, fminf(ftr, 1.0f));
  _cornerRadiusBR = fmaxf(0.0f, fminf(fbr, 1.0f));
  _cornerRadiusBL = fmaxf(0.0f, fminf(fbl, 1.0f));

  float maxRX = (max.x - min.x) * 0.5f;
  float maxRY = (max.y - min.y) * 0.5f;
  float objW = max.x - min.x;
  float objH = max.y - min.y;

  BOOL allZero = (_cornerRadiusTL < 0.0001f && _cornerRadiusTR < 0.0001f &&
                  _cornerRadiusBR < 0.0001f && _cornerRadiusBL < 0.0001f);
  if (allZero) {
    [self ensureCapacity:4];
    _count = 4;
    _points[0] = (KKBezierPoint){min.x, max.y, 0, 0, 0, 0, KKBezierPointLinear};
    _points[1] = (KKBezierPoint){max.x, max.y, 0, 0, 0, 0, KKBezierPointLinear};
    _points[2] = (KKBezierPoint){max.x, min.y, 0, 0, 0, 0, KKBezierPointLinear};
    _points[3] = (KKBezierPoint){min.x, min.y, 0, 0, 0, 0, KKBezierPointLinear};
    return;
  }

  // Compute per-corner rx/ry
  float rx[4], ry[4];
  float fracs[4] = {_cornerRadiusTL, _cornerRadiusTR, _cornerRadiusBR,
                    _cornerRadiusBL};
  for (int i = 0; i < 4; i++)
    cornerRadii(fracs[i], maxRX, maxRY, objW, objH, canvasW, canvasH, &rx[i],
                &ry[i]);

  // Build points: 2 per rounded corner, 1 per sharp corner
  KKBezierPoint tmp[12];
  NSUInteger n = 0;

  // TL corner (left side, then top side)
  if (rx[0] > 0.0001f && ry[0] > 0.0001f) {
    float kx = rx[0] * 0.5522847498f, ky = ry[0] * 0.5522847498f;
    tmp[n++] = (KKBezierPoint){min.x, max.y - ry[0],      0, -ky, 0,
                               ky,    KKBezierPointBezier};
    tmp[n++] = (KKBezierPoint){min.x + rx[0],      max.y, -kx, 0, kx, 0,
                               KKBezierPointBezier};
  } else {
    tmp[n++] = (KKBezierPoint){min.x, max.y, 0, 0, 0, 0, KKBezierPointLinear};
  }

  // TR corner (top side, then right side)
  if (rx[1] > 0.0001f && ry[1] > 0.0001f) {
    float kx = rx[1] * 0.5522847498f, ky = ry[1] * 0.5522847498f;
    tmp[n++] = (KKBezierPoint){max.x - rx[1],      max.y, -kx, 0, kx, 0,
                               KKBezierPointBezier};
    tmp[n++] = (KKBezierPoint){max.x, max.y - ry[1],      0, ky, 0,
                               -ky,   KKBezierPointBezier};
  } else {
    tmp[n++] = (KKBezierPoint){max.x, max.y, 0, 0, 0, 0, KKBezierPointLinear};
  }

  // BR corner (right side, then bottom side)
  if (rx[2] > 0.0001f && ry[2] > 0.0001f) {
    float kx = rx[2] * 0.5522847498f, ky = ry[2] * 0.5522847498f;
    tmp[n++] = (KKBezierPoint){max.x, min.y + ry[2],      0, ky, 0,
                               -ky,   KKBezierPointBezier};
    tmp[n++] = (KKBezierPoint){max.x - rx[2],      min.y, kx, 0, -kx, 0,
                               KKBezierPointBezier};
  } else {
    tmp[n++] = (KKBezierPoint){max.x, min.y, 0, 0, 0, 0, KKBezierPointLinear};
  }

  // BL corner (bottom side, then left side)
  if (rx[3] > 0.0001f && ry[3] > 0.0001f) {
    float kx = rx[3] * 0.5522847498f, ky = ry[3] * 0.5522847498f;
    tmp[n++] = (KKBezierPoint){min.x + rx[3],      min.y, kx, 0, -kx, 0,
                               KKBezierPointBezier};
    tmp[n++] = (KKBezierPoint){min.x, min.y + ry[3],      0, -ky, 0,
                               ky,    KKBezierPointBezier};
  } else {
    tmp[n++] = (KKBezierPoint){min.x, min.y, 0, 0, 0, 0, KKBezierPointLinear};
  }

  // Merge between-corner point pairs whose side has fully collapsed
  // (adjacent corners' radii sum to the full side length). Use a very
  // tight threshold so we only merge at/near 100% — the old 1e-4
  // threshold was triggering at ~99% and warping the curve.
  KKBezierPoint merged[12];
  NSUInteger m = 0;
  // Corner boundary indices: the first point index of each corner group
  NSUInteger cStart[4] = {0, 0, 0, 0};
  NSUInteger ci = 0;
  for (NSUInteger i = 0; i < n && ci < 4; i++) {
    // Each corner emits 1 or 2 points; boundaries are at 0 and after
    // each corner's contribution
    cStart[ci++] = i;
    BOOL rounded = NO;
    if (ci == 1)
      rounded = (rx[0] > 0.0001f && ry[0] > 0.0001f);
    else if (ci == 2)
      rounded = (rx[1] > 0.0001f && ry[1] > 0.0001f);
    else if (ci == 3)
      rounded = (rx[2] > 0.0001f && ry[2] > 0.0001f);
    else if (ci == 4)
      rounded = (rx[3] > 0.0001f && ry[3] > 0.0001f);
    if (rounded)
      i++; // skip second point of this corner
  }
  for (NSUInteger i = 0; i < n; i++) {
    NSUInteger next = (i + 1) % n;
    BOOL isBoundary = (next == cStart[0] || next == cStart[1] ||
                       next == cStart[2] || next == cStart[3]);
    float dx = tmp[next].x - tmp[i].x;
    float dy = tmp[next].y - tmp[i].y;
    if (isBoundary && dx * dx + dy * dy < 1e-8f && i < n - 1) {
      merged[m] = tmp[i];
      merged[m].outX = tmp[next].outX;
      merged[m].outY = tmp[next].outY;
      merged[m].type = KKBezierPointBezier;
      m++;
      i++;
    } else {
      merged[m++] = tmp[i];
    }
  }
  if (m >= 2) {
    float dx = merged[0].x - merged[m - 1].x;
    float dy = merged[0].y - merged[m - 1].y;
    if (dx * dx + dy * dy < 1e-8f) {
      merged[0].inX = merged[m - 1].inX;
      merged[0].inY = merged[m - 1].inY;
      merged[0].type = KKBezierPointBezier;
      m--;
    }
  }

  [self ensureCapacity:m];
  _count = m;
  memcpy(_points, merged, m * sizeof(KKBezierPoint));
}

- (void)toggleTypeAtIndex:(NSUInteger)index
                    start:(simd_float2)start
                      end:(simd_float2)end {
  KKBezierPoint *pt = &_points[index];
  if (pt->type == KKBezierPointBezier) {
    pt->type = KKBezierPointLinear;
    pt->inX = pt->inY = pt->outX = pt->outY = 0;
    return;
  }

  pt->type = KKBezierPointBezier;
  simd_float2 pos = {pt->x, pt->y};
  simd_float2 prev =
      (index > 0) ? (simd_float2){_points[index - 1].x, _points[index - 1].y}
                  : start;
  simd_float2 next = (index < _count - 1) ? (simd_float2){_points[index + 1].x,
                                                          _points[index + 1].y}
                                          : end;

  simd_float2 dir = next - prev;
  float len = simd_length(dir);
  if (len < 0.0001f) {
    pt->inX = pt->inY = pt->outX = pt->outY = 0;
    return;
  }
  dir /= len;
  float distPrev = simd_length(pos - prev);
  float distNext = simd_length(pos - next);
  simd_float2 inH = -dir * distPrev / 3.0f;
  simd_float2 outH = dir * distNext / 3.0f;
  pt->inX = inH.x;
  pt->inY = inH.y;
  pt->outX = outH.x;
  pt->outY = outH.y;
}

- (void)segmentEndpoints:(NSUInteger)segIndex
                   start:(simd_float2)start
                     end:(simd_float2)end
                      p0:(simd_float2 *)p0
                    outH:(simd_float2 *)outH
                   type0:(KKBezierPointType *)type0
                      p1:(simd_float2 *)p1
                     inH:(simd_float2 *)inH
                   type1:(KKBezierPointType *)type1 {
  if (segIndex == 0) {
    *p0 = start;
    *outH = (simd_float2){0, 0};
    *type0 = KKBezierPointLinear;
  } else {
    KKBezierPoint pt = _points[segIndex - 1];
    *p0 = (simd_float2){pt.x, pt.y};
    *outH = (simd_float2){pt.outX, pt.outY};
    *type0 = (KKBezierPointType)pt.type;
  }
  if (segIndex == _count) {
    *p1 = end;
    *inH = (simd_float2){0, 0};
    *type1 = KKBezierPointLinear;
  } else {
    KKBezierPoint pt = _points[segIndex];
    *p1 = (simd_float2){pt.x, pt.y};
    *inH = (simd_float2){pt.inX, pt.inY};
    *type1 = (KKBezierPointType)pt.type;
  }
}

- (simd_float2)evalFrom:(simd_float2)p0
                   outH:(simd_float2)outH
                  type0:(KKBezierPointType)type0
                     to:(simd_float2)p1
                    inH:(simd_float2)inH
                  type1:(KKBezierPointType)type1
                    atT:(float)t {
  if (type0 == KKBezierPointLinear && type1 == KKBezierPointLinear)
    return p0 + t * (p1 - p0);
  return evalCubicBezier(p0, p0 + outH, p1 + inH, p1, t);
}

- (simd_float2)evaluateSegment:(NSUInteger)segIndex
                           atT:(float)t
                         start:(simd_float2)start
                           end:(simd_float2)end {
  simd_float2 p0, p1, outH, inH;
  KKBezierPointType type0, type1;
  [self segmentEndpoints:segIndex
                   start:start
                     end:end
                      p0:&p0
                    outH:&outH
                   type0:&type0
                      p1:&p1
                     inH:&inH
                   type1:&type1];
  return [self evalFrom:p0
                   outH:outH
                  type0:type0
                     to:p1
                    inH:inH
                  type1:type1
                    atT:t];
}

- (simd_float2)evaluatePointAtIndex:(NSUInteger)index
                          nextIndex:(NSUInteger)nextIndex
                                atT:(float)t {
  if (index >= _count || nextIndex >= _count)
    return (simd_float2){0, 0};
  KKBezierPoint p0 = _points[index];
  KKBezierPoint p1 = _points[nextIndex];
  simd_float2 a = {p0.x, p0.y};
  simd_float2 cp0 = {p0.x + p0.outX, p0.y + p0.outY};
  simd_float2 cp1 = {p1.x + p1.inX, p1.y + p1.inY};
  simd_float2 b = {p1.x, p1.y};
  if (p0.type == KKBezierPointLinear && p1.type == KKBezierPointLinear)
    return a + t * (b - a);
  return evalCubicBezier(a, cp0, cp1, b, t);
}

- (simd_float2)evaluateTangentAtIndex:(NSUInteger)index
                            nextIndex:(NSUInteger)nextIndex
                                  atT:(float)t {
  if (index >= _count || nextIndex >= _count)
    return (simd_float2){1, 0};
  KKBezierPoint p0 = _points[index];
  KKBezierPoint p1 = _points[nextIndex];
  simd_float2 a = {p0.x, p0.y};
  simd_float2 cp0 = {p0.x + p0.outX, p0.y + p0.outY};
  simd_float2 cp1 = {p1.x + p1.inX, p1.y + p1.inY};
  simd_float2 b = {p1.x, p1.y};
  if (p0.type == KKBezierPointLinear && p1.type == KKBezierPointLinear)
    return b - a;
  float u = 1.0f - t;
  return 3.0f * u * u * (cp0 - a) + 6.0f * u * t * (cp1 - cp0) +
         3.0f * t * t * (b - cp1);
}

- (simd_float2)positionAtT:(float)t
                     start:(simd_float2)start
                       end:(simd_float2)end {
  NSUInteger segCount = _count + 1;

  if (_count == 0)
    return start + t * (end - start);

  // Build arc-length lookup table
  NSUInteger totalSamples = segCount * kArcLengthSamples;
  simd_float2 *samplePos = malloc((totalSamples + 1) * sizeof(simd_float2));
  float *cumulLen = malloc((totalSamples + 1) * sizeof(float));

  samplePos[0] = start;
  cumulLen[0] = 0;

  for (NSUInteger seg = 0; seg < segCount; seg++) {
    simd_float2 p0, p1, outH, inH;
    KKBezierPointType type0, type1;
    [self segmentEndpoints:seg
                     start:start
                       end:end
                        p0:&p0
                      outH:&outH
                     type0:&type0
                        p1:&p1
                       inH:&inH
                     type1:&type1];

    for (NSUInteger s = 1; s <= kArcLengthSamples; s++) {
      float localT = (float)s / (float)kArcLengthSamples;
      NSUInteger idx = seg * kArcLengthSamples + s;
      samplePos[idx] = [self evalFrom:p0
                                 outH:outH
                                type0:type0
                                   to:p1
                                  inH:inH
                                type1:type1
                                  atT:localT];
      cumulLen[idx] =
          cumulLen[idx - 1] + simd_length(samplePos[idx] - samplePos[idx - 1]);
    }
  }

  float totalLength = cumulLen[totalSamples];
  simd_float2 result;

  if (totalLength < 0.0001f) {
    result = start;
  } else {
    float targetLen = t * totalLength;

    // Binary search
    NSUInteger lo = 0, hi = totalSamples;
    while (lo < hi) {
      NSUInteger mid = (lo + hi) / 2;
      if (cumulLen[mid] < targetLen)
        lo = mid + 1;
      else
        hi = mid;
    }

    if (lo == 0) {
      result = samplePos[0];
    } else {
      float frac = (cumulLen[lo] > cumulLen[lo - 1])
                       ? (targetLen - cumulLen[lo - 1]) /
                             (cumulLen[lo] - cumulLen[lo - 1])
                       : 0.0f;
      result = samplePos[lo - 1] + frac * (samplePos[lo] - samplePos[lo - 1]);
    }
  }

  free(samplePos);
  free(cumulLen);
  return result;
}

- (NSUInteger)contourCount {
  return (_contourCount > 0) ? _contourCount : 1;
}

- (NSRange)contourRangeAtIndex:(NSUInteger)contourIndex {
  if (_contourCount <= 1)
    return NSMakeRange(0, _count);
  NSUInteger start = _contourStarts[contourIndex];
  NSUInteger end = (contourIndex + 1 < _contourCount)
                       ? _contourStarts[contourIndex + 1]
                       : _count;
  return NSMakeRange(start, end - start);
}

- (void)beginContour {
  if (_count == 0)
    return; // first contour starts implicitly at 0
  if (!_contourStarts) {
    _contourCapacity = 4;
    _contourStarts = malloc(_contourCapacity * sizeof(NSUInteger));
    _contourStarts[0] = 0;
    _contourCount = 1;
  }
  if (_contourCount >= _contourCapacity) {
    _contourCapacity *= 2;
    _contourStarts =
        realloc(_contourStarts, _contourCapacity * sizeof(NSUInteger));
  }
  _contourStarts[_contourCount] = _count;
  _contourCount++;
}

- (NSArray<KKBezierPath *> *)splitContours {
  if (_contourCount <= 1)
    return nil;

  NSMutableArray<KKBezierPath *> *result = [NSMutableArray array];
  for (NSUInteger c = 0; c < _contourCount; c++) {
    NSRange range = [self contourRangeAtIndex:c];
    if (range.length == 0)
      continue;

    KKBezierPath *sub = [[KKBezierPath alloc] init];
    for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
      KKBezierPoint pt = _points[i];
      [sub insertAtIndex:sub.count position:(simd_float2){pt.x, pt.y}];
      NSUInteger si = sub.count - 1;
      if (pt.type == KKBezierPointBezier) {
        [sub setInHandle:(simd_float2){pt.inX, pt.inY} atIndex:si];
        [sub setOutHandle:(simd_float2){pt.outX, pt.outY} atIndex:si];
        [sub setType:KKBezierPointBezier atIndex:si];
      }
    }
    sub.closed = YES;
    sub.strokeEnabled = self.strokeEnabled;
    sub.strokeWidth = self.strokeWidth;
    sub.strokeR = self.strokeR;
    sub.strokeG = self.strokeG;
    sub.strokeB = self.strokeB;
    sub.fillEnabled = self.fillEnabled;
    sub.fillR = self.fillR;
    sub.fillG = self.fillG;
    sub.fillB = self.fillB;
    sub.opacity = self.opacity;
    sub.lineCap = self.lineCap;
    sub.lineJoin = self.lineJoin;
    sub.strokeStyle = self.strokeStyle;
    sub.endWidth = self.endWidth;
    [result addObject:sub];
  }
  return result;
}

@end
