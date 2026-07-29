#include <cuda_runtime.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

std::string env(const char* name, bool required = true) {
  const char* value = std::getenv(name);
  if (value != nullptr && value[0] != '\0') {
    return value;
  }
  if (required) {
    throw std::runtime_error(std::string("missing required environment variable: ") +
                             name);
  }
  return "";
}

std::string json_escape(const std::string& value) {
  std::ostringstream output;
  for (const unsigned char character : value) {
    switch (character) {
      case '"':
        output << "\\\"";
        break;
      case '\\':
        output << "\\\\";
        break;
      case '\b':
        output << "\\b";
        break;
      case '\f':
        output << "\\f";
        break;
      case '\n':
        output << "\\n";
        break;
      case '\r':
        output << "\\r";
        break;
      case '\t':
        output << "\\t";
        break;
      default:
        if (character < 0x20) {
          output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                 << static_cast<int>(character) << std::dec;
        } else {
          output << character;
        }
    }
  }
  return output.str();
}

void check(cudaError_t result, const char* operation) {
  if (result == cudaSuccess) {
    return;
  }
  throw std::runtime_error(std::string(operation) + ": " +
                           cudaGetErrorString(result));
}

std::string cuda_uuid(const cudaUUID_t& uuid) {
  const auto* bytes = reinterpret_cast<const unsigned char*>(uuid.bytes);
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (int index = 0; index < 16; ++index) {
    if (index == 4 || index == 6 || index == 8 || index == 10) {
      output << '-';
    }
    output << std::setw(2) << static_cast<unsigned int>(bytes[index]);
  }
  return output.str();
}

int64_t now_ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

void field(std::ostream& output, const char* name, const std::string& value,
           bool comma = true) {
  output << '"' << name << "\":\"" << json_escape(value) << '"';
  if (comma) {
    output << ',';
  }
}

}  // namespace

int main() {
  try {
    const std::string cluster_id = env("HOOKE_CLUSTER_ID");
    const std::string run_id = env("HOOKE_RUN_ID");
    const std::string pod_namespace = env("POD_NAMESPACE");
    const std::string pod_name = env("POD_NAME");
    const std::string pod_uid = env("POD_UID");
    const std::string node_name = env("NODE_NAME");
    const std::string container_name = env("HOOKE_CONTAINER_NAME");
    const std::string claim_name = env("HOOKE_RESOURCE_CLAIM_NAME");
    const std::string claim_uid = env("HOOKE_RESOURCE_CLAIM_UID");
    const std::string device_class = env("HOOKE_DEVICE_CLASS");

    int device_count = 0;
    check(cudaGetDeviceCount(&device_count), "cudaGetDeviceCount");
    if (device_count != 1) {
      throw std::runtime_error("expected exactly one CUDA-visible device, got " +
                               std::to_string(device_count));
    }
    check(cudaSetDevice(0), "cudaSetDevice");

    cudaDeviceProp properties{};
    check(cudaGetDeviceProperties(&properties, 0), "cudaGetDeviceProperties");
    int driver_version = 0;
    int runtime_version = 0;
    check(cudaDriverGetVersion(&driver_version), "cudaDriverGetVersion");
    check(cudaRuntimeGetVersion(&runtime_version), "cudaRuntimeGetVersion");
    char pci_bus_id[32]{};
    check(cudaDeviceGetPCIBusId(pci_bus_id, sizeof(pci_bus_id), 0),
          "cudaDeviceGetPCIBusId");

    constexpr std::size_t allocation_bytes = 4096;
    void* device_buffer = nullptr;
    check(cudaMalloc(&device_buffer, allocation_bytes), "cudaMalloc");
    check(cudaMemset(device_buffer, 0xA5, allocation_bytes), "cudaMemset");
    check(cudaDeviceSynchronize(), "cudaDeviceSynchronize");
    const int64_t success_time_ns = now_ns();
    check(cudaFree(device_buffer), "cudaFree");

    std::ostringstream output;
    output << '{';
    field(output, "hooke_event_type", "FIRST_CUDA_SUCCESS");
    output << "\"source_time_ns\":" << success_time_ns << ',';
    field(output, "hooke_cluster_id", cluster_id);
    field(output, "hooke_run_id", run_id);
    field(output, "pod_namespace", pod_namespace);
    field(output, "pod_name", pod_name);
    field(output, "pod_uid", pod_uid);
    field(output, "node_name", node_name);
    field(output, "container_name", container_name);
    field(output, "workload_kind", env("HOOKE_WORKLOAD_KIND", false));
    field(output, "workload_name", env("HOOKE_WORKLOAD_NAME", false));
    field(output, "workload_uid", env("HOOKE_WORKLOAD_UID", false));
    output << "\"hooke_attributes\":{";
    field(output, "precision", "cuda-device-synchronize-source-timestamp");
    field(output, "resource_claim_name", claim_name);
    field(output, "resource_claim_uid", claim_uid);
    field(output, "device_class", device_class);
    field(output, "cuda_device_name", properties.name);
    field(output, "cuda_device_uuid", cuda_uuid(properties.uuid));
    field(output, "cuda_pci_bus_id", pci_bus_id);
    field(output, "nvidia_visible_devices",
          env("NVIDIA_VISIBLE_DEVICES", false));
    output << "\"cuda_visible_device_count\":" << device_count << ',';
    output << "\"cuda_driver_version\":" << driver_version << ',';
    output << "\"cuda_runtime_version\":" << runtime_version << ',';
    output << "\"compute_capability_major\":" << properties.major << ',';
    output << "\"compute_capability_minor\":" << properties.minor << ',';
    output << "\"total_global_memory_bytes\":" << properties.totalGlobalMem
           << ',';
    output << "\"verified_allocation_bytes\":" << allocation_bytes;
    output << "}}";
    std::cout << output.str() << std::endl;
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "{\"probe_status\":\"failed\",\"error\":\""
              << json_escape(error.what()) << "\"}" << std::endl;
    return 1;
  }
}
