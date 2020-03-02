// Copyright 2016-present 650 Industries. All rights reserved.

#import <ABI37_0_0EXBarCodeScanner/ABI37_0_0EXBarCodeScanner.h>
#import <ABI37_0_0EXBarCodeScanner/ABI37_0_0EXBarCodeScannerUtils.h>
#import <ABI37_0_0UMBarCodeScannerInterface/ABI37_0_0UMBarCodeScannerInterface.h>
#import <ABI37_0_0UMCore/ABI37_0_0UMDefines.h>
#import <ZXingObjC/ZXingObjCCore.h>
#import <ZXingObjC/ZXingObjCPDF417.h>
#import <ZXingObjC/ZXingObjCOneD.h>

@interface ABI37_0_0EXBarCodeScanner() <AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVCaptureMetadataOutput *metadataOutput;
@property (nonatomic, weak) AVCaptureSession *session;
@property (nonatomic, weak) dispatch_queue_t sessionQueue;
@property (nonatomic, copy, nullable) void (^onBarCodeScanned)(NSDictionary*);
@property (nonatomic, assign, getter=isScanningBarCodes) BOOL barCodesScanning;
@property (nonatomic, strong) NSDictionary<NSString *, id> *settings;

@property (nonatomic, strong) NSDictionary<NSString *, id<ZXReader>> *zxingBarcodeReaders;
@property (nonatomic, assign) CGFloat zxingFPSProcessed;
@property (nonatomic, strong) AVCaptureVideoDataOutput* videoDataOutput;
@property (nonatomic, strong) dispatch_queue_t zxingCaptureQueue;
@property (nonatomic, assign) BOOL zxingEnabled;

@end

NSString *const ABI37_0_0EX_BARCODE_TYPES_KEY = @"barCodeTypes";

@implementation ABI37_0_0EXBarCodeScanner

- (instancetype)init
{
  if (self = [super init]) {
    _settings = [[NSMutableDictionary alloc] initWithDictionary:[[self class] _getDefaultSettings]];

    // zxing handles barcodes reading of following types:
    _zxingBarcodeReaders = @{
      // PDF417 - built-in PDF417 reader doesn't handle u'\0' (null) character - https://github.com/expo/expo/issues/4817
      AVMetadataObjectTypePDF417Code: [ZXPDF417Reader new],
      // Code39 - built-in Code39 reader doesn't read non-ideal (slightly rotated) images like this - https://github.com/expo/expo/pull/5976#issuecomment-545001008
      AVMetadataObjectTypeCode39Code: [ZXCode39Reader new],
    };
    _zxingFPSProcessed = 6;
    _zxingCaptureQueue = dispatch_queue_create("com.zxing.captureQueue", NULL);
    _zxingEnabled = YES;
  }
  return self;
}

# pragma mark - JS properties setters

- (void)setSettings:(NSDictionary<NSString *, id> *)settings
{
  for (NSString *key in settings) {
    if ([key isEqualToString:ABI37_0_0EX_BARCODE_TYPES_KEY]) {
      NSArray<NSString *> *value = settings[key];
      NSSet *previousTypes = [NSSet setWithArray:_settings[ABI37_0_0EX_BARCODE_TYPES_KEY]];
      NSSet *newTypes = [NSSet setWithArray:value];
      if (![previousTypes isEqualToSet:newTypes]) {
        NSMutableDictionary<NSString *, id> *nextSettings = [[NSMutableDictionary alloc] initWithDictionary:_settings];
        nextSettings[ABI37_0_0EX_BARCODE_TYPES_KEY] = value;
        _settings = nextSettings;
        NSSet *zxingCoveredTypes = [NSSet setWithArray:[_zxingBarcodeReaders allKeys]];
        _zxingEnabled = [zxingCoveredTypes intersectsSet:newTypes];
        ABI37_0_0UM_WEAKIFY(self);
        [self _runBlockIfQueueIsPresent:^{
          ABI37_0_0UM_ENSURE_STRONGIFY(self);
          [self maybeStartBarCodeScanning];
        }];
      }
    }
  }
}

- (void)setIsEnabled:(BOOL)newBarCodeScanning
{
  if ([self isScanningBarCodes] == newBarCodeScanning) {
    return;
  }
  _barCodesScanning = newBarCodeScanning;
  ABI37_0_0UM_WEAKIFY(self);
  [self _runBlockIfQueueIsPresent:^{
    ABI37_0_0UM_ENSURE_STRONGIFY(self);
    if ([self isScanningBarCodes]) {
      if (self.metadataOutput) {
        [self _setConnectionsEnabled:true];
      } else {
        [self maybeStartBarCodeScanning];
      }
    } else {
      [self _setConnectionsEnabled:false];
    }
  }];
}

# pragma mark - Public API

- (void)maybeStartBarCodeScanning
{
  if (!_session || !_sessionQueue || ![self isScanningBarCodes]) {
    return;
  }

  if (!_metadataOutput || !_videoDataOutput) {
    [_session beginConfiguration];

    if (!_metadataOutput) {
      AVCaptureMetadataOutput *metadataOutput = [[AVCaptureMetadataOutput alloc] init];
      [metadataOutput setMetadataObjectsDelegate:self queue:_sessionQueue];
      if ([_session canAddOutput:metadataOutput]) {
        [_session addOutput:metadataOutput];
        _metadataOutput = metadataOutput;
      }
    }

    if (!_videoDataOutput) {
      AVCaptureVideoDataOutput *videoDataOutput = [AVCaptureVideoDataOutput new];
      [videoDataOutput setVideoSettings:@{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA],
      }];
      [videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
      [videoDataOutput setSampleBufferDelegate:self queue:_zxingCaptureQueue];
      if ([_session canAddOutput:videoDataOutput]) {
        [_session addOutput:videoDataOutput];
        _videoDataOutput = videoDataOutput;
      }
    }

    [_session commitConfiguration];

    if (!_metadataOutput) {
      return;
    }
  }

  NSArray<AVMetadataObjectType> *availableRequestedObjectTypes = @[];
  NSArray<AVMetadataObjectType> *requestedObjectTypes = @[];
  NSArray<AVMetadataObjectType> *availableObjectTypes = _metadataOutput.availableMetadataObjectTypes;
  if (_settings && _settings[ABI37_0_0EX_BARCODE_TYPES_KEY]) {
    requestedObjectTypes = [[NSArray alloc] initWithArray:_settings[ABI37_0_0EX_BARCODE_TYPES_KEY]];
  }

  for(AVMetadataObjectType objectType in requestedObjectTypes) {
    if ([availableObjectTypes containsObject:objectType]) {
      availableRequestedObjectTypes = [availableRequestedObjectTypes arrayByAddingObject:objectType];
    }
  }

  [_metadataOutput setMetadataObjectTypes:availableRequestedObjectTypes];
}

- (void)stopBarCodeScanning
{
  if (!_session) {
    return;
  }

  [_session beginConfiguration];

  if ([_session.outputs containsObject:_metadataOutput]) {
    [_session removeOutput:_metadataOutput];
    _metadataOutput = nil;
  }

  if ([_session.outputs containsObject:_videoDataOutput]) {
    [_session removeOutput:_videoDataOutput];
    _videoDataOutput = nil;
  }

  [_session commitConfiguration];

  if ([self isScanningBarCodes] && _onBarCodeScanned) {
    _onBarCodeScanned(nil);
  }
}

# pragma mark - Private API

- (void)_setConnectionsEnabled:(BOOL)enabled
{
  if (!_metadataOutput) {
    return;
  }
  for (AVCaptureConnection *connection in _metadataOutput.connections) {
    connection.enabled = enabled;
  }
}

- (void)_runBlockIfQueueIsPresent:(void (^)(void))block
{
  if (_sessionQueue) {
    dispatch_async(_sessionQueue, block);
  }
}

# pragma mark - AVCaptureMetadataOutputObjectsDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection
{
  if (!_settings || !_settings[ABI37_0_0EX_BARCODE_TYPES_KEY] || !_metadataOutput) {
    return;
  }

  for (AVMetadataObject *metadata in metadataObjects) {
    if ([metadata isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
      AVMetadataMachineReadableCodeObject *codeMetadata = (AVMetadataMachineReadableCodeObject *) metadata;
      for (id barcodeType in _settings[ABI37_0_0EX_BARCODE_TYPES_KEY]) {
        // some barcodes aren't handled properly by iOS SDK build-in reader -> zxing handles it in separate flow
        if ([_zxingBarcodeReaders objectForKey:barcodeType]) {
          continue;
        }
        if (codeMetadata.stringValue && [codeMetadata.type isEqualToString:barcodeType]) {

          NSDictionary *event = @{
                                  @"type" : codeMetadata.type,
                                  @"data" : codeMetadata.stringValue
                                  };

          if (_onBarCodeScanned) {
            _onBarCodeScanned(event);
          }
          return;
        }
      }
    }
  }
}

# pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate for ZXing

- (void)captureOutput:(AVCaptureVideoDataOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
  if (!_settings || !_settings[ABI37_0_0EX_BARCODE_TYPES_KEY] || !_metadataOutput) {
    return;
  }
  // do not use ZXing library if not scanning for predefined barcodes
  if (!_zxingEnabled) {
    return;
  }

  // below code is mostly taken from ZXing library itself
  float kMinMargin = 1.0 / _zxingFPSProcessed;

  // Gets the timestamp for each frame.
  CMTime presentTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

  @autoreleasepool {
    static double curFrameTimeStamp = 0;
    static double lastFrameTimeStamp = 0;

    curFrameTimeStamp = (double)presentTimeStamp.value / presentTimeStamp.timescale;

    if (curFrameTimeStamp - lastFrameTimeStamp > kMinMargin) {
      lastFrameTimeStamp = curFrameTimeStamp;

      CVImageBufferRef videoFrame = CMSampleBufferGetImageBuffer(sampleBuffer);
      CGImageRef videoFrameImage = [ZXCGImageLuminanceSource createImageFromBuffer:videoFrame];
      [self scanBarcodesFromImage:videoFrameImage withCompletion:^(NSString* text, NSString* type, NSError* error){
        // text contains characteres u'\0' (null character) that malforme resulting string, so we get rid of them
        NSMutableString* data = [NSMutableString new];
        for (int i = 0; i < [text length]; i++) {
          if ([text characterAtIndex:i] != u'\0') {
            [data appendFormat:@"%c", [text characterAtIndex:i]];
          }
        }
        NSDictionary *event = @{
          @"type": type,
          @"data": data,
        };
        if (self->_onBarCodeScanned) {
          self->_onBarCodeScanned(event);
        }
      }];
    }
  }
}

- (void)scanBarcodesFromImage:(CGImageRef)image
               withCompletion:(void(^)(NSString* text, NSString* type, NSError* error))completion
{
  ZXCGImageLuminanceSource *source = [[ZXCGImageLuminanceSource alloc] initWithCGImage:image];
  CGImageRelease(image);

  ZXHybridBinarizer *binarizer = [[ZXHybridBinarizer alloc] initWithSource:source];
  ZXBinaryBitmap *bitmap = [[ZXBinaryBitmap alloc] initWithBinarizer:binarizer];

  NSError *error = nil;
  ZXResult *result;
  
  for (id<ZXReader> reader in [_zxingBarcodeReaders allValues]) {
    result = [reader decode:bitmap hints:nil error:&error];
    if (result) {
      break;
    }
  }
  // rotate bitmap by 90° only, becasue zxing rotates bitmap by 180° internally, so that each possible orientation is covered
  if (!result && [bitmap rotateSupported]) {
    ZXBinaryBitmap *rotatedBitmap = [bitmap rotateCounterClockwise];
    for (id<ZXReader> reader in [_zxingBarcodeReaders allValues]) {
      result = [reader decode:rotatedBitmap hints:nil error:&error];
      if (result) {
        break;
      }
    }
  }

  if (result) {
    NSString* type = [ABI37_0_0EXBarCodeScanner zxingFormatToString:result.barcodeFormat];
    completion(result.text, type, error);
  }
}

+ (NSString *)zxingFormatToString:(ZXBarcodeFormat)format
{
  switch (format) {
    case kBarcodeFormatPDF417:
      return AVMetadataObjectTypePDF417Code;
    case kBarcodeFormatCode39:
      return AVMetadataObjectTypeCode39Code;
    default:
      return @"unknown";
  }
}

# pragma mark - default settings

+ (NSDictionary *)_getDefaultSettings
{
  return @{
           ABI37_0_0EX_BARCODE_TYPES_KEY: [[ABI37_0_0EXBarCodeScannerUtils validBarCodeTypes] allValues],
           };
}

@end
