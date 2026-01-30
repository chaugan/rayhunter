/// Returns true if the given EMM cause code forces GUTI deletion per 3GPP TS 24.301,
/// meaning the UE will expose its IMSI on the next attach attempt.
///
/// This is a macro because pycrate_rs generates a separate `EMMCauseEMMCause` enum
/// in each message module, so a single generic function can't accept all of them.
macro_rules! is_guti_deleting_cause {
    ($cause:expr) => {
        matches!(
            $cause,
            IMSIUnknownInHSS
                | IllegalUE
                | IllegalME
                | EPSServicesNotAllowed
                | EPSServicesAndNonEPSServicesNotAllowed
                | PLMNNotAllowed
                | TrackingAreaNotAllowed
                | RoamingNotAllowedInThisTrackingArea
                | EPSServicesNotAllowedInThisPLMN
                | ImplicitlyDetached
        )
    };
}

pub(crate) use is_guti_deleting_cause;
