cmake_minimum_required(VERSION 3.22)
project(lightonocr_app CXX C)

add_subdirectory(
  ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/ocr_shim
  ocr_shim)
