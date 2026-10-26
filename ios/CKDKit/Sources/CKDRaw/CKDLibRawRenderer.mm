#import "CKDLibRawRenderer.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <vector>

#include "libraw/libraw.h"

NSString * const CKDLibRawRendererErrorDomain = @"CKDLibRawRendererErrorDomain";

@implementation CKDLibRawRenderOptions

- (instancetype)init {
    return [self initWithRedMultiplier:0.0
                       greenMultiplier:0.0
                        blueMultiplier:0.0
                      fourthMultiplier:0.0
                             brightness:1.0];
}

- (instancetype)initWithRedMultiplier:(double)redMultiplier
                      greenMultiplier:(double)greenMultiplier
                       blueMultiplier:(double)blueMultiplier
                     fourthMultiplier:(double)fourthMultiplier
                            brightness:(double)brightness {
    self = [super init];
    if (self) {
        _redMultiplier = redMultiplier;
        _greenMultiplier = greenMultiplier;
        _blueMultiplier = blueMultiplier;
        _fourthMultiplier = fourthMultiplier;
        _brightness = brightness;
        _noAutoBright = YES;
        _useCameraWhiteBalance = NO;
        _useAutoWhiteBalance = NO;
        _outputColor = 0;
        _demosaicAlgorithm = 1;
        _outputBitsPerSample = 8;
        _userFlip = -1;
    }
    return self;
}

@end

@interface CKDLibRawRenderedImage ()

- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                     channels:(NSInteger)channels
               bitsPerChannel:(NSInteger)bitsPerChannel
                     rawWidth:(NSInteger)rawWidth
                    rawHeight:(NSInteger)rawHeight
                 visibleWidth:(NSInteger)visibleWidth
                visibleHeight:(NSInteger)visibleHeight
                   leftMargin:(NSInteger)leftMargin
                    topMargin:(NSInteger)topMargin
                 rgba8888Data:(NSData *)rgba8888Data
                libRawVersion:(NSString *)libRawVersion
            cameraWhiteBalance:(NSArray<NSNumber *> *)cameraWhiteBalance;

@end

@implementation CKDLibRawRenderedImage

- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                     channels:(NSInteger)channels
               bitsPerChannel:(NSInteger)bitsPerChannel
                     rawWidth:(NSInteger)rawWidth
                    rawHeight:(NSInteger)rawHeight
                 visibleWidth:(NSInteger)visibleWidth
                visibleHeight:(NSInteger)visibleHeight
                   leftMargin:(NSInteger)leftMargin
                    topMargin:(NSInteger)topMargin
                 rgba8888Data:(NSData *)rgba8888Data
                libRawVersion:(NSString *)libRawVersion
            cameraWhiteBalance:(NSArray<NSNumber *> *)cameraWhiteBalance {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _channels = channels;
        _bitsPerChannel = bitsPerChannel;
        _rawWidth = rawWidth;
        _rawHeight = rawHeight;
        _visibleWidth = visibleWidth;
        _visibleHeight = visibleHeight;
        _leftMargin = leftMargin;
        _topMargin = topMargin;
        _rgba8888Data = rgba8888Data;
        _libRawVersion = [libRawVersion copy];
        _cameraWhiteBalance = [cameraWhiteBalance copy];
    }
    return self;
}

@end

static NSError *CKDLibRawMakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:CKDLibRawRendererErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *CKDLibRawMakeLibRawError(NSInteger code, NSString *operation) {
    const char *rawMessage = libraw_strerror((int)code);
    NSString *message = [NSString stringWithFormat:@"%@ failed: %s", operation, rawMessage ?: "unknown LibRaw error"];
    return CKDLibRawMakeError(code, message);
}

static NSData *CKDLibRawConvertToRGBA8888(const libraw_processed_image_t *image, NSError **error) {
    if (image->bits != 8) {
        if (error) {
            *error = CKDLibRawMakeError(1001, [NSString stringWithFormat:@"Expected 8-bit LibRaw output, got %u-bit output.", image->bits]);
        }
        return nil;
    }

    const size_t width = image->width;
    const size_t height = image->height;
    const size_t channels = image->colors;
    const size_t pixelCount = width * height;
    const unsigned char *source = image->data;

    unsigned char *destination = static_cast<unsigned char *>(malloc(pixelCount * 4));
    if (destination == nullptr) {
        if (error) {
            *error = CKDLibRawMakeError(1002, @"Not enough memory for the RGBA raster.");
        }
        return nil;
    }

    for (size_t pixel = 0; pixel < pixelCount; pixel++) {
        const size_t sourceOffset = pixel * channels;
        const size_t destinationOffset = pixel * 4;

        if (channels == 1) {
            const unsigned char value = source[sourceOffset];
            destination[destinationOffset + 0] = value;
            destination[destinationOffset + 1] = value;
            destination[destinationOffset + 2] = value;
        } else {
            destination[destinationOffset + 0] = source[sourceOffset + 0];
            destination[destinationOffset + 1] = source[sourceOffset + std::min<size_t>(1, channels - 1)];
            destination[destinationOffset + 2] = source[sourceOffset + std::min<size_t>(2, channels - 1)];
        }
        destination[destinationOffset + 3] = 255;
    }

    return [[NSData alloc] initWithBytesNoCopy:destination length:pixelCount * 4 freeWhenDone:YES];
}

@interface CKDLibRawImageInfo ()
- (instancetype)initWithPixelCount:(NSInteger)pixelCount linear:(BOOL)linear;
@end

@implementation CKDLibRawImageInfo

- (instancetype)initWithPixelCount:(NSInteger)pixelCount linear:(BOOL)linear {
    self = [super init];
    if (self) {
        _pixelCount = pixelCount;
        _linear = linear;
    }
    return self;
}

@end

@implementation CKDLibRawRenderer

+ (NSString *)libRawVersion {
    return [NSString stringWithUTF8String:LibRaw::version()];
}

+ (nullable CKDLibRawImageInfo *)inspectImageAtPath:(NSString *)path error:(NSError **)error {
    std::unique_ptr<LibRaw> rawProcessor = std::make_unique<LibRaw>();
    int result = rawProcessor->open_file(path.fileSystemRepresentation);
    if (result != LIBRAW_SUCCESS) {
        if (error) {
            *error = CKDLibRawMakeLibRawError(result, @"open_file");
        }
        return nil;
    }
    const libraw_image_sizes_t sizes = rawProcessor->imgdata.sizes;
    const NSInteger raw = static_cast<NSInteger>(sizes.raw_width) * sizes.raw_height;
    const NSInteger visible = static_cast<NSInteger>(sizes.width) * sizes.height;
    return [[CKDLibRawImageInfo alloc] initWithPixelCount:std::max(raw, visible)
                                                   linear:rawProcessor->imgdata.idata.filters == 0];
}

+ (NSInteger)libRawVersionNumber {
    return LibRaw::versionNumber();
}

+ (nullable CKDLibRawRenderedImage *)renderImageAtPath:(NSString *)path
                                               options:(CKDLibRawRenderOptions *)options
                                                 error:(NSError **)error {
    if (path.length == 0) {
        if (error) {
            *error = CKDLibRawMakeError(1000, @"RAW path is empty.");
        }
        return nil;
    }

    // LibRaw is large enough to overflow a dispatch worker's stack when stored by value.
    std::unique_ptr<LibRaw> rawProcessor = std::make_unique<LibRaw>();
    int result = rawProcessor->open_file(path.fileSystemRepresentation);
    if (result != LIBRAW_SUCCESS) {
        if (error) {
            *error = CKDLibRawMakeLibRawError(result, @"open_file");
        }
        return nil;
    }

    libraw_output_params_t &params = rawProcessor->imgdata.params;
    params.half_size = 0;
    params.four_color_rgb = 0;
    params.dcb_iterations = 0;
    params.dcb_enhance_fl = 0;
    params.fbdd_noiserd = 0;
    params.threshold = 0.0f;
    params.med_passes = 0;
    params.use_camera_wb = options.useCameraWhiteBalance ? 1 : 0;
    params.use_auto_wb = options.useAutoWhiteBalance ? 1 : 0;
    params.output_color = static_cast<int>(options.outputColor);
    params.output_bps = static_cast<int>(options.outputBitsPerSample);
    params.user_flip = static_cast<int>(options.userFlip);
    params.user_qual = static_cast<int>(options.demosaicAlgorithm);
    params.user_black = -1;
    params.user_sat = -1;
    params.no_auto_bright = options.noAutoBright ? 1 : 0;
    params.no_auto_scale = 0;
    params.auto_bright_thr = LIBRAW_DEFAULT_AUTO_BRIGHTNESS_THRESHOLD;
    params.adjust_maximum_thr = 0.75f;
    params.bright = static_cast<float>(options.brightness);
    params.highlight = 0;
    params.exp_correc = -1;
    params.exp_shift = 1.0f;
    params.exp_preser = 0.0f;
    params.gamm[0] = 1.0 / 2.222;
    params.gamm[1] = 4.5;
    params.aber[0] = 1.0;
    params.aber[2] = 1.0;
    params.user_mul[0] = static_cast<float>(options.redMultiplier);
    params.user_mul[1] = static_cast<float>(options.greenMultiplier);
    params.user_mul[2] = static_cast<float>(options.blueMultiplier);
    params.user_mul[3] = static_cast<float>(options.fourthMultiplier);

    result = rawProcessor->unpack();
    if (result != LIBRAW_SUCCESS) {
        if (error) {
            *error = CKDLibRawMakeLibRawError(result, @"unpack");
        }
        return nil;
    }
    NSArray<NSNumber *> *cameraWhiteBalance = @[
        @(rawProcessor->imgdata.rawdata.color.cam_mul[0]),
        @(rawProcessor->imgdata.rawdata.color.cam_mul[1]),
        @(rawProcessor->imgdata.rawdata.color.cam_mul[2]),
        @(rawProcessor->imgdata.rawdata.color.cam_mul[3])
    ];

    result = rawProcessor->dcraw_process();
    if (result != LIBRAW_SUCCESS) {
        if (error) {
            *error = CKDLibRawMakeLibRawError(result, @"dcraw_process");
        }
        return nil;
    }

    int imageError = LIBRAW_SUCCESS;
    libraw_processed_image_t *processedImage = rawProcessor->dcraw_make_mem_image(&imageError);
    if (processedImage == nullptr || imageError != LIBRAW_SUCCESS) {
        if (error) {
            *error = CKDLibRawMakeLibRawError(imageError, @"dcraw_make_mem_image");
        }
        if (processedImage != nullptr) {
            LibRaw::dcraw_clear_mem(processedImage);
        }
        return nil;
    }

    const libraw_image_sizes_t sizes = rawProcessor->imgdata.sizes;
    rawProcessor.reset();

    NSError *rgbaError = nil;
    NSData *rgbaData = CKDLibRawConvertToRGBA8888(processedImage, &rgbaError);
    if (rgbaData == nil) {
        if (error) {
            *error = rgbaError;
        }
        LibRaw::dcraw_clear_mem(processedImage);
        return nil;
    }

    CKDLibRawRenderedImage *renderedImage = [[CKDLibRawRenderedImage alloc]
        initWithWidth:processedImage->width
               height:processedImage->height
             channels:processedImage->colors
       bitsPerChannel:processedImage->bits
             rawWidth:sizes.raw_width
            rawHeight:sizes.raw_height
         visibleWidth:sizes.width
        visibleHeight:sizes.height
           leftMargin:sizes.left_margin
            topMargin:sizes.top_margin
         rgba8888Data:rgbaData
        libRawVersion:[self libRawVersion]
    cameraWhiteBalance:cameraWhiteBalance];

    LibRaw::dcraw_clear_mem(processedImage);
    return renderedImage;
}

@end
