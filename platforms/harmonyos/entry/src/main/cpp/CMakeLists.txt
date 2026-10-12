cmake_minimum_required(VERSION 3.10)
project(liana_napi)
add_library(liana SHARED napi_shim.cpp)
target_include_directories(liana PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../crates/ffi/include)
# Rust 静态库由 build_ohos.sh 预先放到 libs/<abi>/libliana_ffi.a
target_link_libraries(liana
    ${CMAKE_CURRENT_SOURCE_DIR}/libs/${OHOS_ARCH}/libliana_ffi.a)