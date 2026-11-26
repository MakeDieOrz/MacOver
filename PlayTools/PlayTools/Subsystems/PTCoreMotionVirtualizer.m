//
//  PTCoreMotionVirtualizer.m
//  PlayTools
//
//  CoreMotion sensor virtualization & sample payload spoofing.
//

#import "PSInternal.h"
#import <CoreMotion/CoreMotion.h>
#include <math.h>

__attribute__((visibility("hidden")))
@interface PSVirtualMotionState : NSObject
@property (nonatomic, assign) BOOL accelActive;
@property (nonatomic, assign) BOOL gyroActive;
@property (nonatomic, assign) BOOL magActive;
@property (nonatomic, assign) BOOL dmActive;
@property (nonatomic, assign) uint64_t accelGen;
@property (nonatomic, assign) uint64_t gyroGen;
@property (nonatomic, assign) uint64_t magGen;
@property (nonatomic, assign) uint64_t dmGen;
@property (nonatomic, assign) BOOL hasExplicitMagUpdateInterval;
@property (nonatomic, assign) NSTimeInterval explicitMagUpdateInterval;
@property (nonatomic, assign) CMAttitudeReferenceFrame dmReferenceFrame;
@property (nonatomic, assign) CMQuaternion simQuat;
@property (nonatomic, assign) BOOL hasSimQuat;
@property (nonatomic, assign) double simLastTs;
@property (nonatomic, strong) id lastAccelSample;
@property (nonatomic, assign) double lastAccelMonoSec;
@property (nonatomic, strong) id lastGyroSample;
@property (nonatomic, assign) double lastGyroMonoSec;
@property (nonatomic, strong) id lastMagSample;
@property (nonatomic, assign) double lastMagMonoSec;
@property (nonatomic, strong) id lastDMSample;
@property (nonatomic, assign) double lastDMMonoSec;
@property (nonatomic, strong) dispatch_source_t accelTimer;
@property (nonatomic, strong) dispatch_source_t gyroTimer;
@property (nonatomic, strong) dispatch_source_t magTimer;
@property (nonatomic, strong) dispatch_source_t dmTimer;
@end

@implementation PSVirtualMotionState
- (void)dealloc {
    if (_accelTimer) { dispatch_source_cancel(_accelTimer); _accelTimer = nil; }
    if (_gyroTimer) { dispatch_source_cancel(_gyroTimer); _gyroTimer = nil; }
    if (_magTimer) { dispatch_source_cancel(_magTimer); _magTimer = nil; }
    if (_dmTimer) { dispatch_source_cancel(_dmTimer); _dmTimer = nil; }
}
@end

__attribute__((visibility("hidden")))
@interface PSVirtualAltimeterState : NSObject
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL emittedFirstSample;
@property (nonatomic, assign) uint64_t generation;
@property (nonatomic, strong) dispatch_source_t timer;
@end

@implementation PSVirtualAltimeterState
- (void)dealloc {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
}
@end

__attribute__((visibility("hidden")))
@interface PSVirtualPedometerState : NSObject
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) uint64_t generation;
@property (nonatomic, strong) NSDate *startDate;
@property (nonatomic, strong) dispatch_source_t timer;
@end

@implementation PSVirtualPedometerState
- (void)dealloc {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
}
@end

static const char kPSMotionStateAssocKey = 0;
static const char kPSAltimeterStateAssocKey = 0;
static const char kPSPedometerStateAssocKey = 0;
static const char kPSMotionSamplePayloadKey = 0;
static const char kPSMotionSampleRefFrameKey = 0;
static const char kPSAttitudePayloadKey = 0;
static const char kPSRealAlignedTimestampKey = 0;
static const char kPSRealAlignedContinuousTimestampKey = 0;
static const char kPSRealDMMagneticFieldKey = 0;
static const char kPSPedometerPayloadKey = 0;
static _Atomic uint64_t s_ps_motion_tick = 1ULL;

static os_unfair_lock s_ps_cm_clock_lock = OS_UNFAIR_LOCK_INIT;
static BOOL s_ps_cm_has_real_ts_offset = NO;
static double s_ps_cm_real_ts_offset = 0.0;
static BOOL s_ps_cm_has_real_cont_ts_offset = NO;
static double s_ps_cm_real_cont_ts_offset = 0.0;
static double s_ps_cm_last_virtual_ts = 0.0;

static os_unfair_lock s_cm_swizzle_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_cm_orig_timestamp_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_cont_ts_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_copy_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_encode_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_desc_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_isEqual_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_accel_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_rot_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_mag_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_att_roll_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_att_pitch_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_att_yaw_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_att_quat_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_att_mat_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_att_mul_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_dm_attitude_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_dm_gravity_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_dm_userAccel_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_dm_mag_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_dm_heading_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_dm_headingAcc_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_dm_sensorLoc_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_dm_isInit_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_alt_rel_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_alt_press_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_ped_startDate_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_ped_endDate_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_ped_steps_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_ped_dist_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_ped_floorsAsc_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_ped_floorsDesc_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_ped_curPace_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_ped_curCadence_imps = NULL;
static CFMutableDictionaryRef s_cm_orig_ped_avgPace_imps = NULL;

__attribute__((visibility("hidden")))
@interface PSVirtualAttitudePayload : NSObject {
@public
    os_unfair_lock _lock;
    double _roll;
    double _pitch;
    double _yaw;
    CMQuaternion _quaternion;
    CMRotationMatrix _rotationMatrix;
}
@end

@implementation PSVirtualAttitudePayload
- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}
@end

__attribute__((visibility("hidden")))
@interface PSVirtualMotionSamplePayload : NSObject {
@public
    os_unfair_lock _lock;
    BOOL _hasTimestamp;
    NSTimeInterval _timestamp;
    CMAcceleration _acceleration;
    CMRotationRate _rotationRate;
    CMMagneticField _magneticField;
    CMAcceleration _gravity;
    CMAcceleration _userAcceleration;
    CMCalibratedMagneticField _calibratedMagneticField;
    double _heading;
    double _headingAccuracy;
    CMAttitude *_attitude;
    NSNumber *_relativeAltitude;
    NSNumber *_pressure;
}
@end

@implementation PSVirtualMotionSamplePayload
- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _heading = -1.0;
        _headingAccuracy = -1.0;
    }
    return self;
}
@end

__attribute__((visibility("hidden")))
@interface PSVirtualPedometerPayload : NSObject {
@public
    NSDate *_startDate;
    NSDate *_endDate;
    NSNumber *_numberOfSteps;
    NSNumber *_distance;
    NSNumber *_floorsAscended;
    NSNumber *_floorsDescended;
    NSNumber *_currentPace;
    NSNumber *_currentCadence;
    NSNumber *_averageActivePace;
}
@end

@implementation PSVirtualPedometerPayload
@end

static PSVirtualPedometerState *ps_pedometer_state(id ped, BOOL createIfMissing) {
    if (ped == nil) {
        return nil;
    }
    @synchronized (ped) {
        PSVirtualPedometerState *st = objc_getAssociatedObject(ped, &kPSPedometerStateAssocKey);
        if (st == nil && createIfMissing) {
            st = [[PSVirtualPedometerState alloc] init];
            objc_setAssociatedObject(ped, &kPSPedometerStateAssocKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return st;
    }
}

static PSVirtualPedometerPayload *ps_pedometer_payload(id data) {
    if (data == nil) {
        return nil;
    }
    return objc_getAssociatedObject(data, &kPSPedometerPayloadKey);
}

static BOOL ps_cm_ref_frame_has_north(CMAttitudeReferenceFrame frame) {
    return (frame & (CMAttitudeReferenceFrameXMagneticNorthZVertical |
                     CMAttitudeReferenceFrameXTrueNorthZVertical)) != 0;
}

static BOOL ps_cm_ref_frame_has_calibrated_mag(CMAttitudeReferenceFrame frame) {
    return (frame & (CMAttitudeReferenceFrameXArbitraryCorrectedZVertical |
                     CMAttitudeReferenceFrameXMagneticNorthZVertical |
                     CMAttitudeReferenceFrameXTrueNorthZVertical)) != 0;
}

static PSVirtualMotionState *ps_motion_state(id mgr, BOOL createIfMissing) {
    if (mgr == nil) {
        return nil;
    }
    @synchronized (mgr) {
        PSVirtualMotionState *st = objc_getAssociatedObject(mgr, &kPSMotionStateAssocKey);
        if (st == nil && createIfMissing) {
            st = [[PSVirtualMotionState alloc] init];
            objc_setAssociatedObject(mgr, &kPSMotionStateAssocKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return st;
    }
}

static PSVirtualAltimeterState *ps_altimeter_state(id alt, BOOL createIfMissing) {
    if (alt == nil) {
        return nil;
    }
    @synchronized (alt) {
        PSVirtualAltimeterState *st = objc_getAssociatedObject(alt, &kPSAltimeterStateAssocKey);
        if (st == nil && createIfMissing) {
            st = [[PSVirtualAltimeterState alloc] init];
            objc_setAssociatedObject(alt, &kPSAltimeterStateAssocKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return st;
    }
}

static inline double ps_motion_micro_jitter(uint64_t seed, double scale) {
    uint64_t x = seed * 6364136223846793005ULL + 1442695040888963407ULL;
    x ^= (x >> 33);
    int32_t centered = (int32_t)(x & 0xFFFFU) - 32768;
    return ((double)centered / 32768.0) * scale;
}

static PSVirtualMotionSamplePayload *ps_motion_sample_payload(id sample, BOOL createIfMissing);
static PSVirtualAttitudePayload *ps_attitude_payload(id att, BOOL createIfMissing);

static BOOL ps_is_virtual_motion_sample(id sample) {
    if (sample == nil) {
        return NO;
    }
    return (ps_motion_sample_payload(sample, NO) != nil) || (ps_attitude_payload(sample, NO) != nil);
}

static NSTimeInterval ps_cm_next_virtual_timestamp_locked(double up) {
    static const double kMaxLeadSeconds = 0.01;
    double ts = (isfinite(up) && up >= 0.0) ? up : 0.0;
    if (ts <= s_ps_cm_last_virtual_ts) {
        double nudged = s_ps_cm_last_virtual_ts + 0.0001;
        double ceiling = ts + kMaxLeadSeconds;
        ts = (nudged <= ceiling) ? nudged : ceiling;
        if (ts < s_ps_cm_last_virtual_ts) {
            ts = s_ps_cm_last_virtual_ts;
        }
    }
    s_ps_cm_last_virtual_ts = ts;
    return ts;
}

static NSTimeInterval ps_cm_next_virtual_timestamp(void) {
    double up = [[NSProcessInfo processInfo] systemUptime];
    if (!isfinite(up) || up < 0.0) {
        up = 0.0;
    }
    os_unfair_lock_lock(&s_ps_cm_clock_lock);
    double ts = ps_cm_next_virtual_timestamp_locked(up);
    os_unfair_lock_unlock(&s_ps_cm_clock_lock);
    return ts;
}

static NSTimeInterval ps_cm_aligned_real_timestamp(id sample, double rawTs, BOOL isContinuous) {
    if (sample == nil) {
        return ps_cm_next_virtual_timestamp();
    }
    const void *assocKey = isContinuous ? &kPSRealAlignedContinuousTimestampKey : &kPSRealAlignedTimestampKey;
    @synchronized (sample) {
        NSNumber *cached = objc_getAssociatedObject(sample, assocKey);
        if (cached != nil) {
            return [cached doubleValue];
        }
        double up = [[NSProcessInfo processInfo] systemUptime];
        if (!isfinite(up) || up < 0.0) {
            up = 0.0;
        }
        double aligned;
        os_unfair_lock_lock(&s_ps_cm_clock_lock);
        if (!isfinite(rawTs) || rawTs <= 0.0) {
            aligned = ps_cm_next_virtual_timestamp_locked(up);
        } else {
            BOOL *hasOffsetPtr = isContinuous ? &s_ps_cm_has_real_cont_ts_offset : &s_ps_cm_has_real_ts_offset;
            double *offsetPtr = isContinuous ? &s_ps_cm_real_cont_ts_offset : &s_ps_cm_real_ts_offset;
            double candidate = *hasOffsetPtr ? (rawTs + *offsetPtr) : rawTs;
            if (!isfinite(candidate) || candidate > up + 0.01 || candidate < 0.0 || (up - candidate) > 60.0) {
                *offsetPtr = up - rawTs;
                *hasOffsetPtr = YES;
                candidate = up;
            }
            aligned = candidate;
            if (!isContinuous && aligned > s_ps_cm_last_virtual_ts) {
                s_ps_cm_last_virtual_ts = aligned;
            }
        }
        os_unfair_lock_unlock(&s_ps_cm_clock_lock);
        objc_setAssociatedObject(sample,
                                 assocKey,
                                 @(aligned),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return aligned;
    }
}

static void ps_cm_observe_real_sample(id sample) {
    if (sample == nil || ps_is_virtual_motion_sample(sample)) {
        return;
    }
    if ([sample respondsToSelector:@selector(timestamp)]) {
        double rawTs = ((double (*)(id, SEL))objc_msgSend)(sample, @selector(timestamp));
        (void)ps_cm_aligned_real_timestamp(sample, rawTs, NO);
    }
    SEL contTsSel = NSSelectorFromString(@"continuousTimestamp");
    if ([sample respondsToSelector:contTsSel]) {
        double rawContTs = ((double (*)(id, SEL))objc_msgSend)(sample, contTsSel);
        (void)ps_cm_aligned_real_timestamp(sample, rawContTs, YES);
    }
}

static void ps_attitude_update_from_quaternion_locked(PSVirtualAttitudePayload *att, CMQuaternion q) {
    double normSq = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w;
    if (!isfinite(normSq) || normSq <= 1e-18) {
        q = (CMQuaternion){ .x = 0.00425, .y = 0.0006, .z = 0.0, .w = 0.99999079 };
        normSq = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w;
    }
    double invNorm = 1.0 / sqrt(normSq);
    q.x *= invNorm;
    q.y *= invNorm;
    q.z *= invNorm;
    q.w *= invNorm;
    att->_quaternion = q;

    double xx = q.x * q.x;
    double yy = q.y * q.y;
    double zz = q.z * q.z;
    double xy = q.x * q.y;
    double xz = q.x * q.z;
    double yz = q.y * q.z;
    double xw = q.x * q.w;
    double yw = q.y * q.w;
    double zw = q.z * q.w;

    CMRotationMatrix m = {
        .m11 = 1.0 - 2.0 * (yy + zz),
        .m12 = 2.0 * (xy - zw),
        .m13 = 2.0 * (xz + yw),
        .m21 = 2.0 * (xy + zw),
        .m22 = 1.0 - 2.0 * (xx + zz),
        .m23 = 2.0 * (yz - xw),
        .m31 = 2.0 * (xz - yw),
        .m32 = 2.0 * (yz + xw),
        .m33 = 1.0 - 2.0 * (xx + yy)
    };
    att->_rotationMatrix = m;
    double clampedSinPitch = fmax(-1.0, fmin(1.0, m.m32));
    att->_pitch = asin(clampedSinPitch);
    att->_roll = atan2(-m.m31, m.m33);
    att->_yaw = atan2(-m.m12, m.m22);
}

static PSVirtualAttitudePayload *ps_make_initialized_attitude_payload(CMQuaternion q) {
    PSVirtualAttitudePayload *payload = [[PSVirtualAttitudePayload alloc] init];
    ps_attitude_update_from_quaternion_locked(payload, q);
    return payload;
}

static PSVirtualAttitudePayload *ps_attitude_payload(id att, BOOL createIfMissing) {
    if (att == nil) {
        return nil;
    }
    @synchronized (att) {
        PSVirtualAttitudePayload *payload = objc_getAssociatedObject(att, &kPSAttitudePayloadKey);
        if (payload == nil && createIfMissing) {
            payload = ps_make_initialized_attitude_payload((CMQuaternion){
                .x = 0.00425, .y = 0.0006, .z = 0.0, .w = 0.99999079
            });
            objc_setAssociatedObject(att, &kPSAttitudePayloadKey, payload, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return payload;
    }
}

static CMAttitude *ps_make_virtual_attitude_with_quaternion(CMQuaternion q) {
    Class attCls = objc_getClass("CMAttitude");
    if (attCls == Nil) {
        return nil;
    }
    CMAttitude *att = [[attCls alloc] init];
    if (att != nil) {
        PSVirtualAttitudePayload *payload = ps_make_initialized_attitude_payload(q);
        objc_setAssociatedObject(att, &kPSAttitudePayloadKey, payload, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return att;
}

static PSVirtualMotionSamplePayload *ps_make_initialized_motion_payload_for_state(
    BOOL includeAttitude,
    PSVirtualMotionState *state) {
    PSVirtualMotionSamplePayload *payload = [[PSVirtualMotionSamplePayload alloc] init];
    uint64_t t = atomic_fetch_add_explicit(&s_ps_motion_tick, 1ULL, memory_order_relaxed);
    payload->_timestamp = ps_cm_next_virtual_timestamp();
    payload->_hasTimestamp = YES;
    payload->_acceleration = (CMAcceleration){
        .x = 0.0012 + ps_motion_micro_jitter(t, 0.0004),
        .y = -0.0085 + ps_motion_micro_jitter(t ^ 0x9E3779B9ULL, 0.0004),
        .z = -0.9998 + ps_motion_micro_jitter(t ^ 0x517CC1B7ULL, 0.0004)
    };
    payload->_rotationRate = (CMRotationRate){
        .x = ps_motion_micro_jitter(t ^ 0x11ULL, 0.0003),
        .y = ps_motion_micro_jitter(t ^ 0x22ULL, 0.0003),
        .z = ps_motion_micro_jitter(t ^ 0x33ULL, 0.0003)
    };
    payload->_magneticField = (CMMagneticField){
        .x = 18.4 + ps_motion_micro_jitter(t ^ 0x44ULL, 0.02),
        .y = -6.2 + ps_motion_micro_jitter(t ^ 0x55ULL, 0.02),
        .z = -41.5 + ps_motion_micro_jitter(t ^ 0x66ULL, 0.02)
    };
    payload->_gravity = (CMAcceleration){
        .x = 0.0012,
        .y = -0.0085,
        .z = -0.999963
    };
    payload->_userAcceleration = (CMAcceleration){
        .x = ps_motion_micro_jitter(t ^ 0x77ULL, 0.0003),
        .y = ps_motion_micro_jitter(t ^ 0x88ULL, 0.0003),
        .z = ps_motion_micro_jitter(t ^ 0x99ULL, 0.0003)
    };
    CMAttitudeReferenceFrame refFrame = (state != nil && state.dmReferenceFrame != 0)
        ? state.dmReferenceFrame
        : CMAttitudeReferenceFrameXArbitraryZVertical;
    BOOL hasCalibratedMag = ps_cm_ref_frame_has_calibrated_mag(refFrame);
    BOOL hasNorth = ps_cm_ref_frame_has_north(refFrame);
    if (hasCalibratedMag) {
        payload->_calibratedMagneticField = (CMCalibratedMagneticField){
            .field = payload->_magneticField,
            .accuracy = CMMagneticFieldCalibrationAccuracyHigh
        };
    } else {
        payload->_calibratedMagneticField = (CMCalibratedMagneticField){
            .field = { .x = 0.0, .y = 0.0, .z = 0.0 },
            .accuracy = CMMagneticFieldCalibrationAccuracyUncalibrated
        };
    }
    if (hasNorth) {
        payload->_heading = 18.6 + ps_motion_micro_jitter(t ^ 0xABULL, 0.08);
        payload->_headingAccuracy = 15.0;
    } else {
        payload->_heading = -1.0;
        payload->_headingAccuracy = -1.0;
    }
    if (includeAttitude) {
        CMQuaternion q = {
            .x = 0.00425 + ps_motion_micro_jitter(t ^ 0xAAULL, 0.00005),
            .y = 0.0006 + ps_motion_micro_jitter(t ^ 0xBBULL, 0.00005),
            .z = ps_motion_micro_jitter(t ^ 0xCCULL, 0.00005),
            .w = 0.99999079
        };
        if (state != nil) {
            if (!state.hasSimQuat) {
                state.simQuat = q;
                state.hasSimQuat = YES;
                state.simLastTs = payload->_timestamp;
            } else {
                double dt = payload->_timestamp - state.simLastTs;
                state.simLastTs = payload->_timestamp;
                if (dt > 0.0) {
                    if (dt > 0.2) {
                        dt = 0.2;
                    }
                    double wx = payload->_rotationRate.x;
                    double wy = payload->_rotationRate.y;
                    double wz = payload->_rotationRate.z;
                    double omega = sqrt(wx * wx + wy * wy + wz * wz);
                    double theta = omega * dt;
                    CMQuaternion dq;
                    if (theta > 1e-8 && omega > 0.0) {
                        double s = sin(0.5 * theta) / omega;
                        dq = (CMQuaternion){ .x = wx * s, .y = wy * s, .z = wz * s, .w = cos(0.5 * theta) };
                    } else {
                        dq = (CMQuaternion){ .x = 0.5 * wx * dt, .y = 0.5 * wy * dt, .z = 0.5 * wz * dt, .w = 1.0 };
                    }
                    CMQuaternion q0 = state.simQuat;
                    CMQuaternion q1 = {
                        .w = q0.w * dq.w - q0.x * dq.x - q0.y * dq.y - q0.z * dq.z,
                        .x = q0.w * dq.x + q0.x * dq.w + q0.y * dq.z - q0.z * dq.y,
                        .y = q0.w * dq.y - q0.x * dq.z + q0.y * dq.w + q0.z * dq.x,
                        .z = q0.w * dq.z + q0.x * dq.y - q0.y * dq.x + q0.z * dq.w
                    };
                    double norm = sqrt(q1.x * q1.x + q1.y * q1.y + q1.z * q1.z + q1.w * q1.w);
                    if (isfinite(norm) && norm > 1e-12) {
                        double inv = 1.0 / norm;
                        q1.x *= inv;
                        q1.y *= inv;
                        q1.z *= inv;
                        q1.w *= inv;
                        q = q1;
                        state.simQuat = q1;
                    }
                } else {
                    q = state.simQuat;
                }
            }
        }
        payload->_attitude = ps_make_virtual_attitude_with_quaternion(q);
        PSVirtualAttitudePayload *attP = ps_attitude_payload(payload->_attitude, NO);
        if (attP != nil) {
            payload->_gravity = (CMAcceleration){
                .x = -attP->_rotationMatrix.m31,
                .y = -attP->_rotationMatrix.m32,
                .z = -attP->_rotationMatrix.m33
            };
            if (hasNorth) {
                double deg = fmod(18.6 - attP->_yaw * (180.0 / M_PI), 360.0);
                if (deg < 0.0) {
                    deg += 360.0;
                }
                payload->_heading = deg;
            }
        }
    }
    payload->_relativeAltitude = @(0.0);
    payload->_pressure = @(101.325);
    return payload;
}

static PSVirtualMotionSamplePayload *ps_make_initialized_motion_payload(BOOL includeAttitude) {
    return ps_make_initialized_motion_payload_for_state(includeAttitude, nil);
}

static PSVirtualMotionSamplePayload *ps_motion_sample_payload(id sample, BOOL createIfMissing) {
    if (sample == nil) {
        return nil;
    }
    @synchronized (sample) {
        PSVirtualMotionSamplePayload *payload = objc_getAssociatedObject(sample, &kPSMotionSamplePayloadKey);
        if (payload == nil && createIfMissing) {
            Class dmCls = objc_getClass("CMDeviceMotion");
            BOOL needAtt = (dmCls != Nil && [sample isKindOfClass:dmCls]);
            payload = ps_make_initialized_motion_payload_for_state(needAtt, nil);
            objc_setAssociatedObject(sample, &kPSMotionSamplePayloadKey, payload, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return payload;
    }
}

static id ps_make_virtual_sample_instance_with_state(Class cls, PSVirtualMotionState *state) {
    if (cls == Nil) {
        return nil;
    }
    id instance = [[cls alloc] init];
    if (instance != nil) {
        Class dmCls = objc_getClass("CMDeviceMotion");
        BOOL needAtt = (dmCls != Nil && [cls isSubclassOfClass:dmCls]);
        PSVirtualMotionSamplePayload *payload = ps_make_initialized_motion_payload_for_state(needAtt, state);
        objc_setAssociatedObject(instance, &kPSMotionSamplePayloadKey, payload, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (needAtt) {
            CMAttitudeReferenceFrame refFrame = (state != nil && state.dmReferenceFrame != 0)
                ? state.dmReferenceFrame
                : CMAttitudeReferenceFrameXArbitraryZVertical;
            objc_setAssociatedObject(instance, &kPSMotionSampleRefFrameKey, @(refFrame), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return instance;
}

static id ps_make_virtual_sample_instance(Class cls) {
    return ps_make_virtual_sample_instance_with_state(cls, nil);
}

static CMAltitudeData *ps_make_virtual_altitude_sample(BOOL isFirstSample) {
    Class altDataCls = objc_getClass("CMAltitudeData");
    if (altDataCls == Nil) {
        return nil;
    }
    CMAltitudeData *instance = [[altDataCls alloc] init];
    if (instance != nil) {
        PSVirtualMotionSamplePayload *payload = ps_make_initialized_motion_payload(NO);
        uint64_t t = atomic_fetch_add_explicit(&s_ps_motion_tick, 1ULL, memory_order_relaxed);
        double relAlt = isFirstSample ? 0.0 : ps_motion_micro_jitter(t ^ 0xDDULL, 0.02);
        double press = 101.325 + (isFirstSample ? 0.0 : ps_motion_micro_jitter(t ^ 0xEEULL, 0.002));
        payload->_relativeAltitude = @(relAlt);
        payload->_pressure = @(press);
        objc_setAssociatedObject(instance, &kPSMotionSamplePayloadKey, payload, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return instance;
}

static NSTimeInterval ps_effective_mag_update_interval(id mgr) {
    PSVirtualMotionState *st = ps_motion_state(mgr, NO);
    if (st != nil) {
        @synchronized (st) {
            if (st.hasExplicitMagUpdateInterval) {
                return st.explicitMagUpdateInterval;
            }
        }
    }
    return 0.01;
}

static dispatch_source_t ps_create_suspended_motion_timer(id owner,
                                                          NSTimeInterval interval,
                                                          NSOperationQueue *queue,
                                                          void (^emitBlock)(id strongOwner)) {
    if (owner == nil || emitBlock == nil) {
        return nil;
    }
    double sec = (isfinite(interval) && interval >= 0.01) ? interval : 0.01;
    NSOperationQueue *targetQueue = queue ?: [NSOperationQueue mainQueue];
    __weak id weakOwner = owner;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (timer == nil) {
        return nil;
    }
    __weak dispatch_source_t weakTimer = timer;
    uint64_t ns = (uint64_t)(sec * (double)NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), ns, ns / 5ULL);
    dispatch_source_set_event_handler(timer, ^{
        id strongOwner = weakOwner;
        if (strongOwner == nil) {
            dispatch_source_t t = weakTimer;
            if (t != nil) {
                dispatch_source_cancel(t);
            }
            return;
        }
        [targetQueue addOperationWithBlock:^{
            id innerOwner = weakOwner;
            if (innerOwner != nil) {
                emitBlock(innerOwner);
            }
        }];
    });
    return timer;
}

static inline void ps_swizzle_cm_sel_if_defined(CFMutableDictionaryRef *dictPtr,
                                                Class cls,
                                                SEL origSel,
                                                SEL hookSel) {
    if (cls != Nil && origSel != NULL && hookSel != NULL &&
        ps_class_defines_instance_method(cls, origSel)) {
        ps_swizzle_class_sel_storing_imp(&s_cm_swizzle_lock, dictPtr, cls, origSel, hookSel);
    }
}

typedef id (*ps_cm_copy_zone_imp_t)(id, SEL, NSZone *) NS_RETURNS_RETAINED;

__attribute__((visibility("hidden")))
@interface PSVirtualAttitudeCoder : NSCoder {
@public
    CMQuaternion _q;
}
- (instancetype)initWithQuaternion:(CMQuaternion)q;
@end

@implementation PSVirtualAttitudeCoder
- (instancetype)initWithQuaternion:(CMQuaternion)q {
    self = [super init];
    if (self != nil) {
        _q = q;
    }
    return self;
}
- (BOOL)allowsKeyedCoding {
    return YES;
}
- (BOOL)requiresSecureCoding {
    return YES;
}
- (BOOL)containsValueForKey:(NSString *)key {
    return [key isEqualToString:@"kCMAttitudeCodingKeyQW"] ||
           [key isEqualToString:@"kCMAttitudeCodingKeyQX"] ||
           [key isEqualToString:@"kCMAttitudeCodingKeyQY"] ||
           [key isEqualToString:@"kCMAttitudeCodingKeyQZ"];
}
- (double)decodeDoubleForKey:(NSString *)key {
    if ([key isEqualToString:@"kCMAttitudeCodingKeyQW"]) return _q.w;
    if ([key isEqualToString:@"kCMAttitudeCodingKeyQX"]) return _q.x;
    if ([key isEqualToString:@"kCMAttitudeCodingKeyQY"]) return _q.y;
    if ([key isEqualToString:@"kCMAttitudeCodingKeyQZ"]) return _q.z;
    return 0.0;
}
@end

static NSInteger ps_cm_calibration_level_for_accuracy(CMMagneticFieldCalibrationAccuracy accuracy) {
    switch (accuracy) {
        case CMMagneticFieldCalibrationAccuracyHigh:
            return 6;
        case CMMagneticFieldCalibrationAccuracyMedium:
            return 4;
        case CMMagneticFieldCalibrationAccuracyLow:
            return 2;
        case CMMagneticFieldCalibrationAccuracyUncalibrated:
        default:
            return 0;
    }
}

static NSTimeInterval ps_cm_effective_sample_timestamp(id sample) {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(sample, NO);
    if (payload != nil) {
        os_unfair_lock_lock(&payload->_lock);
        if (!payload->_hasTimestamp) {
            payload->_timestamp = ps_cm_next_virtual_timestamp();
            payload->_hasTimestamp = YES;
        }
        NSTimeInterval ts = payload->_timestamp;
        os_unfair_lock_unlock(&payload->_lock);
        return ts;
    }
    NSNumber *cached = objc_getAssociatedObject(sample, &kPSRealAlignedTimestampKey);
    if (cached != nil) {
        return [cached doubleValue];
    }
    return [sample respondsToSelector:@selector(timestamp)]
        ? ((double (*)(id, SEL))objc_msgSend)(sample, @selector(timestamp))
        : 0.0;
}

static BOOL ps_cm_vec3_close(double ax, double ay, double az,
                             double bx, double by, double bz,
                             double tol) {
    return (fabs(ax - bx) < tol && fabs(ay - by) < tol && fabs(az - bz) < tol);
}

@implementation PSSwizzleHooks (PlayShadowCoreMotion)

- (id) pm_ps_cm_copyWithZone:(NSZone *)zone NS_RETURNS_RETAINED {
    PSVirtualAttitudePayload *attPayload = ps_attitude_payload(self, NO);
    if (attPayload != nil) {
        os_unfair_lock_lock(&attPayload->_lock);
        CMQuaternion q = attPayload->_quaternion;
        os_unfair_lock_unlock(&attPayload->_lock);
        CMAttitude *cloned = ps_make_virtual_attitude_with_quaternion(q);
        return cloned ?: self;
    }
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        Class dmCls = objc_getClass("CMDeviceMotion");
        if (dmCls != Nil && [self isKindOfClass:dmCls]) {
            CMDeviceMotion *cloned = [[object_getClass(self) alloc] init];
            if (cloned != nil) {
                PSVirtualMotionSamplePayload *copyPayload = [[PSVirtualMotionSamplePayload alloc] init];
                os_unfair_lock_lock(&payload->_lock);
                copyPayload->_hasTimestamp = payload->_hasTimestamp;
                copyPayload->_timestamp = payload->_timestamp;
                copyPayload->_acceleration = payload->_acceleration;
                copyPayload->_rotationRate = payload->_rotationRate;
                copyPayload->_magneticField = payload->_magneticField;
                copyPayload->_gravity = payload->_gravity;
                copyPayload->_userAcceleration = payload->_userAcceleration;
                copyPayload->_calibratedMagneticField = payload->_calibratedMagneticField;
                copyPayload->_heading = payload->_heading;
                copyPayload->_relativeAltitude = [payload->_relativeAltitude copy];
                copyPayload->_pressure = [payload->_pressure copy];
                CMAttitude *att = payload->_attitude;
                os_unfair_lock_unlock(&payload->_lock);
                copyPayload->_attitude = [att copyWithZone:zone];
                objc_setAssociatedObject(cloned,
                                         &kPSMotionSamplePayloadKey,
                                         copyPayload,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return cloned;
            }
        }
        return self;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_copy_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((ps_cm_copy_zone_imp_t)origIMP)(self, @selector(copyWithZone:), zone);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return self;
}

- (void) pm_ps_cm_encodeWithCoder:(NSCoder *)coder {
    PSVirtualAttitudePayload *attPayload = ps_attitude_payload(self, NO);
    if (attPayload != nil) {
        os_unfair_lock_lock(&attPayload->_lock);
        CMQuaternion q = attPayload->_quaternion;
        os_unfair_lock_unlock(&attPayload->_lock);
        [coder encodeDouble:q.w forKey:@"kCMAttitudeCodingKeyQW"];
        [coder encodeDouble:q.x forKey:@"kCMAttitudeCodingKeyQX"];
        [coder encodeDouble:q.y forKey:@"kCMAttitudeCodingKeyQY"];
        [coder encodeDouble:q.z forKey:@"kCMAttitudeCodingKeyQZ"];
        return;
    }
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        os_unfair_lock_lock(&payload->_lock);
        NSTimeInterval ts = payload->_hasTimestamp ? payload->_timestamp : ps_cm_next_virtual_timestamp();
        payload->_timestamp = ts;
        payload->_hasTimestamp = YES;
        os_unfair_lock_unlock(&payload->_lock);

        [coder encodeDouble:ts forKey:@"kCMLogItemCodingKeyTimestamp"];
        [coder encodeDouble:ts forKey:@"kCMLogItemCodingKeyContinuousTimestamp"];

        Class selfCls = object_getClass(self);
        if (selfCls == objc_getClass("CMAccelerometerData")) {
            [coder encodeDouble:payload->_acceleration.x forKey:@"kCMAccelerationCodingKeyX"];
            [coder encodeDouble:payload->_acceleration.y forKey:@"kCMAccelerationCodingKeyY"];
            [coder encodeDouble:payload->_acceleration.z forKey:@"kCMAccelerationCodingKeyZ"];
        } else if (selfCls == objc_getClass("CMGyroData")) {
            [coder encodeDouble:payload->_rotationRate.x forKey:@"kCMRotationRateCodingKeyX"];
            [coder encodeDouble:payload->_rotationRate.y forKey:@"kCMRotationRateCodingKeyY"];
            [coder encodeDouble:payload->_rotationRate.z forKey:@"kCMRotationRateCodingKeyZ"];
        } else if (selfCls == objc_getClass("CMMagnetometerData")) {
            [coder encodeDouble:payload->_magneticField.x forKey:@"kCMMagneticFieldCodingKeyX"];
            [coder encodeDouble:payload->_magneticField.y forKey:@"kCMMagneticFieldCodingKeyY"];
            [coder encodeDouble:payload->_magneticField.z forKey:@"kCMMagneticFieldCodingKeyZ"];
        } else if (selfCls == objc_getClass("CMAltitudeData")) {
            [coder encodeDouble:payload->_relativeAltitude.doubleValue forKey:@"kCMAltitudeCodingKeyAltitude"];
            [coder encodeDouble:payload->_pressure.doubleValue * 1000.0 forKey:@"kCMAltitudeCodingKeyPressure"];
        } else if (selfCls == objc_getClass("CMDeviceMotion")) {
            CMQuaternion q = payload->_attitude ? payload->_attitude.quaternion
                                                : (CMQuaternion){ .x = 0.00425, .y = 0.0006, .z = 0.0, .w = 0.99999079 };
            [coder encodeDouble:q.x forKey:@"kCMDeviceMotionCodingKeyQuaternionX"];
            [coder encodeDouble:q.y forKey:@"kCMDeviceMotionCodingKeyQuaternionY"];
            [coder encodeDouble:q.z forKey:@"kCMDeviceMotionCodingKeyQuaternionZ"];
            [coder encodeDouble:q.w forKey:@"kCMDeviceMotionCodingKeyQuaternionW"];
            [coder encodeDouble:payload->_userAcceleration.x forKey:@"kCMDeviceMotionCodingKeyUserAccelerationX"];
            [coder encodeDouble:payload->_userAcceleration.y forKey:@"kCMDeviceMotionCodingKeyUserAccelerationY"];
            [coder encodeDouble:payload->_userAcceleration.z forKey:@"kCMDeviceMotionCodingKeyUserAccelerationZ"];
            [coder encodeDouble:payload->_rotationRate.x forKey:@"kCMDeviceMotionCodingKeyRotationRateX"];
            [coder encodeDouble:payload->_rotationRate.y forKey:@"kCMDeviceMotionCodingKeyRotationRateY"];
            [coder encodeDouble:payload->_rotationRate.z forKey:@"kCMDeviceMotionCodingKeyRotationRateZ"];
            [coder encodeDouble:payload->_calibratedMagneticField.field.x forKey:@"kCMDeviceMotionCodingKeyMagneticFieldX"];
            [coder encodeDouble:payload->_calibratedMagneticField.field.y forKey:@"kCMDeviceMotionCodingKeyMagneticFieldY"];
            [coder encodeDouble:payload->_calibratedMagneticField.field.z forKey:@"kCMDeviceMotionCodingKeyMagneticFieldZ"];
            [coder encodeInteger:ps_cm_calibration_level_for_accuracy(payload->_calibratedMagneticField.accuracy)
                          forKey:@"kCMDeviceMotionCodingKeyMagneticFieldCalibrationLevel"];
            [coder encodeBool:YES forKey:@"kCMDeviceMotionCodingKeyDoingYawCorrection"];
            [coder encodeBool:YES forKey:@"kCMDeviceMotionCodingKeyDoingBiasEstimation"];
            [coder encodeBool:YES forKey:@"kCMDeviceMotionCodingKeyIsInitialized"];
            [coder encodeDouble:payload->_heading forKey:@"kCMDeviceMotionCodingKeyHeading"];
            [coder encodeBool:NO forKey:@"kCMDeviceMotionCodingKeyFusedWithVision"];
            [coder encodeBool:NO forKey:@"kCMDeviceMotionCodingKeyUsingVisionCorrections"];
            [coder encodeInteger:0 forKey:@"kCMDeviceMotionCodingKeySensorLocation"];
            [coder encodeDouble:15.0 forKey:@"kCMDeviceMotionCodingKeyHeadingAccuracy"];
        }
        return;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_encode_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, NSCoder *))origIMP)(self, @selector(encodeWithCoder:), coder);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (NSString *) pm_ps_cm_sample_description {
    PSVirtualAttitudePayload *attPayload = ps_attitude_payload(self, NO);
    if (attPayload != nil) {
        os_unfair_lock_lock(&attPayload->_lock);
        double r = attPayload->_roll * 180.0 / M_PI;
        double p = attPayload->_pitch * 180.0 / M_PI;
        double y = attPayload->_yaw * 180.0 / M_PI;
        os_unfair_lock_unlock(&attPayload->_lock);
        return [NSString stringWithFormat:@"CMAttitude Pitch: %f, Roll: %f, Yaw: %f\n", p, r, y];
    }
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        os_unfair_lock_lock(&payload->_lock);
        NSTimeInterval ts = payload->_hasTimestamp ? payload->_timestamp : ps_cm_next_virtual_timestamp();
        payload->_timestamp = ts;
        payload->_hasTimestamp = YES;
        os_unfair_lock_unlock(&payload->_lock);

        Class selfCls = object_getClass(self);
        if (selfCls == objc_getClass("CMAccelerometerData")) {
            return [NSString stringWithFormat:@"x %f y %f z %f @ %f",
                    payload->_acceleration.x, payload->_acceleration.y, payload->_acceleration.z, ts];
        }
        if (selfCls == objc_getClass("CMGyroData")) {
            return [NSString stringWithFormat:@"x %f y %f z %f @ %f",
                    payload->_rotationRate.x, payload->_rotationRate.y, payload->_rotationRate.z, ts];
        }
        if (selfCls == objc_getClass("CMMagnetometerData")) {
            return [NSString stringWithFormat:@"x %f y %f z %f @ %f",
                    payload->_magneticField.x, payload->_magneticField.y, payload->_magneticField.z, ts];
        }
        if (selfCls == objc_getClass("CMAltitudeData")) {
            return [NSString stringWithFormat:@"Altitude %f Pressure %f @ %f",
                    payload->_relativeAltitude.doubleValue, payload->_pressure.doubleValue * 1000.0, ts];
        }
        CMQuaternion q = payload->_attitude ? payload->_attitude.quaternion
                                            : (CMQuaternion){ .x = 0.00425, .y = 0.0006, .z = 0.0, .w = 0.99999079 };
        return [NSString stringWithFormat:@"QuaternionX %f QuaternionY %f QuaternionZ %f QuaternionW %f UserAccelX %f UserAccelY %f UserAccelZ %f RotationRateX %f RotationRateY %f RotationRateZ %f @ %f",
                q.x, q.y, q.z, q.w,
                payload->_userAcceleration.x, payload->_userAcceleration.y, payload->_userAcceleration.z,
                payload->_rotationRate.x, payload->_rotationRate.y, payload->_rotationRate.z,
                ts];
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_desc_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSString *(*)(id, SEL))origIMP)(self, @selector(description));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return [NSString stringWithFormat:@"<%@ %p>", NSStringFromClass(object_getClass(self)), self];
}

- (BOOL) pm_ps_cm_isEqual:(id)other {
    if (other == self) {
        return YES;
    }
    if (other == nil) {
        return NO;
    }
    PSVirtualAttitudePayload *selfAttPayload = ps_attitude_payload(self, NO);
    PSVirtualAttitudePayload *otherAttPayload = ps_attitude_payload(other, NO);
    if (selfAttPayload != nil || otherAttPayload != nil) {
        Class attCls = objc_getClass("CMAttitude");
        if (attCls == Nil || ![self isKindOfClass:attCls] || ![other isKindOfClass:attCls]) {
            return NO;
        }
        CMQuaternion q1 = ((CMAttitude *)self).quaternion;
        CMQuaternion q2 = ((CMAttitude *)other).quaternion;
        return (fabs(q1.x - q2.x) < 1e-6 &&
                fabs(q1.y - q2.y) < 1e-6 &&
                fabs(q1.z - q2.z) < 1e-6 &&
                fabs(q1.w - q2.w) < 1e-6);
    }
    PSVirtualMotionSamplePayload *selfPayload = ps_motion_sample_payload(self, NO);
    PSVirtualMotionSamplePayload *otherPayload = ps_motion_sample_payload(other, NO);
    if (selfPayload != nil || otherPayload != nil) {
        Class dmCls = objc_getClass("CMDeviceMotion");
        if (dmCls == Nil || ![self isKindOfClass:dmCls] || ![other isKindOfClass:dmCls]) {
            return NO;
        }
        CMDeviceMotion *dm1 = (CMDeviceMotion *)self;
        CMDeviceMotion *dm2 = (CMDeviceMotion *)other;
        NSTimeInterval ts1 = ps_cm_effective_sample_timestamp(dm1);
        NSTimeInterval ts2 = ps_cm_effective_sample_timestamp(dm2);
        if (fabs(ts1 - ts2) >= 1e-9 || fabs(dm1.heading - dm2.heading) >= 1e-4) {
            return NO;
        }
        CMAcceleration g1 = dm1.gravity;
        CMAcceleration g2 = dm2.gravity;
        if (!ps_cm_vec3_close(g1.x, g1.y, g1.z, g2.x, g2.y, g2.z, 1e-4)) {
            return NO;
        }
        CMAcceleration ua1 = dm1.userAcceleration;
        CMAcceleration ua2 = dm2.userAcceleration;
        if (!ps_cm_vec3_close(ua1.x, ua1.y, ua1.z, ua2.x, ua2.y, ua2.z, 1e-4)) {
            return NO;
        }
        CMRotationRate rr1 = dm1.rotationRate;
        CMRotationRate rr2 = dm2.rotationRate;
        if (!ps_cm_vec3_close(rr1.x, rr1.y, rr1.z, rr2.x, rr2.y, rr2.z, 1e-4)) {
            return NO;
        }
        CMCalibratedMagneticField mf1 = dm1.magneticField;
        CMCalibratedMagneticField mf2 = dm2.magneticField;
        if (mf1.accuracy != mf2.accuracy ||
            !ps_cm_vec3_close(mf1.field.x, mf1.field.y, mf1.field.z,
                              mf2.field.x, mf2.field.y, mf2.field.z, 1e-4)) {
            return NO;
        }
        CMAttitude *att1 = dm1.attitude;
        CMAttitude *att2 = dm2.attitude;
        return ((att1 == att2) || (att1 != nil && att2 != nil && [att1 isEqual:att2]));
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_isEqual_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL, id))origIMP)(self, @selector(isEqual:), other);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return (other == self);
}

- (NSTimeInterval) pm_ps_cm_sample_timestamp {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        os_unfair_lock_lock(&payload->_lock);
        if (!payload->_hasTimestamp) {
            payload->_timestamp = ps_cm_next_virtual_timestamp();
            payload->_hasTimestamp = YES;
        }
        NSTimeInterval ts = payload->_timestamp;
        os_unfair_lock_unlock(&payload->_lock);
        return ts;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_timestamp_imps, self, &pushed);
    NSTimeInterval orig = 0.0;
    if (origIMP != NULL) {
        @try {
            orig = ((NSTimeInterval (*)(id, SEL))origIMP)(self, @selector(timestamp));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_cm_aligned_real_timestamp(self, orig, NO);
    }
    return orig;
}

- (NSTimeInterval) pm_ps_cm_sample_continuousTimestamp {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        os_unfair_lock_lock(&payload->_lock);
        if (!payload->_hasTimestamp) {
            payload->_timestamp = ps_cm_next_virtual_timestamp();
            payload->_hasTimestamp = YES;
        }
        NSTimeInterval ts = payload->_timestamp;
        os_unfair_lock_unlock(&payload->_lock);
        return ts;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_cont_ts_imps, self, &pushed);
    NSTimeInterval orig = 0.0;
    if (origIMP != NULL) {
        @try {
            orig = ((NSTimeInterval (*)(id, SEL))origIMP)(self, NSSelectorFromString(@"continuousTimestamp"));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_cm_aligned_real_timestamp(self, orig, YES);
    }
    return orig;
}

- (CMAcceleration) pm_ps_cm_sample_acceleration {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        return payload->_acceleration;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_accel_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CMAcceleration (*)(id, SEL))origIMP)(self, @selector(acceleration));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return (CMAcceleration){ .x = 0.0, .y = 0.0, .z = 0.0 };
}

- (CMRotationRate) pm_ps_cm_sample_rotationRate {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        return payload->_rotationRate;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_rot_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CMRotationRate (*)(id, SEL))origIMP)(self, @selector(rotationRate));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return (CMRotationRate){ .x = 0.0, .y = 0.0, .z = 0.0 };
}

- (CMMagneticField) pm_ps_cm_sample_magneticField {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        return payload->_magneticField;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_mag_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CMMagneticField (*)(id, SEL))origIMP)(self, @selector(magneticField));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return (CMMagneticField){ .x = 0.0, .y = 0.0, .z = 0.0 };
}

- (double) pm_ps_cm_attitude_roll {
    PSVirtualAttitudePayload *att = ps_attitude_payload(self, NO);
    if (att != nil) {
        os_unfair_lock_lock(&att->_lock);
        double val = att->_roll;
        os_unfair_lock_unlock(&att->_lock);
        return val;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_att_roll_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((double (*)(id, SEL))origIMP)(self, @selector(roll));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0.0;
}

- (double) pm_ps_cm_attitude_pitch {
    PSVirtualAttitudePayload *att = ps_attitude_payload(self, NO);
    if (att != nil) {
        os_unfair_lock_lock(&att->_lock);
        double val = att->_pitch;
        os_unfair_lock_unlock(&att->_lock);
        return val;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_att_pitch_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((double (*)(id, SEL))origIMP)(self, @selector(pitch));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0.0;
}

- (double) pm_ps_cm_attitude_yaw {
    PSVirtualAttitudePayload *att = ps_attitude_payload(self, NO);
    if (att != nil) {
        os_unfair_lock_lock(&att->_lock);
        double val = att->_yaw;
        os_unfair_lock_unlock(&att->_lock);
        return val;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_att_yaw_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((double (*)(id, SEL))origIMP)(self, @selector(yaw));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0.0;
}

- (CMQuaternion) pm_ps_cm_attitude_quaternion {
    PSVirtualAttitudePayload *att = ps_attitude_payload(self, NO);
    if (att != nil) {
        os_unfair_lock_lock(&att->_lock);
        CMQuaternion q = att->_quaternion;
        os_unfair_lock_unlock(&att->_lock);
        return q;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_att_quat_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CMQuaternion (*)(id, SEL))origIMP)(self, @selector(quaternion));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return (CMQuaternion){ .x = 0.0, .y = 0.0, .z = 0.0, .w = 1.0 };
}

- (CMRotationMatrix) pm_ps_cm_attitude_rotationMatrix {
    PSVirtualAttitudePayload *att = ps_attitude_payload(self, NO);
    if (att != nil) {
        os_unfair_lock_lock(&att->_lock);
        CMRotationMatrix m = att->_rotationMatrix;
        os_unfair_lock_unlock(&att->_lock);
        return m;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_att_mat_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CMRotationMatrix (*)(id, SEL))origIMP)(self, @selector(rotationMatrix));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return (CMRotationMatrix){
        .m11 = 1.0, .m12 = 0.0, .m13 = 0.0,
        .m21 = 0.0, .m22 = 1.0, .m23 = 0.0,
        .m31 = 0.0, .m32 = 0.0, .m33 = 1.0
    };
}

- (void) pm_ps_cm_attitude_multiplyByInverseOfAttitude:(CMAttitude *)attitude {
    PSVirtualAttitudePayload *att = ps_attitude_payload(self, NO);
    if (att != nil) {
        if (attitude == nil) {
            return;
        }
        CMQuaternion q2 = attitude.quaternion;
        double n2 = q2.x * q2.x + q2.y * q2.y + q2.z * q2.z + q2.w * q2.w;
        if (!isfinite(n2) || n2 <= 1e-18) {
            return;
        }
        double invN2 = 1.0 / n2;
        CMQuaternion q2Inv = {
            .x = -q2.x * invN2,
            .y = -q2.y * invN2,
            .z = -q2.z * invN2,
            .w = q2.w * invN2
        };
        os_unfair_lock_lock(&att->_lock);
        CMQuaternion q1 = att->_quaternion;
        CMQuaternion res = {
            .w = q2Inv.w * q1.w - q2Inv.x * q1.x - q2Inv.y * q1.y - q2Inv.z * q1.z,
            .x = q2Inv.w * q1.x + q2Inv.x * q1.w + q2Inv.y * q1.z - q2Inv.z * q1.y,
            .y = q2Inv.w * q1.y - q2Inv.x * q1.z + q2Inv.y * q1.w + q2Inv.z * q1.x,
            .z = q2Inv.w * q1.z + q2Inv.x * q1.y - q2Inv.y * q1.x + q2Inv.z * q1.w
        };
        ps_attitude_update_from_quaternion_locked(att, res);
        os_unfair_lock_unlock(&att->_lock);
        return;
    }
    CMAttitude *effectiveArg = attitude;
    PSVirtualAttitudePayload *otherAtt = ps_attitude_payload(attitude, NO);
    if (otherAtt != nil) {
        os_unfair_lock_lock(&otherAtt->_lock);
        CMQuaternion q2 = otherAtt->_quaternion;
        os_unfair_lock_unlock(&otherAtt->_lock);
        Class attCls = objc_getClass("CMAttitude");
        CMAttitude *genuineTemp = (attCls != Nil)
            ? [[attCls alloc] initWithCoder:[[PSVirtualAttitudeCoder alloc] initWithQuaternion:q2]]
            : nil;
        if (genuineTemp == nil) {
            return;
        }
        effectiveArg = genuineTemp;
    } else if (ps_is_virtual_motion_sample(attitude)) {
        return;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_att_mul_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, CMAttitude *))origIMP)(self, @selector(multiplyByInverseOfAttitude:), effectiveArg);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (CMAttitude *) pm_ps_cm_dm_attitude {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        os_unfair_lock_lock(&payload->_lock);
        if (payload->_attitude == nil) {
            payload->_attitude = ps_make_virtual_attitude_with_quaternion((CMQuaternion){
                .x = 0.00425, .y = 0.0006, .z = 0.0, .w = 0.99999079
            });
        }
        CMAttitude *att = payload->_attitude;
        os_unfair_lock_unlock(&payload->_lock);
        return att;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_dm_attitude_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CMAttitude *(*)(id, SEL))origIMP)(self, @selector(attitude));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (CMAcceleration) pm_ps_cm_dm_gravity {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        return payload->_gravity;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_dm_gravity_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CMAcceleration (*)(id, SEL))origIMP)(self, @selector(gravity));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return (CMAcceleration){ .x = 0.0, .y = 0.0, .z = -1.0 };
}

- (CMAcceleration) pm_ps_cm_dm_userAcceleration {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        return payload->_userAcceleration;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_dm_userAccel_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CMAcceleration (*)(id, SEL))origIMP)(self, @selector(userAcceleration));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return (CMAcceleration){ .x = 0.0, .y = 0.0, .z = 0.0 };
}

- (CMCalibratedMagneticField) pm_ps_cm_dm_magneticField {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        return payload->_calibratedMagneticField;
    }
    CMCalibratedMagneticField orig = {
        .field = { .x = 0.0, .y = 0.0, .z = 0.0 },
        .accuracy = CMMagneticFieldCalibrationAccuracyUncalibrated
    };
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_dm_mag_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            orig = ((CMCalibratedMagneticField (*)(id, SEL))origIMP)(self, @selector(magneticField));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    NSNumber *refNum = objc_getAssociatedObject(self, &kPSMotionSampleRefFrameKey);
    CMAttitudeReferenceFrame refFrame = (refNum != nil) ? (CMAttitudeReferenceFrame)refNum.unsignedIntegerValue : 0;
    BOOL hasCalibratedMag = ps_cm_ref_frame_has_calibrated_mag(refFrame);
    if (hasCalibratedMag &&
        orig.accuracy == CMMagneticFieldCalibrationAccuracyUncalibrated &&
        orig.field.x == 0.0 &&
        orig.field.y == 0.0 &&
        orig.field.z == 0.0 &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        @synchronized (self) {
            NSValue *cached = objc_getAssociatedObject(self, &kPSRealDMMagneticFieldKey);
            if (cached != nil && strcmp(cached.objCType, @encode(CMCalibratedMagneticField)) == 0) {
                CMCalibratedMagneticField out = {0};
                [cached getValue:&out];
                return out;
            }
            uint64_t t = atomic_fetch_add_explicit(&s_ps_motion_tick, 1ULL, memory_order_relaxed);
            CMCalibratedMagneticField synth = {
                .field = {
                    .x = 18.4 + ps_motion_micro_jitter(t ^ 0x44ULL, 0.02),
                    .y = -6.2 + ps_motion_micro_jitter(t ^ 0x55ULL, 0.02),
                    .z = -41.5 + ps_motion_micro_jitter(t ^ 0x66ULL, 0.02)
                },
                .accuracy = CMMagneticFieldCalibrationAccuracyHigh
            };
            NSValue *boxed = [NSValue valueWithBytes:&synth objCType:@encode(CMCalibratedMagneticField)];
            objc_setAssociatedObject(self, &kPSRealDMMagneticFieldKey, boxed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return synth;
        }
    }
    if (refNum != nil && !hasCalibratedMag && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return (CMCalibratedMagneticField){
            .field = { .x = 0.0, .y = 0.0, .z = 0.0 },
            .accuracy = CMMagneticFieldCalibrationAccuracyUncalibrated
        };
    }
    return orig;
}

- (double) pm_ps_cm_dm_heading {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        return payload->_heading;
    }
    NSNumber *refNum = objc_getAssociatedObject(self, &kPSMotionSampleRefFrameKey);
    if (refNum != nil &&
        !ps_cm_ref_frame_has_north((CMAttitudeReferenceFrame)refNum.unsignedIntegerValue) &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return -1.0;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_dm_heading_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((double (*)(id, SEL))origIMP)(self, @selector(heading));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return -1.0;
}

- (double) pm_ps_cm_dm_headingAccuracy {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        return payload->_headingAccuracy;
    }
    NSNumber *refNum = objc_getAssociatedObject(self, &kPSMotionSampleRefFrameKey);
    if (refNum != nil &&
        !ps_cm_ref_frame_has_north((CMAttitudeReferenceFrame)refNum.unsignedIntegerValue) &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return -1.0;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_dm_headingAcc_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((double (*)(id, SEL))origIMP)(self, NSSelectorFromString(@"headingAccuracy"));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return -1.0;
}

+ (BOOL) pm_ps_cm_ped_isStepCountingAvailable {
    if (pt_is_bypass_enabled() && ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_ped_isStepCountingAvailable];
}

+ (BOOL) pm_ps_cm_ped_isDistanceAvailable {
    if (pt_is_bypass_enabled() && ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_ped_isDistanceAvailable];
}

+ (BOOL) pm_ps_cm_ped_isFloorCountingAvailable {
    if (pt_is_bypass_enabled() && ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_ped_isFloorCountingAvailable];
}

+ (BOOL) pm_ps_cm_ped_isPaceAvailable {
    if (pt_is_bypass_enabled() && ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_ped_isPaceAvailable];
}

+ (BOOL) pm_ps_cm_ped_isCadenceAvailable {
    if (pt_is_bypass_enabled() && ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_ped_isCadenceAvailable];
}

+ (BOOL) pm_ps_cm_ped_isPedometerEventTrackingAvailable {
    if (pt_is_bypass_enabled() && ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_ped_isPedometerEventTrackingAvailable];
}

+ (CMAuthorizationStatus) pm_ps_cm_ped_authorizationStatus {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return CMAuthorizationStatusAuthorized;
    }
    return [self pm_ps_cm_ped_authorizationStatus];
}

static id ps_make_virtual_pedometer_data(NSDate *startDate, NSDate *endDate, NSInteger steps) {
    Class dataCls = objc_getClass("CMPedometerData");
    if (dataCls == Nil) {
        return nil;
    }
    id instance = [[dataCls alloc] init];
    if (instance != nil) {
        PSVirtualPedometerPayload *p = [[PSVirtualPedometerPayload alloc] init];
        p->_startDate = startDate ?: [NSDate date];
        p->_endDate = endDate ?: [NSDate date];
        p->_numberOfSteps = @(steps > 0 ? steps : 0);
        p->_distance = @((double)(steps > 0 ? steps : 0) * 0.72);
        p->_floorsAscended = @(0);
        p->_floorsDescended = @(0);
        p->_currentPace = @(0.0);
        p->_currentCadence = @(0.0);
        p->_averageActivePace = @(0.0);
        objc_setAssociatedObject(instance, &kPSPedometerPayloadKey, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return instance;
}

- (NSDate *) pm_ps_cm_ped_data_startDate {
    PSVirtualPedometerPayload *p = ps_pedometer_payload(self);
    if (p != nil) { return p->_startDate; }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_ped_startDate_imps, self, &pushed);
    if (origIMP != NULL) {
        @try { return ((NSDate *(*)(id, SEL))origIMP)(self, @selector(startDate)); }
        @finally { ps_pop_orig_imp_frame(pushed); }
    }
    return nil;
}

- (NSDate *) pm_ps_cm_ped_data_endDate {
    PSVirtualPedometerPayload *p = ps_pedometer_payload(self);
    if (p != nil) { return p->_endDate; }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_ped_endDate_imps, self, &pushed);
    if (origIMP != NULL) {
        @try { return ((NSDate *(*)(id, SEL))origIMP)(self, @selector(endDate)); }
        @finally { ps_pop_orig_imp_frame(pushed); }
    }
    return nil;
}

- (NSNumber *) pm_ps_cm_ped_data_numberOfSteps {
    PSVirtualPedometerPayload *p = ps_pedometer_payload(self);
    if (p != nil) { return p->_numberOfSteps; }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_ped_steps_imps, self, &pushed);
    if (origIMP != NULL) {
        @try { return ((NSNumber *(*)(id, SEL))origIMP)(self, @selector(numberOfSteps)); }
        @finally { ps_pop_orig_imp_frame(pushed); }
    }
    return @(0);
}

- (NSNumber *) pm_ps_cm_ped_data_distance {
    PSVirtualPedometerPayload *p = ps_pedometer_payload(self);
    if (p != nil) { return p->_distance; }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_ped_dist_imps, self, &pushed);
    if (origIMP != NULL) {
        @try { return ((NSNumber *(*)(id, SEL))origIMP)(self, @selector(distance)); }
        @finally { ps_pop_orig_imp_frame(pushed); }
    }
    return @(0.0);
}

- (NSNumber *) pm_ps_cm_ped_data_floorsAscended {
    PSVirtualPedometerPayload *p = ps_pedometer_payload(self);
    if (p != nil) { return p->_floorsAscended; }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_ped_floorsAsc_imps, self, &pushed);
    if (origIMP != NULL) {
        @try { return ((NSNumber *(*)(id, SEL))origIMP)(self, @selector(floorsAscended)); }
        @finally { ps_pop_orig_imp_frame(pushed); }
    }
    return @(0);
}

- (NSNumber *) pm_ps_cm_ped_data_floorsDescended {
    PSVirtualPedometerPayload *p = ps_pedometer_payload(self);
    if (p != nil) { return p->_floorsDescended; }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_ped_floorsDesc_imps, self, &pushed);
    if (origIMP != NULL) {
        @try { return ((NSNumber *(*)(id, SEL))origIMP)(self, @selector(floorsDescended)); }
        @finally { ps_pop_orig_imp_frame(pushed); }
    }
    return @(0);
}

- (NSNumber *) pm_ps_cm_ped_data_currentPace {
    PSVirtualPedometerPayload *p = ps_pedometer_payload(self);
    if (p != nil) { return p->_currentPace; }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_ped_curPace_imps, self, &pushed);
    if (origIMP != NULL) {
        @try { return ((NSNumber *(*)(id, SEL))origIMP)(self, @selector(currentPace)); }
        @finally { ps_pop_orig_imp_frame(pushed); }
    }
    return nil;
}

- (NSNumber *) pm_ps_cm_ped_data_currentCadence {
    PSVirtualPedometerPayload *p = ps_pedometer_payload(self);
    if (p != nil) { return p->_currentCadence; }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_ped_curCadence_imps, self, &pushed);
    if (origIMP != NULL) {
        @try { return ((NSNumber *(*)(id, SEL))origIMP)(self, @selector(currentCadence)); }
        @finally { ps_pop_orig_imp_frame(pushed); }
    }
    return nil;
}

- (NSNumber *) pm_ps_cm_ped_data_averageActivePace {
    PSVirtualPedometerPayload *p = ps_pedometer_payload(self);
    if (p != nil) { return p->_averageActivePace; }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_ped_avgPace_imps, self, &pushed);
    if (origIMP != NULL) {
        @try { return ((NSNumber *(*)(id, SEL))origIMP)(self, @selector(averageActivePace)); }
        @finally { ps_pop_orig_imp_frame(pushed); }
    }
    return nil;
}

- (void) pm_ps_cm_ped_queryPedometerDataFromDate:(NSDate *)start
                                         toDate:(NSDate *)end
                                    withHandler:(CMPedometerHandler)handler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (handler != nil) {
            NSDate *effStart = start ?: [NSDate date];
            NSDate *effEnd = end ?: [NSDate date];
            CMPedometerData *sample = ps_make_virtual_pedometer_data(effStart, effEnd, 0);
            CMPedometerHandler userHandler = [handler copy];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                userHandler(sample, nil);
            });
        }
        return;
    }
    [self pm_ps_cm_ped_queryPedometerDataFromDate:start toDate:end withHandler:handler];
}

- (void) pm_ps_cm_ped_startPedometerUpdatesFromDate:(NSDate *)start withHandler:(CMPedometerHandler)handler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualPedometerState *st = ps_pedometer_state(self, YES);
        if (st != nil) {
            @synchronized (st) {
                st.active = YES;
                st.startDate = start ?: [NSDate date];
                uint64_t gen = ++st.generation;
                if (st.timer != nil) {
                    dispatch_source_cancel(st.timer);
                    st.timer = nil;
                }
                if (handler != nil) {
                    CMPedometerHandler userHandler = [handler copy];
                    NSDate *effStart = st.startDate;
                    dispatch_source_t timer = ps_create_suspended_motion_timer(self, 2.0, nil, ^(id strongPed) {
                        PSVirtualPedometerState *cur = ps_pedometer_state(strongPed, NO);
                        BOOL emit = NO;
                        if (cur != nil) {
                            @synchronized (cur) {
                                emit = (cur.active && cur.generation == gen);
                            }
                        }
                        if (!emit) {
                            return;
                        }
                        CMPedometerData *sample = ps_make_virtual_pedometer_data(effStart, [NSDate date], 0);
                        if (sample != nil) {
                            userHandler(sample, nil);
                        }
                    });
                    if (timer != nil) {
                        st.timer = timer;
                        dispatch_resume(timer);
                    }
                    CMPedometerData *initial = ps_make_virtual_pedometer_data(effStart, [NSDate date], 0);
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                        userHandler(initial, nil);
                    });
                }
            }
        }
        return;
    }
    [self pm_ps_cm_ped_startPedometerUpdatesFromDate:start withHandler:handler];
}

- (void) pm_ps_cm_ped_stopPedometerUpdates {
    PSVirtualPedometerState *st = ps_pedometer_state(self, NO);
    if (st != nil) {
        @synchronized (st) {
            st.active = NO;
            st.generation++;
            if (st.timer != nil) {
                dispatch_source_cancel(st.timer);
                st.timer = nil;
            }
        }
    }
    [self pm_ps_cm_ped_stopPedometerUpdates];
}

+ (BOOL) pm_ps_cm_activity_isActivityAvailable {
    if (pt_is_bypass_enabled() && ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_activity_isActivityAvailable];
}

- (CMDeviceMotionSensorLocation) pm_ps_cm_dm_sensorLocation {
    if (ps_motion_sample_payload(self, NO) != nil) {
        return CMDeviceMotionSensorLocationDefault;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_dm_sensorLoc_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CMDeviceMotionSensorLocation (*)(id, SEL))origIMP)(self, @selector(sensorLocation));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return CMDeviceMotionSensorLocationDefault;
}

- (BOOL) pm_ps_cm_dm_isInitialized {
    if (ps_motion_sample_payload(self, NO) != nil) {
        return YES;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_dm_isInit_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, NSSelectorFromString(@"isInitialized"));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (NSNumber *) pm_ps_cm_alt_relativeAltitude {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        return payload->_relativeAltitude ?: @(0.0);
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_alt_rel_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSNumber *(*)(id, SEL))origIMP)(self, @selector(relativeAltitude));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return @(0.0);
}

- (NSNumber *) pm_ps_cm_alt_pressure {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, NO);
    if (payload != nil) {
        return payload->_pressure ?: @(101.325);
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_cm_swizzle_lock, s_cm_orig_alt_press_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSNumber *(*)(id, SEL))origIMP)(self, @selector(pressure));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return @(101.325);
}

- (BOOL) pm_ps_cm_isAccelerometerAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_isAccelerometerAvailable];
}

- (BOOL) pm_ps_cm_isGyroAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_isGyroAvailable];
}

- (BOOL) pm_ps_cm_isMagnetometerAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_isMagnetometerAvailable];
}

- (BOOL) pm_ps_cm_isDeviceMotionAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_isDeviceMotionAvailable];
}

+ (BOOL) pm_ps_cm_isRelativeAltitudeAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_isRelativeAltitudeAvailable];
}

+ (BOOL) pm_ps_cm_isAbsoluteAltitudeAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_compat13_7_active()) {
            return NO;
        }
        const char *m = pt_get_device_model_cstr();
        if (m == NULL) {
            return NO;
        }
        if (strncmp(m, "iPhone", 6) == 0) {
            int major = atoi(m + 6);
            return (major >= 13);
        }
        if (strncmp(m, "iPad", 4) == 0) {
            int major = atoi(m + 4);
            int minor = 0;
            const char *comma = strchr(m + 4, ',');
            if (comma != NULL) {
                minor = atoi(comma + 1);
            }
            return (major >= 14) || (major == 13 && minor >= 4);
        }
        return NO;
    }
    return [self pm_ps_cm_isAbsoluteAltitudeAvailable];
}

static CMAttitudeReferenceFrame ps_cm_default_reference_frames_mask(void) {
    return (CMAttitudeReferenceFrame)(CMAttitudeReferenceFrameXArbitraryZVertical |
                                      CMAttitudeReferenceFrameXArbitraryCorrectedZVertical |
                                      CMAttitudeReferenceFrameXMagneticNorthZVertical |
                                      CMAttitudeReferenceFrameXTrueNorthZVertical);
}

static CMAttitudeReferenceFrame ps_cm_fallback_availableAttitudeReferenceFrames(id self __unused, SEL _cmd __unused) {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_cm_default_reference_frames_mask();
    }
    return 0;
}

+ (CMAttitudeReferenceFrame) pm_ps_cm_availableAttitudeReferenceFrames {
    CMAttitudeReferenceFrame orig = [self pm_ps_cm_availableAttitudeReferenceFrames];
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        orig == 0) {
        return ps_cm_default_reference_frames_mask();
    }
    return orig;
}

static CMAttitudeReferenceFrame ps_cm_fallback_attitudeReferenceFrame(id self, SEL _cmd __unused) {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            @synchronized (st) {
                if (st.dmActive && st.dmReferenceFrame != 0) {
                    return st.dmReferenceFrame;
                }
            }
        }
        return CMAttitudeReferenceFrameXArbitraryZVertical;
    }
    return 0;
}

- (CMAttitudeReferenceFrame) pm_ps_cm_attitudeReferenceFrame {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            @synchronized (st) {
                if (st.dmActive && st.dmReferenceFrame != 0) {
                    return st.dmReferenceFrame;
                }
            }
        }
        CMAttitudeReferenceFrame orig = [self pm_ps_cm_attitudeReferenceFrame];
        return (orig != 0) ? orig : CMAttitudeReferenceFrameXArbitraryZVertical;
    }
    return [self pm_ps_cm_attitudeReferenceFrame];
}

- (NSTimeInterval) pm_ps_cm_magnetometerUpdateInterval {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_effective_mag_update_interval(self);
    }
    return [self pm_ps_cm_magnetometerUpdateInterval];
}

- (void) pm_ps_cm_setMagnetometerUpdateInterval:(NSTimeInterval)interval {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        double effective = (isfinite(interval) && interval > 0.01) ? interval : 0.01;
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        if (st != nil) {
            @synchronized (st) {
                double prev = st.hasExplicitMagUpdateInterval ? st.explicitMagUpdateInterval : 0.01;
                BOOL changed = (!st.hasExplicitMagUpdateInterval || fabs(prev - effective) > 1e-9);
                st.hasExplicitMagUpdateInterval = YES;
                st.explicitMagUpdateInterval = effective;
                if (changed && st.magActive && st.magTimer != nil) {
                    uint64_t ns = (uint64_t)(effective * (double)NSEC_PER_SEC);
                    dispatch_source_set_timer(st.magTimer,
                                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)ns),
                                              ns,
                                              ns / 5ULL);
                }
            }
        }
    }
    [self pm_ps_cm_setMagnetometerUpdateInterval:interval];
}

- (BOOL) pm_ps_cm_isAccelerometerActive {
    BOOL orig = [self pm_ps_cm_isAccelerometerActive];
    if (!orig && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            @synchronized (st) {
                return st.accelActive;
            }
        }
    }
    return orig;
}

- (BOOL) pm_ps_cm_isGyroActive {
    BOOL orig = [self pm_ps_cm_isGyroActive];
    if (!orig && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            @synchronized (st) {
                return st.gyroActive;
            }
        }
    }
    return orig;
}

- (BOOL) pm_ps_cm_isMagnetometerActive {
    BOOL orig = [self pm_ps_cm_isMagnetometerActive];
    if (!orig && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            @synchronized (st) {
                return st.magActive;
            }
        }
    }
    return orig;
}

- (BOOL) pm_ps_cm_isDeviceMotionActive {
    BOOL orig = [self pm_ps_cm_isDeviceMotionActive];
    if (!orig && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            @synchronized (st) {
                return st.dmActive;
            }
        }
    }
    return orig;
}

static inline id ps_cm_cached_pull_sample(BOOL active,
                                          id currentSample,
                                          double currentMono,
                                          NSTimeInterval rawInterval,
                                          const char *className,
                                          void (^saveBlock)(id sample, double mono)) {
    if (!active) {
        return nil;
    }
    double eff = (isfinite(rawInterval) && rawInterval >= 0.01) ? rawInterval : 0.01;
    double now = [[NSProcessInfo processInfo] systemUptime];
    if (currentSample != nil && now >= currentMono && (now - currentMono) < eff) {
        return currentSample;
    }
    id fresh = ps_make_virtual_sample_instance(objc_getClass(className));
    if (fresh != nil && saveBlock != nil) {
        saveBlock(fresh, now);
    }
    return fresh;
}

- (CMAccelerometerData *) pm_ps_cm_accelerometerData {
    CMAccelerometerData *orig = [self pm_ps_cm_accelerometerData];
    ps_cm_observe_real_sample(orig);
    if (orig == nil && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            NSTimeInterval iv = ((CMMotionManager *)self).accelerometerUpdateInterval;
            @synchronized (st) {
                return ps_cm_cached_pull_sample(st.accelActive,
                                                st.lastAccelSample,
                                                st.lastAccelMonoSec,
                                                iv,
                                                "CMAccelerometerData",
                                                ^(id sample, double mono) {
                                                    st.lastAccelSample = sample;
                                                    st.lastAccelMonoSec = mono;
                                                });
            }
        }
    }
    return orig;
}

- (CMGyroData *) pm_ps_cm_gyroData {
    CMGyroData *orig = [self pm_ps_cm_gyroData];
    ps_cm_observe_real_sample(orig);
    if (orig == nil && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            NSTimeInterval iv = ((CMMotionManager *)self).gyroUpdateInterval;
            @synchronized (st) {
                return ps_cm_cached_pull_sample(st.gyroActive,
                                                st.lastGyroSample,
                                                st.lastGyroMonoSec,
                                                iv,
                                                "CMGyroData",
                                                ^(id sample, double mono) {
                                                    st.lastGyroSample = sample;
                                                    st.lastGyroMonoSec = mono;
                                                });
            }
        }
    }
    return orig;
}

- (CMMagnetometerData *) pm_ps_cm_magnetometerData {
    CMMagnetometerData *orig = [self pm_ps_cm_magnetometerData];
    ps_cm_observe_real_sample(orig);
    if (orig == nil && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            NSTimeInterval iv = ps_effective_mag_update_interval(self);
            @synchronized (st) {
                return ps_cm_cached_pull_sample(st.magActive,
                                                st.lastMagSample,
                                                st.lastMagMonoSec,
                                                iv,
                                                "CMMagnetometerData",
                                                ^(id sample, double mono) {
                                                    st.lastMagSample = sample;
                                                    st.lastMagMonoSec = mono;
                                                });
            }
        }
    }
    return orig;
}

- (CMDeviceMotion *) pm_ps_cm_deviceMotion {
    CMDeviceMotion *orig = [self pm_ps_cm_deviceMotion];
    ps_cm_observe_real_sample(orig);
    const void *caller = __builtin_return_address(0);
    if (orig != nil && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        CMAttitudeReferenceFrame frame = (st != nil && st.dmReferenceFrame != 0)
            ? st.dmReferenceFrame
            : CMAttitudeReferenceFrameXArbitraryZVertical;
        objc_setAssociatedObject(orig, &kPSMotionSampleRefFrameKey, @(frame), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return orig;
    }
    if (orig == nil && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            NSTimeInterval iv = ((CMMotionManager *)self).deviceMotionUpdateInterval;
            @synchronized (st) {
                if (!st.dmActive) {
                    return nil;
                }
                double eff = (isfinite(iv) && iv >= 0.01) ? iv : 0.01;
                double now = [[NSProcessInfo processInfo] systemUptime];
                if (st.lastDMSample != nil && now >= st.lastDMMonoSec && (now - st.lastDMMonoSec) < eff) {
                    return st.lastDMSample;
                }
                CMDeviceMotion *fresh = ps_make_virtual_sample_instance_with_state(objc_getClass("CMDeviceMotion"), st);
                if (fresh != nil) {
                    st.lastDMSample = fresh;
                    st.lastDMMonoSec = now;
                }
                return fresh;
            }
        }
    }
    return orig;
}

- (void) pm_ps_cm_startAccelerometerUpdates {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isAccelerometerAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.accelActive = YES;
            st.lastAccelSample = nil;
            st.lastAccelMonoSec = 0.0;
        }
    }
    [self pm_ps_cm_startAccelerometerUpdates];
}

- (void) pm_ps_cm_startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isAccelerometerAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.accelActive = YES;
            st.lastAccelSample = nil;
            st.lastAccelMonoSec = 0.0;
            uint64_t gen = ++st.accelGen;
            if (st.accelTimer) { dispatch_source_cancel(st.accelTimer); st.accelTimer = nil; }
            if (handler != nil) {
                CMAccelerometerHandler userHandler = [handler copy];
                NSTimeInterval iv = ((CMMotionManager *)self).accelerometerUpdateInterval;
                dispatch_source_t timer = ps_create_suspended_motion_timer(self, iv, queue, ^(id mgr) {
                    PSVirtualMotionState *curSt = ps_motion_state(mgr, NO);
                    BOOL shouldEmit = NO;
                    if (curSt != nil) {
                        @synchronized (curSt) {
                            shouldEmit = (curSt.accelActive && curSt.accelGen == gen);
                        }
                    }
                    if (!shouldEmit) {
                        return;
                    }
                    CMAccelerometerData *sample = ps_make_virtual_sample_instance(objc_getClass("CMAccelerometerData"));
                    if (sample != nil) {
                        userHandler(sample, nil);
                    }
                });
                if (timer != nil) {
                    st.accelTimer = timer;
                    dispatch_resume(timer);
                }
                return;
            }
        }
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMAccelerometerHandler userHandler = [handler copy];
        [self pm_ps_cm_startAccelerometerUpdatesToQueue:queue withHandler:^(CMAccelerometerData *data, NSError *error) {
            ps_cm_observe_real_sample(data);
            userHandler(data, error);
        }];
        return;
    }
    [self pm_ps_cm_startAccelerometerUpdatesToQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_stopAccelerometerUpdates {
    PSVirtualMotionState *st = ps_motion_state(self, NO);
    if (st != nil) {
        @synchronized (st) {
            st.accelActive = NO;
            st.accelGen++;
            st.lastAccelSample = nil;
            st.lastAccelMonoSec = 0.0;
            if (st.accelTimer) { dispatch_source_cancel(st.accelTimer); st.accelTimer = nil; }
        }
    }
    [self pm_ps_cm_stopAccelerometerUpdates];
}

- (void) pm_ps_cm_startGyroUpdates {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isGyroAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.gyroActive = YES;
            st.lastGyroSample = nil;
            st.lastGyroMonoSec = 0.0;
        }
    }
    [self pm_ps_cm_startGyroUpdates];
}

- (void) pm_ps_cm_startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMGyroHandler)handler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isGyroAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.gyroActive = YES;
            st.lastGyroSample = nil;
            st.lastGyroMonoSec = 0.0;
            uint64_t gen = ++st.gyroGen;
            if (st.gyroTimer) { dispatch_source_cancel(st.gyroTimer); st.gyroTimer = nil; }
            if (handler != nil) {
                CMGyroHandler userHandler = [handler copy];
                NSTimeInterval iv = ((CMMotionManager *)self).gyroUpdateInterval;
                dispatch_source_t timer = ps_create_suspended_motion_timer(self, iv, queue, ^(id mgr) {
                    PSVirtualMotionState *curSt = ps_motion_state(mgr, NO);
                    BOOL shouldEmit = NO;
                    if (curSt != nil) {
                        @synchronized (curSt) {
                            shouldEmit = (curSt.gyroActive && curSt.gyroGen == gen);
                        }
                    }
                    if (!shouldEmit) {
                        return;
                    }
                    CMGyroData *sample = ps_make_virtual_sample_instance(objc_getClass("CMGyroData"));
                    if (sample != nil) {
                        userHandler(sample, nil);
                    }
                });
                if (timer != nil) {
                    st.gyroTimer = timer;
                    dispatch_resume(timer);
                }
                return;
            }
        }
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMGyroHandler userHandler = [handler copy];
        [self pm_ps_cm_startGyroUpdatesToQueue:queue withHandler:^(CMGyroData *data, NSError *error) {
            ps_cm_observe_real_sample(data);
            userHandler(data, error);
        }];
        return;
    }
    [self pm_ps_cm_startGyroUpdatesToQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_stopGyroUpdates {
    PSVirtualMotionState *st = ps_motion_state(self, NO);
    if (st != nil) {
        @synchronized (st) {
            st.gyroActive = NO;
            st.gyroGen++;
            st.lastGyroSample = nil;
            st.lastGyroMonoSec = 0.0;
            if (st.gyroTimer) { dispatch_source_cancel(st.gyroTimer); st.gyroTimer = nil; }
        }
    }
    [self pm_ps_cm_stopGyroUpdates];
}

- (void) pm_ps_cm_startMagnetometerUpdates {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isMagnetometerAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.magActive = YES;
            st.lastMagSample = nil;
            st.lastMagMonoSec = 0.0;
        }
    }
    [self pm_ps_cm_startMagnetometerUpdates];
}

- (void) pm_ps_cm_startMagnetometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMMagnetometerHandler)handler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isMagnetometerAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.magActive = YES;
            st.lastMagSample = nil;
            st.lastMagMonoSec = 0.0;
            uint64_t gen = ++st.magGen;
            if (st.magTimer) { dispatch_source_cancel(st.magTimer); st.magTimer = nil; }
            if (handler != nil) {
                CMMagnetometerHandler userHandler = [handler copy];
                NSTimeInterval iv = st.hasExplicitMagUpdateInterval ? st.explicitMagUpdateInterval : 0.01;
                dispatch_source_t timer = ps_create_suspended_motion_timer(self, iv, queue, ^(id mgr) {
                    PSVirtualMotionState *curSt = ps_motion_state(mgr, NO);
                    BOOL shouldEmit = NO;
                    if (curSt != nil) {
                        @synchronized (curSt) {
                            shouldEmit = (curSt.magActive && curSt.magGen == gen);
                        }
                    }
                    if (!shouldEmit) {
                        return;
                    }
                    CMMagnetometerData *sample = ps_make_virtual_sample_instance(objc_getClass("CMMagnetometerData"));
                    if (sample != nil) {
                        userHandler(sample, nil);
                    }
                });
                if (timer != nil) {
                    st.magTimer = timer;
                    dispatch_resume(timer);
                }
                return;
            }
        }
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMMagnetometerHandler userHandler = [handler copy];
        [self pm_ps_cm_startMagnetometerUpdatesToQueue:queue withHandler:^(CMMagnetometerData *data, NSError *error) {
            ps_cm_observe_real_sample(data);
            userHandler(data, error);
        }];
        return;
    }
    [self pm_ps_cm_startMagnetometerUpdatesToQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_stopMagnetometerUpdates {
    PSVirtualMotionState *st = ps_motion_state(self, NO);
    if (st != nil) {
        @synchronized (st) {
            st.magActive = NO;
            st.magGen++;
            st.lastMagSample = nil;
            st.lastMagMonoSec = 0.0;
            if (st.magTimer) { dispatch_source_cancel(st.magTimer); st.magTimer = nil; }
        }
    }
    [self pm_ps_cm_stopMagnetometerUpdates];
}

- (void) pm_ps_cm_startDeviceMotionUpdates {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        BOOL nativeAvail = [self pm_ps_cm_isDeviceMotionAvailable];
        @synchronized (st) {
            st.dmReferenceFrame = CMAttitudeReferenceFrameXArbitraryZVertical;
            st.hasSimQuat = NO;
            st.simLastTs = 0.0;
            if (!nativeAvail) {
                st.dmActive = YES;
                st.lastDMSample = nil;
                st.lastDMMonoSec = 0.0;
            }
        }
    }
    [self pm_ps_cm_startDeviceMotionUpdates];
}

- (void) pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:(CMAttitudeReferenceFrame)frame {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        BOOL nativeAvail = [self pm_ps_cm_isDeviceMotionAvailable];
        @synchronized (st) {
            st.dmReferenceFrame = (frame != 0) ? frame : CMAttitudeReferenceFrameXArbitraryZVertical;
            st.hasSimQuat = NO;
            st.simLastTs = 0.0;
            if (!nativeAvail) {
                st.dmActive = YES;
                st.lastDMSample = nil;
                st.lastDMMonoSec = 0.0;
            }
        }
    }
    [self pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:frame];
}

- (void) pm_ps_cm_startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMDeviceMotionHandler)handler {
    const void *caller = __builtin_return_address(0);
    CMAttitudeReferenceFrame effectiveFrame = CMAttitudeReferenceFrameXArbitraryZVertical;
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        BOOL nativeAvail = [self pm_ps_cm_isDeviceMotionAvailable];
        @synchronized (st) {
            st.dmReferenceFrame = effectiveFrame;
            st.hasSimQuat = NO;
            st.simLastTs = 0.0;
            if (!nativeAvail) {
                st.dmActive = YES;
                st.lastDMSample = nil;
                st.lastDMMonoSec = 0.0;
                uint64_t gen = ++st.dmGen;
                if (st.dmTimer) { dispatch_source_cancel(st.dmTimer); st.dmTimer = nil; }
                if (handler != nil) {
                    CMDeviceMotionHandler userHandler = [handler copy];
                    NSTimeInterval iv = ((CMMotionManager *)self).deviceMotionUpdateInterval;
                    dispatch_source_t timer = ps_create_suspended_motion_timer(self, iv, queue, ^(id mgr) {
                        PSVirtualMotionState *curSt = ps_motion_state(mgr, NO);
                        CMDeviceMotion *sample = nil;
                        if (curSt != nil) {
                            @synchronized (curSt) {
                                if (curSt.dmActive && curSt.dmGen == gen) {
                                    sample = ps_make_virtual_sample_instance_with_state(objc_getClass("CMDeviceMotion"), curSt);
                                }
                            }
                        }
                        if (sample != nil) {
                            userHandler(sample, nil);
                        }
                    });
                    if (timer != nil) {
                        st.dmTimer = timer;
                        dispatch_resume(timer);
                    }
                    return;
                }
            }
        }
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMDeviceMotionHandler userHandler = [handler copy];
        [self pm_ps_cm_startDeviceMotionUpdatesToQueue:queue withHandler:^(CMDeviceMotion *motion, NSError *error) {
            ps_cm_observe_real_sample(motion);
            if (motion != nil) {
                objc_setAssociatedObject(motion, &kPSMotionSampleRefFrameKey, @(effectiveFrame), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            userHandler(motion, error);
        }];
        return;
    }
    [self pm_ps_cm_startDeviceMotionUpdatesToQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:(CMAttitudeReferenceFrame)frame
                                                      toQueue:(NSOperationQueue *)queue
                                                  withHandler:(CMDeviceMotionHandler)handler {
    const void *caller = __builtin_return_address(0);
    CMAttitudeReferenceFrame effectiveFrame = (frame != 0) ? frame : CMAttitudeReferenceFrameXArbitraryZVertical;
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        BOOL nativeAvail = [self pm_ps_cm_isDeviceMotionAvailable];
        @synchronized (st) {
            st.dmReferenceFrame = effectiveFrame;
            st.hasSimQuat = NO;
            st.simLastTs = 0.0;
            if (!nativeAvail) {
                st.dmActive = YES;
                st.lastDMSample = nil;
                st.lastDMMonoSec = 0.0;
                uint64_t gen = ++st.dmGen;
                if (st.dmTimer) { dispatch_source_cancel(st.dmTimer); st.dmTimer = nil; }
                if (handler != nil) {
                    CMDeviceMotionHandler userHandler = [handler copy];
                    NSTimeInterval iv = ((CMMotionManager *)self).deviceMotionUpdateInterval;
                    dispatch_source_t timer = ps_create_suspended_motion_timer(self, iv, queue, ^(id mgr) {
                        PSVirtualMotionState *curSt = ps_motion_state(mgr, NO);
                        CMDeviceMotion *sample = nil;
                        if (curSt != nil) {
                            @synchronized (curSt) {
                                if (curSt.dmActive && curSt.dmGen == gen) {
                                    sample = ps_make_virtual_sample_instance_with_state(objc_getClass("CMDeviceMotion"), curSt);
                                }
                            }
                        }
                        if (sample != nil) {
                            userHandler(sample, nil);
                        }
                    });
                    if (timer != nil) {
                        st.dmTimer = timer;
                        dispatch_resume(timer);
                    }
                    return;
                }
            }
        }
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMDeviceMotionHandler userHandler = [handler copy];
        [self pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:frame toQueue:queue withHandler:^(CMDeviceMotion *motion, NSError *error) {
            ps_cm_observe_real_sample(motion);
            if (motion != nil) {
                objc_setAssociatedObject(motion, &kPSMotionSampleRefFrameKey, @(effectiveFrame), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            userHandler(motion, error);
        }];
        return;
    }
    [self pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:frame toQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_stopDeviceMotionUpdates {
    PSVirtualMotionState *st = ps_motion_state(self, NO);
    if (st != nil) {
        @synchronized (st) {
            st.dmActive = NO;
            st.dmGen++;
            st.dmReferenceFrame = 0;
            st.hasSimQuat = NO;
            st.simLastTs = 0.0;
            st.lastDMSample = nil;
            st.lastDMMonoSec = 0.0;
            if (st.dmTimer) { dispatch_source_cancel(st.dmTimer); st.dmTimer = nil; }
        }
    }
    [self pm_ps_cm_stopDeviceMotionUpdates];
}

- (void) pm_ps_cm_startRelativeAltitudeUpdatesToQueue:(NSOperationQueue *)queue
                                          withHandler:(CMAltitudeHandler)handler {
    Class altCls = objc_getClass("CMAltimeter");
    BOOL origAvailable = (altCls != Nil)
        ? ((BOOL (*)(id, SEL))objc_msgSend)((id)altCls, @selector(pm_ps_cm_isRelativeAltitudeAvailable))
        : NO;
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        !origAvailable) {
        PSVirtualAltimeterState *st = ps_altimeter_state(self, YES);
        if (st != nil) {
            @synchronized (st) {
                st.active = YES;
                st.emittedFirstSample = NO;
                uint64_t gen = ++st.generation;
                if (st.timer != nil) {
                    dispatch_source_cancel(st.timer);
                    st.timer = nil;
                }
                if (handler != nil) {
                    CMAltitudeHandler userHandler = [handler copy];
                    dispatch_source_t timer = ps_create_suspended_motion_timer(self, 1.0, queue, ^(id strongAlt) {
                        PSVirtualAltimeterState *curSt = ps_altimeter_state(strongAlt, NO);
                        BOOL shouldEmit = NO;
                        BOOL isFirst = NO;
                        if (curSt != nil) {
                            @synchronized (curSt) {
                                if (curSt.active && curSt.generation == gen) {
                                    shouldEmit = YES;
                                    isFirst = !curSt.emittedFirstSample;
                                    curSt.emittedFirstSample = YES;
                                }
                            }
                        }
                        if (!shouldEmit) {
                            return;
                        }
                        CMAltitudeData *sample = ps_make_virtual_altitude_sample(isFirst);
                        if (sample != nil) {
                            userHandler(sample, nil);
                        }
                    });
                    if (timer != nil) {
                        st.timer = timer;
                        dispatch_resume(timer);
                    }
                }
            }
        }
        return;
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMAltitudeHandler userHandler = [handler copy];
        [self pm_ps_cm_startRelativeAltitudeUpdatesToQueue:queue withHandler:^(CMAltitudeData *altitudeData, NSError *error) {
            ps_cm_observe_real_sample(altitudeData);
            userHandler(altitudeData, error);
        }];
        return;
    }
    [self pm_ps_cm_startRelativeAltitudeUpdatesToQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_stopRelativeAltitudeUpdates {
    PSVirtualAltimeterState *st = ps_altimeter_state(self, NO);
    if (st != nil) {
        @synchronized (st) {
            st.active = NO;
            st.generation++;
            if (st.timer != nil) {
                dispatch_source_cancel(st.timer);
                st.timer = nil;
            }
        }
    }
    [self pm_ps_cm_stopRelativeAltitudeUpdates];
}

@end

__attribute__((visibility("hidden"))) void ps_install_coremotion_hooks_if_loaded(void) {
    Class logCls = objc_getClass("CMLogItem");
    Class accelCls = objc_getClass("CMAccelerometerData");
    Class gyroCls = objc_getClass("CMGyroData");
    Class magCls = objc_getClass("CMMagnetometerData");
    Class attCls = objc_getClass("CMAttitude");
    Class dmCls = objc_getClass("CMDeviceMotion");
    Class altDataCls = objc_getClass("CMAltitudeData");
    if (logCls != Nil || accelCls != Nil || gyroCls != Nil || magCls != Nil ||
        attCls != Nil || dmCls != Nil || altDataCls != Nil) {
        static dispatch_once_t cmDataOnce;
        dispatch_once(&cmDataOnce, ^{
            SEL contTsSel = NSSelectorFromString(@"continuousTimestamp");
            Class logHierarchy[] = { logCls, accelCls, gyroCls, magCls, dmCls, altDataCls };
            for (size_t i = 0; i < sizeof(logHierarchy) / sizeof(logHierarchy[0]); i++) {
                Class c = logHierarchy[i];
                if (c == Nil) {
                    continue;
                }
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_timestamp_imps, c, @selector(timestamp), @selector(pm_ps_cm_sample_timestamp));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_cont_ts_imps, c, contTsSel, @selector(pm_ps_cm_sample_continuousTimestamp));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_copy_imps, c, @selector(copyWithZone:), @selector(pm_ps_cm_copyWithZone:));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_encode_imps, c, @selector(encodeWithCoder:), @selector(pm_ps_cm_encodeWithCoder:));
                if (c != logCls) {
                    ps_swizzle_cm_sel_if_defined(&s_cm_orig_desc_imps, c, @selector(description), @selector(pm_ps_cm_sample_description));
                }
            }
            ps_swizzle_cm_sel_if_defined(&s_cm_orig_accel_imps, accelCls, @selector(acceleration), @selector(pm_ps_cm_sample_acceleration));
            ps_swizzle_cm_sel_if_defined(&s_cm_orig_rot_imps, gyroCls, @selector(rotationRate), @selector(pm_ps_cm_sample_rotationRate));
            ps_swizzle_cm_sel_if_defined(&s_cm_orig_mag_imps, magCls, @selector(magneticField), @selector(pm_ps_cm_sample_magneticField));

            if (attCls != Nil) {
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_copy_imps, attCls, @selector(copyWithZone:), @selector(pm_ps_cm_copyWithZone:));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_encode_imps, attCls, @selector(encodeWithCoder:), @selector(pm_ps_cm_encodeWithCoder:));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_desc_imps, attCls, @selector(description), @selector(pm_ps_cm_sample_description));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_isEqual_imps, attCls, @selector(isEqual:), @selector(pm_ps_cm_isEqual:));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_att_roll_imps, attCls, @selector(roll), @selector(pm_ps_cm_attitude_roll));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_att_pitch_imps, attCls, @selector(pitch), @selector(pm_ps_cm_attitude_pitch));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_att_yaw_imps, attCls, @selector(yaw), @selector(pm_ps_cm_attitude_yaw));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_att_quat_imps, attCls, @selector(quaternion), @selector(pm_ps_cm_attitude_quaternion));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_att_mat_imps, attCls, @selector(rotationMatrix), @selector(pm_ps_cm_attitude_rotationMatrix));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_att_mul_imps, attCls, @selector(multiplyByInverseOfAttitude:), @selector(pm_ps_cm_attitude_multiplyByInverseOfAttitude:));
            }
            if (dmCls != Nil) {
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_isEqual_imps, dmCls, @selector(isEqual:), @selector(pm_ps_cm_isEqual:));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_dm_attitude_imps, dmCls, @selector(attitude), @selector(pm_ps_cm_dm_attitude));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_dm_gravity_imps, dmCls, @selector(gravity), @selector(pm_ps_cm_dm_gravity));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_dm_userAccel_imps, dmCls, @selector(userAcceleration), @selector(pm_ps_cm_dm_userAcceleration));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_rot_imps, dmCls, @selector(rotationRate), @selector(pm_ps_cm_sample_rotationRate));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_dm_mag_imps, dmCls, @selector(magneticField), @selector(pm_ps_cm_dm_magneticField));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_dm_heading_imps, dmCls, @selector(heading), @selector(pm_ps_cm_dm_heading));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_dm_headingAcc_imps, dmCls, NSSelectorFromString(@"headingAccuracy"), @selector(pm_ps_cm_dm_headingAccuracy));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_dm_sensorLoc_imps, dmCls, @selector(sensorLocation), @selector(pm_ps_cm_dm_sensorLocation));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_dm_isInit_imps, dmCls, NSSelectorFromString(@"isInitialized"), @selector(pm_ps_cm_dm_isInitialized));
            }
            if (altDataCls != Nil) {
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_alt_rel_imps, altDataCls, @selector(relativeAltitude), @selector(pm_ps_cm_alt_relativeAltitude));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_alt_press_imps, altDataCls, @selector(pressure), @selector(pm_ps_cm_alt_pressure));
            }
            Class pedDataCls = objc_getClass("CMPedometerData");
            if (pedDataCls != Nil) {
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_ped_startDate_imps, pedDataCls, @selector(startDate), @selector(pm_ps_cm_ped_data_startDate));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_ped_endDate_imps, pedDataCls, @selector(endDate), @selector(pm_ps_cm_ped_data_endDate));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_ped_steps_imps, pedDataCls, @selector(numberOfSteps), @selector(pm_ps_cm_ped_data_numberOfSteps));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_ped_dist_imps, pedDataCls, @selector(distance), @selector(pm_ps_cm_ped_data_distance));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_ped_floorsAsc_imps, pedDataCls, @selector(floorsAscended), @selector(pm_ps_cm_ped_data_floorsAscended));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_ped_floorsDesc_imps, pedDataCls, @selector(floorsDescended), @selector(pm_ps_cm_ped_data_floorsDescended));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_ped_curPace_imps, pedDataCls, @selector(currentPace), @selector(pm_ps_cm_ped_data_currentPace));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_ped_curCadence_imps, pedDataCls, @selector(currentCadence), @selector(pm_ps_cm_ped_data_currentCadence));
                ps_swizzle_cm_sel_if_defined(&s_cm_orig_ped_avgPace_imps, pedDataCls, @selector(averageActivePace), @selector(pm_ps_cm_ped_data_averageActivePace));
            }
        });
    }
    Class cmCls = objc_getClass("CMMotionManager");
    if (cmCls != Nil) {
        static dispatch_once_t cmOnce;
        dispatch_once(&cmOnce, ^{
            char frameTypes[32];
            snprintf(frameTypes, sizeof(frameTypes), "%s@:", @encode(CMAttitudeReferenceFrame));
            SEL availFramesSel = sel_registerName("availableAttitudeReferenceFrames");
            Method refMethod = class_getInstanceMethod(cmCls, @selector(isDeviceMotionAvailable));
            IMP refOrigImp = (refMethod != NULL) ? method_getImplementation(refMethod) : NULL;
            if (class_getClassMethod(cmCls, availFramesSel) != NULL) {
                ps_swizzle_class_method(cmCls, availFramesSel, @selector(pm_ps_cm_availableAttitudeReferenceFrames));
            } else {
                Class metaCls = object_getClass(cmCls);
                if (metaCls != Nil) {
                    if (class_addMethod(metaCls,
                                        availFramesSel,
                                        (IMP)ps_cm_fallback_availableAttitudeReferenceFrames,
                                        frameTypes) && refOrigImp != NULL) {
                        pt_register_swizzled_imp((const void *)ps_cm_fallback_availableAttitudeReferenceFrames,
                                                 (const void *)refOrigImp);
                    }
                }
            }
            SEL attFrameSel = sel_registerName("attitudeReferenceFrame");
            if (class_getInstanceMethod(cmCls, attFrameSel) != NULL) {
                ps_swizzle_instance_method(cmCls, attFrameSel, @selector(pm_ps_cm_attitudeReferenceFrame));
            } else {
                if (class_addMethod(cmCls,
                                    attFrameSel,
                                    (IMP)ps_cm_fallback_attitudeReferenceFrame,
                                    frameTypes) && refOrigImp != NULL) {
                    pt_register_swizzled_imp((const void *)ps_cm_fallback_attitudeReferenceFrame,
                                             (const void *)refOrigImp);
                }
            }
            ps_swizzle_instance_method(cmCls, @selector(isAccelerometerAvailable), @selector(pm_ps_cm_isAccelerometerAvailable));
            ps_swizzle_instance_method(cmCls, @selector(isGyroAvailable), @selector(pm_ps_cm_isGyroAvailable));
            ps_swizzle_instance_method(cmCls, @selector(isMagnetometerAvailable), @selector(pm_ps_cm_isMagnetometerAvailable));
            ps_swizzle_instance_method(cmCls, @selector(isDeviceMotionAvailable), @selector(pm_ps_cm_isDeviceMotionAvailable));
            ps_swizzle_instance_method(cmCls, @selector(isAccelerometerActive), @selector(pm_ps_cm_isAccelerometerActive));
            ps_swizzle_instance_method(cmCls, @selector(isGyroActive), @selector(pm_ps_cm_isGyroActive));
            ps_swizzle_instance_method(cmCls, @selector(isMagnetometerActive), @selector(pm_ps_cm_isMagnetometerActive));
            ps_swizzle_instance_method(cmCls, @selector(isDeviceMotionActive), @selector(pm_ps_cm_isDeviceMotionActive));
            ps_swizzle_instance_method(cmCls, @selector(magnetometerUpdateInterval), @selector(pm_ps_cm_magnetometerUpdateInterval));
            ps_swizzle_instance_method(cmCls, @selector(setMagnetometerUpdateInterval:), @selector(pm_ps_cm_setMagnetometerUpdateInterval:));
            ps_swizzle_instance_method(cmCls, @selector(accelerometerData), @selector(pm_ps_cm_accelerometerData));
            ps_swizzle_instance_method(cmCls, @selector(gyroData), @selector(pm_ps_cm_gyroData));
            ps_swizzle_instance_method(cmCls, @selector(magnetometerData), @selector(pm_ps_cm_magnetometerData));
            ps_swizzle_instance_method(cmCls, @selector(deviceMotion), @selector(pm_ps_cm_deviceMotion));
            ps_swizzle_instance_method(cmCls, @selector(startAccelerometerUpdates), @selector(pm_ps_cm_startAccelerometerUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startAccelerometerUpdatesToQueue:withHandler:), @selector(pm_ps_cm_startAccelerometerUpdatesToQueue:withHandler:));
            ps_swizzle_instance_method(cmCls, @selector(stopAccelerometerUpdates), @selector(pm_ps_cm_stopAccelerometerUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startGyroUpdates), @selector(pm_ps_cm_startGyroUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startGyroUpdatesToQueue:withHandler:), @selector(pm_ps_cm_startGyroUpdatesToQueue:withHandler:));
            ps_swizzle_instance_method(cmCls, @selector(stopGyroUpdates), @selector(pm_ps_cm_stopGyroUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startMagnetometerUpdates), @selector(pm_ps_cm_startMagnetometerUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startMagnetometerUpdatesToQueue:withHandler:), @selector(pm_ps_cm_startMagnetometerUpdatesToQueue:withHandler:));
            ps_swizzle_instance_method(cmCls, @selector(stopMagnetometerUpdates), @selector(pm_ps_cm_stopMagnetometerUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startDeviceMotionUpdates), @selector(pm_ps_cm_startDeviceMotionUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startDeviceMotionUpdatesUsingReferenceFrame:), @selector(pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:));
            ps_swizzle_instance_method(cmCls, @selector(startDeviceMotionUpdatesToQueue:withHandler:), @selector(pm_ps_cm_startDeviceMotionUpdatesToQueue:withHandler:));
            ps_swizzle_instance_method(cmCls, @selector(startDeviceMotionUpdatesUsingReferenceFrame:toQueue:withHandler:), @selector(pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:toQueue:withHandler:));
            ps_swizzle_instance_method(cmCls, @selector(stopDeviceMotionUpdates), @selector(pm_ps_cm_stopDeviceMotionUpdates));
        });
    }
    Class altCls = objc_getClass("CMAltimeter");
    if (altCls != Nil) {
        static dispatch_once_t altOnce;
        dispatch_once(&altOnce, ^{
            ps_swizzle_class_method(altCls, @selector(isRelativeAltitudeAvailable), @selector(pm_ps_cm_isRelativeAltitudeAvailable));
            SEL absAltSel = sel_registerName("isAbsoluteAltitudeAvailable");
            if (class_getClassMethod(altCls, absAltSel) != NULL) {
                ps_swizzle_class_method(altCls, absAltSel, @selector(pm_ps_cm_isAbsoluteAltitudeAvailable));
            }
            if (class_getInstanceMethod(altCls, @selector(startRelativeAltitudeUpdatesToQueue:withHandler:)) != NULL) {
                ps_swizzle_instance_method(altCls,
                                           @selector(startRelativeAltitudeUpdatesToQueue:withHandler:),
                                           @selector(pm_ps_cm_startRelativeAltitudeUpdatesToQueue:withHandler:));
            }
            if (class_getInstanceMethod(altCls, @selector(stopRelativeAltitudeUpdates)) != NULL) {
                ps_swizzle_instance_method(altCls,
                                           @selector(stopRelativeAltitudeUpdates),
                                           @selector(pm_ps_cm_stopRelativeAltitudeUpdates));
            }
        });
    }
    Class pedCls = objc_getClass("CMPedometer");
    if (pedCls != Nil) {
        static dispatch_once_t pedOnce;
        dispatch_once(&pedOnce, ^{
            const struct {
                const char *origName;
                SEL hookSel;
            } kPedSwizzles[] = {
                { "isStepCountingAvailable", @selector(pm_ps_cm_ped_isStepCountingAvailable) },
                { "isDistanceAvailable", @selector(pm_ps_cm_ped_isDistanceAvailable) },
                { "isFloorCountingAvailable", @selector(pm_ps_cm_ped_isFloorCountingAvailable) },
                { "isPaceAvailable", @selector(pm_ps_cm_ped_isPaceAvailable) },
                { "isCadenceAvailable", @selector(pm_ps_cm_ped_isCadenceAvailable) },
                { "isPedometerEventTrackingAvailable", @selector(pm_ps_cm_ped_isPedometerEventTrackingAvailable) },
                { "authorizationStatus", @selector(pm_ps_cm_ped_authorizationStatus) }
            };
            for (size_t i = 0; i < sizeof(kPedSwizzles) / sizeof(kPedSwizzles[0]); i++) {
                SEL s = sel_registerName(kPedSwizzles[i].origName);
                if (class_getClassMethod(pedCls, s) != NULL) {
                    ps_swizzle_class_method(pedCls, s, kPedSwizzles[i].hookSel);
                }
            }
            if (class_getInstanceMethod(pedCls, @selector(queryPedometerDataFromDate:toDate:withHandler:)) != NULL) {
                ps_swizzle_instance_method(pedCls,
                                           @selector(queryPedometerDataFromDate:toDate:withHandler:),
                                           @selector(pm_ps_cm_ped_queryPedometerDataFromDate:toDate:withHandler:));
            }
            if (class_getInstanceMethod(pedCls, @selector(startPedometerUpdatesFromDate:withHandler:)) != NULL) {
                ps_swizzle_instance_method(pedCls,
                                           @selector(startPedometerUpdatesFromDate:withHandler:),
                                           @selector(pm_ps_cm_ped_startPedometerUpdatesFromDate:withHandler:));
            }
            if (class_getInstanceMethod(pedCls, @selector(stopPedometerUpdates)) != NULL) {
                ps_swizzle_instance_method(pedCls,
                                           @selector(stopPedometerUpdates),
                                           @selector(pm_ps_cm_ped_stopPedometerUpdates));
            }
        });
    }
    Class actCls = objc_getClass("CMMotionActivityManager");
    if (actCls != Nil) {
        static dispatch_once_t actOnce;
        dispatch_once(&actOnce, ^{
            SEL isActSel = sel_registerName("isActivityAvailable");
            if (class_getClassMethod(actCls, isActSel) != NULL) {
                ps_swizzle_class_method(actCls, isActSel, @selector(pm_ps_cm_activity_isActivityAvailable));
            }
        });
    }
}
