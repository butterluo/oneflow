/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "oneflow/user/kernels/op_kernel_state_wrapper.h"
#include "oneflow/core/common/data_type.h"
#include "oneflow/core/common/device_type.h"
#include "oneflow/core/cuda/elementwise.cuh"
#include "oneflow/core/cuda/atomic.cuh"
#include "oneflow/user/kernels/dropout_kernel.h"
#include "oneflow/core/kernel/cuda_graph_support.h"
#include "oneflow/core/ep/cuda/cuda_stream.h"
#include "oneflow/core/device/cuda_pseudo_bfloat16.h"

namespace oneflow {

namespace {

constexpr int32_t kVecSize = 4;
constexpr int32_t kBlockSize = 256;

template<typename T>
constexpr int32_t GetDropoutPackSize() {
  // For float, bfloat16, half.
  return 4;
};

template<>
constexpr int32_t GetDropoutPackSize<half2>() {
  return 2;
};

template<>
constexpr int32_t GetDropoutPackSize<double>() {
  return 2;
};

using H2PackType = typename std::aligned_storage<4 * sizeof(half), 4 * sizeof(half)>::type;
union H2Pack {
  cuda::elementwise::Pack<half, 4> pack_storage;
  half2 h2[2];
  __device__ H2Pack() {
    // do nothing
  }
};

union RandPack4 {
  float4 storage;
  float elem[4];
};

#define RETURN_VOID_IF_HALF typename std::enable_if_t<std::is_same<T, half>::value, void>
#define RETURN_VOID_IF_FLOAT_BF16 \
  typename std::enable_if_t<      \
      (std::is_same<T, float>::value || std::is_same<T, nv_bfloat16>::value), void>
#define RETURN_VOID_IF_DOUBLE typename std::enable_if_t<std::is_same<T, double>::value, void>

template<typename T, int pack_size, bool tail, bool has_addend>
__global__ RETURN_VOID_IF_FLOAT_BF16 FusedDropoutAddGpu(
    uint64_t seed, one::CUDAGeneratorState* cuda_gen_state, uint64_t inc_offset,
    const int64_t elem_cnt, float rate, float scale, int64_t n_tail, const T* x, int8_t* mask,
    const T* addend, T* y, const T* tail_x, int8_t* tail_mask, const T* tail_addend, T* tail_y) {
  int32_t global_thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  curandStatePhilox4_32_10_t state;
  curand_init(seed, global_thread_id, cuda_gen_state->dev_offset, &state);
  using LoadType = cuda::elementwise::PackType<T, pack_size>;
  using LoadPack = cuda::elementwise::Pack<T, pack_size>;
  using MaskType = cuda::elementwise::PackType<int8_t, pack_size>;
  using MaskPack = cuda::elementwise::Pack<int8_t, pack_size>;

  T t_scale = static_cast<T>(scale);
  RandPack4 rand_uniform_pack4;
  for (int64_t linear_index = global_thread_id * pack_size; linear_index < elem_cnt;
       linear_index += gridDim.x * blockDim.x * pack_size) {
    rand_uniform_pack4.storage = curand_uniform4(&state);

    const LoadType* x_load = reinterpret_cast<const LoadType*>(x + linear_index);
    LoadPack x_vec;
    x_vec.storage = *x_load;

    LoadPack addend_vec;
    if (has_addend) {
      const LoadType* addend_load = reinterpret_cast<const LoadType*>(addend + linear_index);
      addend_vec.storage = *addend_load;
    }

    MaskPack mask_vec;
    LoadPack y_vec;
#pragma unroll
    for (int i = 0; i < pack_size; i++) {
      mask_vec.elem[i] = rand_uniform_pack4.elem[i] > rate;
      T tmp_float_mask = static_cast<float>(mask_vec.elem[i]);
      y_vec.elem[i] = x_vec.elem[i] * tmp_float_mask * t_scale;
      if (has_addend) { y_vec.elem[i] += addend_vec.elem[i]; }
    }

    *(reinterpret_cast<LoadType*>(y + linear_index)) = y_vec.storage; 
    *(reinterpret_cast<MaskType*>(mask + linear_index)) = mask_vec.storage; 
  }

  if (tail && global_thread_id < n_tail) {
    const float rand_uniform = curand_uniform(&state);
    const int8_t mask_val = rand_uniform > rate;
    tail_mask[global_thread_id] = mask_val;
    T tmp_float_mask = static_cast<float>(mask_val);
    T tmp_tail_out = tail_x[global_thread_id] * tmp_float_mask * t_scale;
    if (has_addend) {
      tmp_tail_out  += tail_addend[global_thread_id];
    } 
    tail_y[global_thread_id] = tmp_tail_out;
  }

  __syncthreads();

  if (threadIdx.x == 0) {
    int32_t new_counter = cuda::atomic::Add(&cuda_gen_state->dev_counter, 1) + 1;
    if (new_counter == gridDim.x) {
      cuda_gen_state->dev_counter = 0;               // reset counter to zero
      cuda_gen_state->dev_offset += inc_offset;  // maintain the state of generator's dev_offset
    }
  }
}

template<typename T, int pack_size, bool tail, bool has_addend>
__global__ RETURN_VOID_IF_HALF FusedDropoutAddGpu(
    uint64_t seed, one::CUDAGeneratorState* cuda_gen_state, uint64_t inc_offset,
    const int64_t elem_cnt, float rate, float scale, int64_t n_tail, const T* x, int8_t* mask,
    const T* addend, T* y, const T* tail_x, int8_t* tail_mask, const T* tail_addend, T* tail_y) {
  int32_t global_thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  curandStatePhilox4_32_10_t state;
  curand_init(seed, global_thread_id, cuda_gen_state->dev_offset, &state);
  using LoadType = cuda::elementwise::PackType<T, pack_size>;
  using LoadPack = cuda::elementwise::Pack<T, pack_size>;
  using StoreType = cuda::elementwise::PackType<half2, pack_size/2>;
  using StorePack = cuda::elementwise::Pack<half2, pack_size/2>;
  using MaskType = cuda::elementwise::PackType<int8_t, pack_size>;
  using MaskPack = cuda::elementwise::Pack<int8_t, pack_size>;

  RandPack4 rand_uniform_pack4;
  half2 h2_scale = __float2half2_rn(scale);
  for (int64_t linear_index = global_thread_id * pack_size; linear_index < elem_cnt;
       linear_index += gridDim.x * blockDim.x * pack_size) {
    rand_uniform_pack4.storage = curand_uniform4(&state);
    const LoadType* x_load = reinterpret_cast<const LoadType*>(x + linear_index);
    H2Pack x_vec{};
    x_vec.pack_storage.storage = *x_load;

    H2Pack addend_vec{};
    if (has_addend) {
      const LoadType* addend_load = reinterpret_cast<const LoadType*>(addend+linear_index);
      addend_vec.pack_storage.storage = *addend_load;
    }

    MaskPack mask_vec;
    StorePack y_vec;
    StorePack one_or_zero_h2;

    mask_vec.elem[0] = rand_uniform_pack4.elem[0] > rate;
    one_or_zero_h2.elem[0].x = mask_vec.elem[0];
    mask_vec.elem[1] = rand_uniform_pack4.elem[1] > rate;
    one_or_zero_h2.elem[0].y = mask_vec.elem[1];
    y_vec.elem[0] = __hmul2(__hmul2(x_vec.h2[0], one_or_zero_h2.elem[0]), h2_scale);

    mask_vec.elem[2] = rand_uniform_pack4.elem[2] > rate;
    one_or_zero_h2.elem[1].x = mask_vec.elem[2];
    mask_vec.elem[3] = rand_uniform_pack4.elem[3] > rate;
    one_or_zero_h2.elem[1].y = mask_vec.elem[3];
    y_vec.elem[1] = __hmul2(__hmul2(x_vec.h2[1], one_or_zero_h2.elem[1]), h2_scale);

    if (has_addend) {
      y_vec.elem[0] = __hadd2(y_vec.elem[0], addend_vec.h2[0]);
      y_vec.elem[1] = __hadd2(y_vec.elem[1], addend_vec.h2[1]);
    }

    *(reinterpret_cast<StoreType*>(y + linear_index)) = y_vec.storage;
    *(reinterpret_cast<MaskType*>(mask + linear_index)) = mask_vec.storage;
  }

  if (tail && global_thread_id < n_tail) {
    const float rand_uniform = curand_uniform(&state);
    const int8_t mask_val = rand_uniform > rate;
    tail_mask[global_thread_id] = mask_val;
    half tmp_tail_out = tail_x[global_thread_id] * static_cast<half>(mask_val) * h2_scale.x;
    if (has_addend) {
      tmp_tail_out  += tail_addend[global_thread_id];
    } 
    tail_y[global_thread_id] = tmp_tail_out;
  }

  __syncthreads();
  if (threadIdx.x == 0) {
    int32_t new_counter = cuda::atomic::Add(&cuda_gen_state->dev_counter, 1) + 1;
    if (new_counter == gridDim.x) {
      cuda_gen_state->dev_counter = 0;               // reset counter to zero
      cuda_gen_state->dev_offset += inc_offset;  // maintain the state of generator's dev_offset
    }
  }
}

template<typename T, int pack_size, bool tail, bool has_addend>
__global__ RETURN_VOID_IF_DOUBLE FusedDropoutAddGpu(
    uint64_t seed, one::CUDAGeneratorState* cuda_gen_state, uint64_t inc_offset,
    const int64_t elem_cnt, float rate, float scale, int64_t n_tail, const T* x, int8_t* mask,
    const T* addend, T* y, const T* tail_x, int8_t* tail_mask, const T* tail_addend, T* tail_y) {
  int32_t global_thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  curandStatePhilox4_32_10_t state;
  curand_init(seed, global_thread_id, cuda_gen_state->dev_offset, &state);
  using LoadType = cuda::elementwise::PackType<T, pack_size>;
  using LoadPack = cuda::elementwise::Pack<T, pack_size>;
  using MaskType = cuda::elementwise::PackType<int8_t, pack_size>;
  using MaskPack = cuda::elementwise::Pack<int8_t, pack_size>;

  RandPack4 rand_uniform_pack4;
  bool grid_loop_rand_state = 0;

  for (int64_t linear_index = global_thread_id * pack_size; linear_index < elem_cnt;
       linear_index += gridDim.x * blockDim.x * pack_size) {
    if (grid_loop_rand_state == 0) {
      rand_uniform_pack4.storage = curand_uniform4(&state);
      grid_loop_rand_state ^= 1;
    } else {
      // Use the last two random numbers we generated in previous iteration.
      rand_uniform_pack4.elem[0] = rand_uniform_pack4.elem[2];
      rand_uniform_pack4.elem[1] = rand_uniform_pack4.elem[3];
      grid_loop_rand_state ^= 1;
    }
    const LoadType* x_load = reinterpret_cast<const LoadType*>(x + linear_index);
    LoadPack x_vec;
    x_vec.storage = *x_load;

    LoadPack addend_vec;
    if (has_addend) {
      const LoadType* addend_load = reinterpret_cast<const LoadType*>(addend + linear_index);
      addend_vec.storage = *addend_load;
    }

    MaskPack mask_vec;
    LoadPack y_vec;
#pragma unroll
    for (int i = 0; i < pack_size; i++) {
      mask_vec.elem[i] = rand_uniform_pack4.elem[i] > rate;
      y_vec.elem[i] = x_vec.elem[i] * mask_vec.elem[i] * scale;
      if (has_addend) { y_vec.elem[i] += addend_vec.elem[i]; }
    }
    *(reinterpret_cast<LoadType*>(y + linear_index)) = y_vec.storage;
    *(reinterpret_cast<MaskType*>(mask + linear_index)) = mask_vec.storage;
  }

  if (tail && global_thread_id < n_tail) {
    const float rand_uniform = curand_uniform(&state);
    const int8_t mask_val = rand_uniform > rate;
    tail_mask[global_thread_id] = mask_val;
    double tmp_tail_out = tail_x[global_thread_id] * mask_val * scale;
    if (has_addend) {
      tmp_tail_out  += tail_addend[global_thread_id];
    } 
    tail_y[global_thread_id] = tmp_tail_out;
  }

  __syncthreads();
  if (threadIdx.x == 0) {
    int32_t new_counter = cuda::atomic::Add(&cuda_gen_state->dev_counter, 1) + 1;
    if (new_counter == gridDim.x) {
      cuda_gen_state->dev_counter = 0;               // reset counter to zero
      cuda_gen_state->dev_offset += inc_offset;  // maintain the state of generator's dev_offset
    }
  }
}

template<int pack_size>
unsigned int ComputeGridSize(const int32_t block_size, const int64_t elem_cnt) {
  cudaDeviceProp prop;
  cudaGetDeviceProperties(&prop, 0);
  unsigned int blocks_per_sm = prop.maxThreadsPerMultiProcessor / block_size;
  unsigned int grid_size = ((elem_cnt + block_size - 1) / block_size);
  grid_size = std::min((unsigned int)prop.multiProcessorCount * blocks_per_sm, grid_size);
  return grid_size;
}

template<typename T, bool has_addend>
void DispatchTail(DeviceCtx* ctx, uint64_t seed, one::CUDAGeneratorState* cuda_gen_state,
                  const int64_t elem_cnt, float rate, float scale, const T* x, int8_t* mask,
                  const T* addend, T* y) {
  unsigned int grid_size = ComputeGridSize<4>(kBlockSize, elem_cnt);
  constexpr int pack_size = GetDropoutPackSize<T>();
  const int64_t pack_num = elem_cnt / pack_size;
  const int64_t tail_offset = pack_num * pack_size;
  const int64_t n_tail = elem_cnt - tail_offset;
  const bool tail = n_tail > 0 ? true : false;
  uint64_t inc_offset = 0;

  if (tail) {
    // If tail, we need generate randnum one more time, so here we add another `1`.
    inc_offset = ((elem_cnt - 1) / (kBlockSize * grid_size * kVecSize) + 1) * kVecSize + 1;
    FusedDropoutAddGpu<T, pack_size, true, has_addend>
        <<<grid_size, kBlockSize, 0, ctx->cuda_stream()>>>(
            seed, cuda_gen_state, inc_offset, elem_cnt, rate, scale, n_tail, x, mask, addend, y,
            (x + tail_offset), (mask + tail_offset), (addend + tail_offset), (y + tail_offset));
  } else {
    inc_offset = ((elem_cnt - 1) / (kBlockSize * grid_size * kVecSize) + 1) * kVecSize;
    FusedDropoutAddGpu<T, pack_size, false, has_addend>
        <<<grid_size, kBlockSize, 0, ctx->cuda_stream()>>>(
            seed, cuda_gen_state, inc_offset, elem_cnt, rate, scale, n_tail, x, mask, addend, y,
            nullptr, nullptr, nullptr, nullptr);
  }
}

template<typename T>
struct MaskAndScaleFunctor {
  OF_DEVICE_FUNC explicit MaskAndScaleFunctor(float scale) : scale(scale) {}
  __device__ T operator()(T x, int8_t mask) const {
    return x * static_cast<T>(mask) * static_cast<T>(scale);
  }
  float scale;
};

#if CUDA_VERSION >= 11000
template<>
struct MaskAndScaleFunctor<nv_bfloat16> {
  OF_DEVICE_FUNC explicit MaskAndScaleFunctor(float scale) : scale(scale) {}
  __device__ nv_bfloat16 operator()(nv_bfloat16 x, int8_t mask) const {
    float float_mask = static_cast<float>(mask);
    return x * static_cast<nv_bfloat16>(float_mask) * static_cast<nv_bfloat16>(scale);
  }
  float scale;
};
#endif

template<typename T>
class DropoutKernelGPU final : public user_op::OpKernel, public user_op::CudaGraphSupport {
 public:
  DropoutKernelGPU() = default;
  ~DropoutKernelGPU() = default;

  std::shared_ptr<user_op::OpKernelState> CreateOpKernelState(
      user_op::KernelInitContext* ctx) const override {
    const auto& generator = CHECK_JUST(one::MakeGenerator(DeviceType::kGPU));
    return std::make_shared<FusedDropoutKernelState>(generator);
  }

 private:
  using user_op::OpKernel::Compute;
  void Compute(user_op::KernelComputeContext* ctx, user_op::OpKernelState* state) const override {
    const user_op::Tensor* in = ctx->Tensor4ArgNameAndIndex("in", 0);
    user_op::Tensor* out = ctx->Tensor4ArgNameAndIndex("out", 0);
    user_op::Tensor* mask = ctx->Tensor4ArgNameAndIndex("mask", 0);
    auto* fused_dropout_kernel_state = dynamic_cast<FusedDropoutKernelState*>(state);
    CHECK_NOTNULL(fused_dropout_kernel_state);
    const auto& generator = fused_dropout_kernel_state->generator();
    CHECK_NOTNULL(generator);
    std::shared_ptr<one::CUDAGeneratorImpl> cuda_generator =
        CHECK_JUST(generator->Get<one::CUDAGeneratorImpl>());
    uint64_t seed = cuda_generator->current_seed();

    const float rate = ctx->Attr<float>("rate");
    float scale = 0.0;
    if (rate < 1.0f) { scale = 1.0f / (1.0f - rate); }
    one::CUDAGeneratorState* cuda_gen_state = cuda_generator->cuda_gen_state();

    if (ctx->has_input("_add_to_output", 0)) {
      const user_op::Tensor* addend = ctx->Tensor4ArgNameAndIndex("_add_to_output", 0);
      DispatchTail<T, true>(
          ctx->device_ctx(), seed, cuda_gen_state, in->shape().elem_cnt(), rate, scale,
          reinterpret_cast<const T*>(in->dptr()), reinterpret_cast<int8_t*>(mask->mut_dptr()),
          reinterpret_cast<const T*>(addend->dptr()), reinterpret_cast<T*>(out->mut_dptr()));
    } else {
      DispatchTail<T, false>(ctx->device_ctx(), seed, cuda_gen_state, in->shape().elem_cnt(), rate,
                             scale, reinterpret_cast<const T*>(in->dptr()),
                             reinterpret_cast<int8_t*>(mask->mut_dptr()), nullptr,
                             reinterpret_cast<T*>(out->mut_dptr()));
    }
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

#define REGISTER_DROPOUT_KERNEL_GPU(cpp_type, data_type)                                     \
  REGISTER_USER_KERNEL("dropout").SetCreateFn<DropoutKernelGPU<cpp_type>>().SetIsMatchedHob( \
      (user_op::HobDeviceType() == DeviceType::kGPU)                                         \
      && (user_op::HobDataType("out", 0) == data_type)                                       \
      && (user_op::HobDataType("mask", 0) == GetDataType<int8_t>::value))

REGISTER_DROPOUT_KERNEL_GPU(half, DataType::kFloat16);
REGISTER_DROPOUT_KERNEL_GPU(float, DataType::kFloat);
REGISTER_DROPOUT_KERNEL_GPU(double, DataType::kDouble);
REGISTER_DROPOUT_KERNEL_GPU(nv_bfloat16, DataType::kBFloat16);

template<typename T>
class DropoutGradKernelGPU final : public user_op::OpKernel, public user_op::CudaGraphSupport {
 public:
  DropoutGradKernelGPU() = default;
  ~DropoutGradKernelGPU() = default;

 private:
  using user_op::OpKernel::Compute;
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* dy = ctx->Tensor4ArgNameAndIndex("dy", 0);
    const user_op::Tensor* mask = ctx->Tensor4ArgNameAndIndex("mask", 0);
    user_op::Tensor* dx = ctx->Tensor4ArgNameAndIndex("dx", 0);
    const float scale = ctx->Attr<float>("scale");
    const int64_t elem_cnt = dy->shape().elem_cnt();
    OF_CUDA_CHECK((cuda::elementwise::Binary(
        MaskAndScaleFunctor<T>(scale), elem_cnt, reinterpret_cast<T*>(dx->mut_dptr()),
        reinterpret_cast<const T*>(dy->dptr()), reinterpret_cast<const int8_t*>(mask->dptr()),
        ctx->stream()->As<ep::CudaStream>()->cuda_stream())));
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

#define REGISTER_DROPOUT_GRAD_KERNEL_GPU(cpp_type, data_type)                                   \
  REGISTER_USER_KERNEL("dropout_grad")                                                          \
      .SetCreateFn<DropoutGradKernelGPU<cpp_type>>()                                            \
      .SetIsMatchedHob((user_op::HobDeviceType() == DeviceType::kGPU)                           \
                       && (user_op::HobDataType("dx", 0) == data_type))                         \
      .SetInplaceProposalFn([](const user_op::InferContext&,                                    \
                               user_op::AddInplaceArgPair AddInplaceArgPairFn) -> Maybe<void> { \
        OF_RETURN_IF_ERROR(AddInplaceArgPairFn("dx", 0, "dy", 0, true));                        \
        return Maybe<void>::Ok();                                                               \
      })

REGISTER_DROPOUT_GRAD_KERNEL_GPU(half, DataType::kFloat16);
REGISTER_DROPOUT_GRAD_KERNEL_GPU(float, DataType::kFloat);
REGISTER_DROPOUT_GRAD_KERNEL_GPU(double, DataType::kDouble);
REGISTER_DROPOUT_GRAD_KERNEL_GPU(nv_bfloat16, DataType::kBFloat16);

}  // namespace

}  // namespace oneflow
