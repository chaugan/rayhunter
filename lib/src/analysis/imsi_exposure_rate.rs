use std::borrow::Cow;
use std::collections::VecDeque;

use pycrate_rs::nas::NASMessage;
use pycrate_rs::nas::emm::EMMMessage;
use pycrate_rs::nas::generated::emm::emm_attach_reject::EMMCauseEMMCause as AttachRejectCause;
use pycrate_rs::nas::generated::emm::emm_detach_request_mt::EPSDetachTypeMTType;
use pycrate_rs::nas::generated::emm::emm_service_reject::EMMCauseEMMCause as ServiceRejectCause;
use pycrate_rs::nas::generated::emm::emm_tracking_area_update_reject::EMMCauseEMMCause as TauRejectCause;
use pycrate_rs::nas::generated::emm::emm_detach_request_mt::EMMCauseEMMCause as DetachMtCause;

use super::analyzer::{Analyzer, Event, EventType};
use super::information_element::{InformationElement, LteInformationElement};
use super::util::is_guti_deleting_cause;

const WINDOW_SIZE: usize = 100;
const MEDIUM_THRESHOLD: f64 = 0.05;
const HIGH_THRESHOLD: f64 = 0.15;

pub struct ImsiExposureRateAnalyzer {
    window: VecDeque<bool>,
    exposing_count: usize,
}

impl Default for ImsiExposureRateAnalyzer {
    fn default() -> Self {
        Self::new()
    }
}

impl ImsiExposureRateAnalyzer {
    pub fn new() -> Self {
        Self {
            window: VecDeque::with_capacity(WINDOW_SIZE),
            exposing_count: 0,
        }
    }

    fn is_imsi_exposing(payload: &NASMessage) -> bool {
        match payload {
            NASMessage::EMMMessage(EMMMessage::EMMAttachReject(msg)) => {
                use AttachRejectCause::*;
                is_guti_deleting_cause!(&msg.emm_cause.inner)
            }
            NASMessage::EMMMessage(EMMMessage::EMMTrackingAreaUpdateReject(msg)) => {
                use TauRejectCause::*;
                is_guti_deleting_cause!(&msg.emm_cause.inner)
            }
            NASMessage::EMMMessage(EMMMessage::EMMServiceReject(msg)) => {
                use ServiceRejectCause::*;
                is_guti_deleting_cause!(&msg.emm_cause.inner)
            }
            NASMessage::EMMMessage(EMMMessage::EMMDetachRequestMT(msg)) => {
                if msg.eps_detach_type.inner.typ == EPSDetachTypeMTType::ReAttachNotRequired {
                    return true;
                }
                if let Some(ref cause) = msg.emm_cause.inner {
                    use DetachMtCause::*;
                    return is_guti_deleting_cause!(cause);
                }
                false
            }
            NASMessage::EMMMessage(EMMMessage::EMMAuthenticationReject(_)) => true,
            NASMessage::EMMMessage(EMMMessage::EMMIdentityRequest(_)) => true,
            _ => false,
        }
    }
}

impl Analyzer for ImsiExposureRateAnalyzer {
    fn get_name(&self) -> Cow<'_, str> {
        Cow::from("IMSI Exposure Rate")
    }

    fn get_description(&self) -> Cow<'_, str> {
        Cow::from(
            "Tracks the rate of IMSI-exposing NAS messages over a sliding window. \
             Normal LTE networks show <3% incidence; >=5% triggers a Medium warning, \
             >=15% triggers a High warning. Based on Tucker et al. (NDSS 2025).",
        )
    }

    fn get_version(&self) -> u32 {
        1
    }

    fn analyze_information_element(
        &mut self,
        ie: &InformationElement,
        _packet_num: usize,
    ) -> Option<Event> {
        let payload = match ie {
            InformationElement::LTE(inner) => match &**inner {
                LteInformationElement::NAS(payload) => payload,
                _ => return None,
            },
            _ => return None,
        };

        let is_exposing = Self::is_imsi_exposing(payload);

        // Evict oldest entry if window is full
        if self.window.len() >= WINDOW_SIZE
            && let Some(old) = self.window.pop_front()
            && old
        {
            self.exposing_count -= 1;
        }

        self.window.push_back(is_exposing);
        if is_exposing {
            self.exposing_count += 1;
        }

        // Only evaluate once we have a full window
        if self.window.len() < WINDOW_SIZE {
            return None;
        }

        let rate = self.exposing_count as f64 / WINDOW_SIZE as f64;

        if rate >= HIGH_THRESHOLD {
            Some(Event {
                event_type: EventType::High,
                message: format!(
                    "IMSI exposure rate {:.0}% over last {} NAS messages (>={:.0}% threshold)",
                    rate * 100.0,
                    WINDOW_SIZE,
                    HIGH_THRESHOLD * 100.0,
                ),
            })
        } else if rate >= MEDIUM_THRESHOLD {
            Some(Event {
                event_type: EventType::Medium,
                message: format!(
                    "IMSI exposure rate {:.0}% over last {} NAS messages (>={:.0}% threshold)",
                    rate * 100.0,
                    WINDOW_SIZE,
                    MEDIUM_THRESHOLD * 100.0,
                ),
            })
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pycrate_rs::nas::generated::emm::emm_attach_reject::EMMAttachReject;
    use pycrate_rs::nas::layer3::{Type3V, Type4TLV, Type6TLVE, Type1TV};

    fn wrap_nas(msg: NASMessage) -> InformationElement {
        InformationElement::LTE(Box::new(LteInformationElement::NAS(msg)))
    }

    fn make_attach_reject(cause: AttachRejectCause) -> InformationElement {
        wrap_nas(NASMessage::EMMMessage(EMMMessage::EMMAttachReject(
            EMMAttachReject {
                emm_cause: Type3V { inner: cause },
                esm_container: Type6TLVE { tag: 0, length: 0, inner: None },
                t_3346: Type4TLV { tag: 0, length: 0, inner: None },
                t_3402: Type4TLV { tag: 0, length: 0, inner: None },
                ext_emm_cause: Type1TV { tag: 0, v: 0, inner: None },
            },
        )))
    }

    fn make_benign_ie() -> InformationElement {
        make_attach_reject(AttachRejectCause::Congestion)
    }

    fn make_exposing_ie() -> InformationElement {
        make_attach_reject(AttachRejectCause::IllegalUE)
    }

    #[test]
    fn test_no_warning_below_threshold() {
        let mut analyzer = ImsiExposureRateAnalyzer::new();
        for i in 0..100 {
            let result = analyzer.analyze_information_element(&make_benign_ie(), i);
            if i < 99 {
                assert!(result.is_none(), "should not fire before window is full");
            } else {
                assert!(result.is_none(), "0% rate should not fire");
            }
        }
    }

    #[test]
    fn test_medium_warning_at_5_percent() {
        let mut analyzer = ImsiExposureRateAnalyzer::new();
        // 5 exposing + 95 benign = 5%
        for i in 0..5 {
            analyzer.analyze_information_element(&make_exposing_ie(), i);
        }
        let mut last_event = None;
        for i in 5..100 {
            last_event = analyzer.analyze_information_element(&make_benign_ie(), i);
        }
        let event = last_event.unwrap();
        assert_eq!(event.event_type, EventType::Medium);
    }

    #[test]
    fn test_high_warning_at_15_percent() {
        let mut analyzer = ImsiExposureRateAnalyzer::new();
        // 15 exposing + 85 benign = 15%
        for i in 0..15 {
            analyzer.analyze_information_element(&make_exposing_ie(), i);
        }
        let mut last_event = None;
        for i in 15..100 {
            last_event = analyzer.analyze_information_element(&make_benign_ie(), i);
        }
        let event = last_event.unwrap();
        assert_eq!(event.event_type, EventType::High);
    }

    #[test]
    fn test_sliding_window_eviction() {
        let mut analyzer = ImsiExposureRateAnalyzer::new();
        // Fill with 5 exposing then 95 benign (5% = medium)
        for i in 0..5 {
            analyzer.analyze_information_element(&make_exposing_ie(), i);
        }
        for i in 5..100 {
            analyzer.analyze_information_element(&make_benign_ie(), i);
        }
        // Push 5 more benign, evicting the 5 exposing ones
        let mut last_event = None;
        for i in 100..105 {
            last_event = analyzer.analyze_information_element(&make_benign_ie(), i);
        }
        // Rate should now be 0%, no warning
        assert!(last_event.is_none());
    }
}
