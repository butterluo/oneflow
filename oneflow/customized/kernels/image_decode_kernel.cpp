#include "oneflow/core/framework/framework.h"
#include "oneflow/core/thread/thread_manager.h"
#include "oneflow/customized/image/image_util.h"
#include <opencv2/opencv.hpp>

namespace oneflow {

namespace {

void DecodeImage(const TensorBuffer& raw_bytes, TensorBuffer* image_buffer,
                 const std::string& color_space, DataType data_type) {
  // should only support kChar, but numpy ndarray maybe cannot convert to char*
  CHECK(raw_bytes.data_type() == DataType::kChar || raw_bytes.data_type() == DataType::kInt8
        || raw_bytes.data_type() == DataType::kUInt8);
  cv::_InputArray raw_bytes_arr(raw_bytes.data<char>(), raw_bytes.elem_cnt());
  cv::Mat image_mat = cv::imdecode(
      raw_bytes_arr, (ImageUtil::IsColor(color_space) ? cv::IMREAD_COLOR : cv::IMREAD_GRAYSCALE)
                         | cv::IMREAD_ANYDEPTH);
  if (ImageUtil::IsColor(color_space) && color_space != "BGR") {
    ImageUtil::ConvertColor("BGR", image_mat, color_space, image_mat);
  }
  if (data_type == DataType::kUInt8) {
    image_mat.convertTo(image_mat, CV_8U);
  } else if (data_type == DataType::kFloat) {
    image_mat.convertTo(image_mat, CV_32F);
  } else {
    UNIMPLEMENTED();
  }

  int64_t h = image_mat.rows;
  int64_t w = image_mat.cols;
  int64_t c = image_mat.channels();
  image_buffer->Resize(Shape({h, w, c}), data_type);

  w *= c;
  if (image_mat.isContinuous()) {
    w *= h;
    h = 1;
  }
  char* image_ptr = image_buffer->mut_data<char>();
  FOR_RANGE(int64_t, i, 0, h) {
    memcpy(image_ptr + i * w, image_mat.ptr(i), w * GetSizeOfDataType(data_type));
  }
}

}  // namespace

class ImageDecodeKernel final : public user_op::OpKernel {
 public:
  ImageDecodeKernel() = default;
  ~ImageDecodeKernel() = default;

 private:
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* in_tensor = ctx->Tensor4ArgNameAndIndex("in", 0);
    user_op::Tensor* out_tensor = ctx->Tensor4ArgNameAndIndex("out", 0);
    CHECK_EQ(in_tensor->shape().elem_cnt(), out_tensor->shape().elem_cnt());
    CHECK_GT(in_tensor->shape().elem_cnt(), 0);

    const TensorBuffer* in_img_buf = in_tensor->dptr<TensorBuffer>();
    TensorBuffer* out_img_buf = out_tensor->mut_dptr<TensorBuffer>();
    const std::string& color_space = ctx->Attr<std::string>("color_space");
    const DataType data_type = ctx->Attr<DataType>("data_type");

    MultiThreadLoop(in_tensor->shape().elem_cnt(), [&](size_t i) {
      DecodeImage(in_img_buf[i], out_img_buf + i, color_space, data_type);
    });
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

REGISTER_USER_KERNEL("image_decode")
    .SetCreateFn<ImageDecodeKernel>()
    .SetIsMatchedPred([](const user_op::KernelRegContext& ctx) {
      const auto* in_desc = ctx.TensorDesc4ArgNameAndIndex("in", 0);
      const auto* out_desc = ctx.TensorDesc4ArgNameAndIndex("out", 0);
      return ctx.device_type() == DeviceType::kCPU
             && in_desc->data_type() == DataType::kTensorBuffer
             && out_desc->data_type() == DataType::kTensorBuffer;
    });

}  // namespace oneflow
