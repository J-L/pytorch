# ---[ cuda

# Poor man's include guard
if(TARGET torch::cudart)
  return()
endif()

# We don't want to statically link cudart, because we rely on it's dynamic linkage in
# python (follow along torch/cuda/__init__.py and usage of cudaGetErrorName).
# Technically, we can link cudart here statically, and link libtorch_python.so
# to a dynamic libcudart.so, but that's just wasteful.
# However, on Windows, if this one gets switched off, the error "cuda: unknown error"
# will be raised when running the following code:
# >>> import torch
# >>> torch.cuda.is_available()
# >>> torch.cuda.current_device()
# More details can be found in the following links.
# https://github.com/pytorch/pytorch/issues/20635
# https://github.com/pytorch/pytorch/issues/17108
if(NOT MSVC)
  set(CUDA_USE_STATIC_CUDA_RUNTIME OFF CACHE INTERNAL "")
endif()

# We use our own versions of FindCUDA.cmake and FindCUDAToolkit.cmake
# to include some fixes for newer CUDA architectures and other issues.
set(old_CMAKE_MODULE_PATH "${CMAKE_MODULE_PATH}")
list(PREPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_LIST_DIR}/../Modules_CUDA_fix)
list(PREPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_LIST_DIR}/../Modules)

# Find CUDA.
find_package(CUDA)
if(NOT CUDA_FOUND)
  message(WARNING
    "Caffe2: CUDA cannot be found. Depending on whether you are building "
    "Caffe2 or a Caffe2 dependent library, the next warning / error will "
    "give you more info.")
  set(CAFFE2_USE_CUDA OFF)
  set(CMAKE_MODULE_PATH "${old_CMAKE_MODULE_PATH}")
  return()
endif()

# Enable CUDA language support
set(CUDAToolkit_ROOT "${CUDA_TOOLKIT_ROOT_DIR}")
# Pass clang as host compiler, which according to the docs
# Must be done before CUDA language is enabled, see
# https://cmake.org/cmake/help/v3.15/variable/CMAKE_CUDA_HOST_COMPILER.html
if("${CMAKE_CXX_COMPILER_ID}" MATCHES "Clang" AND NOT CMAKE_CUDA_HOST_COMPILER)
  set(CMAKE_CUDA_HOST_COMPILER "${CMAKE_CXX_COMPILER}")
endif()
enable_language(CUDA)
set(CMAKE_CUDA_STANDARD ${CMAKE_CXX_STANDARD})
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

# CMP0074 - find_package will respect <PackageName>_ROOT variables
cmake_policy(PUSH)
cmake_policy(SET CMP0074 NEW)

find_package(CUDAToolkit REQUIRED)
cmake_policy(POP)

if(NOT CMAKE_CUDA_COMPILER_VERSION STREQUAL CUDAToolkit_VERSION OR
    NOT CUDA_INCLUDE_DIRS STREQUAL CUDAToolkit_INCLUDE_DIR)
  message(FATAL_ERROR "Found two conflicting CUDA installs:\n"
                      "V${CMAKE_CUDA_COMPILER_VERSION} in '${CUDA_INCLUDE_DIRS}' and\n"
                      "V${CUDAToolkit_VERSION} in '${CUDAToolkit_INCLUDE_DIR}'")
endif()

if(NOT TARGET CUDA::nvToolsExt)
  message(FATAL_ERROR "Failed to find nvToolsExt")
endif()

message(STATUS "Caffe2: CUDA detected: " ${CUDA_VERSION})
message(STATUS "Caffe2: CUDA nvcc is: " ${CUDA_NVCC_EXECUTABLE})
message(STATUS "Caffe2: CUDA toolkit directory: " ${CUDA_TOOLKIT_ROOT_DIR})
if(CUDA_VERSION VERSION_LESS 11.0)
  message(FATAL_ERROR "PyTorch requires CUDA 11.0 or above.")
endif()

# Optionally, find TensorRT
if(CAFFE2_USE_TENSORRT)
  find_path(TENSORRT_INCLUDE_DIR NvInfer.h
    HINTS ${TENSORRT_ROOT} ${CUDA_TOOLKIT_ROOT_DIR}
    PATH_SUFFIXES include)
  find_library(TENSORRT_LIBRARY nvinfer
    HINTS ${TENSORRT_ROOT} ${CUDA_TOOLKIT_ROOT_DIR}
    PATH_SUFFIXES lib lib64 lib/x64)
  find_package_handle_standard_args(
    TENSORRT DEFAULT_MSG TENSORRT_INCLUDE_DIR TENSORRT_LIBRARY)
  if(TENSORRT_FOUND)
    execute_process(COMMAND /bin/sh -c "[ -r \"${TENSORRT_INCLUDE_DIR}/NvInferVersion.h\" ] && awk '/^\#define NV_TENSORRT_MAJOR/ {print $3}' \"${TENSORRT_INCLUDE_DIR}/NvInferVersion.h\"" OUTPUT_VARIABLE TENSORRT_VERSION_MAJOR)
    execute_process(COMMAND /bin/sh -c "[ -r \"${TENSORRT_INCLUDE_DIR}/NvInferVersion.h\" ] && awk '/^\#define NV_TENSORRT_MINOR/ {print $3}' \"${TENSORRT_INCLUDE_DIR}/NvInferVersion.h\"" OUTPUT_VARIABLE TENSORRT_VERSION_MINOR)
    if(TENSORRT_VERSION_MAJOR)
      string(STRIP ${TENSORRT_VERSION_MAJOR} TENSORRT_VERSION_MAJOR)
      string(STRIP ${TENSORRT_VERSION_MINOR} TENSORRT_VERSION_MINOR)
      set(TENSORRT_VERSION "${TENSORRT_VERSION_MAJOR}.${TENSORRT_VERSION_MINOR}")
      #CAFFE2_USE_TRT is set in Dependencies
      set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DTENSORRT_VERSION_MAJOR=${TENSORRT_VERSION_MAJOR}")
      set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DTENSORRT_VERSION_MINOR=${TENSORRT_VERSION_MINOR}")
    else()
      message(WARNING "Caffe2: Cannot find ${TENSORRT_INCLUDE_DIR}/NvInferVersion.h. Assuming TRT 5.0 which is no longer supported. Turning the option off.")
      set(CAFFE2_USE_TENSORRT OFF)
    endif()
  else()
    message(WARNING
      "Caffe2: Cannot find TensorRT library. Turning the option off.")
    set(CAFFE2_USE_TENSORRT OFF)
  endif()
endif()

# ---[ CUDA libraries wrapper

# find libcuda.so and lbnvrtc.so
# For libcuda.so, we will find it under lib, lib64, and then the
# stubs folder, in case we are building on a system that does not
# have cuda driver installed. On windows, we also search under the
# folder lib/x64.
set(CUDA_CUDA_LIB "${CUDA_cuda_driver_LIBRARY}" CACHE FILEPATH "")
set(CUDA_NVRTC_LIB "${CUDA_nvrtc_LIBRARY}" CACHE FILEPATH "")
if(CUDA_NVRTC_LIB AND NOT CUDA_NVRTC_SHORTHASH)
  if("${PYTHON_EXECUTABLE}" STREQUAL "")
    set(_python_exe "python")
  else()
    set(_python_exe "${PYTHON_EXECUTABLE}")
  endif()
  execute_process(
    COMMAND "${_python_exe}" -c
    "import hashlib;hash=hashlib.sha256();hash.update(open('${CUDA_NVRTC_LIB}','rb').read());print(hash.hexdigest()[:8])"
    RESULT_VARIABLE _retval
    OUTPUT_VARIABLE CUDA_NVRTC_SHORTHASH)
  if(NOT _retval EQUAL 0)
    message(WARNING "Failed to compute shorthash for libnvrtc.so")
    set(CUDA_NVRTC_SHORTHASH "XXXXXXXX")
  else()
    string(STRIP "${CUDA_NVRTC_SHORTHASH}" CUDA_NVRTC_SHORTHASH)
    message(STATUS "${CUDA_NVRTC_LIB} shorthash is ${CUDA_NVRTC_SHORTHASH}")
  endif()
endif()

# Create new style imported libraries.
# Several of these libraries have a hardcoded path if CAFFE2_STATIC_LINK_CUDA
# is set. This path is where sane CUDA installations have their static
# libraries installed. This flag should only be used for binary builds, so
# end-users should never have this flag set.

# cuda
add_library(caffe2::cuda INTERFACE IMPORTED)
target_link_libraries(caffe2::cuda INTERFACE CUDA::cuda_driver)

# cudart
add_library(torch::cudart INTERFACE IMPORTED)
if(CAFFE2_STATIC_LINK_CUDA)
  target_link_libraries(torch::cudart INTERFACE CUDA::cudart_static)
else()
  target_link_libraries(torch::cudart INTERFACE CUDA::cudart)
endif()

# nvToolsExt
add_library(torch::nvtoolsext INTERFACE IMPORTED)
set_property(
    TARGET torch::nvtoolsext PROPERTY INTERFACE_LINK_LIBRARIES
    CUDA::nvToolsExt)

# cublas
add_library(caffe2::cublas INTERFACE IMPORTED)
if(CAFFE2_STATIC_LINK_CUDA AND NOT WIN32)
    set_property(
        TARGET caffe2::cublas PROPERTY INTERFACE_LINK_LIBRARIES
        # NOTE: cublas is always linked dynamically
        CUDA::cublas CUDA::cublasLt)
    set_property(
        TARGET caffe2::cublas APPEND PROPERTY INTERFACE_LINK_LIBRARIES
        CUDA::cudart_static rt)
else()
    set_property(
        TARGET caffe2::cublas PROPERTY INTERFACE_LINK_LIBRARIES
        CUDA::cublas CUDA::cublasLt)
endif()

# cudnn interface
# static linking is handled by USE_STATIC_CUDNN environment variable
if(CAFFE2_USE_CUDNN)
  if(USE_STATIC_CUDNN)
    set(CUDNN_STATIC ON CACHE BOOL "")
  else()
    set(CUDNN_STATIC OFF CACHE BOOL "")
  endif()

  find_package(CUDNN)

  if(NOT CUDNN_FOUND)
    message(WARNING
      "Cannot find cuDNN library. Turning the option off")
    set(CAFFE2_USE_CUDNN OFF)
  else()
    if(CUDNN_VERSION VERSION_LESS "8.0.0")
      message(FATAL_ERROR "PyTorch requires cuDNN 8 and above.")
    endif()
  endif()

  add_library(torch::cudnn INTERFACE IMPORTED)
  target_include_directories(torch::cudnn INTERFACE ${CUDNN_INCLUDE_PATH})
  if(CUDNN_STATIC AND NOT WIN32)
    target_link_options(torch::cudnn INTERFACE
        "-Wl,--exclude-libs,libcudnn_static.a")
  else()
    target_link_libraries(torch::cudnn INTERFACE ${CUDNN_LIBRARY_PATH})
  endif()
else()
  message(STATUS "USE_CUDNN is set to 0. Compiling without cuDNN support")
endif()

# curand
add_library(caffe2::curand INTERFACE IMPORTED)
if(CAFFE2_STATIC_LINK_CUDA AND NOT WIN32)
    target_link_libraries(caffe2::curand INTERFACE CUDA::curand_static)
else()
    target_link_libraries(caffe2::curand INTERFACE CUDA::curand)
endif()

# cufft
add_library(caffe2::cufft INTERFACE IMPORTED)
if(CAFFE2_STATIC_LINK_CUDA AND NOT WIN32)
    target_link_libraries(caffe2::cufft INTERFACE CUDA::cufft_static_nocallback)
else()
    target_link_libraries(caffe2::cufft INTERFACE CUDA::cufft)
endif()

# TensorRT
if(CAFFE2_USE_TENSORRT)
  add_library(caffe2::tensorrt UNKNOWN IMPORTED)
  set_property(
      TARGET caffe2::tensorrt PROPERTY IMPORTED_LOCATION
      ${TENSORRT_LIBRARY})
  set_property(
      TARGET caffe2::tensorrt PROPERTY INTERFACE_INCLUDE_DIRECTORIES
      ${TENSORRT_INCLUDE_DIR})
endif()

# nvrtc
add_library(caffe2::nvrtc INTERFACE IMPORTED)
target_link_libraries(caffe2::nvrtc INTERFACE CUDA::nvrtc)

# Add onnx namepsace definition to nvcc
if(ONNX_NAMESPACE)
  list(APPEND CUDA_NVCC_FLAGS "-DONNX_NAMESPACE=${ONNX_NAMESPACE}")
else()
  list(APPEND CUDA_NVCC_FLAGS "-DONNX_NAMESPACE=onnx_c2")
endif()

# Don't activate VC env again for Ninja generators with MSVC on Windows if CUDAHOSTCXX is not defined
# by adding --use-local-env.
if(MSVC AND CMAKE_GENERATOR STREQUAL "Ninja" AND NOT DEFINED ENV{CUDAHOSTCXX})
  list(APPEND CUDA_NVCC_FLAGS "--use-local-env")
endif()

# setting nvcc arch flags
torch_cuda_get_nvcc_gencode_flag(NVCC_FLAGS_EXTRA)
# CMake 3.18 adds integrated support for architecture selection, but we can't rely on it
set(CMAKE_CUDA_ARCHITECTURES OFF)
list(APPEND CUDA_NVCC_FLAGS ${NVCC_FLAGS_EXTRA})
message(STATUS "Added CUDA NVCC flags for: ${NVCC_FLAGS_EXTRA}")

# disable some nvcc diagnostic that appears in boost, glog, glags, opencv, etc.
foreach(diag cc_clobber_ignored integer_sign_change useless_using_declaration
             set_but_not_used field_without_dll_interface
             base_class_has_different_dll_interface
             dll_interface_conflict_none_assumed
             dll_interface_conflict_dllexport_assumed
             implicit_return_from_non_void_function
             unsigned_compare_with_zero
             declared_but_not_referenced
             bad_friend_decl)
  list(APPEND SUPPRESS_WARNING_FLAGS --diag_suppress=${diag})
endforeach()
string(REPLACE ";" "," SUPPRESS_WARNING_FLAGS "${SUPPRESS_WARNING_FLAGS}")
list(APPEND CUDA_NVCC_FLAGS -Xcudafe ${SUPPRESS_WARNING_FLAGS})

set(CUDA_PROPAGATE_HOST_FLAGS_BLOCKLIST "-Werror")
if(MSVC)
  list(APPEND CUDA_NVCC_FLAGS "--Werror" "cross-execution-space-call")
  list(APPEND CUDA_NVCC_FLAGS "--no-host-device-move-forward")
endif()

# Debug and Release symbol support
if(MSVC)
  if(${CAFFE2_USE_MSVC_STATIC_RUNTIME})
    string(APPEND CMAKE_CUDA_FLAGS_DEBUG " -Xcompiler /MTd")
    string(APPEND CMAKE_CUDA_FLAGS_MINSIZEREL " -Xcompiler /MT")
    string(APPEND CMAKE_CUDA_FLAGS_RELEASE " -Xcompiler /MT")
    string(APPEND CMAKE_CUDA_FLAGS_RELWITHDEBINFO " -Xcompiler /MT")
  else()
    string(APPEND CMAKE_CUDA_FLAGS_DEBUG " -Xcompiler /MDd")
    string(APPEND CMAKE_CUDA_FLAGS_MINSIZEREL " -Xcompiler /MD")
    string(APPEND CMAKE_CUDA_FLAGS_RELEASE " -Xcompiler /MD")
    string(APPEND CMAKE_CUDA_FLAGS_RELWITHDEBINFO " -Xcompiler /MD")
  endif()
  if(CUDA_NVCC_FLAGS MATCHES "Zi")
    list(APPEND CUDA_NVCC_FLAGS "-Xcompiler" "-FS")
  endif()
elseif(CUDA_DEVICE_DEBUG)
  list(APPEND CUDA_NVCC_FLAGS "-g" "-G")  # -G enables device code debugging symbols
endif()

# Set expt-relaxed-constexpr to suppress Eigen warnings
list(APPEND CUDA_NVCC_FLAGS "--expt-relaxed-constexpr")

# Set expt-extended-lambda to support lambda on device
list(APPEND CUDA_NVCC_FLAGS "--expt-extended-lambda")

foreach(FLAG ${CUDA_NVCC_FLAGS})
  string(FIND "${FLAG}" " " flag_space_position)
  if(NOT flag_space_position EQUAL -1)
    message(FATAL_ERROR "Found spaces in CUDA_NVCC_FLAGS entry '${FLAG}'")
  endif()
  string(APPEND CMAKE_CUDA_FLAGS " ${FLAG}")
endforeach()

set(CMAKE_MODULE_PATH "${old_CMAKE_MODULE_PATH}")
