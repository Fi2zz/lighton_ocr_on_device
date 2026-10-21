cmake_minimum_required(VERSION 3.22)
project(lightonocr_app CXX C)

# Flutter's debug native build defaults to -O0. llama.cpp at -O0 is ~10-50x
# slower, which made a 300-token vision encode take minutes on device.
set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -O3")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -O3")
set(CMAKE_ASM_FLAGS_DEBUG "${CMAKE_ASM_FLAGS_DEBUG} -O3")

add_subdirectory(
  ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/ocr_shim
  ocr_shim)
