#!/bin/sh

SHADERS_SRC="./src/render/shaders/glsl"
SHADERS_OUTPUT="${1:?shader output directory is required}"

echo "-- Generating shader includes"

mkdir -p "${SHADERS_OUTPUT}"

echo '#pragma once' > "${SHADERS_OUTPUT}/Shaders.hpp"
echo '#include <map>' >> "${SHADERS_OUTPUT}/Shaders.hpp"
echo 'static const std::map<std::string, std::string> SHADERS = {' >> "${SHADERS_OUTPUT}/Shaders.hpp"

for filename in `ls ${SHADERS_SRC}`; do
	echo "--	${filename}"
	
	{ echo -n 'R"#('; cat "${SHADERS_SRC}/${filename}"; echo ')#"'; } > "${SHADERS_OUTPUT}/${filename}.inc"
	echo "{\"${filename}\"," >> "${SHADERS_OUTPUT}/Shaders.hpp"
	echo "#include \"./${filename}.inc\"" >> "${SHADERS_OUTPUT}/Shaders.hpp"
	echo "}," >> "${SHADERS_OUTPUT}/Shaders.hpp"
done

echo '};' >> "${SHADERS_OUTPUT}/Shaders.hpp"
