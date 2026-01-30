use std::borrow::Cow;

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

pub struct ImsiExposingRejectAnalyzer;

fn check_attach_reject_cause(cause: &AttachRejectCause) -> bool {
    use AttachRejectCause::*;
    is_guti_deleting_cause!(cause)
}

fn check_tau_reject_cause(cause: &TauRejectCause) -> bool {
    use TauRejectCause::*;
    is_guti_deleting_cause!(cause)
}

fn check_service_reject_cause(cause: &ServiceRejectCause) -> bool {
    use ServiceRejectCause::*;
    is_guti_deleting_cause!(cause)
}

fn check_detach_mt_cause(cause: &DetachMtCause) -> bool {
    use DetachMtCause::*;
    is_guti_deleting_cause!(cause)
}

impl Analyzer for ImsiExposingRejectAnalyzer {
    fn get_name(&self) -> Cow<'_, str> {
        Cow::from("IMSI-Exposing Reject/Detach")
    }

    fn get_description(&self) -> Cow<'_, str> {
        Cow::from(
            "Detects NAS reject or detach messages that force GUTI deletion, \
             causing the UE to expose its IMSI on the next attach. \
             Based on Tucker et al. (NDSS 2025).",
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

        match payload {
            NASMessage::EMMMessage(EMMMessage::EMMAttachReject(msg)) => {
                if check_attach_reject_cause(&msg.emm_cause.inner) {
                    return Some(Event {
                        event_type: EventType::Informational,
                        message: format!(
                            "Attach Reject with GUTI-deleting cause: {:?}",
                            msg.emm_cause.inner
                        ),
                    });
                }
            }
            NASMessage::EMMMessage(EMMMessage::EMMTrackingAreaUpdateReject(msg)) => {
                if check_tau_reject_cause(&msg.emm_cause.inner) {
                    return Some(Event {
                        event_type: EventType::Informational,
                        message: format!(
                            "TAU Reject with GUTI-deleting cause: {:?}",
                            msg.emm_cause.inner
                        ),
                    });
                }
            }
            NASMessage::EMMMessage(EMMMessage::EMMServiceReject(msg)) => {
                if check_service_reject_cause(&msg.emm_cause.inner) {
                    return Some(Event {
                        event_type: EventType::Informational,
                        message: format!(
                            "Service Reject with GUTI-deleting cause: {:?}",
                            msg.emm_cause.inner
                        ),
                    });
                }
            }
            NASMessage::EMMMessage(EMMMessage::EMMDetachRequestMT(msg)) => {
                if msg.eps_detach_type.inner.typ == EPSDetachTypeMTType::ReAttachNotRequired {
                    return Some(Event {
                        event_type: EventType::Informational,
                        message: "MT Detach with re-attach not required (forces GUTI deletion)"
                            .to_string(),
                    });
                }
                if let Some(ref cause) = msg.emm_cause.inner
                    && check_detach_mt_cause(cause)
                {
                    return Some(Event {
                        event_type: EventType::Informational,
                        message: format!(
                            "MT Detach with GUTI-deleting cause: {:?}",
                            cause
                        ),
                    });
                }
            }
            NASMessage::EMMMessage(EMMMessage::EMMAuthenticationReject(_)) => {
                return Some(Event {
                    event_type: EventType::Informational,
                    message: "Authentication Reject (forces GUTI deletion)".to_string(),
                });
            }
            _ => {}
        }

        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pycrate_rs::nas::generated::emm::emm_attach_reject::EMMAttachReject;
    use pycrate_rs::nas::generated::emm::emm_authentication_reject::EMMAuthenticationReject;
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

    #[test]
    fn test_auth_reject_always_fires() {
        let mut analyzer = ImsiExposingRejectAnalyzer;
        let ie = wrap_nas(NASMessage::EMMMessage(EMMMessage::EMMAuthenticationReject(
            EMMAuthenticationReject {},
        )));
        let event = analyzer.analyze_information_element(&ie, 1);
        assert!(event.is_some());
        let event = event.unwrap();
        assert_eq!(event.event_type, EventType::Informational);
        assert!(event.message.contains("Authentication Reject"));
    }

    #[test]
    fn test_attach_reject_non_guti_deleting_ignored() {
        let mut analyzer = ImsiExposingRejectAnalyzer;
        let ie = make_attach_reject(AttachRejectCause::Congestion);
        let event = analyzer.analyze_information_element(&ie, 1);
        assert!(event.is_none());
    }

    #[test]
    fn test_attach_reject_guti_deleting_fires() {
        let mut analyzer = ImsiExposingRejectAnalyzer;
        let ie = make_attach_reject(AttachRejectCause::IllegalUE);
        let event = analyzer.analyze_information_element(&ie, 1);
        assert!(event.is_some());
        assert!(event.unwrap().message.contains("GUTI-deleting"));
    }
}
