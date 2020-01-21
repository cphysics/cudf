/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.
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

#include <cudf/types.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/detail/copy.hpp>
#include <cudf/column/column.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/scalar/scalar_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/strings/detail/utilities.hpp>
#include <cudf/strings/detail/utilities.cuh>
#include <cudf/replace.hpp>
#include <cudf/detail/iterator.cuh>

namespace cudf {
namespace experimental {
namespace detail {
namespace {

template <typename Transformer>
std::pair<std::unique_ptr<column>, std::unique_ptr<column>>
form_offsets_and_char_column (cudf::column_device_view input,
                              Transformer offsets_transformer,
                              rmm::mr::device_memory_resource* mr,
                              cudaStream_t stream) {

    std::unique_ptr<column> offsets_column{};
    auto strings_count = input.size();

    if (input.nullable()) {
        auto input_begin = cudf::experimental::detail::make_null_replacement_iterator<string_view>(input, string_view{});
        auto offsets_transformer_itr = thrust::make_transform_iterator(input_begin, offsets_transformer);
        offsets_column = std::move(cudf::strings::detail::make_offsets_child_column(offsets_transformer_itr,
                    offsets_transformer_itr + strings_count,
                    mr, stream));
    } else {
        auto offsets_transformer_itr = thrust::make_transform_iterator(input.begin<string_view>(), offsets_transformer);
        offsets_column = std::move(cudf::strings::detail::make_offsets_child_column(offsets_transformer_itr,
                    offsets_transformer_itr + strings_count,
                    mr, stream));
    }

    auto d_offsets = offsets_column->view().template data<size_type>();
    // build chars column
    size_type bytes = thrust::device_pointer_cast(d_offsets)[strings_count];
    auto chars_column = cudf::strings::detail::create_chars_child_column( strings_count, input.null_count(), bytes, mr, stream);

    return std::make_pair(std::move(offsets_column), std::move(chars_column));
}

template <typename ScalarIterator>
std::unique_ptr<cudf::column> clamp_string_column (strings_column_view const& input,
                                                   ScalarIterator const& lo_itr,
                                                   ScalarIterator const& lo_replace_itr,
                                                   ScalarIterator const& hi_itr,
                                                   ScalarIterator const& hi_replace_itr,
                                                   rmm::mr::device_memory_resource* mr,
                                                   cudaStream_t stream) {

    auto input_device_column = column_device_view::create(input.parent(),stream);
    auto d_input = *input_device_column;
    auto d_lo = (*lo_itr).first;
    auto d_hi = (*hi_itr).first;
    auto d_lo_replace = (*lo_replace_itr).first;
    auto d_hi_replace = (*hi_replace_itr).first;
    auto lo_valid = (*lo_itr).second;
    auto hi_valid = (*hi_itr).second;
    auto strings_count = input.size();
    auto exec = rmm::exec_policy(stream);

    if (lo_valid and hi_valid) {
        // build offset column
        auto offsets_transformer = [d_lo, d_lo_replace, d_hi, d_hi_replace] __device__ (string_view element, bool is_valid=true) {
            size_type bytes = 0;

            if (is_valid) {
                if (element < d_lo){
                    bytes = d_lo_replace.size_bytes();
                } else if (d_hi < element) {
                    bytes = d_hi_replace.size_bytes();
                } else {
                    bytes = element.size_bytes();
                }
            }
            return bytes;
        };

        auto offset_and_char = form_offsets_and_char_column(d_input, offsets_transformer, mr, stream);
        auto offsets_column(std::move(offset_and_char.first));
        auto chars_column(std::move(offset_and_char.second));

        auto d_offsets = offsets_column->view().template data<size_type>();
        auto d_chars = chars_column->mutable_view().template data<char>();
        // fill in chars
        auto copy_transformer = [d_input, d_lo, d_lo_replace, d_hi, d_hi_replace, d_offsets, d_chars] __device__(size_type idx){
            if (d_input.is_null(idx)){
                return;
            }
            auto input_element = d_input.element<string_view>(idx);

            if (input_element < d_lo){
                memcpy(d_chars + d_offsets[idx], d_lo_replace.data(), d_lo_replace.size_bytes() );
            } else if (d_hi < input_element) {
                memcpy(d_chars + d_offsets[idx], d_hi_replace.data(), d_hi_replace.size_bytes() );
            } else {
                memcpy(d_chars + d_offsets[idx], input_element.data(), input_element.size_bytes() );
            }
        };
        thrust::for_each_n(exec->on(stream), thrust::make_counting_iterator<size_type>(0), strings_count, copy_transformer);

        return make_strings_column(strings_count, std::move(offsets_column), std::move(chars_column),
                input.null_count(), std::move(copy_bitmask(input.parent())), stream, mr);
    } else if (hi_valid) {
        // build offset column
        auto offsets_transformer = [d_hi, d_hi_replace] __device__ (string_view element, bool is_valid=true) {
            size_type bytes = 0;

            if (is_valid) {

                if (d_hi < element) {
                    bytes = d_hi_replace.size_bytes();
                } else {
                    bytes = element.size_bytes();
                }
            }
            return bytes;
        };

        auto offset_and_char = form_offsets_and_char_column(d_input, offsets_transformer, mr, stream);
        auto offsets_column(std::move(offset_and_char.first));
        auto chars_column(std::move(offset_and_char.second));

        auto d_offsets = offsets_column->view().template data<size_type>();
        auto d_chars = chars_column->mutable_view().template data<char>();
        // fill in chars
        auto copy_transformer = [d_input, d_hi, d_hi_replace, d_offsets, d_chars] __device__(size_type idx){
            if (d_input.is_null(idx)){
                return;
            }
            auto input_element = d_input.element<string_view>(idx);

            if (d_hi < input_element) {
                memcpy(d_chars + d_offsets[idx], d_hi_replace.data(), d_hi_replace.size_bytes() );
            } else {
                memcpy(d_chars + d_offsets[idx], input_element.data(), input_element.size_bytes() );
            }
        };
        thrust::for_each_n(exec->on(stream), thrust::make_counting_iterator<size_type>(0), strings_count, copy_transformer);

        return make_strings_column(strings_count, std::move(offsets_column), std::move(chars_column),
                input.null_count(), std::move(copy_bitmask(input.parent())), stream, mr);
    } else {
        // build offset column
        auto offsets_transformer = [d_lo, d_lo_replace] __device__ (string_view element, bool is_valid=true) {
            size_type bytes = 0;

            if (is_valid) {

                if (element < d_lo){
                    bytes = d_lo_replace.size_bytes();
                } else {
                    bytes = element.size_bytes();
                }
            }
            return bytes;
        };

        auto offset_and_char = form_offsets_and_char_column(d_input, offsets_transformer, mr, stream);
        auto offsets_column(std::move(offset_and_char.first));
        auto chars_column(std::move(offset_and_char.second));

        auto d_offsets = offsets_column->view().template data<size_type>();
        auto d_chars = chars_column->mutable_view().template data<char>();
        // fill in chars
        auto copy_transformer = [d_input, d_lo, d_lo_replace, d_offsets, d_chars] __device__(size_type idx){
            if ( d_input.is_null(idx)){
                return;
            }
            auto input_element = d_input.element<string_view>(idx);

            if (input_element < d_lo){
                memcpy(d_chars + d_offsets[idx], d_lo_replace.data(), d_lo_replace.size_bytes() );
            } else {
                memcpy(d_chars + d_offsets[idx], input_element.data(), input_element.size_bytes() );
            }
        };
        thrust::for_each_n(exec->on(stream), thrust::make_counting_iterator<size_type>(0), strings_count, copy_transformer);

        return make_strings_column(strings_count, std::move(offsets_column), std::move(chars_column),
                input.null_count(), std::move(copy_bitmask(input.parent())), stream, mr);
    }
}

template <typename T, typename InputIterator, typename ScalarZipIterator, typename Transformer>
void apply_transform (InputIterator input_begin,
        InputIterator input_end,
        ScalarZipIterator scalar_zip_itr,
        mutable_column_device_view output,
        Transformer trans,
        cudaStream_t stream)
{
    thrust::transform(rmm::exec_policy(stream)->on(stream),
            input_begin,
            input_end,
            scalar_zip_itr,
            output.begin<T>(),
            trans);
}

template <typename T, typename ScalarIterator>
std::enable_if_t<cudf::is_fixed_width<T>(), std::unique_ptr<cudf::column>>
clamper(column_view const& input,
        ScalarIterator const& lo_itr,
        ScalarIterator const& lo_replace_itr,
        ScalarIterator const& hi_itr,
        ScalarIterator const& hi_replace_itr,
        rmm::mr::device_memory_resource* mr,
        cudaStream_t stream) {
    auto output = detail::allocate_like(input, input.size(), mask_allocation_policy::NEVER, mr, stream);
    // mask will not change
    if (input.nullable()){
        output->set_null_mask(copy_bitmask(input), input.null_count());
    }

    auto output_device_view  = cudf::mutable_column_device_view::create(output->mutable_view(), stream);
    auto input_device_view  = cudf::column_device_view::create(input, stream);
    auto scalar_zip_itr = thrust::make_zip_iterator(thrust::make_tuple(lo_itr, lo_replace_itr, hi_itr, hi_replace_itr));

    auto trans = [] __device__ (auto element_validity_pair,
                                auto scalar_tuple) {
        if(element_validity_pair.second) {
            auto lo_validity_pair = thrust::get<0>(scalar_tuple);
            auto hi_validity_pair = thrust::get<2>(scalar_tuple);
            if(lo_validity_pair.second and
                (element_validity_pair.first < lo_validity_pair.first)) {
                return thrust::get<1>(scalar_tuple).first;
            } else if(hi_validity_pair.second and
                (element_validity_pair.first > hi_validity_pair.first)) {
                return thrust::get<3>(scalar_tuple).first;
            }
        }

        return element_validity_pair.first;
    };

    if (input.has_nulls()) {
        auto input_pair_iterator = make_pair_iterator<T, true>(*input_device_view);
        apply_transform<T>(input_pair_iterator, input_pair_iterator+input.size(),
                           scalar_zip_itr, *output_device_view, trans, stream);
    } else {
        auto input_pair_iterator = make_pair_iterator<T, false>(*input_device_view);
        apply_transform<T>(input_pair_iterator, input_pair_iterator+input.size(),
                           scalar_zip_itr, *output_device_view, trans, stream);
    }

    return output;
}

template <typename T, typename ScalarIterator>
std::enable_if_t<std::is_same<T, string_view>::value, std::unique_ptr<cudf::column>>
clamper (column_view const& input,
         ScalarIterator const& lo_itr,
         ScalarIterator const& lo_replace_itr,
         ScalarIterator const& hi_itr,
         ScalarIterator const& hi_replace_itr,
         rmm::mr::device_memory_resource* mr,
         cudaStream_t stream) {

    return clamp_string_column (input, lo_itr, lo_replace_itr,
                                hi_itr, hi_replace_itr, mr, stream);
}

} //namespace

template<typename T, typename ScalarIterator>
std::unique_ptr<column> clamp(column_view const& input,
                              ScalarIterator const& lo_itr,
                              ScalarIterator const& lo_replace_itr,
                              ScalarIterator const& hi_itr,
                              ScalarIterator const& hi_replace_itr,
                              rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                              cudaStream_t stream = 0) {
    return clamper<T>(input, lo_itr, lo_replace_itr, hi_itr, hi_replace_itr, mr, stream);
}

struct dispatch_clamp {
    template<typename T>
    std::unique_ptr<column> operator ()(column_view const& input,
                scalar const& lo,
                scalar const& lo_replace,
                scalar const& hi,
                scalar const& hi_replace,
                rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                cudaStream_t stream = 0) {
        
        auto lo_itr = make_pair_iterator<T>(lo);
        auto hi_itr = make_pair_iterator<T>(hi);
        auto lo_replace_itr = make_pair_iterator<T>(lo_replace);
        auto hi_replace_itr = make_pair_iterator<T>(hi_replace);


        return clamp<T>(input, lo_itr, lo_replace_itr,
                     hi_itr, hi_replace_itr, mr, stream);
    }
};

/**
 * @copydoc cudf::experimental::clamp(column_view const& input,
                                      scalar const& lo,
                                      scalar const& lo_replace,
                                      scalar const& hi,
                                      scalar const& hi_replace,
                                      rmm::mr::device_memory_resource* mr);
 *
 * @param[in] stream Optional stream on which to issue all memory allocations
 */
std::unique_ptr<column> clamp(column_view const& input,
                              scalar const& lo,
                              scalar const& lo_replace,
                              scalar const& hi,
                              scalar const& hi_replace,
                              rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                              cudaStream_t stream = 0) {
    CUDF_EXPECTS(lo.type() == hi.type(), "mismatching types of limit scalars");
    CUDF_EXPECTS(lo_replace.type() == hi_replace.type(), "mismatching types of replace scalars");
    CUDF_EXPECTS(lo.type() == lo_replace.type(), "mismatching types of limit and replace scalars");
    CUDF_EXPECTS(lo.type() == input.type(), "mismatching types of scalar and input");

    if ((not lo.is_valid(stream) and not hi.is_valid(stream)) or 
        (input.is_empty())) {
        // There will be no change
        return std::make_unique<column>(input, stream, mr);
    }

    if (lo.is_valid(stream)) {
        CUDF_EXPECTS(lo_replace.is_valid(stream), "lo_replace can't be null");
    }
    if (hi.is_valid(stream)) {
        CUDF_EXPECTS(hi_replace.is_valid(stream), "hi_replace can't be null");
    }

    return cudf::experimental::type_dispatcher(input.type(), dispatch_clamp{},
                                               input, lo, lo_replace,
                                               hi, hi_replace,
                                               mr, stream);
}   

}// namespace detail

// clamp input at lo and hi with lo_replace and hi_replace
std::unique_ptr<column> clamp(column_view const& input,
                              scalar const& lo,
                              scalar const& lo_replace,
                              scalar const& hi,
                              scalar const& hi_replace,
                              rmm::mr::device_memory_resource* mr) {

    return detail::clamp(input, lo, lo_replace, hi, hi_replace, mr);
}

// clamp input at lo and hi
std::unique_ptr<column> clamp(column_view const& input,
                              scalar const& lo,
                              scalar const& hi,
                              rmm::mr::device_memory_resource* mr) {

    return detail::clamp(input, lo, lo, hi, hi, mr);
}
}// namespace experimental
}// namespace cudf
