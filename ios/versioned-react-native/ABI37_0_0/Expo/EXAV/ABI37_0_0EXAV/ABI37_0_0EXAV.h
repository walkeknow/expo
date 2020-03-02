// Copyright 2017-present 650 Industries. All rights reserved.

#import <AVFoundation/AVFoundation.h>

#import <ABI37_0_0UMCore/ABI37_0_0UMModuleRegistryConsumer.h>
#import <ABI37_0_0UMCore/ABI37_0_0UMAppLifecycleListener.h>
#import <ABI37_0_0UMCore/ABI37_0_0UMExportedModule.h>
#import <ABI37_0_0UMCore/ABI37_0_0UMEventEmitter.h>
#import <ABI37_0_0EXAV/ABI37_0_0EXAVObject.h>

typedef NS_OPTIONS(NSUInteger, ABI37_0_0EXAudioInterruptionMode)
{
  ABI37_0_0EXAudioInterruptionModeMixWithOthers = 0,
  ABI37_0_0EXAudioInterruptionModeDoNotMix      = 1,
  ABI37_0_0EXAudioInterruptionModeDuckOthers    = 2
};

typedef NS_OPTIONS(NSUInteger, ABI37_0_0EXAudioRecordingOptionBitRateStrategy)
{
  ABI37_0_0EXAudioRecordingOptionBitRateStrategyConstant            = 0,
  ABI37_0_0EXAudioRecordingOptionBitRateStrategyLongTermAverage     = 1,
  ABI37_0_0EXAudioRecordingOptionBitRateStrategyVariableConstrained = 2,
  ABI37_0_0EXAudioRecordingOptionBitRateStrategyVariable            = 3
};

@protocol ABI37_0_0EXAVScopedModuleDelegate

// Call this when your module knows it won't use the audio session now
// but may do in the future (settings persist).
- (void)moduleDidBackground:(id)module;
// Call this when your module knows it will use the audio session now.
- (void)moduleDidForeground:(id)module;
// Call this when your module knows it won't use the audio session now
// or in the future (forget settings).
- (void)moduleWillDeallocate:(id)module;
- (BOOL)isActiveForModule:(id)module;
- (NSString *)activeCategory;
- (AVAudioSessionCategoryOptions)activeCategoryOptions;
- (NSError *)setActive:(BOOL)active forModule:(id)module;
- (NSError *)setCategory:(NSString *)category withOptions:(AVAudioSessionCategoryOptions)options forModule:(id)module;

@end

@protocol ABI37_0_0EXAVInterface

- (NSError *)promoteAudioSessionIfNecessary;

- (NSError *)demoteAudioSessionIfPossible;

- (void)registerVideoForAudioLifecycle:(NSObject<ABI37_0_0EXAVObject> *)video;

- (void)unregisterVideoForAudioLifecycle:(NSObject<ABI37_0_0EXAVObject> *)video;

@end

@interface ABI37_0_0EXAV : ABI37_0_0UMExportedModule <ABI37_0_0UMEventEmitter, ABI37_0_0UMAppLifecycleListener, ABI37_0_0UMModuleRegistryConsumer, ABI37_0_0EXAVInterface>

- (void)handleMediaServicesReset:(NSNotification *)notification;
- (void)handleAudioSessionInterruption:(NSNotification *)notification;

@end
