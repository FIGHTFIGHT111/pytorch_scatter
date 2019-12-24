#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>

#include <THC/THCGeneral.h>
#include <THC/THCThrustAllocator.cuh>

#include <thrust/execution_policy.h>

#include "compat.cuh"

#define THREADS 256
#define BLOCKS(TB, N) (TB * N + THREADS - 1) / THREADS
#define FULL_MASK 0xffffffff

template <typename scalar_t, int TB>
__global__ void segment_add_csr_kernel(const scalar_t *src_data,
                                       const int64_t *indptr_data,
                                       scalar_t *out_data, size_t numel) {

  int thread_idx = blockIdx.x * blockDim.x + threadIdx.x;
  int warp_idx = thread_idx / TB;
  int lane_idx = thread_idx & (TB - 1);

  if (warp_idx < numel) {
    int row_start = __ldg(indptr_data + warp_idx);
    int row_end = __ldg(indptr_data + warp_idx + 1);
    scalar_t val = (scalar_t)0;

    for (int src_idx = row_start + lane_idx; src_idx < row_end; src_idx += TB) {
      val += __ldg(src_data + src_idx);
    }

#pragma unroll
    for (int offset = TB / 2; offset > 0; offset /= 2)
      val += __shfl_down_sync(FULL_MASK, val, offset); // Parallel reduction.

    if (lane_idx == 0) {
      out_data[warp_idx] = val;
    }
  }
}

at::Tensor segment_add_csr_cuda(at::Tensor src, at::Tensor indptr) {
  auto numel = indptr.numel() - 1;
  auto avg_length = (float)src.numel() / (float)numel;

  auto out = at::empty({numel}, src.options());

  auto indptr_data = indptr.DATA_PTR<int64_t>();
  auto stream = at::cuda::getCurrentCUDAStream();
  AT_DISPATCH_ALL_TYPES(src.scalar_type(), "segment_add_kernel", [&] {
    auto src_data = src.DATA_PTR<scalar_t>();
    auto out_data = out.DATA_PTR<scalar_t>();

    if (avg_length <= 4)
      segment_add_csr_kernel<scalar_t, 4>
          <<<BLOCKS(4, numel), THREADS, 0, stream>>>(src_data, indptr_data,
                                                     out_data, numel);
    else if (avg_length <= 8)
      segment_add_csr_kernel<scalar_t, 8>
          <<<BLOCKS(8, numel), THREADS, 0, stream>>>(src_data, indptr_data,
                                                     out_data, numel);
    else if (avg_length <= 16)
      segment_add_csr_kernel<scalar_t, 16>
          <<<BLOCKS(16, numel), THREADS, 0, stream>>>(src_data, indptr_data,
                                                      out_data, numel);
    else
      segment_add_csr_kernel<scalar_t, 32>
          <<<BLOCKS(32, numel), THREADS, 0, stream>>>(src_data, indptr_data,
                                                      out_data, numel);
  });

  return out;
}

at::Tensor segment_add_coo_cuda(at::Tensor src, at::Tensor index) {
  return src;
}

void segment_add_thrust_cuda(at::Tensor src, at::Tensor index, at::Tensor out) {
  auto stream = at::cuda::getCurrentCUDAStream();
  auto allocator = THCThrustAllocator(at::globalContext().lazyInitCUDA());
  auto policy = thrust::cuda::par(allocator).on(stream);

  auto key = at::full_like(out, -1, out.options().dtype(at::kLong));

  auto index_data = thrust::device_ptr<int64_t>(index.DATA_PTR<int64_t>());
  auto key_data = thrust::device_ptr<int64_t>(key.DATA_PTR<int64_t>());

  AT_DISPATCH_ALL_TYPES(src.scalar_type(), "segment_add_thrust_kernel", [&] {
    auto src_data = thrust::device_ptr<scalar_t>(src.DATA_PTR<scalar_t>());
    auto out_data = thrust::device_ptr<scalar_t>(out.DATA_PTR<scalar_t>());

    thrust::reduce_by_key(policy, index_data, index_data + index.numel(),
                          src_data, key_data, out_data);
  });
}
