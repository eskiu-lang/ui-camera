// <camera> on macOS: an open panel for the photo library (any image file), and AVFoundation for
// the live "camera" view, its captures and its frames. macOS has no system camera screen, so
// camera_take_photo answers unavailable: an app shows a CameraView and calls camera_capture.
// Every photo is saved upright, at most 2048 pixels on its longer side, as a JPEG in the caches
// directory; results go to the "camera" channel (src/camera.esk). Live frames come from the
// view's AVCaptureVideoDataOutput as NV12 pixel buffers, lent to Eskiu by pointer, upright as
// they are (rotation 0).
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <os/lock.h>
#import "ui_native.h"

static void emit(NSString *payload) { ui_native_emit("camera", payload.UTF8String); }

// An image's data (a file's, a capture's) drawn upright and scaled down to 2048 pixels,
// written as a JPEG; emits the photo.
static void savePhoto(NSData *data) {
    CGImageSourceRef source = data ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
    CGImageRef image = NULL;
    if (source) {
        NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                  (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                  (id)kCGImageSourceThumbnailMaxPixelSize: @2048};
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
    }
    if (!image) { emit(@"failed"); return; }
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    caches = [caches stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier ?: @"eskiu-ui"];
    [NSFileManager.defaultManager createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [caches stringByAppendingPathComponent:[NSString stringWithFormat:@"photo-%lld.jpg",
                      (long long)(NSDate.date.timeIntervalSince1970 * 1000)]];
    CGImageDestinationRef out = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
    BOOL ok = NO;
    if (out) {
        CGImageDestinationAddImage(out, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.9});
        ok = CGImageDestinationFinalize(out);
        CFRelease(out);
    }
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGImageRelease(image);
    if (!ok) { emit(@"failed"); return; }
    emit([NSString stringWithFormat:@"photo %d %d %@", (int)width, (int)height, path]);
}

void camera_native_pick(void) {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypeImage];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    void (^done)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) { emit(@"cancelled"); return; }
        savePhoto([NSData dataWithContentsOfURL:panel.URL]);
    };
    NSWindow *window = ui_native_window();
    if (window) [panel beginSheetModalForWindow:window completionHandler:done];
    else done([panel runModal]);
}

void camera_native_take(void) { emit(@"unavailable"); }

// `then` once the user allowed the camera, else the reason on the channel.
static void withCamera(void (^then)(void)) {
    if (![AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo]) { emit(@"unavailable"); return; }
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) { then(); return; }
    if (status != AVAuthorizationStatusNotDetermined) { emit(@"denied"); return; }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (granted) then(); else emit(@"denied"); });
    }];
}

// Live frames, as on iOS: camera_native_frames sets what use_camera_frames asks for; the
// view's video output keeps the latest buffer in `latest` (retained) and posts "frame" on the
// "camera_frame" channel when none is posted since the last acquire. Acquire lends `latest`
// with its base address locked until release.
static struct { int on, width, height, fps; } wanted;
static os_unfair_lock frameLock = OS_UNFAIR_LOCK_INIT;
static CVPixelBufferRef latest;
static int64_t latestTime;
static bool latestFront;
static bool posted;
static CVPixelBufferRef lent;

void camera_native_frame_release(void);

static void dropLatest(void) {
    os_unfair_lock_lock(&frameLock);
    CVPixelBufferRef old = latest;
    latest = NULL;
    posted = false;
    os_unfair_lock_unlock(&frameLock);
    if (old) CVPixelBufferRelease(old);
}

// The session preset for frames of `width` x `height` (landscape): the smallest that holds them.
static AVCaptureSessionPreset framePreset(int width, int height) {
    int longer = MAX(width, height), shorter = MIN(width, height);
    if (longer <= 640 && shorter <= 480) return AVCaptureSessionPreset640x480;
    if (longer <= 1280 && shorter <= 720) return AVCaptureSessionPreset1280x720;
    if (longer <= 1920 && shorter <= 1080) return AVCaptureSessionPreset1920x1080;
    return AVCaptureSessionPreset3840x2160;
}

// The camera for `facing`: one at that position, else the system's default camera (a Mac's
// built-in camera faces the user; an external one has no position).
static AVCaptureDevice *cameraFacing(NSString *facing) {
    AVCaptureDevicePosition position = [facing isEqualToString:@"front"] ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                 mediaType:AVMediaTypeVideo position:position];
    return device ?: [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
}

@interface EskiuCameraView : NSView <AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoDataOutput *frames;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *preview;
@property(nonatomic) BOOL front;
@property(nonatomic, strong) AVCapturePhotoOutput *output;
@property(nonatomic, copy) NSString *facing;
@end

static dispatch_queue_t sessionQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("org.eskiu.camera.session", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

// The view mounted last, which camera_native_capture captures from.
static __weak EskiuCameraView *live;

@implementation EskiuCameraView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.preview = [AVCaptureVideoPreviewLayer new];
        self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.preview.frame = self.layer.bounds;
        self.preview.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        [self.layer addSublayer:self.preview];
        self.facing = @"back";
    }
    return self;
}
- (void)start {
    [self stop];
    AVCaptureDevice *device = cameraFacing(self.facing);
    AVCaptureDeviceInput *input = device ? [AVCaptureDeviceInput deviceInputWithDevice:device error:nil] : nil;
    if (!input) { emit(@"unavailable"); return; }
    AVCaptureSession *session = [AVCaptureSession new];
    [session beginConfiguration];
    AVCaptureSessionPreset preset = wanted.on ? framePreset(wanted.width, wanted.height) : AVCaptureSessionPresetPhoto;
    if (![session canSetSessionPreset:preset]) preset = AVCaptureSessionPresetHigh;
    session.sessionPreset = preset;
    AVCapturePhotoOutput *output = [AVCapturePhotoOutput new];
    if (![session canAddInput:input] || ![session canAddOutput:output]) { [session commitConfiguration]; emit(@"unavailable"); return; }
    [session addInput:input];
    [session addOutput:output];
    self.frames = nil;
    self.front = device.position == AVCaptureDevicePositionFront;
    if (wanted.on) {
        AVCaptureVideoDataOutput *frames = [AVCaptureVideoDataOutput new];
        frames.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
        frames.alwaysDiscardsLateVideoFrames = YES;
        static dispatch_queue_t queue;
        if (!queue) queue = dispatch_queue_create("org.eskiu.camera.frames", DISPATCH_QUEUE_SERIAL);
        [frames setSampleBufferDelegate:self queue:queue];
        if ([session canAddOutput:frames]) { [session addOutput:frames]; self.frames = frames; }
        if (wanted.fps > 0 && [device lockForConfiguration:nil]) {
            for (AVFrameRateRange *range in device.activeFormat.videoSupportedFrameRateRanges) {
                if (wanted.fps >= range.minFrameRate && wanted.fps <= range.maxFrameRate) {
                    device.activeVideoMinFrameDuration = CMTimeMake(1, wanted.fps);
                    break;
                }
            }
            [device unlockForConfiguration];
        }
    }
    [session commitConfiguration];
    self.session = session;
    self.output = output;
    self.preview.session = session;
    dispatch_async(sessionQueue(), ^{ [session startRunning]; });
}
- (void)stop {
    AVCaptureSession *session = self.session;
    self.session = nil;
    [self.frames setSampleBufferDelegate:nil queue:NULL];
    self.frames = nil;
    dropLatest();
    if (session) dispatch_sync(sessionQueue(), ^{ [session stopRunning]; });
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        live = self;
        withCamera(^{ if (self.window) [self start]; });
    } else [self stop];
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    (void)connection;
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
    if (!buffer || !wanted.on || output != _frames) return;
    CVPixelBufferRetain(buffer);
    CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
    os_unfair_lock_lock(&frameLock);
    CVPixelBufferRef old = latest;
    latest = buffer;
    latestTime = CMTIME_IS_NUMERIC(time) ? (int64_t)(CMTimeGetSeconds(time) * 1e9) : 0;
    latestFront = _front;
    bool post = !posted;
    posted = true;
    os_unfair_lock_unlock(&frameLock);
    if (old) CVPixelBufferRelease(old);
    if (post) ui_native_emit("camera_frame", "frame");
}
- (void)capture {
    if (!self.session) { emit(@"unavailable"); return; }
    [self.output capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:self];
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    (void)output;
    NSData *data = error ? nil : photo.fileDataRepresentation;
    dispatch_async(dispatch_get_main_queue(), ^{ savePhoto(data); });
}
@end

void camera_native_capture(void) {
    EskiuCameraView *view = live;
    if (view) [view capture];
    else emit(@"unavailable");
}

void camera_native_frames(int on, int width, int height, int fps) {
    BOOL changed = wanted.on != (on != 0) || (on && (wanted.width != width || wanted.height != height || wanted.fps != fps));
    wanted.on = on != 0;
    wanted.width = width;
    wanted.height = height;
    wanted.fps = fps;
    if (!on) dropLatest();
    os_unfair_lock_lock(&frameLock);
    posted = false;
    os_unfair_lock_unlock(&frameLock);
    EskiuCameraView *view = live;
    if (changed && view.session) [view start];
}

int camera_native_frame_acquire(int64_t *info) {
    camera_native_frame_release();
    os_unfair_lock_lock(&frameLock);
    CVPixelBufferRef buffer = latest;
    if (buffer) CVPixelBufferRetain(buffer);
    int64_t time = latestTime;
    bool front = latestFront;
    posted = false;
    os_unfair_lock_unlock(&frameLock);
    if (!buffer) return 0;
    if (CVPixelBufferGetPlaneCount(buffer) != 2 ||
        CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferRelease(buffer);
        return 0;
    }
    lent = buffer;
    for (int i = 0; i < 24; i++) info[i] = 0;
    info[0] = (int64_t)CVPixelBufferGetWidth(buffer);
    info[1] = (int64_t)CVPixelBufferGetHeight(buffer);
    info[2] = 0;
    info[3] = 2;
    info[4] = 0;
    info[5] = front;
    if (@available(macOS 12.0, *)) {
        CFTypeRef matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, NULL);
        info[6] = matrix && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) ? 1 : 0;
        if (matrix) CFRelease(matrix);
    }
    info[7] = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    info[8] = time;
    for (int p = 0; p < 2; p++) {
        size_t row = CVPixelBufferGetBytesPerRowOfPlane(buffer, p);
        info[9 + p * 4] = (int64_t)(intptr_t)CVPixelBufferGetBaseAddressOfPlane(buffer, p);
        info[10 + p * 4] = (int64_t)row;
        info[11 + p * 4] = p == 0 ? 1 : 2;
        info[12 + p * 4] = (int64_t)(row * CVPixelBufferGetHeightOfPlane(buffer, p));
    }
    return 1;
}

void camera_native_frame_release(void) {
    CVPixelBufferRef buffer = lent;
    lent = NULL;
    if (!buffer) return;
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(buffer);
}

UI_NATIVE_SETUP(camera) {
    ui_register_view(@"camera", ^NSView *(UiViewEmit unused) {
        (void)unused;
        return [[EskiuCameraView alloc] initWithFrame:NSZeroRect];
    }, ^(NSView *view, NSString *name, NSString *value) {
        EskiuCameraView *camera = (EskiuCameraView *)view;
        if ([name isEqualToString:@"facing"] && ![value isEqualToString:camera.facing]) {
            camera.facing = value.length ? value : @"back";
            if (camera.session) [camera start];
        }
    });
}
