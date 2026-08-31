use super::*;

pub(super) fn run_session_worker(commands: Receiver<SessionCommand>) {
    while let Ok(command) = commands.recv() {
        match command {
            SessionCommand::Suspend => {
                if let Err(error) = suspend() {
                    warn!(%error, "automatic system suspend failed");
                }
            }
            SessionCommand::Stop => return,
        }
    }
}

fn suspend() -> Result<(), String> {
    let connection = zbus::blocking::Connection::system()
        .map_err(|error| format!("could not connect to the system bus: {error}"))?;
    let manager = zbus::blocking::Proxy::new(
        &connection,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
    )
    .map_err(|error| format!("could not open the logind manager: {error}"))?;
    let _: () = manager
        .call("Suspend", &false)
        .map_err(|error| format!("logind Suspend failed: {error}"))?;
    Ok(())
}
