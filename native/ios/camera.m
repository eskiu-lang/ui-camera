// <camera> on iOS: PHPickerViewController for the library, UIImagePickerController for the
// system's camera, and AVFoundation for the live "camera" view. Every photo is saved upright,
// at most 2048 pixels on its longer side, as a JPEG in the caches directory; results go to the
// "camera" channel (src/camera.esk).
#import <AVFoundation/AVFoundation.h>
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

// The live view: a session on the chosen camera, its preview filling the view (cropped).
@interface EskiuCameraView : UIView <AVCapturePhotoCaptureDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
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
    session.sessionPreset = AVCaptureSessionPresetPhoto;
    AVCapturePhotoOutput *output = [AVCapturePhotoOutput new];
    if (![session canAddInput:input] || ![session canAddOutput:output]) { emit(@"unavailable"); return; }
    [session addInput:input];
    [session addOutput:output];
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
    if (session) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [session stopRunning]; });
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        live = self;
        withCamera(^{ if (self.window) [self start]; });
    } else [self stop];
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
