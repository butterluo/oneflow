#include "oneflow/core/kernel/kernel.h"

namespace oneflow {

template<DeviceType device_type, typename T>
struct ClipBoxesToImageUtil {
  static void ClipBoxes(DeviceCtx* ctx, const int32_t num_boxes, const T* boxes_ptr,
                        const int32_t* image_size_ptr, T* out_ptr);
};

}  // namespace oneflow