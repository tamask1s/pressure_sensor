idf_component_register(SRCS "main.cpp" "hardware.cpp" "radio.cpp"
  INCLUDE_DIRS "."
  REQUIRES bt nvs_flash esp_driver_gpio esp_driver_i2c esp_driver_spi esp_adc fatfs esp_timer esp_hw_support cjson mbedtls)
target_compile_features(${COMPONENT_LIB} PUBLIC cxx_std_17)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Wno-missing-field-initializers)
