get_property(LLVM_INSTALL_DIR GLOBAL PROPERTY LLVM_INSTALL_DIR)
set(LLVM_INSTALL_DIR ${THIRD_PARTY_DIR}/llvm)
set(LLVM_DIR ${LLVM_INSTALL_DIR}/lib/cmake/llvm)
set(ONEFLOW_OP_GROUPS
    "ASSIGN"
    "BINARY"
    "BROADCAST"
    "CONV"
    "CROSS_ENTROPY"
    "CUDA"
    "DATASET"
    "DETECTION"
    "EAGER"
    "FUSED"
    "IDEMPOTENT"
    "IDENTITY"
    "IMAGE"
    "INDICES"
    "INVOLUTION"
    "LOSS"
    "MATH"
    "MATMUL"
    "MISC"
    "NCCL"
    "NORMALIZATION"
    "OPTIMIZER"
    "PADDING"
    "PARALLEL_CAST"
    "POOL"
    "QUANTIZATION"
    "REDUCE"
    "RESHAPE"
    "SCALAR"
    "SOFTMAX"
    "SUMMARY"
    "TENSOR_BUFFER"
    "TEST"
    "TRIGONOMETRIC"
    "UNARY"
    "UPSAMPLE")
foreach(OP_GROUP_NAME IN LISTS ONEFLOW_OP_GROUPS)
  list(APPEND ONEFLOW_SCHEMA_TABLEGEN_FLAGS "-DGET_ONEFLOW_${OP_GROUP_NAME}_OP_DEFINITIONS")
endforeach()
list(APPEND ONEFLOW_SCHEMA_TABLEGEN_FLAGS "-DREMOVE_ONEFLOW_MLIR_ONLY_OP_DEFINITIONS")

set(GENERATED_OP_SCHEMA_DIR oneflow/core/framework)
set(GENERATED_IR_INCLUDE_DIR oneflow/ir/include)
set(SOURCE_IR_INCLUDE_DIR ${PROJECT_SOURCE_DIR}/oneflow/ir/include)
set(ONEFLOW_ODS ${SOURCE_IR_INCLUDE_DIR}/OneFlow/OneFlowOps.td)

list(APPEND ONEFLOW_SCHEMA_TABLEGEN_FLAGS "-I${GENERATED_IR_INCLUDE_DIR}")
list(APPEND ONEFLOW_SCHEMA_TABLEGEN_FLAGS "-I${SOURCE_IR_INCLUDE_DIR}")
list(APPEND ONEFLOW_SCHEMA_TABLEGEN_FLAGS "-I${LLVM_INSTALL_DIR}/include")

set(GENERATED_OP_SCHEMA_H "${GENERATED_OP_SCHEMA_DIR}/op_generated.h")
set(GENERATED_OP_SCHEMA_CPP "${GENERATED_OP_SCHEMA_DIR}/op_generated.cpp")

set(ONEFLOW_TABLE_GEN_EXE ${LLVM_INSTALL_DIR}/bin/oneflow_tblgen)
if(LLVM_PROVIDER STREQUAL "in-tree")
  set(ONEFLOW_TABLE_GEN_TARGET oneflow_tblgen install-oneflow-tblgen install-mlir-headers)
elseif(LLVM_PROVIDER STREQUAL "install")
  set(ONEFLOW_TABLE_GEN_TARGET ${ONEFLOW_TABLE_GEN_EXE})
endif()

file(GLOB_RECURSE ODS_FILES LIST_DIRECTORIES false "${SOURCE_IR_INCLUDE_DIR}/*.td")
if(NOT ODS_FILES)
  message(FATAL_ERROR "ODS_FILES not found: ${ODS_FILES}")
endif()
add_custom_command(
  OUTPUT ${GENERATED_OP_SCHEMA_H} ${GENERATED_OP_SCHEMA_CPP}
  COMMAND ${CMAKE_COMMAND} ARGS -E make_directory ${GENERATED_OP_SCHEMA_DIR}
  COMMAND ${ONEFLOW_TABLE_GEN_EXE} ARGS --gen-op-schema-h ${ONEFLOW_ODS}
          ${ONEFLOW_SCHEMA_TABLEGEN_FLAGS} -o ${GENERATED_OP_SCHEMA_H}
  COMMAND ${ONEFLOW_TABLE_GEN_EXE} ARGS --gen-op-schema-cpp ${ONEFLOW_ODS}
          ${ONEFLOW_SCHEMA_TABLEGEN_FLAGS} --op-include ${GENERATED_OP_SCHEMA_H} -o
          ${GENERATED_OP_SCHEMA_CPP}
  DEPENDS ${ONEFLOW_TABLE_GEN_TARGET} ${ODS_FILES}
  VERBATIM)
set_source_files_properties(${GENERATED_OP_SCHEMA_H} ${GENERATED_OP_SCHEMA_CPP} PROPERTIES GENERATED
                                                                                           TRUE)

oneflow_add_library(of_op_schema OBJECT ${GENERATED_OP_SCHEMA_H} ${GENERATED_OP_SCHEMA_CPP})
target_link_libraries(of_op_schema glog::glog)
add_dependencies(of_op_schema of_cfgobj)
add_dependencies(of_op_schema prepare_oneflow_third_party)
