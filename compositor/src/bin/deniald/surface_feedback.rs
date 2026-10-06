//! One-shot feedback ownership follows the sampled client buffer through scanout.
use smithay::desktop::utils::SurfacePresentationFeedback;
use std::sync::{Arc, Mutex};

#[derive(Debug)]
pub(crate) struct FeedbackLatch<T>(Arc<Mutex<Option<T>>>);
impl<T> Clone for FeedbackLatch<T> {
    fn clone(&self) -> Self {
        Self(Arc::clone(&self.0))
    }
}
impl<T> FeedbackLatch<T> {
    pub(crate) fn new(value: T) -> Self {
        Self(Arc::new(Mutex::new(Some(value))))
    }
    pub(crate) fn take(&self) -> Option<T> {
        self.0.lock().unwrap().take()
    }
    pub(crate) fn pending(&self) -> bool {
        self.0.lock().unwrap().is_some()
    }
    pub(crate) fn same(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}
pub(crate) type SurfaceFeedback = FeedbackLatch<SurfacePresentationFeedback>;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn an_older_scanout_cannot_acknowledge_a_newer_commit() {
        let old_source = FeedbackLatch::new(1);
        let queued_scanout = old_source.clone();
        let new_source = FeedbackLatch::new(2);
        drop(old_source);
        assert_eq!(queued_scanout.take(), Some(1));
        assert_eq!(new_source.take(), Some(2));
    }
    #[test]
    fn first_presented_output_consumes_feedback_once() {
        let source = FeedbackLatch::new(1);
        let first_output = source.clone();
        let second_output = source.clone();
        assert_eq!(second_output.take(), Some(1));
        assert_eq!(first_output.take(), None);
        assert!(!source.pending());
    }
    #[test]
    fn discarded_render_does_not_consume_a_source_that_can_be_sampled_again() {
        let source = FeedbackLatch::new(1);
        let abandoned = source.clone();
        drop(abandoned);
        assert_eq!(source.take(), Some(1));
    }
}
