cmake_minimum_required(VERSION 3.22)
project(ocr_cli CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../native/ocr_shim ocr_shim)

add_executable(ocr_cli main.cpp)
target_link_libraries(ocr_cli PRIVATE ocr_shim)
