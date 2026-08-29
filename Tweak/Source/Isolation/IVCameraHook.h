#import <Foundation/Foundation.h>

@class IVContainer;

NS_ASSUME_NONNULL_BEGIN

/// Global virtual camera (shared by ALL containers).
///
/// When a global verification video is configured ([IVPaths globalCameraVideoPath]),
/// this feeds that video INTO Instagram's own native capture pipeline instead of the real
/// camera — for the passive photo / pose "Photo Verification" and profile-photo
/// capture. It works entirely in-process, substrate-free, and covers BOTH what Instagram
/// analyzes AND what the user sees on screen:
///
///   1. DATA PATH — swizzle `-[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]`
///      to learn the concrete delegate class Instagram installs the moment it wires up the
///      camera, then swizzle that delegate's
///      `-captureOutput:didOutputSampleBuffer:fromConnection:`. On every real camera
///      frame we replace the image buffer with the next frame decoded from the video
///      (scaled/cropped to the exact incoming geometry + pixel format, original timing
///      preserved) and forward THAT to Instagram. The video loops seamlessly.
///   2. PREVIEW PATH — swizzle `-[AVCaptureVideoPreviewLayer setSession:]` so the
///      instant Instagram shows a live preview we lay an AVPlayerLayer (looping the same
///      video, aspect-fill) OVER it. This is what makes the user SEE the video instead
///      of the real camera; the overlay is kept sized to the preview via a
///      `layoutSublayers` swizzle.
///   3. STILL-PHOTO PATH — the actual verification CAPTURE. When the user taps the
///      shutter Instagram grabs a still via `AVCapturePhotoOutput` and reads the resulting
///      `AVCapturePhoto`'s data. The photo object is immutable, but every consumer must
///      call one of its data accessors to get pixels, so we swizzle those class-wide —
///      `-fileDataRepresentation` (re-encoded as JPEG from a video frame at the real
///      photo's upright geometry), `-CGImageRepresentation`, `-pixelBuffer` and
///      `-previewPixelBuffer` — to hand back the video frame. The deprecated
///      CMSampleBuffer photo callback is also covered by learning the photo delegate via
///      `-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]`.
///
/// A single global video is shared by every container by design (the user swaps the
/// file to verify a different account) — state = the mere existence of the file, no
/// per-container flag.
///
/// DEFENSIVE BY DESIGN: any failure at any step (missing frameworks, decode error,
/// geometry mismatch, buffer alloc failure) falls through to Instagram's UNTOUCHED real
/// frame / real preview — the hook must never crash or freeze Instagram's camera.
///
/// HONEST LIMITS (in-process, no jailbreak):
///   * Feeds Instagram's OWN native AVFoundation camera only — data stream, preview AND
///     the still capture (see path 3). It does NOT reach the Veriff ID/age KYC selfie,
///     which runs getUserMedia inside a WebView in a separate process — unreachable by
///     an in-process hook.
@interface IVCameraHook : NSObject

/// Install the global virtual camera. No-op unless a global verification video exists
/// ([IVPaths hasGlobalCameraVideo]). Idempotent; call once from Bootstrap
/// UNCONDITIONALLY at launch (NOT under the isolation gate — the camera is global).
+ (void)installGlobal;

@end

NS_ASSUME_NONNULL_END
