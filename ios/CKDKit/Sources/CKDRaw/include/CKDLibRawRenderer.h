#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const CKDLibRawRendererErrorDomain;

@interface CKDLibRawRenderOptions : NSObject

@property (nonatomic) double redMultiplier;
@property (nonatomic) double greenMultiplier;
@property (nonatomic) double blueMultiplier;
@property (nonatomic) double fourthMultiplier;
@property (nonatomic) double brightness;
@property (nonatomic) BOOL noAutoBright;
@property (nonatomic) BOOL useCameraWhiteBalance;
@property (nonatomic) BOOL useAutoWhiteBalance;
@property (nonatomic) NSInteger outputColor;
@property (nonatomic) NSInteger demosaicAlgorithm;
@property (nonatomic) NSInteger outputBitsPerSample;
@property (nonatomic) NSInteger userFlip;

- (instancetype)initWithRedMultiplier:(double)redMultiplier
                      greenMultiplier:(double)greenMultiplier
                       blueMultiplier:(double)blueMultiplier
                     fourthMultiplier:(double)fourthMultiplier
                            brightness:(double)brightness;

@end

@interface CKDLibRawRenderedImage : NSObject

@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) NSInteger channels;
@property (nonatomic, readonly) NSInteger bitsPerChannel;
@property (nonatomic, readonly) NSInteger rawWidth;
@property (nonatomic, readonly) NSInteger rawHeight;
@property (nonatomic, readonly) NSInteger visibleWidth;
@property (nonatomic, readonly) NSInteger visibleHeight;
@property (nonatomic, readonly) NSInteger leftMargin;
@property (nonatomic, readonly) NSInteger topMargin;
@property (nonatomic, strong, readonly) NSData *rgba8888Data;
@property (nonatomic, copy, readonly) NSString *libRawVersion;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *cameraWhiteBalance;

@end

@interface CKDLibRawImageInfo : NSObject

@property (nonatomic, readonly) NSInteger pixelCount;
@property (nonatomic, readonly) BOOL linear;

@end

@interface CKDLibRawRenderer : NSObject

+ (NSString *)libRawVersion;
+ (nullable CKDLibRawImageInfo *)inspectImageAtPath:(NSString *)path error:(NSError **)error;
+ (NSInteger)libRawVersionNumber;
+ (nullable CKDLibRawRenderedImage *)renderImageAtPath:(NSString *)path
                                               options:(CKDLibRawRenderOptions *)options
                                                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
