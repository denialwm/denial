//! Live device-local memory of the composer's Vulkan device by what made it,
//! from the driver's own reports (VK_EXT_device_memory_report). The engine
//! renders on the same device, so this sees Impeller's memory too: memory
//! objects anyone allocated (`vkAllocateMemory`), memory imported from other
//! processes and the driver's own memory per object type. For the composer's
//! log marks.

use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::Mutex;

use ash::vk;

pub(super) struct MemoryLedger {
    /// Heaps that are device-local, by index.
    device_local: Vec<bool>,
    live: Mutex<HashMap<u64, Entry>>,
}

struct Entry {
    size: u64,
    object_type: vk::ObjectType,
    imported: bool,
    heap: u32,
}

impl MemoryLedger {
    pub(super) fn new(memory: &vk::PhysicalDeviceMemoryProperties) -> Self {
        let device_local = memory.memory_heaps[..memory.memory_heap_count as usize]
            .iter()
            .map(|heap| heap.flags.contains(vk::MemoryHeapFlags::DEVICE_LOCAL))
            .collect();
        Self {
            device_local,
            live: Mutex::new(HashMap::new()),
        }
    }

    fn record(&self, data: &vk::DeviceMemoryReportCallbackDataEXT<'_>) {
        let mut live = self
            .live
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match data.ty {
            vk::DeviceMemoryReportEventTypeEXT::ALLOCATE
            | vk::DeviceMemoryReportEventTypeEXT::IMPORT => {
                live.insert(
                    data.memory_object_id,
                    Entry {
                        size: data.size,
                        object_type: data.object_type,
                        imported: data.ty == vk::DeviceMemoryReportEventTypeEXT::IMPORT,
                        heap: data.heap_index,
                    },
                );
            }
            vk::DeviceMemoryReportEventTypeEXT::FREE
            | vk::DeviceMemoryReportEventTypeEXT::UNIMPORT => {
                live.remove(&data.memory_object_id);
            }
            _ => {}
        }
    }

    /// Live device-local bytes per source: `allocated` (memory objects),
    /// `imported`, and the driver's own per object type; largest first.
    pub(super) fn device_local(&self) -> Vec<(String, u64)> {
        let live = self
            .live
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut sources: Vec<(String, u64)> = Vec::new();
        for entry in live.values() {
            if !self
                .device_local
                .get(entry.heap as usize)
                .copied()
                .unwrap_or(false)
            {
                continue;
            }
            let source = source(entry.object_type, entry.imported);
            match sources.iter_mut().find(|(known, _)| *known == source) {
                Some((_, bytes)) => *bytes += entry.size,
                None => sources.push((source, entry.size)),
            }
        }
        sources.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        sources
    }
}

fn source(object_type: vk::ObjectType, imported: bool) -> String {
    if imported {
        "imported".to_owned()
    } else if object_type == vk::ObjectType::DEVICE_MEMORY {
        "allocated".to_owned()
    } else {
        format!("driver {object_type:?}").to_lowercase()
    }
}

/// The driver's report callback; `user_data` is the device's ledger.
pub(super) unsafe extern "system" fn report(
    data: *const vk::DeviceMemoryReportCallbackDataEXT<'_>,
    user_data: *mut c_void,
) {
    // SAFETY: the driver passes a valid report and the pointer the device
    // was created with, a ledger that outlives the device.
    if let (Some(data), Some(ledger)) =
        unsafe { (data.as_ref(), user_data.cast::<MemoryLedger>().as_ref()) }
    {
        ledger.record(data);
    }
}

#[cfg(test)]
impl MemoryLedger {
    pub(super) fn record_for_test(&self, data: &vk::DeviceMemoryReportCallbackDataEXT<'_>) {
        self.record(data);
    }
}
