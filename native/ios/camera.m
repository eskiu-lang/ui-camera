// <camera> on iOS: PHPickerViewController for the library, UIImagePickerController for the
// system's camera, and AVFoundation for the live "camera" view. Every photo is saved upright,
// at most 2048 pixels on its longer side, as a JPEG in the caches directory; results go to the
// "camera" channel (src/camera.esk). Live frames (use_camera_frames) come from the view's
// AVCaptureVideoDataOutput as NV12 pixel buffers, lent to Eskiu by pointer.
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>
#import <PhotosUI/PhotosUI.h>
#import "ui_native.h"

static void emit(NSString *payload) { ui_native_emit("camera", payload.UTF8String); }

// `image` drawn upright and scaled down to 2048 pixels, written as a JPEG; emits the photo.
static void savePhoto(UIImage *image) {
    if (!image) { emit(@"failed"); return; }
    CGSize size = image.size;
    CGFloat scale = MIN(1.0, 2048.0 / MAX(size.width * image.scale, size.height * image.scale)) * image.scale;
    CGSize pixels = CGSizeMake(round(size.width * scale), round(size.height * scale));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    UIImage *upright = [[[UIGraphicsImageRenderer alloc] initWithSize:pixels format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, pixels.width, pixels.height)];
    }];
    NSData *jpeg = UIImageJPEGRepresentation(upright, 0.9);
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [caches stringByAppendingPathComponent:[NSString stringWithFormat:@"photo-%lld.jpg",
                      (long long)(NSDate.date.timeIntervalSince1970 * 1000)]];
    if (![jpeg writeToFile:path atomically:YES]) { emit(@"failed"); return; }
    emit([NSString stringWithFormat:@"photo %d %d %@", (int)pixels.width, (int)pixels.height, path]);
}

@interface EskiuCamera : NSObject <PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

static EskiuCamera *shared;

@implementation EskiuCamera
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *item = results.firstObject.itemProvider;
    if (!item) { emit(@"cancelled"); return; }
    if (![item canLoadObjectOfClass:UIImage.class]) { emit(@"failed"); return; }
    [item loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ savePhoto((UIImage *)object); });
    }];
}
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    savePhoto(info[UIImagePickerControllerOriginalImage]);
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
    emit(@"cancelled");
}
@end

void camera_native_pick(void) {
    if (!shared) shared = [EskiuCamera new];
    PHPickerConfiguration *config = [PHPickerConfiguration new];
    config.filter = PHPickerFilter.imagesFilter;
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = shared;
    [ui_view_controller() presentViewController:picker animated:YES completion:nil];
}

// `then` once the user allowed the camera, else the reason on the channel.
static void withCamera(void (^then)(void)) {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera] ||
        ![AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo]) {
        emit(@"unavailable");
        return;
    }
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) { then(); return; }
    if (status != AVAuthorizationStatusNotDetermined) { emit(@"denied"); return; }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (granted) then(); else emit(@"denied"); });
    }];
}

void camera_native_take(void) {
    if (!shared) shared = [EskiuCamera new];
    withCamera(^{
        UIImagePickerController *picker = [UIImagePickerController new];
        picker.sourceType = UIImagePickerControllerSourceTypeCamera;
        picker.delegate = shared;
        [ui_view_controller() presentViewController:picker animated:YES completion:nil];
    });
}

// Live frames. camera_native_frames sets what use_camera_frames asks for; the view's
// video output keeps the latest buffer in `latest` (retained) and posts "frame" on the
// "camera_frame" channel when none is posted since the last acquire, so a busy handler sees
// the newest frame and the others are dropped. Acquire lends `latest` with its base address
// locked until release.
static struct { int on, width, height, fps; } wanted;
static os_unfair_lock frameLock = OS_UNFAIR_LOCK_INIT;
static CVPixelBufferRef latest;
static int64_t latestTime;
static bool latestFront;
static bool posted;
static CVPixelBufferRef lent;

void camera_native_frame_release(void);

// Drops the frame waiting, if any.
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

// The live view: a session on the chosen camera, its preview filling the view (cropped).
@interface EskiuCameraView : UIView <AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoDataOutput *frames;
@property(nonatomic) BOOL front;
@property(nonatomic, strong) AVCapturePhotoOutput *output;
@property(nonatomic, copy) NSString *facing;
@end

// The view mounted last, which camera_native_capture captures from.
static __weak EskiuCameraView *live;

@implementation EskiuCameraView
+ (Class)layerClass { return AVCaptureVideoPreviewLayer.class; }
- (void)start {
    [self stop];
    AVCaptureDevicePosition position = [self.facing isEqualToString:@"front"] ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                 mediaType:AVMediaTypeVideo position:position];
    AVCaptureDeviceInput *input = device ? [AVCaptureDeviceInput deviceInputWithDevice:device error:nil] : nil;
    if (!input) { emit(@"unavailable"); return; }
    AVCaptureSession *session = [AVCaptureSession new];
    [session beginConfiguration];
    // With frames on, the session runs at their size (so are captures); else at photo size.
    AVCaptureSessionPreset preset = wanted.on ? framePreset(wanted.width, wanted.height) : AVCaptureSessionPresetPhoto;
    if (![session canSetSessionPreset:preset]) preset = wanted.on ? AVCaptureSessionPresetHigh : AVCaptureSessionPresetPhoto;
    session.sessionPreset = preset;
    AVCapturePhotoOutput *output = [AVCapturePhotoOutput new];
    if (![session canAddInput:input] || ![session canAddOutput:output]) { [session commitConfiguration]; emit(@"unavailable"); return; }
    [session addInput:input];
    [session addOutput:output];
    self.frames = nil;
    self.front = position == AVCaptureDevicePositionFront;
    if (wanted.on) {
        AVCaptureVideoDataOutput *frames = [AVCaptureVideoDataOutput new];
        frames.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
        frames.alwaysDiscardsLateVideoFrames = YES;
        static dispatch_queue_t queue;
        if (!queue) queue = dispatch_queue_create("org.eskiu.camera.frames", DISPATCH_QUEUE_SERIAL);
        [frames setSampleBufferDelegate:self queue:queue];
        if ([session canAddOutput:frames]) { [session addOutput:frames]; self.frames = frames; }
        // At most `fps` frames a second, when the camera's format allows that rate.
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
    AVCaptureVideoPreviewLayer *preview = (AVCaptureVideoPreviewLayer *)self.layer;
    preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    preview.session = session;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [session startRunning]; });
}
- (void)stop {
    AVCaptureSession *session = self.session;
    self.session = nil;
    [self.frames setSampleBufferDelegate:nil queue:NULL];
    self.frames = nil;
    dropLatest();
    if (session) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [session stopRunning]; });
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        live = self;
        withCamera(^{ if (self.window) [self start]; });
    } else [self stop];
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
    // A late buffer from a session this view already replaced or stopped is dropped.
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
    NSData *data = photo.fileDataRepresentation;
    UIImage *image = data && !error ? [UIImage imageWithData:data] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{ savePhoto(image); });
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
    // A handler that went away may have left a post unanswered: post again with the next frame.
    if (!on) dropLatest();
    os_unfair_lock_lock(&frameLock);
    posted = false;
    os_unfair_lock_unlock(&frameLock);
    EskiuCameraView *view = live;
    if (changed && view.session) [view start];
}

// How far a frame turns clockwise to be upright as the interface is held: the sensors give
// landscape with the home side on the right; the front one is turned the other way.
static int frameRotation(bool front) {
    UIInterfaceOrientation orientation = ui_view_controller().view.window.windowScene.interfaceOrientation;
    int device = 0;
    if (orientation == UIInterfaceOrientationLandscapeRight) device = 90;
    else if (orientation == UIInterfaceOrientationPortraitUpsideDown) device = 180;
    else if (orientation == UIInterfaceOrientationLandscapeLeft) device = 270;
    return front ? (270 + device) % 360 : (450 - device) % 360;
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
    info[4] = frameRotation(front);
    info[5] = front;
    CFTypeRef matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, NULL);
    info[6] = matrix && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) ? 1 : 0;
    if (matrix) CFRelease(matrix);
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
    ui_register_view(@"camera", ^UIView *(UiViewEmit emit) {
        EskiuCameraView *view = [EskiuCameraView new];
        view.backgroundColor = UIColor.blackColor;
        view.facing = @"back";
        return view;
    }, ^(UIView *view, NSString *name, NSString *value) {
        EskiuCameraView *camera = (EskiuCameraView *)view;
        if ([name isEqualToString:@"facing"] && ![value isEqualToString:camera.facing]) {
            camera.facing = value.length ? value : @"back";
            if (camera.session) [camera start];
        }
    });
}
