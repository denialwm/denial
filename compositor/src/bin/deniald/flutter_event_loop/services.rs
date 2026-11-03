//! Workers the Flutter session starts and feeds into the event loop.

use super::*;

pub(super) fn start_notification_server(
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<Option<NotificationServer>, Box<dyn Error>> {
    let notification_events = Arc::new(Mutex::new(VecDeque::with_capacity(
        NOTIFICATION_EVENT_QUEUE_CAPACITY,
    )));
    let notification_publish_queue = Arc::clone(&notification_events);
    let (notification_sender, notification_source) = channel();
    match NotificationServer::start(move |event, _| {
        let should_wake = {
            let mut queue = notification_publish_queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let should_wake = queue.is_empty();
            if queue.len() == NOTIFICATION_EVENT_QUEUE_CAPACITY {
                queue.pop_front();
            }
            queue.push_back(event);
            should_wake
        };
        if should_wake {
            // One calloop message wakes the compositor for the complete
            // coalesced batch; the notification worker never busy-waits.
            let _ = notification_sender.send(());
        }
    }) {
        Ok(server) => {
            let notification_dispatch_queue = Arc::clone(&notification_events);
            event_loop.handle().insert_source(
                notification_source,
                move |event, _, state: &mut RuntimeState| {
                    if let ChannelEvent::Msg(()) = event {
                        let mut queue = notification_dispatch_queue
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        state.pending_notification_events.extend(queue.drain(..));
                    }
                },
            )?;
            Ok(Some(server))
        }
        Err(error) => {
            error!(%error, "Denial could not start its notification service");
            Ok(None)
        }
    }
}

pub(super) fn start_orientation_sensor(
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<Option<orientation_sensor::OrientationSensor>, Box<dyn Error>> {
    match orientation_sensor::OrientationSensor::start() {
        Ok((sensor, source)) => {
            event_loop
                .handle()
                .insert_source(source, |event, _, state: &mut RuntimeState| {
                    if let ChannelEvent::Msg(orientation) = event {
                        orientation.update_pending(&mut state.pending_orientation);
                    }
                })?;
            Ok(Some(sensor))
        }
        Err(error) => {
            warn!(%error, "could not start the orientation sensor worker");
            Ok(None)
        }
    }
}

pub(super) fn start_text_prediction(
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<Option<text_prediction::TextPredictionService>, Box<dyn Error>> {
    match text_prediction::TextPredictionService::start() {
        Ok((service, source)) => {
            event_loop
                .handle()
                .insert_source(source, |event, _, state: &mut RuntimeState| {
                    if let ChannelEvent::Msg(prediction) = event {
                        state.pending_text_prediction = Some(prediction);
                    }
                })?;
            Ok(Some(service))
        }
        Err(error) => {
            warn!(%error, "could not start the keyboard word suggestions");
            Ok(None)
        }
    }
}
