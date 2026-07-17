#include "npz_loader.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <zlib.h>

namespace simulst {
namespace {

struct ZipEntry {
  std::string name;
  std::vector<uint8_t> data;
};

static uint16_t ReadU16LE(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

static uint32_t ReadU32LE(const uint8_t* p) {
  return static_cast<uint32_t>(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
}

static bool ParseNpy(const std::vector<uint8_t>& raw,
                     std::vector<float>* out_float,
                     std::vector<int64_t>* out_int,
                     std::vector<int64_t>* out_shape,
                     std::string* error) {
  if (raw.size() < 10 || raw[0] != 0x93 ||
      std::memcmp(raw.data() + 1, "NUMPY", 5) != 0) {
    if (error) *error = "invalid npy magic";
    return false;
  }

  uint8_t major = raw[6];
  uint8_t minor = raw[7];
  size_t header_len = 0;
  size_t header_off = 0;
  if (major == 1) {
    header_len = ReadU16LE(raw.data() + 8);
    header_off = 10;
  } else if (major == 2) {
    header_len = ReadU32LE(raw.data() + 8);
    header_off = 12;
  } else {
    if (error) *error = "unsupported npy version";
    return false;
  }
  if (header_off + header_len > raw.size()) {
    if (error) *error = "truncated npy header";
    return false;
  }

  std::string header(reinterpret_cast<const char*>(raw.data() + header_off),
                     header_len);
  const size_t data_off = header_off + header_len;
  if (data_off > raw.size()) {
    if (error) *error = "missing npy payload";
    return false;
  }

  const bool is_fortran = header.find("'fortran_order': True") != std::string::npos;
  if (is_fortran) {
    if (error) *error = "fortran_order arrays are not supported";
    return false;
  }

  std::string descr;
  {
    const auto pos = header.find("'descr':");
    if (pos == std::string::npos) {
      if (error) *error = "missing descr in npy header";
      return false;
    }
    const auto q1 = header.find('\'', pos + 8);
    const auto q2 = header.find('\'', q1 + 1);
    if (q1 == std::string::npos || q2 == std::string::npos) {
      if (error) *error = "invalid descr in npy header";
      return false;
    }
    descr = header.substr(q1 + 1, q2 - q1 - 1);
  }

  std::vector<int64_t> shape;
  {
    const auto pos = header.find("'shape':");
    if (pos == std::string::npos) {
      if (error) *error = "missing shape in npy header";
      return false;
    }
    const auto lb = header.find('(', pos);
    const auto rb = header.find(')', lb);
    if (lb == std::string::npos || rb == std::string::npos) {
      if (error) *error = "invalid shape in npy header";
      return false;
    }
    std::string shape_str = header.substr(lb + 1, rb - lb - 1);
  std::stringstream ss(shape_str);
    while (ss.good()) {
      std::string token;
      std::getline(ss, token, ',');
      if (token.empty()) continue;
      shape.push_back(std::stoll(token));
    }
  }

  int64_t count = 1;
  for (int64_t d : shape) count *= d;
  if (count < 0) {
    if (error) *error = "invalid tensor shape";
    return false;
  }
  if (out_shape) *out_shape = shape;

  const uint8_t* payload = raw.data() + data_off;
  const size_t payload_size = raw.size() - data_off;

  if (descr == "<f4") {
    if (payload_size < static_cast<size_t>(count) * sizeof(float)) {
      if (error) *error = "truncated float32 payload";
      return false;
    }
    out_float->resize(static_cast<size_t>(count));
    std::memcpy(out_float->data(), payload, static_cast<size_t>(count) * sizeof(float));
    return true;
  }

  if (descr == "<i8") {
    if (payload_size < static_cast<size_t>(count) * sizeof(int64_t)) {
      if (error) *error = "truncated int64 payload";
      return false;
    }
    out_int->resize(static_cast<size_t>(count));
    std::memcpy(out_int->data(), payload, static_cast<size_t>(count) * sizeof(int64_t));
    return true;
  }

  if (error) *error = "unsupported dtype: " + descr;
  return false;
}

static bool InflateRaw(const uint8_t* src, size_t src_len, std::vector<uint8_t>* out,
                       std::string* error) {
  z_stream strm;
  std::memset(&strm, 0, sizeof(strm));
  if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) {
    if (error) *error = "inflateInit2 failed";
    return false;
  }

  strm.avail_in = static_cast<uInt>(src_len);
  strm.next_in = const_cast<Bytef*>(src);

  const size_t chunk = 1 << 16;
  int ret = Z_OK;
  while (ret == Z_OK) {
    size_t old = out->size();
    out->resize(old + chunk);
    strm.avail_out = chunk;
    strm.next_out = reinterpret_cast<Bytef*>(out->data() + old);
    ret = inflate(&strm, Z_NO_FLUSH);
    out->resize(old + chunk - strm.avail_out);
    if (ret == Z_STREAM_END) break;
    if (ret != Z_OK) {
      inflateEnd(&strm);
      if (error) *error = "inflate failed";
      return false;
    }
  }
  inflateEnd(&strm);
  return true;
}

static bool ParseZip(const std::vector<uint8_t>& zip, std::vector<ZipEntry>* entries,
                     std::string* error) {
  size_t off = 0;
  while (off + 30 <= zip.size()) {
    if (ReadU32LE(zip.data() + off) != 0x04034b50) break;

    const uint16_t method = ReadU16LE(zip.data() + off + 8);
    const uint32_t comp_size = ReadU32LE(zip.data() + off + 18);
    const uint32_t uncomp_size = ReadU32LE(zip.data() + off + 22);
    const uint16_t name_len = ReadU16LE(zip.data() + off + 26);
    const uint16_t extra_len = ReadU16LE(zip.data() + off + 28);
    const size_t header_size = 30 + name_len + extra_len;
    if (off + header_size + comp_size > zip.size()) {
      if (error) *error = "truncated zip local header";
      return false;
    }

    std::string name(reinterpret_cast<const char*>(zip.data() + off + 30), name_len);
    const uint8_t* comp_data = zip.data() + off + header_size;

    ZipEntry entry;
    entry.name = name;
    if (method == 0) {
      entry.data.assign(comp_data, comp_data + comp_size);
    } else if (method == 8) {
      if (!InflateRaw(comp_data, comp_size, &entry.data, error)) return false;
      if (uncomp_size != 0 && entry.data.size() != uncomp_size) {
        if (error) *error = "unexpected uncompressed size for " + name;
        return false;
      }
    } else {
      if (error) *error = "unsupported zip compression method";
      return false;
    }

    entries->push_back(std::move(entry));
    off += header_size + comp_size;
  }
  return true;
}

}  // namespace

bool NpzLoader::Load(const std::string& path,
                     std::map<std::string, std::vector<float>>& float_arrays,
                     std::map<std::string, std::vector<int64_t>>& int_arrays,
                     std::string* error,
                     std::map<std::string, std::vector<int64_t>>* shapes) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    if (error) *error = "failed to open npz: " + path;
    return false;
  }
  in.seekg(0, std::ios::end);
  const auto file_size = in.tellg();
  in.seekg(0, std::ios::beg);
  if (file_size <= 0) {
    if (error) *error = "empty npz file";
    return false;
  }

  std::vector<uint8_t> zip(static_cast<size_t>(file_size));
  in.read(reinterpret_cast<char*>(zip.data()), file_size);
  if (!in) {
    if (error) *error = "failed to read npz file";
    return false;
  }

  std::vector<ZipEntry> entries;
  if (!ParseZip(zip, &entries, error)) return false;

  for (const auto& entry : entries) {
    if (entry.name.size() < 5 ||
        entry.name.compare(entry.name.size() - 4, 4, ".npy") != 0) {
      continue;
    }
    std::string key = entry.name.substr(0, entry.name.size() - 4);
    std::vector<float> floats;
    std::vector<int64_t> ints;
    std::vector<int64_t> shape;
    if (!ParseNpy(entry.data, &floats, &ints, shapes ? &shape : nullptr, error)) {
      if (error) *error = key + ": " + *error;
      return false;
    }
    if (!floats.empty()) {
      float_arrays[key] = std::move(floats);
      if (shapes && !shape.empty()) (*shapes)[key] = std::move(shape);
    } else if (!ints.empty()) {
      int_arrays[key] = std::move(ints);
      if (shapes && !shape.empty()) (*shapes)[key] = std::move(shape);
    }
  }

  if (float_arrays.empty() && int_arrays.empty()) {
    if (error) *error = "no arrays found in npz";
    return false;
  }
  return true;
}

}  // namespace simulst
