#ifndef NPZ_LOADER_H_
#define NPZ_LOADER_H_

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace simulst {

// Minimal NPZ reader for ONNX init states (float32 / int64 arrays).
class NpzLoader {
 public:
  static bool Load(const std::string& path,
                   std::map<std::string, std::vector<float>>& float_arrays,
                   std::map<std::string, std::vector<int64_t>>& int_arrays,
                   std::string* error,
                   std::map<std::string, std::vector<int64_t>>* shapes = nullptr);
};

}  // namespace simulst

#endif  // NPZ_LOADER_H_
