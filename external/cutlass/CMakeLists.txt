include(FetchContent)
FetchContent_Declare(
        cutlass
        URL ${CUTLASS_URL}
        URL_HASH MD5=${CUTLASS_MD5}
)
FetchContent_Populate(cutlass)

add_library(cutlass_headers INTERFACE)
# list(APPEND cutlass_interface_headers ${cutlass_SOURCE_DIR}/include)
# list(APPEND cutlass_interface_headers ${cutlass_SOURCE_DIR}/tools/util/include/)
set_property(TARGET cutlass_headers PROPERTY INTERFACE_INCLUDE_DIRECTORIES
  $<BUILD_INTERFACE:${cutlass_SOURCE_DIR}/include;${cutlass_SOURCE_DIR}/tools/util/include/>
  $<INSTALL_INTERFACE:include>
)
add_library(cutlass_fmha_headers INTERFACE)
set_property(TARGET cutlass_fmha_headers PROPERTY INTERFACE_INCLUDE_DIRECTORIES
  $<BUILD_INTERFACE:${cutlass_SOURCE_DIR}/examples/41_fused_multi_head_attention>
  $<INSTALL_INTERFACE:include>
)
add_library(cutlass_dual_gemm_headers INTERFACE)
set_property(TARGET cutlass_dual_gemm_headers PROPERTY INTERFACE_INCLUDE_DIRECTORIES
  $<BUILD_INTERFACE:${cutlass_SOURCE_DIR}/examples/45_dual_gemm>
  $<INSTALL_INTERFACE:include>
)

install(TARGETS cutlass_headers;cutlass_fmha_headers;cutlass_dual_gemm_headers EXPORT oneflow DESTINATION include)
