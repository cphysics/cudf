/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/cudf.h>
#include <cudf/types.hpp>
#include <cudf/copying.hpp>
#include <cudf/stream_compaction.hpp>

#include <bitmask/bit_mask.cuh>
#include <table/device_table.cuh>

#include <utilities/device_atomics.cuh>
#include <utilities/cudf_utils.h>
#include <utilities/error_utils.hpp>
#include <utilities/type_dispatcher.hpp>
#include <utilities/wrapper_types.hpp>
#include <utilities/cuda_utils.hpp>

#include <utilities/column_utils.hpp>
#include <string/nvcategory_util.hpp>

#include <rmm/thrust_rmm_allocator.h>

#include <cub/cub.cuh>
#include <algorithm>

using bit_mask::bit_mask_t;

namespace {

static constexpr int warp_size = 32;

// Compute the count of elements that pass the mask within each block
template <typename Filter, int block_size, int per_thread>
__global__ void compute_block_counts(gdf_size_type  * __restrict__ block_counts,
                                     Filter filter)
{
  int tid = threadIdx.x + per_thread * block_size * blockIdx.x;
  int count = 0;

  for (int i = 0; i < per_thread; i++) {
    count += __syncthreads_count(filter(tid));
    tid += block_size;
  }

  if (threadIdx.x == 0) block_counts[blockIdx.x] = count;
}

// Compute the exclusive prefix sum of each thread's mask value within each block
template <int block_size>
__device__ gdf_index_type block_scan_mask(bool mask_true, 
                                          gdf_index_type &block_sum)
{
  int offset = 0;

  using BlockScan = cub::BlockScan<gdf_size_type, block_size>;
  __shared__ typename BlockScan::TempStorage temp_storage;
  BlockScan(temp_storage).ExclusiveSum(mask_true, offset, block_sum);
  
  return offset;
}


// This kernel scatters data and validity mask of a column based on the 
// scan of the boolean mask. The block offsets for the scan are already computed.
// Just compute the scan of the mask in each block and add it to the block's
// output offset. This is the output index of each element. Scattering
// the valid mask is not as easy, because each thread is only responsible for
// one bit. Warp-level processing (ballot) makes this simpler.
// To make scattering efficient, we "coalesce" the block's scattered data and 
// valids in shared memory, and then write from shared memory to global memory
// in a contiguous manner.
// The has_validity template parameter specializes this kernel for the 
// non-nullable case for performance without writing another kernel.
//
// Note: `filter` is expected to return false if the index is out of bounds.
template <typename T, typename Filter, 
          int block_size, int per_thread, bool has_validity>
__launch_bounds__(block_size, 2048/block_size)
__global__ void scatter_kernel(T* __restrict__ output_data,
                               bit_mask_t * __restrict__ output_valid,
                               gdf_size_type * output_null_count,
                               T const * __restrict__ input_data,
                               bit_mask_t const * __restrict__ input_valid,
                               gdf_size_type  * __restrict__ block_offsets,
                               Filter filter)
{
  static_assert(block_size <= 1024, "Maximum thread block size exceeded");

  int tid = threadIdx.x + per_thread * block_size * blockIdx.x;
  gdf_size_type block_offset = block_offsets[blockIdx.x];
  
  // one extra warp worth in case the block is not aligned
  __shared__ bool temp_valids[has_validity ? block_size+warp_size : 1];
  __shared__ T    temp_data[block_size];
  
  // Note that since the maximum gridDim.x on all supported GPUs is as big as
  // gdf_size_type, this loop is sufficient to cover our maximum column size
  // regardless of the value of block_size and per_thread.
  for (int i = 0; i < per_thread; i++) {
    bool mask_true = filter(tid);

    // get output location using a scan of the mask result
    gdf_index_type block_sum = 0;
    const gdf_index_type local_index = block_scan_mask<block_size>(mask_true,
                                                                   block_sum);

    if (has_validity) {
      temp_valids[threadIdx.x] = false; // init shared memory
      if (threadIdx.x < warp_size) temp_valids[block_size + threadIdx.x] = false;
      __syncthreads(); // wait for init
    }

    if (mask_true) {
      temp_data[local_index] = input_data[tid]; // scatter data to shared

      // scatter validity mask to shared memory
      if (has_validity && bit_mask::is_valid(input_valid, tid)) {
        // determine aligned offset for this warp's output
        const gdf_size_type aligned_offset = block_offset % warp_size;
        temp_valids[local_index + aligned_offset] = true;
      }
    }

    // each warp shares its total valid count to shared memory to ease
    // computing the total number of valid / non-null elements written out.
    // note maximum block size is limited to 1024 by this, but that's OK
    __shared__ uint32_t warp_valid_counts[has_validity ? warp_size : 1];
    if (has_validity && threadIdx.x < warp_size) warp_valid_counts[threadIdx.x] = 0;

    __syncthreads(); // wait for shared data and validity mask to be complete

    // Copy output data coalesced from shared to global
    if (threadIdx.x < block_sum)
      output_data[block_offset + threadIdx.x] = temp_data[threadIdx.x];

    if (has_validity) {
      // Since the valid bools are contiguous in shared memory now, we can use
      // __popc to combine them into a single mask element.
      // Then, most mask elements can be directly copied from shared to global
      // memory. Only the first and last 32-bit mask elements of each block must
      // use an atomicOr, because these are where other blocks may overlap.

      constexpr int num_warps = block_size / warp_size;
      const int last_warp = block_sum / warp_size;
      const int wid = threadIdx.x / warp_size;
      const int lane = threadIdx.x % warp_size;

      if (block_sum > 0 && wid <= last_warp) {
        int valid_index = (block_offset / warp_size) + wid;

        // compute the valid mask for this warp
        uint32_t valid_warp = __ballot_sync(0xffffffff, temp_valids[threadIdx.x]);

        if (lane == 0 && valid_warp != 0) {
          warp_valid_counts[wid] = __popc(valid_warp);
          if (wid > 0 && wid < last_warp)
            output_valid[valid_index] = valid_warp;
          else {
            atomicOr(&output_valid[valid_index], valid_warp);
          }
        }

        // if the block is full and not aligned then we have one more warp to cover
        if ((wid == 0) && (last_warp == num_warps)) {
          uint32_t valid_warp =
            __ballot_sync(0xffffffff, temp_valids[block_size + threadIdx.x]);
          if (lane == 0 && valid_warp != 0) {
            warp_valid_counts[wid] += __popc(valid_warp);
            atomicOr(&output_valid[valid_index + num_warps], valid_warp);
          }
        }
      }

      __syncthreads(); // wait for warp_valid_counts to be ready

      // Compute total null_count for this block and add it to global count
      if (threadIdx.x < warp_size) {
        uint32_t my_valid_count = warp_valid_counts[threadIdx.x];

        __shared__ typename cub::WarpReduce<uint32_t>::TempStorage temp_storage;
        
        uint32_t block_valid_count =
          cub::WarpReduce<uint32_t>(temp_storage).Sum(my_valid_count);
        
        if (lane == 0) { // one thread computes and adds to null count
          atomicAdd(output_null_count, block_sum - block_valid_count);
        }
      }
    }

    block_offset += block_sum;
    tid += block_size;
  }
}

// Dispatch functor which performs the scatter
template <typename Filter, int block_size, int per_thread>
struct scatter_functor
{
  template <typename T>
  void operator()(gdf_column & output_column,
                  gdf_column const & input_column,
                  gdf_size_type  *block_offsets,
                  Filter filter,
                  cudaStream_t stream = 0) {
    cudf::util::cuda::grid_config_1d grid{input_column.size,
                                          block_size, per_thread};
    
    bool has_valid = cudf::is_nullable(input_column);

    auto scatter = (has_valid) ?
      scatter_kernel<T, Filter, block_size, per_thread, true> :
      scatter_kernel<T, Filter, block_size, per_thread, false>;

    gdf_size_type *null_count = nullptr;
    if (has_valid) {
      RMM_ALLOC(&null_count, sizeof(gdf_size_type), stream);
      CUDA_TRY(cudaMemsetAsync(null_count, 0, sizeof(gdf_size_type), stream));
    }

    bit_mask_t * __restrict__ output_valid =
      reinterpret_cast<bit_mask_t*>(output_column.valid);
    bit_mask_t const * __restrict__ input_valid =
      reinterpret_cast<bit_mask_t*>(input_column.valid);

    scatter<<<grid.num_blocks, block_size, 0, stream>>>
      (static_cast<T*>(output_column.data), output_valid, null_count,
       static_cast<T const*>(input_column.data), input_valid,
       block_offsets, filter);

    if (has_valid) {
      CUDA_TRY(cudaMemcpyAsync(&output_column.null_count, null_count,
                               sizeof(gdf_size_type), cudaMemcpyDefault, stream));
      RMM_FREE(null_count, stream);
    }
  }
};

// Computes the output size of apply_boolean_mask, which is the sum of the
// last block's offset and the last block's pass count
gdf_size_type get_output_size(gdf_size_type * block_counts,
                              gdf_size_type * block_offsets,
                              gdf_size_type num_blocks,
                              cudaStream_t stream = 0)
{
  gdf_size_type last_block_count = 0;
  cudaMemcpyAsync(&last_block_count, &block_counts[num_blocks - 1],
                  sizeof(gdf_size_type), cudaMemcpyDefault, stream);
  gdf_size_type last_block_offset = 0;
  if (num_blocks > 1)
    cudaMemcpyAsync(&last_block_offset, &block_offsets[num_blocks - 1],
                    sizeof(gdf_size_type), cudaMemcpyDefault, stream);
  cudaStreamSynchronize(stream);
  return last_block_count + last_block_offset;
}

} // namespace anonymous

namespace cudf {

namespace detail {

/*
 * @brief Filters a column using a Filter function object
 * 
 * @p filter must be a functor or lambda with the following signature:
 * __device__ bool operator()(gdf_index_type i);
 * It return true if element i of @p input should be copied, false otherwise.
 *
 * @tparam Filter the filter functor type
 * @param[in] input The column to filter-copy
 * @param[in] filter A function object that takes an index and returns a bool
 * @return The filter-copied result column
 */
template <typename Filter>
table copy_if(table const &input, Filter filter, cudaStream_t stream = 0) {
  /*  * High Level Algorithm: First, compute a `scatter_map` from the boolean_mask 
  * that scatters input[i] if boolean_mask[i] is non-null and "true". This is 
  * simply an exclusive scan of the mask. Second, use the `scatter_map` to
  * scatter elements from the `input` column into the `output` column.
  * 
  * Slightly more complicated for performance reasons: we first compute the 
  * per-block count of passed elements, then scan that, and perform the
  * intra-block scan inside the kernel that scatters the output
  */
  // no error for empty input, just return empty output
  if (0 == input.num_rows() || 0 == input.num_columns()) 
    return empty_like(input);
  
  CUDF_EXPECTS(std::all_of(input.begin(), input.end(), 
                [](gdf_column const* c) { return c->data != nullptr; }), 
               "Null input data"); // nonzero size but null

  constexpr int block_size = 256;
  constexpr int per_thread = 32;
  cudf::util::cuda::grid_config_1d grid{input.num_rows(), block_size, per_thread};

  // allocate temp storage for block counts and offsets
  // TODO: use an uninitialized buffer to avoid the initialization kernel
  rmm::device_vector<gdf_size_type> temp_counts(2 * grid.num_blocks);
  gdf_size_type *block_counts = thrust::raw_pointer_cast(temp_counts.data());
  gdf_size_type *block_offsets = block_counts + grid.num_blocks;

  // 1. Find the count of elements in each block that "pass" the mask
  compute_block_counts<Filter, block_size, per_thread>
    <<<grid.num_blocks, block_size, 0, stream>>>(block_counts, filter);

  // 2. Find the offset for each block's output using a scan of block counts
  if (grid.num_blocks > 1) {
    // Determine and allocate temporary device storage
    void *d_temp_storage = nullptr;
    size_t temp_storage_bytes = 0;
    cub::DeviceScan::ExclusiveSum(d_temp_storage, temp_storage_bytes,
                                  block_counts, block_offsets,
                                  grid.num_blocks, stream);
    RMM_ALLOC(&d_temp_storage, temp_storage_bytes, stream);

    // Run exclusive prefix sum
    cub::DeviceScan::ExclusiveSum(d_temp_storage, temp_storage_bytes,
                                  block_counts, block_offsets,
                                  grid.num_blocks, stream);
    RMM_FREE(d_temp_storage, stream);
  }
  else {
    cudaMemsetAsync(block_offsets, 0, grid.num_blocks * sizeof(gdf_size_type),
                    stream);
  }

  CHECK_STREAM(stream);
  
  // 3. compute the output size from the last block's offset + count
  gdf_size_type output_size = 
    get_output_size(block_counts, block_offsets, grid.num_blocks, stream);

  if (output_size == input.num_rows()) {
    return cudf::copy(input);
  }
  else if (output_size > 0) {
    // Allocate/initialize output columns
    table output = cudf::allocate_like(input, output_size, true, stream);

    // 4. Scatter the output data and valid mask
    for (int col = 0; col < input.num_columns(); col++) {
      cudf::type_dispatcher(output.get_column(col)->dtype,
                            scatter_functor<Filter, block_size, per_thread>{},
                            *output.get_column(col), *input.get_column(col), 
                            block_offsets, filter, stream);
    }

    CHECK_STREAM(stream);

    return output;
  }
  return empty_like(input);
}

/*
 * @brief Filters a column using a Filter function object
 * 
 * @p filter must be a functor or lambda with the following signature:
 * __device__ bool operator()(gdf_index_type i);
 * It returns true if element i of @p input should be copied, false otherwise.
 * 
 * @note: filter must return false if its input i is out of bounds for any 
 * memory accesses, therefore it is expected to know the bounds of any 
 * arrays it uses internally.
 *
 * @tparam Filter the filter functor type
 * @param[in] input The column to filter-copy
 * @param[in] filter A function object that takes an index and returns a bool
 * @return The filter-copied result column
 */
template <typename Filter>
gdf_column copy_if(gdf_column const &input, Filter filter,
                   cudaStream_t stream = 0)
{
  // convert column to table
  gdf_column * cols[1];
  cols[0] = const_cast<gdf_column*>(&input);
  const table input_table(cols, 1);
  table output_table = copy_if(input_table, filter, stream);
  gdf_column * out = output_table.get_column(0);
    
  // synchronize nvcategory after filtering
  if (out->dtype == GDF_STRING_CATEGORY) {
    CUDF_EXPECTS(
    GDF_SUCCESS ==
      nvcategory_gather(out,
                        static_cast<NVCategory *>(input.dtype_info.category)),
      "could not set nvcategory");
  }
  return *out;
}

} // namespace detail

}  // namespace cudf
