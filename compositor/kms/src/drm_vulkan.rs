//! Create the compositor's Vulkan instance for its DRM node. A global
//! extension query can initialize every installed driver, even when the
//! eventual logical device is on a different card.

use std::{
    collections::BTreeSet,
    env,
    ffi::CStr,
    fs,
    path::{Path, PathBuf},
};

use ash::{Entry, vk};
use libloading::Library;

pub struct DrmInstance {
    pub instance: ash::Instance,
    pub entry: Entry,
    pub extensions: Vec<&'static CStr>,
    // The loader calls into this library until vkDestroyInstance returns.
    _driver: Option<Library>,
}

impl Drop for DrmInstance {
    fn drop(&mut self) {
        // SAFETY: the owner destroys its devices before releasing the instance.
        unsafe { self.instance.destroy_instance(None) };
    }
}

impl DrmInstance {
    pub fn new(
        entry: Entry,
        node: libc::dev_t,
        app: &vk::ApplicationInfo<'_>,
        extensions: &[&'static CStr],
        layers: &[&CStr],
    ) -> Result<Self, vk::Result> {
        let layer_names: Vec<_> = layers.iter().map(|name| name.as_ptr()).collect();
        let mut names: Vec<_> = extensions.iter().map(|name| name.as_ptr()).collect();
        let create = vk::InstanceCreateInfo::default()
            .application_info(app)
            .enabled_layer_names(&layer_names);
        if let Some(path) = driver_for_node(node) {
            // SAFETY: this is an installed Vulkan ICD. Its exported function
            // uses the ICD ABI and the library is retained alongside the instance.
            if let Ok(driver) = unsafe { Library::new(&path) }
                // SAFETY: the ICD interface defines this symbol and its signature.
                && let Ok(get_proc) = unsafe {
                    driver.get::<vk::PFN_vkGetInstanceProcAddr>(c"vk_icdGetInstanceProcAddr")
                }
            {
                let drivers = [vk::DirectDriverLoadingInfoLUNARG::default()
                    .pfn_get_instance_proc_addr(Some(*get_proc))];
                let mut only = vk::DirectDriverLoadingListLUNARG::default()
                    .mode(vk::DirectDriverLoadingModeLUNARG::EXCLUSIVE)
                    .drivers(&drivers);
                names.push(ash::lunarg::direct_driver_loading::NAME.as_ptr());
                let direct = create.enabled_extension_names(&names).push_next(&mut only);
                // SAFETY: all pointers in the create info live through the call.
                match unsafe { entry.create_instance(&direct, None) } {
                    Ok(instance) => {
                        tracing::debug!(?path, "using Vulkan driver for the selected DRM node");
                        let mut extensions = extensions.to_vec();
                        extensions.push(ash::lunarg::direct_driver_loading::NAME);
                        return Ok(Self {
                            instance,
                            entry,
                            extensions,
                            _driver: Some(driver),
                        });
                    }
                    Err(error) => {
                        tracing::debug!(?error, ?path, "using normal Vulkan driver discovery")
                    }
                }
                names.pop();
            }
        }
        // vkCreateInstance checks required extensions. A separate global
        // extension query would defeat exclusive driver loading.
        // SAFETY: all pointers in the create info live through the call.
        let instance =
            unsafe { entry.create_instance(&create.enabled_extension_names(&names), None) }?;
        Ok(Self {
            instance,
            entry,
            extensions: extensions.to_vec(),
            _driver: None,
        })
    }
}

/// Use exclusive loading only when the installed manifests unambiguously
/// identify the hardware driver. Alternate drivers, explicit loader policy
/// and unrecognized installations keep the system loader's normal selection.
fn driver_for_node(node: libc::dev_t) -> Option<PathBuf> {
    if [
        "VK_DRIVER_FILES",
        "VK_ICD_FILENAMES",
        "VK_ADD_DRIVER_FILES",
        "VK_LOADER_DRIVERS_SELECT",
        "VK_LOADER_DRIVERS_DISABLE",
        "VK_LOADER_DRIVERS_ENABLE",
        "VK_LOADER_DRIVER_ID_FILTER",
        "VK_LOADER_DEVICE_ID_FILTER",
    ]
    .iter()
    .any(|name| env::var_os(name).is_some())
    {
        return None;
    }
    // Let the loader apply all of its secure-execution path restrictions.
    // SAFETY: reading an auxiliary vector entry has no preconditions.
    if unsafe { libc::getauxval(libc::AT_SECURE) } != 0 {
        return None;
    }
    let kernel = fs::read_link(format!(
        "/sys/dev/char/{}:{}/device/driver",
        libc::major(node),
        libc::minor(node)
    ))
    .ok()?;
    let kernel = kernel.file_name()?.to_str()?;
    let mut roots = BTreeSet::from([PathBuf::from("/etc"), PathBuf::from("/usr/local/etc")]);
    let home = env::var_os("HOME").map(PathBuf::from);
    for (key, default) in [
        ("XDG_CONFIG_HOME", ".config"),
        ("XDG_DATA_HOME", ".local/share"),
    ] {
        if let Some(root) = env::var_os(key)
            .filter(|p| !p.is_empty())
            .map(PathBuf::from)
            .or_else(|| home.as_ref().map(|h| h.join(default)))
        {
            roots.insert(root);
        }
    }
    for (key, default) in [
        ("XDG_CONFIG_DIRS", "/etc/xdg"),
        ("XDG_DATA_DIRS", "/usr/local/share:/usr/share"),
    ] {
        let dirs = env::var_os(key)
            .filter(|p| !p.is_empty())
            .unwrap_or_else(|| default.into());
        roots.extend(env::split_paths(&dirs));
    }

    let mut matched = None;
    let mut other_gpu = false;
    for root in roots {
        let dir = root.join("vulkan");
        if dir
            .join("loader_settings.d/vk_loader_settings.json")
            .exists()
        {
            return None;
        }
        let entries = match fs::read_dir(dir.join("icd.d")) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return None,
        };
        for entry in entries {
            let path = entry.ok()?.path();
            if path.extension().is_none_or(|ext| ext != "json") {
                continue;
            }
            let manifest: serde_json::Value =
                serde_json::from_slice(&fs::read(&path).ok()?).ok()?;
            let icd = manifest.get("ICD")?;
            if let Some(bits) = icd.get("library_arch").and_then(|arch| arch.as_str())
                && bits != usize::BITS.to_string()
            {
                continue;
            }
            let lib = Path::new(icd.get("library_path")?.as_str()?);
            let matches = match lib.file_name()?.to_str()? {
                "libvulkan_radeon.so" => kernel == "amdgpu",
                "libGLX_nvidia.so.0" => kernel == "nvidia",
                "libvulkan_nouveau.so" => kernel == "nouveau",
                "libvulkan_intel.so" | "libvulkan_intel_hasvk.so" => {
                    matches!(kernel, "i915" | "xe")
                }
                "libvulkan_lvp.so" => continue,
                _ => return None,
            };
            if matches {
                // Bare sonames use the dynamic linker's search path. Other
                // relative paths in an ICD are relative to the manifest.
                let library = if lib.is_relative() && lib.components().count() > 1 {
                    path.parent()?.join(lib)
                } else {
                    lib.to_owned()
                };
                if matched.as_ref().is_some_and(|old| *old != library) {
                    return None;
                }
                matched = Some(library);
            } else {
                other_gpu = true;
            }
        }
    }
    matched.filter(|_| other_gpu)
}
