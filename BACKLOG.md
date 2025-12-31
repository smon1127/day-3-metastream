# Metastream Backlog

## SDK Feature Requests

### Request H.264 Codec Option from Meta DAT SDK
**Priority:** High  
**Impact:** Would eliminate re-encoding, reduce latency by ~20ms, save CPU/battery

Currently the SDK only exposes `VideoCodec.raw` which gives us decoded `CMSampleBuffer` frames. We have to re-encode to H.264 for network transmission.

**Requested API:**
```swift
public enum VideoCodec {
  case raw      // Current - decoded frames
  case h264     // Requested - pass through encoded NAL units
}
```

**Benefits:**
- Skip decode→encode round trip
- ~20ms latency reduction
- Significant CPU/battery savings on iPhone
- Simpler pipeline

**Action:** File issue/feature request with Meta Developer Support
