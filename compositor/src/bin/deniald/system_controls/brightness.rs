use super::*;

trait BrightnessProvider {
    fn name(&self) -> &'static str;
    fn controls(&mut self, connector: &str) -> bool;
    fn read(&mut self, connector: &str) -> Result<f64, String>;
    fn set(&mut self, connector: &str, level: f64) -> Result<(), String>;
}

struct BrightnessProviders {
    providers: Vec<Box<dyn BrightnessProvider>>,
    desired: HashMap<String, f64>,
    failure_latched: HashMap<String, bool>,
}

impl BrightnessProviders {
    fn start() -> Result<Self, String> {
        let mut providers: Vec<Box<dyn BrightnessProvider>> = Vec::new();
        let mut failures = Vec::new();

        match BacklightWorker::start() {
            Ok(provider) => providers.push(Box::new(provider)),
            Err(error) => failures.push(format!("kernel backlight: {error}")),
        }
        match DdcWorker::start() {
            Ok(provider) => providers.push(Box::new(provider)),
            Err(error) => failures.push(format!("DDC/CI: {error}")),
        }

        if providers.is_empty() {
            return Err(failures.join("; "));
        }
        if !failures.is_empty() {
            info!(unavailable = %failures.join("; "), "some brightness providers are unavailable");
        }
        Ok(Self {
            providers,
            desired: HashMap::new(),
            failure_latched: HashMap::new(),
        })
    }

    fn read(&mut self, connector: &str, monitor_id: i64, events: &SystemControlEventSender) {
        self.control(connector, monitor_id, None, events);
    }

    fn set(
        &mut self,
        connector: &str,
        monitor_id: i64,
        level: f64,
        events: &SystemControlEventSender,
    ) {
        self.control(
            connector,
            monitor_id,
            Some(BrightnessChange::Set(level)),
            events,
        );
    }

    fn adjust(
        &mut self,
        connector: &str,
        monitor_id: i64,
        delta: f64,
        events: &SystemControlEventSender,
    ) {
        self.control(
            connector,
            monitor_id,
            Some(BrightnessChange::Adjust(delta)),
            events,
        );
    }

    fn control(
        &mut self,
        connector: &str,
        monitor_id: i64,
        change: Option<BrightnessChange>,
        events: &SystemControlEventSender,
    ) {
        let Some(provider) = self
            .providers
            .iter_mut()
            .find_map(|provider| provider.controls(connector).then_some(provider))
        else {
            self.log_failure_once(connector, "no registered provider controls this output");
            return;
        };
        let provider_name = provider.name();
        let actual = match provider.read(connector) {
            Ok(level) => level.clamp(0.0, 1.0),
            Err(error) => {
                self.log_failure_once(
                    connector,
                    &format!("{provider_name} could not read brightness: {error}"),
                );
                return;
            }
        };
        let Some(change) = change else {
            self.desired.insert(connector.to_owned(), actual);
            self.failure_latched.insert(connector.to_owned(), false);
            let _ = events.try_send(SystemControlEvent::BrightnessLevel {
                monitor_id,
                level: actual,
            });
            return;
        };
        let target = match change {
            BrightnessChange::Set(level) => level.clamp(0.0, 1.0),
            BrightnessChange::Adjust(delta) => {
                (self.desired.get(connector).copied().unwrap_or(actual) + delta).clamp(0.0, 1.0)
            }
        };
        let _ = events.try_send(SystemControlEvent::BrightnessLevel {
            monitor_id,
            level: target,
        });
        if let Err(error) = provider.set(connector, target) {
            self.log_failure_once(
                connector,
                &format!("{provider_name} could not write brightness: {error}"),
            );
            let _ = events.try_send(SystemControlEvent::BrightnessLevel {
                monitor_id,
                level: actual,
            });
            self.desired.insert(connector.to_owned(), actual);
            return;
        }
        self.desired.insert(connector.to_owned(), target);
        self.failure_latched.insert(connector.to_owned(), false);
    }

    fn log_failure_once(&mut self, connector: &str, message: &str) {
        if !self
            .failure_latched
            .insert(connector.to_owned(), true)
            .unwrap_or(false)
        {
            warn!(connector, %message, "native brightness adjustment failed");
        }
    }
}

#[derive(Clone, Debug)]
struct BacklightDevice {
    name: String,
    path: PathBuf,
    device_path: PathBuf,
    kind: String,
    maximum: u32,
}

struct BacklightWorker {
    connection: zbus::blocking::Connection,
    displays: HashMap<String, BacklightDevice>,
}

impl BacklightWorker {
    fn start() -> Result<Self, String> {
        let connection = zbus::blocking::Connection::system()
            .map_err(|error| format!("could not connect to logind: {error}"))?;
        let mut worker = Self {
            connection,
            displays: HashMap::new(),
        };
        worker.refresh_displays();
        info!(
            outputs = worker.displays.len(),
            "Denial brightness registered the kernel backlight provider"
        );
        Ok(worker)
    }

    fn refresh_displays(&mut self) {
        self.displays = discover_backlights(
            Path::new("/sys/class/backlight"),
            Path::new("/sys/class/drm"),
        );
    }

    fn display(&mut self, connector: &str) -> Option<&BacklightDevice> {
        if !self.displays.contains_key(connector) {
            self.refresh_displays();
        }
        self.displays.get(connector)
    }
}

impl BrightnessProvider for BacklightWorker {
    fn name(&self) -> &'static str {
        "kernel backlight"
    }

    fn controls(&mut self, connector: &str) -> bool {
        self.display(connector).is_some()
    }

    fn read(&mut self, connector: &str) -> Result<f64, String> {
        let display = self
            .display(connector)
            .ok_or_else(|| "output is not associated with a backlight device".to_owned())?;
        let current = read_u32(&display.path.join("actual_brightness"))
            .or_else(|_| read_u32(&display.path.join("brightness")))?;
        Ok(f64::from(current.min(display.maximum)) / f64::from(display.maximum))
    }

    fn set(&mut self, connector: &str, level: f64) -> Result<(), String> {
        let (name, maximum) = {
            let display = self
                .display(connector)
                .ok_or_else(|| "output is not associated with a backlight device".to_owned())?;
            (display.name.clone(), display.maximum)
        };
        let value = (level.clamp(0.0, 1.0) * f64::from(maximum)).round() as u32;
        let proxy = zbus::blocking::Proxy::new(
            &self.connection,
            "org.freedesktop.login1",
            "/org/freedesktop/login1/session/auto",
            "org.freedesktop.login1.Session",
        )
        .map_err(|error| format!("could not open the logind session: {error}"))?;
        let _: () = proxy
            .call("SetBrightness", &("backlight", name.as_str(), value))
            .map_err(|error| format!("logind SetBrightness failed: {error}"))?;
        Ok(())
    }
}

fn read_u32(path: &Path) -> Result<u32, String> {
    fs::read_to_string(path)
        .map_err(|error| format!("could not read {}: {error}", path.display()))?
        .trim()
        .parse()
        .map_err(|error| format!("invalid value in {}: {error}", path.display()))
}

fn internal_connector(name: &str) -> bool {
    ["eDP-", "LVDS-", "DSI-"]
        .iter()
        .any(|prefix| name.starts_with(prefix))
}

fn connected_internal_connector(name: &str, status: &str) -> bool {
    internal_connector(name) && status.trim() == "connected"
}

fn backlight_kind_priority(kind: &str) -> u8 {
    match kind {
        "raw" => 3,
        "platform" => 2,
        "firmware" => 1,
        _ => 0,
    }
}

fn paths_related(left: &Path, right: &Path) -> bool {
    left == right || left.starts_with(right) || right.starts_with(left)
}

fn discover_backlights(backlight_root: &Path, drm_root: &Path) -> HashMap<String, BacklightDevice> {
    let mut backlights = fs::read_dir(backlight_root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let maximum = read_u32(&path.join("max_brightness"))
                .ok()
                .filter(|value| *value > 0)?;
            let device_path = fs::canonicalize(path.join("device")).ok()?;
            let kind = fs::read_to_string(path.join("type"))
                .unwrap_or_default()
                .trim()
                .to_owned();
            Some(BacklightDevice {
                name: entry.file_name().to_string_lossy().into_owned(),
                path,
                device_path,
                kind,
                maximum,
            })
        })
        .collect::<Vec<_>>();
    backlights.sort_by(|left, right| left.name.cmp(&right.name));

    let connectors = fs::read_dir(drm_root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if !path.join("connector_id").is_file() {
                return None;
            }
            let name = connector_from_ddc_name(&entry.file_name().to_string_lossy());
            let status = fs::read_to_string(path.join("status")).unwrap_or_default();
            if !connected_internal_connector(&name, &status) {
                return None;
            }
            let device_path = fs::canonicalize(path.join("device")).ok()?;
            Some((name, device_path))
        })
        .collect::<Vec<_>>();

    let mut displays = HashMap::new();
    for (connector, connector_device) in &connectors {
        let mut related = backlights
            .iter()
            .filter(|backlight| paths_related(&backlight.device_path, connector_device))
            .collect::<Vec<_>>();
        if related.is_empty() && connectors.len() == 1 && backlights.len() == 1 {
            related.push(&backlights[0]);
        }
        related
            .sort_by_key(|backlight| std::cmp::Reverse(backlight_kind_priority(&backlight.kind)));
        let Some(selected) = related.first() else {
            continue;
        };
        if related.get(1).is_some_and(|other| {
            backlight_kind_priority(&other.kind) == backlight_kind_priority(&selected.kind)
        }) {
            warn!(
                connector,
                "multiple equally suitable kernel backlights; leaving output unclaimed"
            );
            continue;
        }
        displays.insert(connector.clone(), (*selected).clone());
    }
    displays
}

type DdcDisplayRef = *mut c_void;
type DdcDisplayHandle = *mut c_void;

#[repr(C)]
struct DdcIoPath {
    io_mode: c_int,
    path: c_int,
}

#[repr(C)]
struct DdcDisplayInfo {
    marker: [c_char; 4],
    dispno: c_int,
    path: DdcIoPath,
    usb_bus: c_int,
    usb_device: c_int,
    mfg_id: [c_char; 4],
    model_name: [c_char; 14],
    serial: [c_char; 14],
    product_code: u16,
    edid_bytes: [u8; 128],
    vcp_version: [u8; 2],
    dref: DdcDisplayRef,
}

#[repr(C)]
struct DdcDisplayInfo2 {
    legacy: DdcDisplayInfo,
    drm_card_connector: [c_char; 32],
    drm_card_connector_found_by: c_int,
    drm_connector_id: i16,
    unused: [*mut c_void; 8],
}

#[repr(C)]
#[derive(Default)]
struct DdcNonTableValue {
    maximum_high: u8,
    maximum_low: u8,
    current_high: u8,
    current_low: u8,
}

#[derive(Clone, Copy)]
enum DdcDisplayInfoApi {
    ConnectorAware {
        get: unsafe extern "C" fn(DdcDisplayRef, *mut *mut DdcDisplayInfo2) -> c_int,
        free: unsafe extern "C" fn(*mut DdcDisplayInfo2),
    },
    Stable {
        get: unsafe extern "C" fn(DdcDisplayRef, *mut *mut DdcDisplayInfo) -> c_int,
        free: unsafe extern "C" fn(*mut DdcDisplayInfo),
    },
}

struct DdcApi {
    _library: Library,
    init: unsafe extern "C" fn(*const c_char, c_int, c_int, *mut *mut *mut c_char) -> c_int,
    redetect_displays: unsafe extern "C" fn() -> c_int,
    get_display_refs: unsafe extern "C" fn(bool, *mut *mut DdcDisplayRef) -> c_int,
    display_info: DdcDisplayInfoApi,
    open_display: unsafe extern "C" fn(DdcDisplayRef, bool, *mut DdcDisplayHandle) -> c_int,
    close_display: unsafe extern "C" fn(DdcDisplayHandle) -> c_int,
    get_value: unsafe extern "C" fn(DdcDisplayHandle, u8, *mut DdcNonTableValue) -> c_int,
    set_value: unsafe extern "C" fn(DdcDisplayHandle, u8, u8, u8) -> c_int,
    status_description: unsafe extern "C" fn(c_int) -> *const c_char,
}

impl DdcApi {
    fn load() -> Result<Self, String> {
        // SAFETY: fixed SONAMEs are tried in ABI order and copied symbols stay
        // live because this value owns the loaded library.
        unsafe {
            let library = Library::new("libddcutil.so.5")
                .or_else(|_| Library::new("libddcutil.so"))
                .map_err(|error| format!("could not load libddcutil: {error}"))?;
            macro_rules! symbol {
                ($name:literal) => {
                    *library
                        .get(concat!($name, "\0").as_bytes())
                        .map_err(|error| format!("missing libddcutil symbol {}: {error}", $name))?
                };
            }
            let display_info = match (
                library
                    .get::<unsafe extern "C" fn(DdcDisplayRef, *mut *mut DdcDisplayInfo2) -> c_int>(
                        b"ddca_get_display_info2\0",
                    ),
                library.get::<unsafe extern "C" fn(*mut DdcDisplayInfo2)>(
                    b"ddca_free_display_info2\0",
                ),
            ) {
                (Ok(get), Ok(free)) => DdcDisplayInfoApi::ConnectorAware {
                    get: *get,
                    free: *free,
                },
                _ => {
                    let get: unsafe extern "C" fn(
                        DdcDisplayRef,
                        *mut *mut DdcDisplayInfo,
                    ) -> c_int = symbol!("ddca_get_display_info");
                    let free: unsafe extern "C" fn(*mut DdcDisplayInfo) =
                        symbol!("ddca_free_display_info");
                    info!(
                        "libddcutil exposes its stable display metadata API; correlating displays through DRM sysfs"
                    );
                    DdcDisplayInfoApi::Stable { get, free }
                }
            };
            let set_value: unsafe extern "C" fn(DdcDisplayHandle, u8, u8, u8) -> c_int =
                match library.get(b"ddca_set_non_table_vcp_value2\0") {
                    Ok(symbol) => *symbol,
                    Err(preferred_error) => {
                        let symbol = library.get(b"ddca_set_non_table_vcp_value\0").map_err(
                            |legacy_error| {
                                format!(
                                    concat!(
                                        "missing libddcutil VCP setter: ",
                                        "ddca_set_non_table_vcp_value2: {}; ",
                                        "ddca_set_non_table_vcp_value: {}"
                                    ),
                                    preferred_error, legacy_error
                                )
                            },
                        )?;
                        info!(
                            "libddcutil does not expose the verification-free VCP setter; using its ABI-compatible legacy setter"
                        );
                        *symbol
                    }
                };
            Ok(Self {
                init: symbol!("ddca_init2"),
                redetect_displays: symbol!("ddca_redetect_displays"),
                get_display_refs: symbol!("ddca_get_display_refs"),
                display_info,
                open_display: symbol!("ddca_open_display2"),
                close_display: symbol!("ddca_close_display"),
                get_value: symbol!("ddca_get_non_table_vcp_value"),
                set_value,
                status_description: symbol!("ddca_rc_desc"),
                _library: library,
            })
        }
    }

    fn describe_status(&self, status: c_int) -> String {
        // SAFETY: libddcutil returns a process-lifetime NUL-terminated string.
        let description = unsafe { (self.status_description)(status) };
        if description.is_null() {
            format!("status {status}")
        } else {
            // SAFETY: checked for null and owned by the loaded library.
            unsafe { CStr::from_ptr(description) }
                .to_string_lossy()
                .into_owned()
        }
    }

    fn display_connector(
        &self,
        reference: DdcDisplayRef,
        drm_connectors: &[DrmConnectorIdentity],
    ) -> Option<String> {
        // SAFETY: the selected function/free pair belongs to the same loaded
        // ABI, and the display reference came from that library.
        unsafe {
            match self.display_info {
                DdcDisplayInfoApi::ConnectorAware { get, free } => {
                    let mut info = ptr::null_mut();
                    let status = get(reference, &mut info);
                    let connector = (status == 0 && !info.is_null()).then(|| {
                        let metadata = &*info;
                        let published = fixed_c_string(&metadata.drm_card_connector);
                        if published.is_empty() {
                            connector_for_stable_display(&metadata.legacy, drm_connectors)
                        } else {
                            Some(connector_from_ddc_name(&published))
                        }
                    });
                    if !info.is_null() {
                        free(info);
                    }
                    connector.flatten().filter(|name| !name.is_empty())
                }
                DdcDisplayInfoApi::Stable { get, free } => {
                    let mut info = ptr::null_mut();
                    let status = get(reference, &mut info);
                    let connector = (status == 0 && !info.is_null())
                        .then(|| connector_for_stable_display(&*info, drm_connectors));
                    if !info.is_null() {
                        free(info);
                    }
                    connector.flatten().filter(|name| !name.is_empty())
                }
            }
        }
    }
}

#[derive(Debug)]
struct DrmConnectorIdentity {
    name: String,
    i2c_bus: Option<c_int>,
    edid: Option<[u8; 128]>,
}

fn fixed_c_string(chars: &[c_char]) -> String {
    let bytes = chars
        .iter()
        .map(|character| *character as u8)
        .take_while(|character| *character != 0)
        .collect::<Vec<_>>();
    String::from_utf8_lossy(&bytes).into_owned()
}

fn drm_connector_identities(root: &Path) -> Vec<DrmConnectorIdentity> {
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if !path.join("connector_id").is_file() {
                return None;
            }
            let name = connector_from_ddc_name(&entry.file_name().to_string_lossy());
            if name.is_empty() {
                return None;
            }
            let i2c_bus = fs::canonicalize(path.join("ddc"))
                .ok()
                .and_then(|path| {
                    path.file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                })
                .and_then(|name| name.strip_prefix("i2c-").and_then(|bus| bus.parse().ok()));
            let edid = fs::read(path.join("edid"))
                .ok()
                .and_then(|bytes| bytes.get(..128).and_then(|prefix| prefix.try_into().ok()));
            Some(DrmConnectorIdentity {
                name,
                i2c_bus,
                edid,
            })
        })
        .collect()
}

fn connector_for_stable_display(
    info: &DdcDisplayInfo,
    drm_connectors: &[DrmConnectorIdentity],
) -> Option<String> {
    // I2C bus ownership is authoritative and distinguishes identical monitor
    // models. USB displays lack that relationship, so use their complete base
    // EDID only when it identifies exactly one DRM connector.
    if info.path.io_mode == 0
        && let Some(connector) = drm_connectors
            .iter()
            .find(|connector| connector.i2c_bus == Some(info.path.path))
    {
        return Some(connector.name.clone());
    }
    if info.edid_bytes.iter().all(|byte| *byte == 0) {
        return None;
    }
    let mut matches = drm_connectors
        .iter()
        .filter(|connector| connector.edid.as_ref() == Some(&info.edid_bytes));
    let connector = matches.next()?;
    matches.next().is_none().then(|| connector.name.clone())
}

struct DdcWorker {
    api: DdcApi,
    displays: HashMap<String, DdcDisplayRef>,
}

impl DdcWorker {
    fn start() -> Result<Self, String> {
        let api = DdcApi::load()?;
        // DDCA_SYSLOG_NEVER=0 and DISABLE_CONFIG_FILE=1 keep this embedded
        // controller independent from global logging/configuration policy.
        // SAFETY: null optional arguments and flags follow ddca_init2's API.
        let status = unsafe { (api.init)(ptr::null(), 0, 1, ptr::null_mut()) };
        if status != 0 {
            return Err(format!(
                "DDC initialization failed: {}",
                api.describe_status(status)
            ));
        }
        let mut worker = Self {
            api,
            displays: HashMap::new(),
        };
        let outputs = worker
            .refresh_displays(false)
            .map_or(0, |()| worker.displays.len());
        info!(
            outputs,
            "Denial brightness registered the native DDC/CI provider"
        );
        Ok(worker)
    }

    fn refresh_displays(&mut self, redetect: bool) -> Result<(), String> {
        if redetect {
            // SAFETY: called only on the dedicated DDC worker.
            let status = unsafe { (self.api.redetect_displays)() };
            if status != 0 {
                return Err(format!(
                    "DDC display redetection failed: {}",
                    self.api.describe_status(status)
                ));
            }
        }
        let mut references: *mut DdcDisplayRef = ptr::null_mut();
        // SAFETY: libddcutil returns its null-terminated reference array.
        let status = unsafe { (self.api.get_display_refs)(false, &mut references) };
        if status != 0 || references.is_null() {
            return Err(format!(
                "DDC display enumeration failed: {}",
                self.api.describe_status(status)
            ));
        }
        let mut displays = HashMap::new();
        let drm_connectors = drm_connector_identities(Path::new("/sys/class/drm"));
        let mut index = 0usize;
        loop {
            // SAFETY: get_display_refs promises a null-terminated array.
            let reference = unsafe { *references.add(index) };
            if reference.is_null() {
                break;
            }
            if let Some(connector) = self.api.display_connector(reference, &drm_connectors) {
                displays.insert(connector, reference);
            }
            index += 1;
        }
        self.displays = displays;
        if self.displays.is_empty() {
            Err("DDC found no controllable displays".into())
        } else {
            Ok(())
        }
    }

    fn display(&mut self, connector: &str) -> Option<DdcDisplayRef> {
        if let Some(reference) = self.displays.get(connector) {
            return Some(*reference);
        }
        self.refresh_displays(true).ok()?;
        self.displays.get(connector).copied()
    }

    fn read_level(&mut self, connector: &str) -> Result<f64, String> {
        let Some(reference) = self.display(connector) else {
            return Err("has no matching DDC display".into());
        };
        let mut handle = ptr::null_mut();
        // SAFETY: reference is owned by libddcutil and all use is serialized.
        let open_status = unsafe { (self.api.open_display)(reference, false, &mut handle) };
        if open_status != 0 || handle.is_null() {
            let detail = self.api.describe_status(open_status);
            return Err(format!("could not open DDC display: {detail}"));
        }

        let mut value = DdcNonTableValue::default();
        // SAFETY: handle is open and value is a complete response buffer.
        let read_status = unsafe { (self.api.get_value)(handle, 0x10, &mut value) };
        let maximum = u16::from_be_bytes([value.maximum_high, value.maximum_low]);
        let current = u16::from_be_bytes([value.current_high, value.current_low]);
        if read_status != 0 || maximum == 0 {
            // SAFETY: balances the successful open above.
            unsafe { (self.api.close_display)(handle) };
            let detail = self.api.describe_status(read_status);
            return Err(format!("could not read VCP 0x10: {detail}"));
        }
        // SAFETY: balances the successful open above.
        unsafe { (self.api.close_display)(handle) };
        Ok(f64::from(current) / f64::from(maximum))
    }

    fn set_level(&mut self, connector: &str, level: f64) -> Result<(), String> {
        let Some(reference) = self.display(connector) else {
            return Err("has no matching DDC display".into());
        };
        let mut handle = ptr::null_mut();
        // SAFETY: reference is owned by libddcutil and all use is serialized.
        let open_status = unsafe { (self.api.open_display)(reference, false, &mut handle) };
        if open_status != 0 || handle.is_null() {
            let detail = self.api.describe_status(open_status);
            return Err(format!("could not open DDC display: {detail}"));
        }
        let mut value = DdcNonTableValue::default();
        // SAFETY: handle is open and value is a complete response buffer.
        let read_status = unsafe { (self.api.get_value)(handle, 0x10, &mut value) };
        let maximum = u16::from_be_bytes([value.maximum_high, value.maximum_low]);
        if read_status != 0 || maximum == 0 {
            // SAFETY: balances the successful open above.
            unsafe { (self.api.close_display)(handle) };
            let detail = self.api.describe_status(read_status);
            return Err(format!("could not read VCP 0x10: {detail}"));
        }
        let target_value = (level.clamp(0.0, 1.0) * f64::from(maximum)).round() as u16;
        let [high, low] = target_value.to_be_bytes();
        // SAFETY: handle is open and the VCP payload is two scalar bytes.
        let write_status = unsafe { (self.api.set_value)(handle, 0x10, high, low) };
        // SAFETY: balances the successful open above.
        unsafe { (self.api.close_display)(handle) };
        if write_status != 0 {
            let detail = self.api.describe_status(write_status);
            return Err(format!("could not write VCP 0x10: {detail}"));
        }
        Ok(())
    }
}

impl BrightnessProvider for DdcWorker {
    fn name(&self) -> &'static str {
        "DDC/CI"
    }

    fn controls(&mut self, connector: &str) -> bool {
        self.display(connector).is_some()
    }

    fn read(&mut self, connector: &str) -> Result<f64, String> {
        self.read_level(connector)
    }

    fn set(&mut self, connector: &str, level: f64) -> Result<(), String> {
        self.set_level(connector, level)
    }
}

#[derive(Clone, Copy)]
enum BrightnessChange {
    Set(f64),
    Adjust(f64),
}

fn connector_from_ddc_name(name: &str) -> String {
    let name = name.trim_matches(char::from(0));
    if let Some(rest) = name.strip_prefix("card")
        && let Some((_, connector)) = rest.split_once('-')
    {
        return connector.to_owned();
    }
    name.to_owned()
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum PendingBrightnessCommand {
    Read,
    Set(f64),
    Adjust(f64),
}

fn brightness_command_parts(
    command: BrightnessCommand,
) -> Option<(String, i64, PendingBrightnessCommand)> {
    match command {
        BrightnessCommand::Read {
            connector,
            monitor_id,
        } => Some((connector, monitor_id, PendingBrightnessCommand::Read)),
        BrightnessCommand::Set {
            connector,
            monitor_id,
            level,
        } => Some((connector, monitor_id, PendingBrightnessCommand::Set(level))),
        BrightnessCommand::Adjust {
            connector,
            monitor_id,
            delta,
        } => Some((
            connector,
            monitor_id,
            PendingBrightnessCommand::Adjust(delta),
        )),
        BrightnessCommand::Stop => None,
    }
}

fn merge_brightness_command(
    pending: &mut HashMap<String, (i64, PendingBrightnessCommand)>,
    connector: String,
    monitor_id: i64,
    incoming: PendingBrightnessCommand,
) {
    let Some((saved_monitor_id, saved)) = pending.get_mut(&connector) else {
        pending.insert(connector, (monitor_id, incoming));
        return;
    };
    *saved_monitor_id = monitor_id;
    *saved = match (*saved, incoming) {
        (saved, PendingBrightnessCommand::Read) => saved,
        (_, PendingBrightnessCommand::Set(level)) => PendingBrightnessCommand::Set(level),
        (PendingBrightnessCommand::Set(level), PendingBrightnessCommand::Adjust(delta)) => {
            PendingBrightnessCommand::Set((level + delta).clamp(0.0, 1.0))
        }
        (PendingBrightnessCommand::Adjust(delta), PendingBrightnessCommand::Adjust(next)) => {
            PendingBrightnessCommand::Adjust((delta + next).clamp(-1.0, 1.0))
        }
        (PendingBrightnessCommand::Read, PendingBrightnessCommand::Adjust(delta)) => {
            PendingBrightnessCommand::Adjust(delta)
        }
    };
}

fn receive_brightness_batch(
    first: BrightnessCommand,
    commands: &Receiver<BrightnessCommand>,
) -> Option<HashMap<String, (i64, PendingBrightnessCommand)>> {
    let (connector, monitor_id, command) = brightness_command_parts(first)?;
    let mut pending = HashMap::new();
    merge_brightness_command(&mut pending, connector, monitor_id, command);
    let deadline = Instant::now() + DDC_COALESCE_WINDOW;
    loop {
        let timeout = deadline.saturating_duration_since(Instant::now());
        match commands.recv_timeout(timeout) {
            Ok(command) => {
                let (connector, monitor_id, command) = brightness_command_parts(command)?;
                merge_brightness_command(&mut pending, connector, monitor_id, command);
            }
            Err(RecvTimeoutError::Disconnected) => return None,
            Err(RecvTimeoutError::Timeout) => return Some(pending),
        }
    }
}

pub(super) fn run_brightness_worker(
    commands: Receiver<BrightnessCommand>,
    events: SystemControlEventSender,
) {
    let mut worker = match BrightnessProviders::start() {
        Ok(worker) => worker,
        Err(error) => {
            warn!(%error, "native brightness controls are unavailable");
            while !matches!(commands.recv(), Ok(BrightnessCommand::Stop) | Err(_)) {}
            return;
        }
    };
    while let Ok(first) = commands.recv() {
        let Some(batch) = receive_brightness_batch(first, &commands) else {
            break;
        };
        for (connector, (monitor_id, command)) in batch {
            match command {
                PendingBrightnessCommand::Read => worker.read(&connector, monitor_id, &events),
                PendingBrightnessCommand::Set(level) => {
                    worker.set(&connector, monitor_id, level, &events);
                }
                PendingBrightnessCommand::Adjust(delta) => {
                    worker.adjust(&connector, monitor_id, delta, &events);
                }
            }
        }
    }
}
